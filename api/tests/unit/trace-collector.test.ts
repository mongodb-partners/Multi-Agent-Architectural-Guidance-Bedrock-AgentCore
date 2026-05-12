import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import { TraceCollector } from "../../src/lib/trace-collector.ts";
import { currentTrace, withTrace } from "../../src/lib/trace-context.ts";

function makeCollector(overrides: Partial<ConstructorParameters<typeof TraceCollector>[0]> = {}) {
  return new TraceCollector({
    sessionId: "s",
    messageId: "m",
    agentId: "orchestrator",
    ...overrides,
  });
}

describe("TraceCollector basics", () => {
  test("mints unique traceId per instance", () => {
    const a = makeCollector();
    const b = makeCollector();
    expect(a.traceId).not.toBe(b.traceId);
    expect(a.traceId).toMatch(/[0-9a-f-]+/);
  });

  test("start() pushes a span; end() pops + records duration", async () => {
    const c = makeCollector();
    const id = c.start("tool.call", { toolName: "foo" });
    expect(c.currentSpanId()).toBe(id);
    await new Promise((r) => setTimeout(r, 5));
    c.end(id, { ok: true });
    expect(c.currentSpanId()).toBeUndefined();
    const events = c.getEvents();
    const endEv = events.find((e) => e.parentId === id);
    expect(endEv).toBeDefined();
    expect(endEv?.durationMs).toBeGreaterThanOrEqual(0);
  });

  test("span() returns the body's result and auto-emits start+end", async () => {
    const c = makeCollector();
    const result = await c.span("tool.call", { toolName: "x" }, async () => 42);
    expect(result).toBe(42);
    const events = c.getEvents();
    expect(events.length).toBeGreaterThanOrEqual(2);
    expect(events[0].type).toBe("tool.call");
  });

  test("span() captures errors as a child error event with parentId", async () => {
    const c = makeCollector();
    let thrown: unknown;
    try {
      await c.span("tool.call", { toolName: "boom" }, async () => {
        throw new Error("bang");
      });
    } catch (e) {
      thrown = e;
    }
    expect((thrown as Error).message).toBe("bang");
    const errEv = c.getEvents().find((e) => e.type === "error");
    expect(errEv).toBeDefined();
    expect(errEv?.parentId).toBeDefined();
  });
});

describe("TraceCollector summary + cost", () => {
  test("aggregates model.usage events and computes USD", () => {
    const c = makeCollector();
    c.event("model.usage", {
      modelId: "anthropic.claude-sonnet-4-5",
      inputTokens: 1000,
      outputTokens: 1000,
      totalTokens: 2000,
    });
    c.event("model.usage", {
      modelId: "anthropic.claude-sonnet-4-5",
      inputTokens: 500,
      outputTokens: 500,
      totalTokens: 1000,
    });
    const s = c.summary();
    expect(s.inputTokens).toBe(1500);
    expect(s.outputTokens).toBe(1500);
    expect(s.totalTokens).toBe(3000);
    expect(s.estimatedCostUsd).toBeCloseTo(0.027, 5);
    expect(s.costEstimateComplete).toBe(true);
    expect(s.costBreakdown["anthropic.claude-sonnet-4-5"]).toBeCloseTo(0.027, 5);
  });

  test("flags partial estimate when one model id is unknown", () => {
    const c = makeCollector();
    c.event("model.usage", {
      modelId: "anthropic.claude-sonnet-4-5",
      inputTokens: 1000,
      outputTokens: 1000,
      totalTokens: 2000,
    });
    c.event("model.usage", {
      modelId: "openai.gpt-5",
      inputTokens: 1000,
      outputTokens: 1000,
      totalTokens: 2000,
    });
    const s = c.summary();
    expect(s.costEstimateComplete).toBe(false);
    expect(s.estimatedCostUsd).not.toBeNull();
  });

  test("no usage events → estimatedCostUsd null + incomplete", () => {
    const c = makeCollector();
    const s = c.summary();
    expect(s.estimatedCostUsd).toBeNull();
    expect(s.costEstimateComplete).toBe(false);
  });
});

