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

  test("GET /traces/:id returns the trace when it has no userId (unscoped)", async () => {
    await persistTrace(makeTrace({ traceId: "trc-pub" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/traces/trc-pub", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Trace;
    expect(body.traceId).toBe("trc-pub");
  });

  test("GET /trace by sessionId+messageId returns the trace", async () => {
    await persistTrace(makeTrace({ traceId: "trc-q", sessionId: "s-q", messageId: "m-q" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/trace?sessionId=s-q&messageId=m-q", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Trace;
    expect(body.traceId).toBe("trc-q");
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

  test("GET /trace/mongo filters to mongo.* events only", async () => {
    await persistTrace(makeTrace({ traceId: "trc-mongo" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/trace/mongo?traceId=trc-mongo", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { events: Array<{ type: string }> };
    expect(body.events.length).toBe(1);
    expect(body.events[0].type).toBe("mongo.query");
  });

  test("GET /traces returns recent traces wrapped in { traces: [...] }", async () => {
    await persistTrace(makeTrace({ traceId: "trc-list-1" }));
    await persistTrace(makeTrace({ traceId: "trc-list-2", sessionId: "s2", messageId: "m2" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/traces?limit=5", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { traces: Array<{ traceId: string }> };
    expect(body.traces.length).toBeGreaterThanOrEqual(2);
    const ids = body.traces.map((t) => t.traceId);
    expect(ids).toContain("trc-list-1");
    expect(ids).toContain("trc-list-2");
  });

  test("GET /traces/:id returns 404 when trace.userId mismatches caller userId", async () => {
    await persistTrace(makeTrace({ traceId: "trc-other", userId: "user-other" }));
    const tok = await jwtFor("user-a");
    const res = await app.request("http://localhost/traces/trc-other", {
      headers: { Authorization: `Bearer ${tok}` },
    });
    expect(res.status).toBe(404);
  });
});
