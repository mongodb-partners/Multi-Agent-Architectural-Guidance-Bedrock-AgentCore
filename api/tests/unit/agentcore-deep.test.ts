import { describe, expect, test } from "bun:test";
import { TraceCollector } from "../../src/lib/trace-collector.ts";
import type { TraceEvent } from "../../src/lib/trace-types.ts";

function makeEvent(over: Partial<TraceEvent>): TraceEvent {
  return {
    id: over.id ?? "ev-x",
    ts: over.ts ?? Date.now(),
    parentId: over.parentId,
    type: over.type ?? "tool.call",
    payload: (over.payload as never) ?? ({} as never),
  } as TraceEvent;
}

describe("AgentCore deep tracing — nested event splicing", () => {
  test("rewires nested root + descendants to the wrapper span", () => {
    const parent = new TraceCollector({ sessionId: "s1", agentId: "ec2", messageId: "m1" });
    const wrapper = parent.start("agentcore.invoke", {
      arn: "arn:aws:bedrock-agentcore:us-east-1:000000000000:runtime/abc",
      mode: "ec2_to_orchestrator",
      latencyMs: 0,
    });

    const t0 = Date.now() + 1_000_000;
    const nested: TraceEvent[] = [
      makeEvent({ id: "n-root", ts: t0, type: "chat.turn.start" }),
      makeEvent({ id: "n-child", ts: t0 + 100, parentId: "n-root", type: "model.request" }),
      makeEvent({ id: "n-orphan", ts: t0 + 200, parentId: "ghost", type: "tool.call" }),
    ];

    parent.end(wrapper, { mode: "ec2_to_orchestrator", latencyMs: 250 });
    parent.attachEventsNested(nested, wrapper);

    const events = parent.getEvents();
    const root = events.find((e) => e.id === "n-root");
    const child = events.find((e) => e.id === "n-child");
    const orphan = events.find((e) => e.id === "n-orphan");

    expect(root?.parentId).toBe(wrapper);
    expect(child?.parentId).toBe(wrapper);
    expect(orphan?.parentId).toBe(wrapper);
    expect((orphan?.payload as Record<string, unknown> | undefined)?._orphanFrom).toBe("ghost");
  });

  test("normalizes nested timestamps so nested.first aligns with wrapper start", () => {
    const parent = new TraceCollector({ sessionId: "s1", agentId: "ec2", messageId: "m1" });
    const wrapper = parent.start("agentcore.invoke", { mode: "ec2_to_orchestrator", latencyMs: 0 });
    parent.end(wrapper, { mode: "ec2_to_orchestrator", latencyMs: 1000 });

    const wrapperEvent = parent.getEvents().find((e) => e.id === wrapper);
    const wrapperStart = wrapperEvent!.ts;

    const nestedOrigin = wrapperStart + 5_000_000; // wildly skewed clock
    const nested: TraceEvent[] = [
      makeEvent({ id: "n-root", ts: nestedOrigin, type: "chat.turn.start" }),
      makeEvent({ id: "n-child", ts: nestedOrigin + 150, parentId: "n-root", type: "model.request" }),
    ];

    parent.attachEventsNested(nested, wrapper);
    const root = parent.getEvents().find((e) => e.id === "n-root");
    expect(root?.ts).toBe(wrapperStart);
    const child = parent.getEvents().find((e) => e.id === "n-child");
    expect(child?.ts).toBe(wrapperStart + 150);
  });

  test("preserves original timestamp on payload._originalTs", () => {
    const parent = new TraceCollector({ sessionId: "s1", agentId: "ec2", messageId: "m1" });
    const wrapper = parent.start("agentcore.invoke", { mode: "ec2_to_orchestrator", latencyMs: 0 });
    parent.end(wrapper, { mode: "ec2_to_orchestrator", latencyMs: 100 });

    const nested: TraceEvent[] = [
      makeEvent({ id: "n-root", ts: 999_000, type: "chat.turn.start" }),
    ];
    parent.attachEventsNested(nested, wrapper);
    const root = parent.getEvents().find((e) => e.id === "n-root");
    expect((root?.payload as Record<string, unknown>)._originalTs).toBe(999_000);
  });

  test("does nothing when wrapper id is unknown", () => {
    const parent = new TraceCollector({ sessionId: "s1", agentId: "ec2", messageId: "m1" });
    const before = parent.getEvents().length;
    parent.attachEventsNested(
      [makeEvent({ id: "n-1", ts: 1, type: "model.request" })],
      "unknown-wrapper-id",
    );
    expect(parent.getEvents().length).toBe(before);
  });

  test("handles empty nested array as no-op", () => {
    const parent = new TraceCollector({ sessionId: "s1", agentId: "ec2", messageId: "m1" });
    const wrapper = parent.start("agentcore.invoke", { mode: "ec2_to_orchestrator", latencyMs: 0 });
    const before = parent.getEvents().length;
    parent.attachEventsNested([], wrapper);
    expect(parent.getEvents().length).toBe(before);
  });
});
