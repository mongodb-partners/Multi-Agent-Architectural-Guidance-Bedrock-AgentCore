import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import {
  _clearTraceStoreForTests,
  persistTrace,
} from "../../src/lib/trace-store.ts";
import type { Trace } from "../../src/lib/trace-types.ts";
import { createApp } from "../../src/app.ts";

const app = createApp();

function makeTrace(over: Partial<Trace>): Trace {
  return {
    traceId: over.traceId ?? "trc-1",
    sessionId: over.sessionId ?? "sess-1",
    messageId: over.messageId ?? "msg-1",
    userId: over.userId,
    agentId: over.agentId ?? "orchestrator",
    events: over.events ?? [
      {
        id: "e1",
        ts: Date.now(),
        type: "mongo.query",
        payload: { mode: "direct", collection: "orders", op: "find" } as never,
      },
      {
        id: "e2",
        ts: Date.now(),
        type: "model.usage",
        payload: { modelId: "anthropic.claude-haiku-4-5", inputTokens: 10, outputTokens: 5, totalTokens: 15 } as never,
      },
    ],
    summary: over.summary ?? {
      inputTokens: 10,
      outputTokens: 5,
      totalTokens: 15,
      toolCalls: 0,
      mongoQueries: 1,
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
  };
}

describe("Trace routes — auth ownership matrix", () => {
  const saved = { ...process.env };

  beforeAll(() => {
    process.env.RATE_LIMIT_DISABLED = "1";
    delete process.env.REQUIRE_AUTH;
  });

  afterAll(() => {
    process.env = { ...saved };
  });

  beforeEach(() => {
    _clearTraceStoreForTests();
  });

  test("GET /traces/:id returns 404 when trace doesn't exist", async () => {
    const res = await app.request("http://localhost/traces/does-not-exist");
    expect(res.status).toBe(404);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("TRACE_NOT_FOUND");
  });

  test("GET /traces/:id returns the trace when unscoped (no userId)", async () => {
    await persistTrace(makeTrace({ traceId: "trc-pub" }));
    const res = await app.request("http://localhost/traces/trc-pub");
    expect(res.status).toBe(200);
    const body = (await res.json()) as Trace;
    expect(body.traceId).toBe("trc-pub");
  });

  test("GET /trace by sessionId+messageId returns the trace", async () => {
    await persistTrace(makeTrace({ traceId: "trc-q", sessionId: "s-q", messageId: "m-q" }));
    const res = await app.request("http://localhost/trace?sessionId=s-q&messageId=m-q");
    expect(res.status).toBe(200);
    const body = (await res.json()) as Trace;
    expect(body.traceId).toBe("trc-q");
  });

  test("GET /trace returns 400 when sessionId/messageId missing", async () => {
    const res = await app.request("http://localhost/trace");
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("MISSING_QUERY");
  });

  test("GET /trace/mongo filters to mongo.* events only", async () => {
    await persistTrace(makeTrace({ traceId: "trc-mongo" }));
    const res = await app.request("http://localhost/trace/mongo?traceId=trc-mongo");
    expect(res.status).toBe(200);
    const body = (await res.json()) as { events: Array<{ type: string }> };
    expect(body.events.length).toBe(1);
    expect(body.events[0].type).toBe("mongo.query");
  });

  test("GET /traces returns recent traces wrapped in { traces: [...] }", async () => {
    await persistTrace(makeTrace({ traceId: "trc-list-1" }));
    await persistTrace(makeTrace({ traceId: "trc-list-2", sessionId: "s2", messageId: "m2" }));
    const res = await app.request("http://localhost/traces?limit=5");
    expect(res.status).toBe(200);
    const body = (await res.json()) as { traces: Array<{ traceId: string }> };
    expect(body.traces.length).toBeGreaterThanOrEqual(2);
    const ids = body.traces.map((t) => t.traceId);
    expect(ids).toContain("trc-list-1");
    expect(ids).toContain("trc-list-2");
  });

  test("GET /traces/:id returns 404 when trace.userId mismatches caller userId", async () => {
    // Inject a trace owned by user-other; no auth is enforced here (REQUIRE_AUTH disabled)
    // so the c.get("jwtPayload")?.sub returns undefined and the ownership rule short-circuits
    // to "trace.userId set + caller has none ⇒ 404".
    await persistTrace(makeTrace({ traceId: "trc-other", userId: "user-other" }));
    const res = await app.request("http://localhost/traces/trc-other");
    expect(res.status).toBe(404);
  });
});
