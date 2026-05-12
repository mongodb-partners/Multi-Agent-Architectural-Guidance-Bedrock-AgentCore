import { describe, expect, test, beforeEach } from "bun:test";
import {
  _clearTraceStoreForTests,
  getTraceById,
  getTraceForMessage,
  listRecentTraces,
  persistTrace,
} from "../../src/lib/trace-store.ts";
import type { Trace } from "../../src/lib/trace-types.ts";

function makeTrace(over: Partial<Trace> = {}): Trace {
  return {
    traceId: over.traceId ?? `tr-${Math.random().toString(36).slice(2)}`,
    sessionId: over.sessionId ?? "sess-1",
    messageId: over.messageId ?? "msg-1",
    userId: over.userId,
    agentId: over.agentId ?? "orchestrator",
    events: over.events ?? [],
    summary: over.summary ?? {
      inputTokens: 0,
      outputTokens: 0,
      totalTokens: 0,
      toolCalls: 0,
      mongoQueries: 0,
      mongoDocsReturned: 0,
      mcpCalls: 0,
      bytesIn: 0,
      bytesOut: 0,
      eventsDropped: 0,
      estimatedCostUsd: null,
      costBreakdown: {},
      costEstimateComplete: false,
    },
    createdAt: over.createdAt ?? new Date().toISOString(),
    truncated: over.truncated,
    eventsDropped: over.eventsDropped,
  };
}

describe("trace-store ring buffer", () => {
  beforeEach(() => {
    _clearTraceStoreForTests();
    delete process.env.TRACE_RING_BUFFER_SIZE;
  });

  test("persistTrace + getTraceById round-trip via ring buffer", async () => {
    const t = makeTrace();
    await persistTrace(t);
    const back = await getTraceById(t.traceId);
    expect(back?.traceId).toBe(t.traceId);
  });

  test("persistTrace + getTraceForMessage round-trip", async () => {
    const t = makeTrace({ sessionId: "s2", messageId: "m2" });
    await persistTrace(t);
    const back = await getTraceForMessage("s2", "m2");
    expect(back?.traceId).toBe(t.traceId);
  });

  test("ring buffer evicts oldest beyond TRACE_RING_BUFFER_SIZE", async () => {
    process.env.TRACE_RING_BUFFER_SIZE = "3";
    const ids: string[] = [];
    for (let i = 0; i < 5; i++) {
      const t = makeTrace({ traceId: `tr-${i}` });
      await persistTrace(t);
      ids.push(t.traceId);
    }
    expect(await getTraceById("tr-0")).toBeUndefined();
    expect(await getTraceById("tr-1")).toBeUndefined();
    expect((await getTraceById("tr-4"))?.traceId).toBe("tr-4");
  });

  test("listRecentTraces returns ring buffer in reverse insertion order", async () => {
    for (let i = 0; i < 3; i++) {
      await persistTrace(makeTrace({ traceId: `tr-${i}`, sessionId: `s-${i}`, messageId: `m-${i}` }));
    }
    const list = await listRecentTraces(10);
    expect(list[0].traceId).toBe("tr-2");
    expect(list[list.length - 1].traceId).toBe("tr-0");
  });
});