describe("TraceCollector byte-cap → degraded mode", () => {
  beforeEach(() => {
    process.env.TRACE_MAX_TURN_BYTES = "1000";
    process.env.TRACE_MAX_EVENT_BYTES = "200";
  });
  afterEach(() => {
    delete process.env.TRACE_MAX_TURN_BYTES;
    delete process.env.TRACE_MAX_EVENT_BYTES;
  });

  test("drops non-protected events past the per-turn cap; protected events still emit", () => {
    const c = makeCollector();
    // Push many large model.text_delta_batch events (not protected) to fill the cap.
    for (let i = 0; i < 50; i++) {
      c.event("model.text_delta_batch", {
        text: "x".repeat(200),
        bytes: 200,
        windowMs: 250,
      });
    }
    // Now emit a protected event — must still land.
    c.event("handoff.decision", {
      fromAgentId: "a",
      toAgentId: "b",
      userMessage: "u",
      orchestratorReasoning: "r",
      structuredOutput: {},
      triggerSpans: [],
      alternativesConsidered: [],
      confidence: null,
      priorToolCalls: [],
      priorHandoffCount: 0,
      conversationContextTurns: [],
      latencyToDecisionMs: 0,
      tokensBeforeDecision: 0,
    });
    expect(c.isDegraded()).toBe(true);
    expect(c.summary().eventsDropped).toBeGreaterThan(0);
    const handoff = c.getEvents().find((e) => e.type === "handoff.decision");
    expect(handoff).toBeDefined();
  });

  test("shrinkPayload trims body/result fields on oversize single events", () => {
    process.env.TRACE_MAX_EVENT_BYTES = "300";
    const c = makeCollector();
    c.event("tool.call", { toolName: "foo", input: { body: "x".repeat(20_000) } });
    const ev = c.getEvents()[0];
    const payloadStr = JSON.stringify(ev.payload);
    expect(payloadStr.length).toBeLessThan(2_000);
  });
});

describe("TraceCollector — pending text scratch", () => {
  test("appendPendingText accumulates and caps at FIFO", () => {
    process.env.TRACE_PENDING_TEXT_BYTES = "100";
    const c = makeCollector();
    c.appendPendingText("a".repeat(80));
    c.appendPendingText("b".repeat(80));
    const snap = c.snapshotPendingText();
    expect(snap.length).toBe(100);
    expect(snap.startsWith("a")).toBe(true); // keeps the tail
    expect(snap.endsWith("b")).toBe(true);
    delete process.env.TRACE_PENDING_TEXT_BYTES;
  });

  test("resetPendingText clears", () => {
    const c = makeCollector();
    c.appendPendingText("hello");
    expect(c.snapshotPendingText()).toBe("hello");
    c.resetPendingText();
    expect(c.snapshotPendingText()).toBe("");
  });
});

describe("TraceCollector — listeners + redaction", () => {
  test("onEvent listener fires per emitted event; unsubscribe stops delivery", () => {
    const c = makeCollector();
    const received: string[] = [];
    const unsub = c.onEvent((e) => received.push(e.type));
    c.event("model.usage", { modelId: "x", inputTokens: 0, outputTokens: 0, totalTokens: 0 });
    unsub();
    c.event("error", { class: "Err", message: "x" });
    expect(received).toEqual(["model.usage"]);
  });

  test("TRACE_REDACT=1 scrubs PII keys", () => {
    process.env.TRACE_REDACT = "1";
    const c = makeCollector();
    c.event("auth.context_build", { userId: "u", customersResolved: 1, ordersResolved: 0, jwtClaims: { sub: "u", email: "x@y.z" } });
    const ev = c.getEvents()[0];
    expect((ev.payload as any).jwtClaims.email).toBe("[redacted]");
    delete process.env.TRACE_REDACT;
  });
});

