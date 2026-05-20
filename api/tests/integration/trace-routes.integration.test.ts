import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import * as jose from "jose";
import {
  _clearTraceStoreForTests,
  persistTrace,
} from "../../src/lib/trace-store.ts";
import type { Trace } from "../../src/lib/trace-types.ts";
import { _setJwksResolverForTests } from "../../src/lib/jwt-verify.ts";
import { createApp } from "../../src/app.ts";

const ISS = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_testpool";
const KID = "trace-int-test-kid";

let signingKey: CryptoKey;
let app: ReturnType<typeof createApp>;

async function jwtFor(sub: string | undefined): Promise<string> {
  const builder = new jose.SignJWT({ token_use: "access", client_id: "test-client" })
    .setProtectedHeader({ alg: "ES256", kid: KID })
    .setIssuer(ISS)
    .setExpirationTime("1h");
  if (sub) builder.setSubject(sub);
  return builder.sign(signingKey);
}

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

  beforeAll(async () => {
    process.env.RATE_LIMIT_DISABLED = "1";
    process.env.AUTH_JWKS_URI = "https://example.invalid/jwks.json";
    process.env.AUTH_ISSUER = ISS;

    const { privateKey, publicKey } = await jose.generateKeyPair("ES256", { extractable: true });
    const pub = await jose.exportJWK(publicKey);
    pub.kid = KID;
    pub.alg = "ES256";
    _setJwksResolverForTests(jose.createLocalJWKSet({ keys: [pub] }));
    signingKey = privateKey;

    app = createApp();
  });

  afterAll(() => {
    _setJwksResolverForTests(null);
    process.env = { ...saved };
  });

  beforeEach(() => {
    _clearTraceStoreForTests();
  });

  test("GET /traces/:id returns 401 without a Bearer token", async () => {
    const res = await app.request("http://localhost/traces/anything");
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("UNAUTHORIZED");
  });

  test("GET /traces/:id returns 404 when trace doesn't exist", async () => {
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/traces/does-not-exist", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(404);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("TRACE_NOT_FOUND");
  });

  test("GET /traces/:id returns 404 when trace has no userId (unscoped traces are denied)", async () => {
    await persistTrace(makeTrace({ traceId: "trc-pub" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/traces/trc-pub", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(404);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("TRACE_NOT_FOUND");
  });

  test("GET /trace by sessionId+messageId returns the trace when owned by caller", async () => {
    await persistTrace(makeTrace({ traceId: "trc-q", sessionId: "s-q", messageId: "m-q", userId: "user-a" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/trace?sessionId=s-q&messageId=m-q", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Trace;
    expect(body.traceId).toBe("trc-q");
  });

  test("GET /trace by sessionId+messageId returns 404 for unscoped trace", async () => {
    await persistTrace(makeTrace({ traceId: "trc-q-unscoped", sessionId: "s-q-u", messageId: "m-q-u" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/trace?sessionId=s-q-u&messageId=m-q-u", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(404);
  });

  test("GET /trace returns 400 when sessionId/messageId missing", async () => {
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/trace", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("MISSING_QUERY");
  });

  test("GET /trace/mongo filters to mongo.* events only (scoped to owner)", async () => {
    await persistTrace(makeTrace({ traceId: "trc-mongo", userId: "user-a" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/trace/mongo?traceId=trc-mongo", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { events: Array<{ type: string }> };
    expect(body.events.length).toBe(1);
    expect(body.events[0].type).toBe("mongo.query");
  });

  test("GET /trace/mongo returns 404 for unscoped trace", async () => {
    await persistTrace(makeTrace({ traceId: "trc-mongo-unscoped" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/trace/mongo?traceId=trc-mongo-unscoped", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(404);
  });

  test("GET /traces returns only the caller's scoped traces wrapped in { traces: [...] }", async () => {
    await persistTrace(makeTrace({ traceId: "trc-list-1", userId: "user-a" }));
    await persistTrace(makeTrace({ traceId: "trc-list-2", sessionId: "s2", messageId: "m2", userId: "user-a" }));
    await persistTrace(makeTrace({ traceId: "trc-list-unscoped" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/traces?limit=5", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { traces: Array<{ traceId: string }> };
    const ids = body.traces.map((t) => t.traceId);
    expect(ids).toContain("trc-list-1");
    expect(ids).toContain("trc-list-2");
    expect(ids).not.toContain("trc-list-unscoped");
  });

  test("GET /traces/:id returns 404 when trace.userId mismatches caller userId", async () => {
    await persistTrace(makeTrace({ traceId: "trc-other", userId: "user-other" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/traces/trc-other", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(404);
  });

  // -------------------------------------------------------------------------
  // /traces?sessionId= + ?excludeTraceId= filters
  //
  // The Trace Viewer's prev/next-turn-in-session arrows depend on these
  // filters returning a session-scoped, deterministic ordering so the UI
  // can find the previous/next traceId without paging.
  // -------------------------------------------------------------------------

  test("GET /traces?sessionId= filters to a single session", async () => {
    await persistTrace(makeTrace({ traceId: "sess-a-1", sessionId: "sess-a", messageId: "m1", userId: "user-a" }));
    await persistTrace(makeTrace({ traceId: "sess-a-2", sessionId: "sess-a", messageId: "m2", userId: "user-a" }));
    await persistTrace(makeTrace({ traceId: "sess-b-1", sessionId: "sess-b", messageId: "m1", userId: "user-a" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/traces?sessionId=sess-a", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { traces: Array<{ traceId: string; sessionId: string }> };
    const ids = body.traces.map((t) => t.traceId).sort();
    expect(ids).toEqual(["sess-a-1", "sess-a-2"]);
    for (const t of body.traces) expect(t.sessionId).toBe("sess-a");
  });

  test("GET /traces?excludeTraceId= drops the named trace from the list", async () => {
    await persistTrace(makeTrace({ traceId: "exc-1", sessionId: "exc", messageId: "m1", userId: "user-a" }));
    await persistTrace(makeTrace({ traceId: "exc-2", sessionId: "exc", messageId: "m2", userId: "user-a" }));
    const tok = await jwtFor("user-a");
    const res = await app.request(
      "http://localhost/traces?sessionId=exc&excludeTraceId=exc-1",
      { headers: { Authorization: `Bearer ${tok}` } },
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { traces: Array<{ traceId: string }> };
    const ids = body.traces.map((t) => t.traceId);
    expect(ids).not.toContain("exc-1");
    expect(ids).toContain("exc-2");
  });

  test("GET /traces?sessionId= scopes to caller — never leaks another user's session", async () => {
    await persistTrace(makeTrace({ traceId: "shared-sess-a", sessionId: "shared", messageId: "m1", userId: "user-a" }));
    await persistTrace(makeTrace({ traceId: "shared-sess-b", sessionId: "shared", messageId: "m2", userId: "user-b" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/traces?sessionId=shared", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { traces: Array<{ traceId: string }> };
    const ids = body.traces.map((t) => t.traceId);
    expect(ids).toContain("shared-sess-a");
    expect(ids).not.toContain("shared-sess-b");
  });

  // -------------------------------------------------------------------------
  // ?include=core|dev|full + X-Trace-Include response header
  //
  // The Streamlit Trace Viewer opts into core for the initial fast load and
  // fetches dev on-demand when the user clicks "Show developer details".
  // The header round-trip lets the client assert it got back what it asked
  // for (api_client.get_trace asserts this) so a routing regression that
  // silently downgrades the projection becomes a test failure, not a
  // missing-developer-detail mystery.
  // -------------------------------------------------------------------------

  test("GET /traces/:id?include=core returns X-Trace-Include=core and strips dev-only top-level fields", async () => {
    const trace = makeTrace({
      traceId: "trc-core",
      userId: "user-a",
      events: [
        {
          id: "e1",
          ts: Date.now(),
          type: "dev.environment",
          payload: { chatMode: "live" } as never,
        },
        {
          id: "e2",
          ts: Date.now(),
          type: "prompt.assembled",
          payload: {
            body: "x".repeat(800),
            bodyBytes: 800,
            totalBytes: 800,
            personaBytes: 0,
            discoveryBytes: 0,
            memoryContextBytes: 0,
          } as never,
        },
      ],
    });
    trace.release = { gitSha: "deadbeef" } as never;
    trace.otel = { traceId: "a".repeat(32), rootSpanId: "b".repeat(16) } as never;
    await persistTrace(trace);
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/traces/trc-core?include=core", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-trace-include")).toBe("core");
    const body = (await res.json()) as Trace & { release?: unknown; otel?: unknown };
    // Dev-only top-level fields stripped.
    expect(body.release).toBeUndefined();
    expect(body.otel).toBeUndefined();
    // Dev-only event type dropped.
    expect(body.events.find((e) => e.type === "dev.environment")).toBeUndefined();
    // Heavy field replaced with the sentinel.
    const prompt = body.events.find((e) => e.type === "prompt.assembled");
    expect((prompt?.payload as any).body._omittedForCoreMode).toBe(true);
  });

  test("GET /traces/:id?include=dev returns the full doc and X-Trace-Include=dev", async () => {
    const trace = makeTrace({ traceId: "trc-dev", userId: "user-a" });
    trace.release = { gitSha: "abc" } as never;
    await persistTrace(trace);
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/traces/trc-dev?include=dev", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-trace-include")).toBe("dev");
    const body = (await res.json()) as Trace & { release?: { gitSha?: string } };
    expect(body.release?.gitSha).toBe("abc");
  });

  test("GET /traces/:id with no include defaults to full + X-Trace-Include=full (back-compat)", async () => {
    await persistTrace(makeTrace({ traceId: "trc-default", userId: "user-a" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/traces/trc-default", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-trace-include")).toBe("full");
  });

  test("GET /trace by sessionId+messageId honors ?include= and sets X-Trace-Include", async () => {
    await persistTrace(
      makeTrace({ traceId: "trc-via-msg", sessionId: "s-i", messageId: "m-i", userId: "user-a" }),
    );
    const tok = await jwtFor("user-a");
    const res = await app.request(
      "http://localhost/trace?sessionId=s-i&messageId=m-i&include=core",
      { headers: { Authorization: `Bearer ${tok}` } },
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("x-trace-include")).toBe("core");
  });

  test("Unknown ?include= value falls back to full (server default)", async () => {
    await persistTrace(makeTrace({ traceId: "trc-bad-include", userId: "user-a" }));
    const tok = await jwtFor("user-a");
    const res = await app.request(
      "http://localhost/traces/trc-bad-include?include=nonsense",
      { headers: { Authorization: `Bearer ${tok}` } },
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("x-trace-include")).toBe("full");
  });
});
