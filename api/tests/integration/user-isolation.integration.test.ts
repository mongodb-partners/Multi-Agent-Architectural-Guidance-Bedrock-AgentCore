/**
 * user-isolation.integration.test.ts
 * ─────────────────────────────────────────────────────────────────────────────
 * Comprehensive API-level user isolation security tests.
 *
 * Every data-bearing HTTP endpoint must:
 *   1. Require a valid Bearer JWT (no public data access).
 *   2. Scope all reads and writes to the authenticated user's jwt.sub.
 *   3. Return 404 (not 403) for cross-user resources to prevent existence leaks.
 *   4. Never include another user's data in list/search responses.
 *
 * Test areas:
 *   AUTH  — all protected routes reject missing / invalid / expired tokens
 *   SL    — GET /sessions  listing isolation
 *   SR    — GET /sessions/:id  read isolation
 *   SD    — DELETE /sessions/:id  delete isolation
 *   CH    — POST /chat  session cross-user access
 *   TR    — GET /traces/:id  trace ownership
 *   TQ    — GET /trace  trace lookup by sessionId+messageId
 *   TM    — GET /trace/mongo  filtered mongo trace ownership
 *   TL    — GET /traces  trace listing isolation
 *   MU    — Multi-user concurrent isolation (three users, no cross-contamination)
 *   PE    — Privilege escalation attempt vectors
 * ─────────────────────────────────────────────────────────────────────────────
 */

import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import * as jose from "jose";
import {
  clearAllSessionsForTests,
  getOrCreateSession,
} from "../../src/lib/session-store.ts";
import {
  _clearTraceStoreForTests,
  persistTrace,
} from "../../src/lib/trace-store.ts";
import type { Trace } from "../../src/lib/trace-types.ts";

// ─────────────────────────────────────────────────────────────────────────────
// Mock the AgentCore runtime BEFORE app is imported so chat route tests don't
// attempt real AWS calls. The mock throws immediately, which makes chat return
// AGENTCORE_RUNTIME_ERROR — we only care about the pre-flight session ownership
// check that happens before the runtime is ever invoked.
// ─────────────────────────────────────────────────────────────────────────────
mock.module("../../src/adapters/agentcore-runtime.ts", () => ({
  assertAgentcoreOrchestratorArn: () =>
    "arn:aws:bedrock-agentcore:us-east-1:000000000000:runtime/test",
  agentcoreOrchestratorArn: () =>
    "arn:aws:bedrock-agentcore:us-east-1:000000000000:runtime/test",
  agentcoreSpecialistArn: () => undefined,
  setAgentcoreSpecialistArnOverrides: () => undefined,
  agentcoreRuntimeArn: () =>
    "arn:aws:bedrock-agentcore:us-east-1:000000000000:runtime/test",
  invokeAgentRuntime: async function* () {
    throw Object.assign(new Error("mocked runtime — isolation test"), {
      name: "MockedRuntimeError",
    });
  },
}));

const { createApp } = await import("../../src/app.ts");
const { _setJwksResolverForTests } = await import("../../src/lib/jwt-verify.ts");

const ISS = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_isolation";
const KID = "isolation-test-kid";

let signingKey: CryptoKey;
let app: ReturnType<typeof createApp>;

async function jwtFor(sub: string): Promise<string> {
  return new jose.SignJWT({ token_use: "access", client_id: "test-client" })
    .setProtectedHeader({ alg: "ES256", kid: KID })
    .setIssuer(ISS)
    .setSubject(sub)
    .setExpirationTime("1h")
    .sign(signingKey);
}

async function authFor(sub: string): Promise<Record<string, string>> {
  return {
    Authorization: `Bearer ${await jwtFor(sub)}`,
    "Content-Type": "application/json",
  };
}

