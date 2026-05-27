import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import * as jose from "jose";
import { clearAllSessionsForTests } from "../../src/lib/session-store.ts";
import { _clearTraceStoreForTests } from "../../src/lib/trace-store.ts";

// Mock the AgentCore Runtime invocation to return a tiny deterministic
// response. The trace collector still fires chat.turn.start / chat.turn.end
// around the call.
mock.module("../../src/adapters/agentcore-runtime.ts", () => ({
  assertAgentcoreOrchestratorArn: () =>
    "arn:aws:bedrock-agentcore:us-east-1:000000000000:runtime/test",
  agentcoreOrchestratorArn: () =>
    "arn:aws:bedrock-agentcore:us-east-1:000000000000:runtime/test",
  agentcoreSpecialistArn: () => undefined,
  setAgentcoreSpecialistArnOverrides: () => undefined,
  // The streaming contract is `AsyncIterable<RuntimeStreamEvent>`. Yield a
  // single token then a `done` frame so the chat route forwards exactly the
  // shape it would in production.
  // eslint-disable-next-line require-yield
  invokeAgentRuntime: async function* () {
    yield { kind: "stream", part: { type: "token", text: "Hello!" } };
    yield {
      kind: "done",
      payload: {
        agentId: "order-management",
        nestedTraceId: "nested-trace-stub",
        nestedEventsDropped: 0,
      },
    };
  },
}));

const { createApp } = await import("../../src/app.ts");
const { _setJwksResolverForTests } = await import("../../src/lib/jwt-verify.ts");
const { parseSseResponse } = await import("../helpers/sse-parse.ts");

const ISS = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_testpool";
const KID = "chat-trace-test-kid";

let signingKey: CryptoKey;
let app: ReturnType<typeof createApp>;

async function authHeaders(sub: string): Promise<Record<string, string>> {
  const jwt = await new jose.SignJWT({ token_use: "access", client_id: "test-client" })
    .setProtectedHeader({ alg: "ES256", kid: KID })
    .setIssuer(ISS)
    .setSubject(sub)
    .setExpirationTime("1h")
    .sign(signingKey);
  return { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" };
}

describe("POST /chat — SSE trace events", () => {
  const saved = { ...process.env };

  beforeAll(async () => {
    process.env.RATE_LIMIT_DISABLED = "1";
    process.env.TRACING_ENABLED = "1";
    process.env.AUTH_JWKS_URI = "https://example.invalid/jwks.json";
    process.env.AUTH_ISSUER = ISS;
    delete process.env.ORCHESTRATOR_MODE;

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
    clearAllSessionsForTests();
    _clearTraceStoreForTests();
  });

  test("emits trace events including chat.turn.start and chat.turn.end; persists trace; tags message", async () => {
    const headers = await authHeaders("user-trace");
    const res = await app.request("http://localhost/chat", {
      method: "POST",
      headers,
      body: JSON.stringify({
        message: "hi there",
        sessionId: "trace_sess",
        agentId: "order-management",
      }),
    });
    expect(res.status).toBe(200);
    const xTrace = res.headers.get("X-Trace-Id");
    expect(xTrace).toBeTruthy();
    expect(xTrace).toMatch(/^[0-9a-f]{32}$/i);
    const body = await res.text();
    const events = parseSseResponse(body);

    const traceEvents = events.filter((e) => e.event === "trace");
    expect(traceEvents.length).toBeGreaterThan(0);
    const types = traceEvents
      .map((e) => {
        try {
          return (JSON.parse(e.data) as { type: string }).type;
        } catch {
          return undefined;
        }
      })
      .filter(Boolean);
    expect(types).toContain("chat.turn.start");
    expect(types).toContain("chat.turn.end");

    // done event should carry a traceId.
    const doneEv = events.filter((e) => e.event === "done").pop();
    expect(doneEv).toBeDefined();
    const donePayload = JSON.parse(doneEv!.data) as { traceId?: string; messageId: string };
    expect(donePayload.traceId).toBeDefined();

    // Trace is retrievable by id and tagged on the assistant message.
    const trace = await app.request(`http://localhost/traces/${donePayload.traceId}`, {
      headers,
    });
    expect(trace.status).toBe(200);

    const hist = await app.request("http://localhost/sessions/trace_sess", { headers });
    const j = (await hist.json()) as { messages: Array<{ role: string; traceId?: string }> };
    const asst = j.messages.find((m) => m.role === "assistant");
    expect(asst?.traceId).toBe(donePayload.traceId);
  });
});