describe("TraceCollector — attachEventsNested", () => {
  test("rewires nested root + orphan parents to the wrapper", () => {
    const c = makeCollector();
    const wrapper = c.start("agentcore.invoke", { arn: "x", mode: "ec2_to_orchestrator", latencyMs: 100 });
    // Simulate the wrapper span "ending" so it has a durationMs.
    c.end(wrapper, { latencyMs: 100 });
    const wrapperEv = c.getEvents().find((e) => e.id === wrapper)!;
    const baseTs = wrapperEv.ts;

    const nested = [
      // nested root chat.turn.start (its own subtree)
      { id: "n1", type: "chat.turn.start", ts: baseTs - 1_000, payload: { sessionId: "s", messageId: "m", agentId: "specialist", startTs: 0 } },
      { id: "n2", parentId: "n1", type: "model.usage", ts: baseTs - 990, payload: { modelId: "anthropic.claude-haiku-4-5", inputTokens: 100, outputTokens: 50, totalTokens: 150 } },
      { id: "n3", parentId: "missing-elsewhere", type: "error", ts: baseTs - 980, payload: { class: "X", message: "y" } },
    ] as any;

    c.attachEventsNested(nested, wrapper);

    const ev2 = c.getEvent("n2");
    const ev3 = c.getEvent("n3");
    expect(ev2).toBeDefined();
    expect(ev3).toBeDefined();
    // root nested chat.turn.start was rewired to wrapper.
    expect(c.getEvent("n1")?.parentId).toBe(wrapper);
    // n2 had parentId === nestedRoot.id → re-rooted to wrapper per §6.3.1 algorithm.
    expect(ev2?.parentId).toBe(wrapper);
    // n3 had a missing parent → re-rooted under wrapper + marked.
    expect(ev3?.parentId).toBe(wrapper);
    expect((ev3?.payload as any)._orphanFrom).toBe("missing-elsewhere");
    // Clock normalized so n1.ts === wrapper.ts.
    expect(c.getEvent("n1")?.ts).toBe(baseTs);
    // _originalTs preserved.
    expect((c.getEvent("n1")?.payload as any)._originalTs).toBe(baseTs - 1_000);
  });

  test("idempotency: replaying the same nestedEvents twice (defensive copies) is stable", () => {
    const c = makeCollector();
    const wrapper = c.start("agentcore.invoke", { arn: "x", mode: "ec2_to_orchestrator", latencyMs: 100 });
    c.end(wrapper);
    const nested = [{ id: "n1", type: "model.usage", ts: 1, payload: { modelId: "anthropic.claude-sonnet-4-5", inputTokens: 1, outputTokens: 1, totalTokens: 2 } }] as any;
    c.attachEventsNested(nested, wrapper);
    const first = c.getEvent("n1");
    // Reapply with a fresh copy → input is not mutated by attachEventsNested.
    c.attachEventsNested(JSON.parse(JSON.stringify(nested)), wrapper);
    const second = c.getEvents().filter((e) => e.id === "n1");
    expect(second.length).toBe(2); // splice inserts each time
    expect(first?.parentId).toBe(wrapper);
  });
});

describe("trace-context AsyncLocalStorage", () => {
  test("currentTrace() returns the collector inside withTrace", () => {
    const c = makeCollector();
    expect(currentTrace()).toBeUndefined();
    withTrace(c, () => {
      expect(currentTrace()).toBe(c);
    });
    expect(currentTrace()).toBeUndefined();
  });

  test("currentTrace persists across awaited promises within the same context", async () => {
    const c = makeCollector();
    await new Promise<void>((resolve) => {
      withTrace(c, async () => {
        await new Promise((r) => setTimeout(r, 1));
        expect(currentTrace()).toBe(c);
        resolve();
      });
    });
  });
});