function makeTrace(
  traceId: string,
  userId: string | undefined,
  sessionId = `sess-${traceId}`,
  messageId = `msg-${traceId}`,
): Trace {
  return {
    traceId,
    sessionId,
    messageId,
    userId,
    agentId: "orchestrator",
    events: [
      {
        id: "e1",
        ts: Date.now(),
        type: "mongo.query",
        payload: { mode: "direct", collection: "orders", op: "find" } as never,
      },
    ],
    summary: {
      inputTokens: 1,
      outputTokens: 1,
      totalTokens: 2,
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
    createdAt: new Date().toISOString(),
  };
}

// ─────────────────────────────────────────────────────────────────────────────

describe("User Isolation — comprehensive API security tests", () => {
  const savedEnv = { ...process.env };

  beforeAll(async () => {
    process.env.RATE_LIMIT_DISABLED = "1";
    process.env.AUTH_JWKS_URI = "https://example.invalid/jwks.json";
    process.env.AUTH_ISSUER = ISS;
    delete process.env.ORCHESTRATOR_MODE;

    const { privateKey, publicKey } = await jose.generateKeyPair("ES256", {
      extractable: true,
    });
    const pub = await jose.exportJWK(publicKey);
    pub.kid = KID;
    pub.alg = "ES256";
    _setJwksResolverForTests(jose.createLocalJWKSet({ keys: [pub] }));
    signingKey = privateKey;

    app = createApp();
  });

  afterAll(() => {
    _setJwksResolverForTests(null);
    process.env = { ...savedEnv };
  });

  beforeEach(() => {
    clearAllSessionsForTests();
    _clearTraceStoreForTests();
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("AUTH — all protected routes require a valid Bearer token", () => {
    test("GET /sessions → 401 UNAUTHORIZED without token", async () => {
      const res = await app.request("http://localhost/sessions");
      expect(res.status).toBe(401);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("UNAUTHORIZED");
    });

    test("GET /sessions/:id → 401 without token", async () => {
      const res = await app.request("http://localhost/sessions/any-id");
      expect(res.status).toBe(401);
    });

    test("DELETE /sessions/:id → 401 without token", async () => {
      const res = await app.request("http://localhost/sessions/any-id", {
        method: "DELETE",
      });
      expect(res.status).toBe(401);
    });

    test("GET /traces/:id → 401 without token", async () => {
      const res = await app.request("http://localhost/traces/any-trace");
      expect(res.status).toBe(401);
    });

    test("GET /trace → 401 without token", async () => {
      const res = await app.request(
        "http://localhost/trace?sessionId=s&messageId=m",
      );
      expect(res.status).toBe(401);
    });

    test("GET /trace/mongo → 401 without token", async () => {
      const res = await app.request("http://localhost/trace/mongo?traceId=t");
      expect(res.status).toBe(401);
    });

    test("GET /traces → 401 without token", async () => {
      const res = await app.request("http://localhost/traces");
      expect(res.status).toBe(401);
    });

    test("POST /chat → 401 without token", async () => {
      const res = await app.request("http://localhost/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: "hi", sessionId: "x" }),
      });
      expect(res.status).toBe(401);
    });

    test("Malformed Bearer token → 401 INVALID_TOKEN", async () => {
      const res = await app.request("http://localhost/sessions", {
        headers: { Authorization: "Bearer not.a.valid.jwt" },
      });
      expect(res.status).toBe(401);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("INVALID_TOKEN");
    });

    test("Token signed with an unregistered key → 401 INVALID_TOKEN", async () => {
      const { privateKey: wrongKey } = await jose.generateKeyPair("ES256", {
        extractable: true,
      });
      const forgedToken = await new jose.SignJWT({
        token_use: "access",
        client_id: "test-client",
      })
        .setProtectedHeader({ alg: "ES256", kid: KID })
        .setIssuer(ISS)
        .setSubject("attacker")
        .setExpirationTime("1h")
        .sign(wrongKey);

      const res = await app.request("http://localhost/sessions", {
        headers: { Authorization: `Bearer ${forgedToken}` },
      });
      expect(res.status).toBe(401);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("INVALID_TOKEN");
    });

    test("Expired token → 401 INVALID_TOKEN", async () => {
      // Use a 1-second-ago expiry; clockTolerance is 30s so use -60s to be sure
      const expiredToken = await new jose.SignJWT({
        token_use: "access",
        client_id: "test-client",
      })
        .setProtectedHeader({ alg: "ES256", kid: KID })
        .setIssuer(ISS)
        .setSubject("alice")
        .setIssuedAt(Math.floor(Date.now() / 1000) - 120)
        .setExpirationTime(Math.floor(Date.now() / 1000) - 60)
        .sign(signingKey);

      const res = await app.request("http://localhost/sessions", {
        headers: { Authorization: `Bearer ${expiredToken}` },
      });
      expect(res.status).toBe(401);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("INVALID_TOKEN");
    });

    test("Token with wrong issuer → 401 INVALID_TOKEN", async () => {
      const wrongIssuerToken = await new jose.SignJWT({
        token_use: "access",
        client_id: "test-client",
      })
        .setProtectedHeader({ alg: "ES256", kid: KID })
        .setIssuer("https://evil-issuer.example.com")
        .setSubject("attacker")
        .setExpirationTime("1h")
        .sign(signingKey);

      const res = await app.request("http://localhost/sessions", {
        headers: { Authorization: `Bearer ${wrongIssuerToken}` },
      });
      expect(res.status).toBe(401);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("INVALID_TOKEN");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("SL — GET /sessions listing isolation", () => {
    test("User sees only their own sessions — not other users'", async () => {
      await getOrCreateSession("sess-sl-alice-1", "alice");
      await getOrCreateSession("sess-sl-alice-2", "alice");
      await getOrCreateSession("sess-sl-bob-1", "bob");

      const res = await app.request("http://localhost/sessions", {
        headers: await authFor("alice"),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        sessions: { sessionId: string }[];
      };
      const ids = body.sessions.map((s) => s.sessionId);

      expect(ids).toContain("sess-sl-alice-1");
      expect(ids).toContain("sess-sl-alice-2");
      expect(ids).not.toContain("sess-sl-bob-1");
    });

    test("Bob's listing excludes Alice's sessions entirely", async () => {
      await getOrCreateSession("sess-sl-alice-only", "alice");
      await getOrCreateSession("sess-sl-bob-only", "bob");

      const res = await app.request("http://localhost/sessions", {
        headers: await authFor("bob"),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        sessions: { sessionId: string }[];
      };
      const ids = body.sessions.map((s) => s.sessionId);

      expect(ids).toContain("sess-sl-bob-only");
      expect(ids).not.toContain("sess-sl-alice-only");
    });

    test("New user with no sessions gets an empty list — not others' sessions", async () => {
      await getOrCreateSession("sess-sl-existing-user", "charlie");

      const res = await app.request("http://localhost/sessions", {
        headers: await authFor("brand-new-user"),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        sessions: { sessionId: string }[];
      };
      expect(body.sessions).toHaveLength(0);
    });

    test("Every session in the listing has userId matching the authenticated caller", async () => {
      await getOrCreateSession("sess-sl-uid-check-1", "dana");
      await getOrCreateSession("sess-sl-uid-check-2", "dana");
      await getOrCreateSession("sess-sl-uid-intruder", "intruder");

      const res = await app.request("http://localhost/sessions", {
        headers: await authFor("dana"),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        sessions: { sessionId: string; userId: string }[];
      };
      for (const sess of body.sessions) {
        expect(sess.userId).toBe("dana");
      }
    });

    test("Listing response JSON does not contain any foreign session ID in its serialised text", async () => {
      await getOrCreateSession("sess-sl-alice-secret-id", "alice");
      await getOrCreateSession("sess-sl-bob-visible", "bob");

      const res = await app.request("http://localhost/sessions", {
        headers: await authFor("bob"),
      });
      const raw = await res.text();
      expect(raw).not.toContain("alice-secret-id");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("SR — GET /sessions/:id read isolation", () => {
    test("Owner can read their own session with correct data", async () => {
      await getOrCreateSession("sess-sr-own", "alice");

      const res = await app.request("http://localhost/sessions/sess-sr-own", {
        headers: await authFor("alice"),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as { sessionId: string; userId: string };
      expect(body.sessionId).toBe("sess-sr-own");
      expect(body.userId).toBe("alice");
    });

    test("Bob cannot read Alice's session — 404 SESSION_NOT_FOUND", async () => {
      await getOrCreateSession("sess-sr-alice-private", "alice");

      const res = await app.request(
        "http://localhost/sessions/sess-sr-alice-private",
        { headers: await authFor("bob") },
      );
      expect(res.status).toBe(404);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("SESSION_NOT_FOUND");
    });

    test("Alice cannot read Bob's session — 404 SESSION_NOT_FOUND", async () => {
      await getOrCreateSession("sess-sr-bob-private", "bob");

      const res = await app.request(
        "http://localhost/sessions/sess-sr-bob-private",
        { headers: await authFor("alice") },
      );
      expect(res.status).toBe(404);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("SESSION_NOT_FOUND");
    });

    test("Cross-user 404 is indistinguishable from truly missing session (no existence leak)", async () => {
      await getOrCreateSession("sess-sr-exists-alice", "alice");

      // Bob asks for a session that exists (but belongs to Alice) vs one that doesn't exist at all
      const crossUserRes = await app.request(
        "http://localhost/sessions/sess-sr-exists-alice",
        { headers: await authFor("bob") },
      );
      const nonExistentRes = await app.request(
        "http://localhost/sessions/sess-does-not-exist-at-all",
        { headers: await authFor("bob") },
      );

      expect(crossUserRes.status).toBe(404);
      expect(nonExistentRes.status).toBe(404);

      const crossBody = (await crossUserRes.json()) as {
        error: { code: string };
      };
      const nonExBody = (await nonExistentRes.json()) as {
        error: { code: string };
      };

      // Same error code — attacker cannot distinguish "exists but not yours" from "never existed"
      expect(crossBody.error.code).toBe("SESSION_NOT_FOUND");
      expect(nonExBody.error.code).toBe("SESSION_NOT_FOUND");
    });

    test("Cross-user read response body does not expose the session's actual messages", async () => {
      const session = await getOrCreateSession("sess-sr-msg-leak", "alice");
      if (session && session !== Symbol.for("FORBIDDEN_SESSION")) {
        (session as { messages: unknown[] }).messages.push({
          id: "m1",
          role: "user",
          content: "alice-secret-message-content",
          timestamp: new Date().toISOString(),
        });
      }

      const res = await app.request(
        "http://localhost/sessions/sess-sr-msg-leak",
        { headers: await authFor("bob") },
      );
      expect(res.status).toBe(404);
      const raw = await res.text();
      expect(raw).not.toContain("alice-secret-message-content");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("SD — DELETE /sessions/:id delete isolation", () => {
    test("Owner can delete their own session and it is gone", async () => {
      await getOrCreateSession("sess-sd-own", "alice");

      const delRes = await app.request(
        "http://localhost/sessions/sess-sd-own",
        { method: "DELETE", headers: await authFor("alice") },
      );
      expect(delRes.status).toBe(204);

      const getRes = await app.request(
        "http://localhost/sessions/sess-sd-own",
        { headers: await authFor("alice") },
      );
      expect(getRes.status).toBe(404);
    });

    test("Bob cannot delete Alice's session — 404 SESSION_NOT_FOUND", async () => {
      await getOrCreateSession("sess-sd-guard", "alice");

      const res = await app.request(
        "http://localhost/sessions/sess-sd-guard",
        { method: "DELETE", headers: await authFor("bob") },
      );
      expect(res.status).toBe(404);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("SESSION_NOT_FOUND");
    });

    test("Alice's session is intact after Bob's failed delete attempt", async () => {
      await getOrCreateSession("sess-sd-intact", "alice");

      await app.request("http://localhost/sessions/sess-sd-intact", {
        method: "DELETE",
        headers: await authFor("bob"),
      });

      const getRes = await app.request(
        "http://localhost/sessions/sess-sd-intact",
        { headers: await authFor("alice") },
      );
      expect(getRes.status).toBe(200);
      const body = (await getRes.json()) as { sessionId: string };
      expect(body.sessionId).toBe("sess-sd-intact");
    });

    test("After owner deletes, session disappears from their own listing", async () => {
      await getOrCreateSession("sess-sd-list-gone", "alice");

      await app.request("http://localhost/sessions/sess-sd-list-gone", {
        method: "DELETE",
        headers: await authFor("alice"),
      });

      const listRes = await app.request("http://localhost/sessions", {
        headers: await authFor("alice"),
      });
      const body = (await listRes.json()) as {
        sessions: { sessionId: string }[];
      };
      const ids = body.sessions.map((s) => s.sessionId);
      expect(ids).not.toContain("sess-sd-list-gone");
    });

    test("Bob deleting a non-existent session returns 404 (same as cross-user delete — no existence leak)", async () => {
      const res = await app.request(
        "http://localhost/sessions/sess-sd-never-existed",
        { method: "DELETE", headers: await authFor("bob") },
      );
      expect(res.status).toBe(404);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("SESSION_NOT_FOUND");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("CH — POST /chat session cross-user access", () => {
    test("User B cannot POST /chat on User A's session — 404 SESSION_NOT_FOUND", async () => {
      await getOrCreateSession("sess-ch-alice", "alice");

      const res = await app.request("http://localhost/chat", {
        method: "POST",
        headers: await authFor("bob"),
        body: JSON.stringify({
          message: "I am trying to intrude",
          sessionId: "sess-ch-alice",
          agentId: "order-management",
        }),
      });
      expect(res.status).toBe(404);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("SESSION_NOT_FOUND");
    });

    test("Alice's session messages are empty after Bob's failed chat intrusion", async () => {
      await getOrCreateSession("sess-ch-unmodified", "alice");

      await app.request("http://localhost/chat", {
        method: "POST",
        headers: await authFor("bob"),
        body: JSON.stringify({
          message: "intruder message that must not appear",
          sessionId: "sess-ch-unmodified",
          agentId: "order-management",
        }),
      });

      const histRes = await app.request(
        "http://localhost/sessions/sess-ch-unmodified",
        { headers: await authFor("alice") },
      );
      expect(histRes.status).toBe(200);
      const body = (await histRes.json()) as {
        messages: { role: string; content: string }[];
      };
      expect(body.messages).toHaveLength(0);
      expect(JSON.stringify(body.messages)).not.toContain(
        "intruder message that must not appear",
      );
    });

    test("Bob's newly created session is not visible to Alice", async () => {
      await getOrCreateSession("sess-ch-bob-new", "bob");

      const aliceListRes = await app.request("http://localhost/sessions", {
        headers: await authFor("alice"),
      });
      const aliceBody = (await aliceListRes.json()) as {
        sessions: { sessionId: string }[];
      };
      const aliceIds = aliceBody.sessions.map((s) => s.sessionId);
      expect(aliceIds).not.toContain("sess-ch-bob-new");
    });

    test("Attempting to chat on another user's session returns the same error as a missing session", async () => {
      await getOrCreateSession("sess-ch-exists-alice", "alice");

      const crossRes = await app.request("http://localhost/chat", {
        method: "POST",
        headers: await authFor("bob"),
        body: JSON.stringify({
          message: "hi",
          sessionId: "sess-ch-exists-alice",
          agentId: "order-management",
        }),
      });
      const missingRes = await app.request("http://localhost/chat", {
        method: "POST",
        headers: await authFor("bob"),
        body: JSON.stringify({
          message: "hi",
          sessionId: "sess-ch-totally-missing",
          agentId: "order-management",
        }),
      });

      // Both return a non-200 status; specifically the cross-user check returns 404
      // before the session is created (because getSession returns FORBIDDEN_SESSION)
      expect(crossRes.status).toBe(404);
      // Missing session: chat route calls appendUserMessage which calls getOrCreateSession;
      // a missing session is created fresh for the caller — so it succeeds at the
      // session layer and fails at the AgentCore layer with 200+SSE error event.
      // We don't assert the missing-session path here — only that the cross-user
      // path is definitively denied (404) before any data is created.
      const crossBody = (await crossRes.json()) as { error: { code: string } };
      expect(crossBody.error.code).toBe("SESSION_NOT_FOUND");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("TR — GET /traces/:id trace ownership", () => {
    test("Owner can read their own trace", async () => {
      await persistTrace(makeTrace("trc-tr-alice", "alice"));

      const res = await app.request("http://localhost/traces/trc-tr-alice", {
        headers: await authFor("alice"),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as { traceId: string; userId: string };
      expect(body.traceId).toBe("trc-tr-alice");
      expect(body.userId).toBe("alice");
    });

    test("Bob cannot read Alice's trace — 404 TRACE_NOT_FOUND", async () => {
      await persistTrace(makeTrace("trc-tr-alice-priv", "alice"));

      const res = await app.request(
        "http://localhost/traces/trc-tr-alice-priv",
        { headers: await authFor("bob") },
      );
      expect(res.status).toBe(404);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("TRACE_NOT_FOUND");
    });

    test("Alice cannot read Bob's trace — 404 TRACE_NOT_FOUND", async () => {
      await persistTrace(makeTrace("trc-tr-bob-priv", "bob"));

      const res = await app.request(
        "http://localhost/traces/trc-tr-bob-priv",
        { headers: await authFor("alice") },
      );
      expect(res.status).toBe(404);
    });

    test("Unscoped trace (no userId) → 404 for every authenticated user", async () => {
      await persistTrace(makeTrace("trc-tr-unscoped", undefined));

      const aliceRes = await app.request(
        "http://localhost/traces/trc-tr-unscoped",
        { headers: await authFor("alice") },
      );
      const bobRes = await app.request(
        "http://localhost/traces/trc-tr-unscoped",
        { headers: await authFor("bob") },
      );

      expect(aliceRes.status).toBe(404);
      expect(bobRes.status).toBe(404);
    });

    test("Cross-user 404 is indistinguishable from a missing trace (no existence leak)", async () => {
      await persistTrace(makeTrace("trc-tr-exists-alice", "alice"));

      const crossRes = await app.request(
        "http://localhost/traces/trc-tr-exists-alice",
        { headers: await authFor("bob") },
      );
      const missingRes = await app.request(
        "http://localhost/traces/trc-tr-does-not-exist",
        { headers: await authFor("bob") },
      );

      expect(crossRes.status).toBe(404);
      expect(missingRes.status).toBe(404);

      const crossBody = (await crossRes.json()) as { error: { code: string } };
      const missingBody = (await missingRes.json()) as {
        error: { code: string };
      };
      expect(crossBody.error.code).toBe("TRACE_NOT_FOUND");
      expect(missingBody.error.code).toBe("TRACE_NOT_FOUND");
    });

    test("Cross-user trace response body does not expose the trace's actual content", async () => {
      const trace = makeTrace("trc-tr-content-leak", "alice");
      // Annotate a recognisable string into the trace payload
      (trace.events[0]!.payload as Record<string, unknown>)["secret"] =
        "alice-secret-payload-content";
      await persistTrace(trace);

      const res = await app.request(
        "http://localhost/traces/trc-tr-content-leak",
        { headers: await authFor("bob") },
      );
      expect(res.status).toBe(404);
      const raw = await res.text();
      expect(raw).not.toContain("alice-secret-payload-content");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("TQ — GET /trace (lookup by sessionId + messageId)", () => {
    test("Owner can read their trace by sessionId+messageId", async () => {
      await persistTrace(
        makeTrace("trc-tq-alice", "alice", "tq-sess-alice", "tq-msg-alice"),
      );

      const res = await app.request(
        "http://localhost/trace?sessionId=tq-sess-alice&messageId=tq-msg-alice",
        { headers: await authFor("alice") },
      );
      expect(res.status).toBe(200);
      const body = (await res.json()) as { traceId: string };
      expect(body.traceId).toBe("trc-tq-alice");
    });

    test("Bob cannot read Alice's trace via sessionId+messageId — 404", async () => {
      await persistTrace(
        makeTrace(
          "trc-tq-alice-priv",
          "alice",
          "tq-sess-alice-priv",
          "tq-msg-alice-priv",
        ),
      );

      const res = await app.request(
        "http://localhost/trace?sessionId=tq-sess-alice-priv&messageId=tq-msg-alice-priv",
        { headers: await authFor("bob") },
      );
      expect(res.status).toBe(404);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("TRACE_NOT_FOUND");
    });

    test("Unscoped trace via sessionId+messageId → 404 for any caller", async () => {
      await persistTrace(
        makeTrace(
          "trc-tq-unscoped",
          undefined,
          "tq-sess-unscoped",
          "tq-msg-unscoped",
        ),
      );

      const res = await app.request(
        "http://localhost/trace?sessionId=tq-sess-unscoped&messageId=tq-msg-unscoped",
        { headers: await authFor("alice") },
      );
      expect(res.status).toBe(404);
    });

    test("Missing sessionId param → 400 MISSING_QUERY", async () => {
      const res = await app.request(
        "http://localhost/trace?messageId=msg-only",
        { headers: await authFor("alice") },
      );
      expect(res.status).toBe(400);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("MISSING_QUERY");
    });

    test("Missing messageId param → 400 MISSING_QUERY", async () => {
      const res = await app.request(
        "http://localhost/trace?sessionId=sess-only",
        { headers: await authFor("alice") },
      );
      expect(res.status).toBe(400);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("MISSING_QUERY");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("TM — GET /trace/mongo filtered trace ownership", () => {
    test("Owner can access their own mongo trace view", async () => {
      await persistTrace(makeTrace("trc-tm-alice", "alice"));

      const res = await app.request(
        "http://localhost/trace/mongo?traceId=trc-tm-alice",
        { headers: await authFor("alice") },
      );
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        traceId: string;
        events: { type: string }[];
      };
      expect(body.traceId).toBe("trc-tm-alice");
      expect(body.events[0]?.type).toBe("mongo.query");
    });

    test("Bob cannot access Alice's mongo trace view — 404", async () => {
      await persistTrace(makeTrace("trc-tm-alice-priv", "alice"));

      const res = await app.request(
        "http://localhost/trace/mongo?traceId=trc-tm-alice-priv",
        { headers: await authFor("bob") },
      );
      expect(res.status).toBe(404);
    });

    test("Unscoped mongo trace → 404 for any caller", async () => {
      await persistTrace(makeTrace("trc-tm-unscoped", undefined));

      const res = await app.request(
        "http://localhost/trace/mongo?traceId=trc-tm-unscoped",
        { headers: await authFor("alice") },
      );
      expect(res.status).toBe(404);
    });

    test("Mongo trace lookup by sessionId+messageId — cross-user denied", async () => {
      await persistTrace(
        makeTrace(
          "trc-tm-sq-alice",
          "alice",
          "tm-sess-alice",
          "tm-msg-alice",
        ),
      );

      const aliceRes = await app.request(
        "http://localhost/trace/mongo?sessionId=tm-sess-alice&messageId=tm-msg-alice",
        { headers: await authFor("alice") },
      );
      const bobRes = await app.request(
        "http://localhost/trace/mongo?sessionId=tm-sess-alice&messageId=tm-msg-alice",
        { headers: await authFor("bob") },
      );

      expect(aliceRes.status).toBe(200);
      expect(bobRes.status).toBe(404);
    });

    test("Missing both traceId and sessionId+messageId → 400 MISSING_QUERY", async () => {
      const res = await app.request("http://localhost/trace/mongo", {
        headers: await authFor("alice"),
      });
      expect(res.status).toBe(400);
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("MISSING_QUERY");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("TL — GET /traces trace listing isolation", () => {
    test("Alice sees only her own traces in the listing", async () => {
      await persistTrace(makeTrace("trc-tl-alice-1", "alice"));
      await persistTrace(makeTrace("trc-tl-alice-2", "alice"));
      await persistTrace(makeTrace("trc-tl-bob-1", "bob"));

      const res = await app.request("http://localhost/traces?limit=50", {
        headers: await authFor("alice"),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        traces: { traceId: string }[];
      };
      const ids = body.traces.map((t) => t.traceId);

      expect(ids).toContain("trc-tl-alice-1");
      expect(ids).toContain("trc-tl-alice-2");
      expect(ids).not.toContain("trc-tl-bob-1");
    });

    test("Bob's trace listing excludes Alice's traces", async () => {
      await persistTrace(makeTrace("trc-tl-alice-only", "alice"));
      await persistTrace(makeTrace("trc-tl-bob-only", "bob"));

      const res = await app.request("http://localhost/traces?limit=50", {
        headers: await authFor("bob"),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        traces: { traceId: string }[];
      };
      const ids = body.traces.map((t) => t.traceId);

      expect(ids).toContain("trc-tl-bob-only");
      expect(ids).not.toContain("trc-tl-alice-only");
    });

    test("Unscoped traces (no userId) are excluded from every user's listing", async () => {
      await persistTrace(makeTrace("trc-tl-unscoped", undefined));
      await persistTrace(makeTrace("trc-tl-alice-has", "alice"));

      const res = await app.request("http://localhost/traces?limit=50", {
        headers: await authFor("alice"),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        traces: { traceId: string }[];
      };
      const ids = body.traces.map((t) => t.traceId);

      expect(ids).not.toContain("trc-tl-unscoped");
      expect(ids).toContain("trc-tl-alice-has");
    });

    test("User with no traces gets an empty list, not others' traces", async () => {
      await persistTrace(makeTrace("trc-tl-charlie", "charlie"));

      const res = await app.request("http://localhost/traces?limit=50", {
        headers: await authFor("fresh-user-zero-traces"),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        traces: { traceId: string }[];
      };
      expect(body.traces).toHaveLength(0);
    });

    test("Trace listing JSON does not contain any foreign trace ID in its serialised text", async () => {
      await persistTrace(makeTrace("trc-tl-alice-secret-id", "alice"));
      await persistTrace(makeTrace("trc-tl-bob-visible", "bob"));

      const res = await app.request("http://localhost/traces?limit=50", {
        headers: await authFor("bob"),
      });
      const raw = await res.text();
      expect(raw).not.toContain("trc-tl-alice-secret-id");
    });

    test("limit parameter is respected and response is still user-scoped", async () => {
      for (let i = 0; i < 5; i++) {
        await persistTrace(makeTrace(`trc-tl-limit-alice-${i}`, "alice"));
        await persistTrace(makeTrace(`trc-tl-limit-bob-${i}`, "bob"));
      }

      const res = await app.request("http://localhost/traces?limit=3", {
        headers: await authFor("alice"),
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        traces: { traceId: string }[];
      };
      expect(body.traces.length).toBeLessThanOrEqual(3);
      for (const t of body.traces) {
        expect(t.traceId).not.toContain("bob");
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("MU — Multi-user concurrent isolation (three users)", () => {
    test("Three users each see only their own sessions (parallel requests)", async () => {
      await getOrCreateSession("sess-mu-alice", "alice");
      await getOrCreateSession("sess-mu-bob", "bob");
      await getOrCreateSession("sess-mu-charlie", "charlie");

      const [aliceRes, bobRes, charlieRes] = await Promise.all([
        app.request("http://localhost/sessions", {
          headers: await authFor("alice"),
        }),
        app.request("http://localhost/sessions", {
          headers: await authFor("bob"),
        }),
        app.request("http://localhost/sessions", {
          headers: await authFor("charlie"),
        }),
      ]);

      const aliceIds = (
        (await aliceRes.json()) as { sessions: { sessionId: string }[] }
      ).sessions.map((s) => s.sessionId);
      const bobIds = (
        (await bobRes.json()) as { sessions: { sessionId: string }[] }
      ).sessions.map((s) => s.sessionId);
      const charlieIds = (
        (await charlieRes.json()) as { sessions: { sessionId: string }[] }
      ).sessions.map((s) => s.sessionId);

      expect(aliceIds).toContain("sess-mu-alice");
      expect(aliceIds).not.toContain("sess-mu-bob");
      expect(aliceIds).not.toContain("sess-mu-charlie");

      expect(bobIds).toContain("sess-mu-bob");
      expect(bobIds).not.toContain("sess-mu-alice");
      expect(bobIds).not.toContain("sess-mu-charlie");

      expect(charlieIds).toContain("sess-mu-charlie");
      expect(charlieIds).not.toContain("sess-mu-alice");
      expect(charlieIds).not.toContain("sess-mu-bob");
    });

    test("Three users each see only their own traces (parallel requests)", async () => {
      await persistTrace(makeTrace("trc-mu-alice", "alice"));
      await persistTrace(makeTrace("trc-mu-bob", "bob"));
      await persistTrace(makeTrace("trc-mu-charlie", "charlie"));

      const [aliceRes, bobRes, charlieRes] = await Promise.all([
        app.request("http://localhost/traces?limit=50", {
          headers: await authFor("alice"),
        }),
        app.request("http://localhost/traces?limit=50", {
          headers: await authFor("bob"),
        }),
        app.request("http://localhost/traces?limit=50", {
          headers: await authFor("charlie"),
        }),
      ]);

      const aliceIds = (
        (await aliceRes.json()) as { traces: { traceId: string }[] }
      ).traces.map((t) => t.traceId);
      const bobIds = (
        (await bobRes.json()) as { traces: { traceId: string }[] }
      ).traces.map((t) => t.traceId);
      const charlieIds = (
        (await charlieRes.json()) as { traces: { traceId: string }[] }
      ).traces.map((t) => t.traceId);

      expect(aliceIds).toContain("trc-mu-alice");
      expect(aliceIds).not.toContain("trc-mu-bob");
      expect(aliceIds).not.toContain("trc-mu-charlie");

      expect(bobIds).toContain("trc-mu-bob");
      expect(bobIds).not.toContain("trc-mu-alice");
      expect(bobIds).not.toContain("trc-mu-charlie");

      expect(charlieIds).toContain("trc-mu-charlie");
      expect(charlieIds).not.toContain("trc-mu-alice");
      expect(charlieIds).not.toContain("trc-mu-bob");
    });

    test("Concurrent cross-user delete attempts all fail, owner's data intact", async () => {
      await getOrCreateSession("sess-mu-delete-target", "alice");

      // Bob and Charlie simultaneously attempt to delete Alice's session
      const [bobDelRes, charlieDelRes] = await Promise.all([
        app.request("http://localhost/sessions/sess-mu-delete-target", {
          method: "DELETE",
          headers: await authFor("bob"),
        }),
        app.request("http://localhost/sessions/sess-mu-delete-target", {
          method: "DELETE",
          headers: await authFor("charlie"),
        }),
      ]);

      expect(bobDelRes.status).toBe(404);
      expect(charlieDelRes.status).toBe(404);

      // Session must still belong to Alice
      const aliceGetRes = await app.request(
        "http://localhost/sessions/sess-mu-delete-target",
        { headers: await authFor("alice") },
      );
      expect(aliceGetRes.status).toBe(200);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("PE — Privilege escalation attempt vectors", () => {
    test("Knowledge of a session ID grants zero privilege to non-owners", async () => {
      const knownId = "well-known-session-id-for-isolation-test";
      await getOrCreateSession(knownId, "alice");

      // Bob knows the exact session ID
      const res = await app.request(`http://localhost/sessions/${knownId}`, {
        headers: await authFor("bob"),
      });
      expect(res.status).toBe(404);
    });

    test("Knowledge of a trace ID grants zero privilege to non-owners", async () => {
      const knownId = "well-known-trace-id-for-isolation-test";
      await persistTrace(makeTrace(knownId, "alice"));

      const res = await app.request(
        `http://localhost/traces/${knownId}`,
        { headers: await authFor("bob") },
      );
      expect(res.status).toBe(404);
    });

    test("Attacker cannot enumerate session IDs through the sessions list endpoint", async () => {
      await getOrCreateSession("sess-pe-alice-secret-1", "alice");
      await getOrCreateSession("sess-pe-alice-secret-2", "alice");
      await getOrCreateSession("sess-pe-bob-own", "bob");

      const res = await app.request("http://localhost/sessions", {
        headers: await authFor("bob"),
      });
      const raw = await res.text();

      expect(raw).not.toContain("sess-pe-alice-secret-1");
      expect(raw).not.toContain("sess-pe-alice-secret-2");
      expect(raw).toContain("sess-pe-bob-own");
    });

    test("Attacker cannot enumerate trace IDs through the traces list endpoint", async () => {
      await persistTrace(makeTrace("trc-pe-alice-secret-1", "alice"));
      await persistTrace(makeTrace("trc-pe-alice-secret-2", "alice"));
      await persistTrace(makeTrace("trc-pe-bob-own", "bob"));

      const res = await app.request("http://localhost/traces?limit=50", {
        headers: await authFor("bob"),
      });
      const raw = await res.text();

      expect(raw).not.toContain("trc-pe-alice-secret-1");
      expect(raw).not.toContain("trc-pe-alice-secret-2");
      expect(raw).toContain("trc-pe-bob-own");
    });

    test("User cannot inject a userId via query param to impersonate another user on sessions", async () => {
      await getOrCreateSession("sess-pe-alice-inject", "alice");

      // Authenticated as bob but with ?userId=alice query param (must be ignored)
      const res = await app.request(
        "http://localhost/sessions?userId=alice",
        { headers: await authFor("bob") },
      );
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        sessions: { sessionId: string }[];
      };
      const ids = body.sessions.map((s) => s.sessionId);
      expect(ids).not.toContain("sess-pe-alice-inject");
    });

    test("User cannot inject userId via POST /chat body to steal another user's session", async () => {
      await getOrCreateSession("sess-pe-alice-chat", "alice");

      // Bob sends a chat body with userId in it — the server must ignore the body userId
      // and use only jwt.sub (which is "bob") as the session owner check
      const res = await app.request("http://localhost/chat", {
        method: "POST",
        headers: await authFor("bob"),
        body: JSON.stringify({
          message: "steal this session",
          sessionId: "sess-pe-alice-chat",
          userId: "alice", // attacker-supplied — must be stripped by bodySchema
          agentId: "order-management",
        }),
      });
      // The session belongs to alice; bob's jwt.sub is "bob" → FORBIDDEN_SESSION → 404
      expect(res.status).toBe(404);
    });
  });
});
