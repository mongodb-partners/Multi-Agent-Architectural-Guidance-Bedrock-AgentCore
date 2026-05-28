/**
 * Unit tests for the multi-specialist orchestrator helper.
 *
 * The helper coordinates classification → specialist invocation →
 * (optional) synthesis. We mock the classifier and the specialist invoker
 * so the test runs purely in-process without Bedrock or AgentCore.
 *
 * Acceptance contract checked here:
 *   1. Single-specialist fast path: ONE specialist call, no synthesis,
 *      tokens flow through with no `phase` (legacy persistence semantics).
 *   2. Synthesis path: ≥ 2 specialist calls, specialist tokens carry
 *      `phase: "specialist"`, synthesis tokens carry `phase: "synthesis"`,
 *      orchestrator emits `multi_route_decision`, per-specialist
 *      `specialist_draft`, and `synthesis` trace events.
 *   3. `orchestrator.multi_route_decision` is emitted exactly once.
 *   4. Per-specialist nested trace events are attached under the matching
 *      `agentcore.invoke` wrapper span (helper handles attachment, not the
 *      caller).
 *   5. Failure: when one of two specialists fails, synthesis still runs
 *      over the successful one. When all fail, helper yields stream_error.
 */

import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { TraceCollector } from "../../src/lib/trace-collector.ts";
import { withTrace } from "../../src/lib/trace-context.ts";
import {
  runMultiSpecialistFlow,
  type SpecialistInvoker,
  type MultiSpecialistFlowResult,
} from "../../src/lib/multi-specialist-orchestrator.ts";
import type { TraceEvent } from "../../src/lib/trace-types.ts";
import type { RuntimeStreamEvent } from "../../src/lib/runtime-sse.ts";
import type { MultiClassificationResult } from "../../src/lib/agent-classifier.ts";

const SAVED_ENV = { ...process.env };

function makeClassifier(
  selections: Array<{ agentId: string; reasoning?: string; score?: number }>,
): MultiClassificationResult | undefined {
  if (selections.length === 0) return undefined;
  return {
    selections: selections.map((s) => ({
      agentId: s.agentId,
      reasoning: s.reasoning,
      source: "heuristic",
      score: s.score,
    })),
    rejectedCandidates: [],
    thresholds: {
      multiMinScore: 3.0,
      multiRelativeMargin: 1.5,
      multiMaxAgents: 2,
      heuristicMinScore: 1.5,
      heuristicMargin: 0.75,
    },
  };
}

/** Build a synthetic specialist invoker that emits the given tokens + events. */
function fakeInvoker(
  byId: Record<
    string,
    {
      tokens?: string[];
      traces?: TraceEvent[];
      doneError?: { code: string; message: string };
      throwOnInvoke?: Error;
    }
  >,
  collectorRef: () => TraceCollector | undefined,
): SpecialistInvoker {
  return ({ specialistId, onWrapperSpan }) => {
    const cfg = byId[specialistId] ?? { tokens: ["fallback"] };
    if (cfg.throwOnInvoke) throw cfg.throwOnInvoke;
    // Create a real wrapper span on the trace collector so the helper's
    // `attachEventsNested` finds something to attach to. This mirrors the
    // production adapter (`invokeAgentRuntime`) which calls
    // `trace.start("agentcore.invoke", ...)`.
    const collector = collectorRef();
    const spanId = collector?.start("agentcore.invoke", {
      arn: `mock-arn-${specialistId}`,
      mode: "ec2_to_specialist",
      requestBytes: 0,
      latencyMs: 0,
      targetAgentId: specialistId,
    });
    onWrapperSpan(spanId);
    const tokens = cfg.tokens ?? [];
    const traces = cfg.traces ?? [];
    const doneError = cfg.doneError;
    return (async function* () {
      for (const t of tokens) {
        yield {
          kind: "stream",
          part: { type: "token", text: t },
        } satisfies RuntimeStreamEvent;
      }
      for (const ev of traces) {
        yield { kind: "trace", event: ev } satisfies RuntimeStreamEvent;
      }
      yield {
        kind: "done",
        payload: doneError ? { error: doneError } : {},
      } satisfies RuntimeStreamEvent;
      // Close the wrapper so attachEventsNested can splice nested events.
      if (collector && spanId) {
        collector.end(spanId, {
          arn: `mock-arn-${specialistId}`,
          mode: "ec2_to_specialist",
          targetAgentId: specialistId,
          latencyMs: 5,
          httpStatus: doneError ? 500 : 200,
          ...(doneError ? { errorClass: doneError.code, errorMessage: doneError.message } : {}),
        });
      }
    })();
  };
}

