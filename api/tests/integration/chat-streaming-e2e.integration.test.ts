/**
 * End-to-end streaming integration test for `POST /chat`.
 *
 * Stubs `invokeAgentRuntime` to yield a sequence of stream + trace + done
 * frames asynchronously (with `setTimeout(0)` between yields to simulate
 * network gaps). Verifies that the chat route forwards each token to the
 * client SSE channel as soon as it arrives, in the same order — i.e., the
 * route never buffers the entire response before flushing.
 *
 * This is the test that catches the original "buffered SSE masquerading as
 * stream" regression: if anyone reverts the for-await loop in chat.ts to
 * accumulate `fullReply` and write a single `event: token`, this test will
 * see one frame instead of three and fail.
 */

import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import * as jose from "jose";
import { clearAllSessionsForTests } from "../../src/lib/session-store.ts";
import { _clearTraceStoreForTests } from "../../src/lib/trace-store.ts";

mock.module("../../src/adapters/agentcore-runtime.ts", () => ({
  assertAgentcoreOrchestratorArn: () =>
    "arn:aws:bedrock-agentcore:us-east-1:000000000000:runtime/test",
  agentcoreOrchestratorArn: () =>
    "arn:aws:bedrock-agentcore:us-east-1:000000000000:runtime/test",
  // Direct routing: classifier picks order-management; we expose its ARN.
  agentcoreSpecialistArn: (id: string) =>
    id === "order-management"
      ? "arn:aws:bedrock-agentcore:us-east-1:000000000000:runtime/order"
      : undefined,
  setAgentcoreSpecialistArnOverrides: () => undefined,
  // Async generator that yields each frame on a separate microtask so the
  // chat route MUST forward incrementally to surface them in order.
  invokeAgentRuntime: async function* () {
    const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
    yield { kind: "stream", part: { type: "agent_active", agentId: "order-management", agentName: "Order Management" } };
    await sleep(5);
    yield { kind: "stream", part: { type: "token", text: "Hello " } };
    await sleep(5);
    yield {
      kind: "trace",
      event: {
        id: "trace-1",
        type: "model.text_delta_batch",
        ts: Date.now(),
        payload: { text: "Hello ", bytes: 6, windowMs: 5 },
      },
    };
    await sleep(5);
    yield { kind: "stream", part: { type: "token", text: "from " } };
    await sleep(5);
    yield { kind: "stream", part: { type: "token", text: "specialist!" } };
    await sleep(5);
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

const ISS = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_streamingpool";
const KID = "stream-test-kid";
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

describe("POST /chat — end-to-end streaming through mocked AgentCore Runtime", () => {
  const saved = { ...process.env };

  beforeAll(async () => {
    process.env.RATE_LIMIT_DISABLED = "1";
    process.env.AUTH_JWKS_URI = "https://example.invalid/jwks.json";
    process.env.AUTH_ISSUER = ISS;
    process.env.CLASSIFIER_BACKEND = "heuristic";
    delete process.env.USE_ORCHESTRATOR_RUNTIME;

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

  test("classifier-direct path: each runtime stream frame becomes its own SSE event in order", async () => {
    const headers = await authHeaders("user-stream");
    const res = await app.request("http://localhost/chat", {
      method: "POST",
      headers,
      body: JSON.stringify({
        message: "Where is my order shipment delivery tracking",
        sessionId: "stream_sess",
      }),
    });
    expect(res.status).toBe(200);
    const body = await res.text();
    const events = parseSseResponse(body);

    const tokens = events.filter((e) => e.event === "token");
    expect(tokens).toHaveLength(3);
    expect(tokens.map((t) => (JSON.parse(t.data) as { text: string }).text)).toEqual([
      "Hello ",
      "from ",
      "specialist!",
    ]);

    const agentActives = events.filter((e) => e.event === "agent_active");
    expect(agentActives).toHaveLength(1);
    expect(JSON.parse(agentActives[0].data)).toMatchObject({ agentId: "order-management" });

    const handoff = events.find((e) => e.event === "handoff");
    expect(handoff).toBeDefined();
    const hp = JSON.parse(handoff!.data) as { from: string; to: string };
    expect(hp.from).toBe("orchestrator");
    expect(hp.to).toBe("order-management");

    const done = events.filter((e) => e.event === "done").pop();
    expect(done).toBeDefined();
    const dp = JSON.parse(done!.data) as { sessionId: string; messageId: string; traceId?: string };
    expect(dp.sessionId).toBe("stream_sess");
    expect(dp.traceId).toBeDefined();

    // Token frames must precede the done frame (otherwise we are buffering).
    const orderedEvents = events.map((e) => e.event);
    const lastTokenIdx = orderedEvents.lastIndexOf("token");
    const doneIdx = orderedEvents.lastIndexOf("done");
    expect(lastTokenIdx).toBeLessThan(doneIdx);

    // Assistant message is persisted with the assembled token text.
    const hist = await app.request("http://localhost/sessions/stream_sess", { headers });
    const j = (await hist.json()) as { messages: Array<{ role: string; content: string }> };
    const asst = j.messages.find((m) => m.role === "assistant");
    expect(asst?.content).toBe("Hello from specialist!");
  });
});
