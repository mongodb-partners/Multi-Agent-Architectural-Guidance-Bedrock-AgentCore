/**
 * Tests for the per-event / per-turn byte-cap path's `dev.byte_cap_hit`
 * emissions. The Developer details panel renders these so a developer can
 * see exactly which event type lost bytes and why; the prior behavior was
 * to silently drop, which left a "summary says 12 tool calls but trace
 * shows 3" debugging hole.
 */

import { describe, expect, test, beforeEach, afterEach } from "bun:test";
import { TraceCollector } from "../../src/lib/trace-collector.ts";

function makeCollector() {
  return new TraceCollector({ sessionId: "s", messageId: "m", agentId: "orchestrator" });
}

describe("TraceCollector — dev.byte_cap_hit emissions", () => {
  beforeEach(() => {
    process.env.TRACE_MAX_TURN_BYTES = "2000";
    process.env.TRACE_MAX_EVENT_BYTES = "300";
  });
  afterEach(() => {
    delete process.env.TRACE_MAX_TURN_BYTES;
    delete process.env.TRACE_MAX_EVENT_BYTES;
  });

  test("per-event oversize emits a dev.byte_cap_hit with reason=per_event", () => {
    const c = makeCollector();
    c.event("tool.call", { toolName: "x", input: { body: "a".repeat(5_000) } });
    const cap = c.getEvents().find((e) => e.type === "dev.byte_cap_hit");
    expect(cap).toBeDefined();
    const p = cap?.payload as Record<string, unknown>;
    expect(p.droppedType).toBe("tool.call");
    expect(p.reason).toBe("per_event");
    expect(p.bytes).toBeGreaterThan(300);
  });

  test("per-turn drop emits a dev.byte_cap_hit with reason=per_turn", () => {
    const c = makeCollector();
    // Fill the per-turn cap with droppable (non-protected) events first.
    for (let i = 0; i < 20; i++) {
      c.event("model.text_delta_batch", { text: "x".repeat(200), bytes: 200, windowMs: 250 });
    }
    const caps = c.getEvents().filter(
      (e) => e.type === "dev.byte_cap_hit" && (e.payload as any).reason === "per_turn",
    );
    expect(caps.length).toBeGreaterThan(0);
    expect((caps[0].payload as any).droppedType).toBe("model.text_delta_batch");
  });

  test("dev.byte_cap_hit emissions are capped at MAX_BYTE_CAP_HIT_EMISSIONS to avoid spam", () => {
    const c = makeCollector();
    // 200 oversize tool.call events — way past the 50-emission cap.
    for (let i = 0; i < 200; i++) {
      c.event("tool.call", { toolName: `t${i}`, input: { body: "a".repeat(5_000) } });
    }
    const caps = c.getEvents().filter((e) => e.type === "dev.byte_cap_hit");
    expect(caps.length).toBeLessThanOrEqual(50);
  });

  test("the synthetic cap event never recursively triggers another cap event", () => {
    const c = makeCollector();
    c.event("tool.call", { toolName: "x", input: { body: "a".repeat(50_000) } });
    const caps = c.getEvents().filter((e) => e.type === "dev.byte_cap_hit");
    // At most one cap event per oversize emission; never `dev.byte_cap_hit`
    // about a `dev.byte_cap_hit`.
    for (const ev of caps) {
      expect((ev.payload as any).droppedType).not.toBe("dev.byte_cap_hit");
    }
  });
});