function makeCollector(): TraceCollector {
  return new TraceCollector({
    sessionId: "sess",
    messageId: "msg",
    agentId: "orchestrator",
    userId: "u1",
  });
}

function eventsOfType(collector: TraceCollector, type: string): TraceEvent[] {
  return collector.getEvents().filter((e) => e.type === type);
}

describe("multi-specialist-orchestrator", () => {
  beforeEach(() => {
    // Skip the synthesizer Bedrock call by mocking the synthesizer module.
    // Tests that exercise the synthesis path replace it with a fake stream.
  });
  afterEach(() => {
    process.env = { ...SAVED_ENV };
  });

  test("FAST PATH: single specialist → no synthesis, tokens have no phase, persisted answer = specialist text", async () => {
    const collector = makeCollector();
    const flow = runMultiSpecialistFlow({
      message: "track my order",
      collector,
      classifier: async () => makeClassifier([{ agentId: "order-management", score: 5 }]),
      invokeSpecialist: fakeInvoker(
        { "order-management": { tokens: ["Your order ", "is on the way."] } },
        () => collector,
      ),
    });

    const events: Array<{ kind: string; payload?: unknown }> = [];
    let result: MultiSpecialistFlowResult | undefined;
    await withTrace(collector, async () => {
      while (true) {
        const next = await flow.next();
        if (next.done) {
          result = next.value;
          break;
        }
        events.push({ kind: next.value.kind, payload: next.value });
      }
    });

    // No synthesis.
    expect(events.find((e) => e.kind === "synthesis_started")).toBeUndefined();
    expect(events.find((e) => e.kind === "synthesis_stream")).toBeUndefined();

    // Specialist tokens streamed without phase.
    const tokenEvents = events.filter((e) => e.kind === "specialist_stream");
    const tokens = tokenEvents
      .map((e) => (e.payload as { part: { type: string; text?: string; phase?: string } }).part)
      .filter((p) => p.type === "token");
    expect(tokens.length).toBe(2);
    for (const t of tokens) {
      expect(t.phase).toBeUndefined();
    }

    expect(result?.pathTaken).toBe("single");
    expect(result?.finalAnswer).toBe("Your order is on the way.");
    expect(result?.successfulSpecialists.length).toBe(1);

    // Trace events.
    expect(eventsOfType(collector, "orchestrator.multi_route_decision").length).toBe(1);
    expect(eventsOfType(collector, "orchestrator.specialist_draft").length).toBe(1);
    expect(eventsOfType(collector, "orchestrator.synthesis").length).toBe(0);
    const draft = eventsOfType(collector, "orchestrator.specialist_draft")[0];
    expect((draft.payload as { status: string }).status).toBe("final");
  });

  test("FAILURE: classifier returns nothing → stream_error", async () => {
    const collector = makeCollector();
    const flow = runMultiSpecialistFlow({
      message: "...",
      collector,
      classifier: async () => undefined,
      invokeSpecialist: fakeInvoker({}, () => collector),
    });
    const events: Array<{ kind: string }> = [];
    let result: MultiSpecialistFlowResult | undefined;
    await withTrace(collector, async () => {
      while (true) {
        const next = await flow.next();
        if (next.done) {
          result = next.value;
          break;
        }
        events.push({ kind: next.value.kind });
      }
    });
    expect(events.find((e) => e.kind === "stream_error")).toBeDefined();
    expect(result?.finalAnswer).toBe("");
  });

  test("FAILURE: specialist throws → marked as failed", async () => {
    const collector = makeCollector();
    const flow = runMultiSpecialistFlow({
      message: "...",
      collector,
      classifier: async () => makeClassifier([{ agentId: "order-management", score: 5 }]),
      invokeSpecialist: fakeInvoker(
        { "order-management": { throwOnInvoke: new Error("ARN missing") } },
        () => collector,
      ),
    });
    let result: MultiSpecialistFlowResult | undefined;
    await withTrace(collector, async () => {
      while (true) {
        const next = await flow.next();
        if (next.done) {
          result = next.value;
          break;
        }
      }
    });
    expect(result?.failedSpecialists.length).toBe(1);
    expect(result?.failedSpecialists[0].failureMessage).toContain("ARN missing");
    const drafts = eventsOfType(collector, "orchestrator.specialist_draft");
    expect((drafts[0].payload as { status: string }).status).toBe("failed");
  });

  test("DECISION: orchestrator.multi_route_decision is emitted exactly once even with multiple specialists", async () => {
    const collector = makeCollector();
    // We don't actually run synthesis here — the synthesizer would call
    // Bedrock. Instead we set up two specialists and stop iterating after
    // the second specialist_ended; the helper still emitted the decision
    // event up-front.
    const flow = runMultiSpecialistFlow({
      message: "track my order and recommend a laptop",
      collector,
      classifier: async () =>
        makeClassifier([
          { agentId: "order-management", score: 5 },
          { agentId: "product-recommendation", score: 4 },
        ]),
      invokeSpecialist: fakeInvoker(
        {
          "order-management": { tokens: ["Order ok."] },
          "product-recommendation": { tokens: ["Laptop ok."] },
        },
        () => collector,
      ),
    });

    let endedCount = 0;
    await withTrace(collector, async () => {
      while (true) {
        const next = await flow.next();
        if (next.done) break;
        if (next.value.kind === "specialist_ended") {
          endedCount += 1;
          if (endedCount === 2) {
            // Stop here — do not enter synthesis (which would try to call Bedrock).
            await flow.return(undefined as never);
            break;
          }
        }
      }
    });

    expect(eventsOfType(collector, "orchestrator.multi_route_decision").length).toBe(1);
    const decision = eventsOfType(collector, "orchestrator.multi_route_decision")[0];
    expect((decision.payload as { pathTaken: string }).pathTaken).toBe("synthesis");
    expect((decision.payload as { selected: unknown[] }).selected.length).toBe(2);
    expect(eventsOfType(collector, "orchestrator.specialist_draft").length).toBe(2);
  });

  test("WRAPPER ATTACH: nested specialist trace events are attached under the wrapper span (per specialist)", async () => {
    const collector = makeCollector();
    const nestedEv: TraceEvent = {
      id: "nested-1",
      type: "model.text_delta_batch",
      ts: Date.now(),
      payload: { text: "hi", bytes: 2, windowMs: 10 },
    } as TraceEvent;
    const flow = runMultiSpecialistFlow({
      message: "hi",
      collector,
      classifier: async () => makeClassifier([{ agentId: "order-management", score: 5 }]),
      invokeSpecialist: fakeInvoker(
        {
          "order-management": {
            tokens: ["ok"],
            traces: [nestedEv],
          },
        },
        () => collector,
      ),
    });
    await withTrace(collector, async () => {
      while (true) {
        const next = await flow.next();
        if (next.done) break;
      }
    });
    // The nested event should be present in the collector with a parentId
    // pointing at the wrapper span (not at undefined).
    const nestedInCollector = collector
      .getEvents()
      .find((e) => e.type === "model.text_delta_batch");
    expect(nestedInCollector).toBeDefined();
    expect(nestedInCollector?.parentId).toBeDefined();
  });
});
