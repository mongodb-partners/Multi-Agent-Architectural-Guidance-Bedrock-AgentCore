import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import * as jose from "jose";
import { clearAllSessionsForTests } from "../../src/lib/session-store.ts";

/** Mock the AgentCore Runtime invocation before `app` (and `chat` route) load. */
mock.module("../../src/adapters/agentcore-runtime.ts", () => ({
  assertAgentcoreOrchestratorArn: () => "arn:aws:bedrock-agentcore:us-east-1:000000000000:runtime/test",
  agentcoreOrchestratorArn: () => "arn:aws:bedrock-agentcore:us-east-1:000000000000:runtime/test",
  invokeAgentRuntime: async () => {
    throw Object.assign(new Error("mocked stream failure"), { name: "MockedRuntimeError" });
  },
}));

const { createApp } = await import("../../src/app.ts");
const { _setJwksResolverForTests } = await import("../../src/lib/jwt-verify.ts");
const { parseSseResponse } = await import("../helpers/sse-parse.ts");

const ISS = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_testpool";
const KID = "chat-sse-test-kid";

let signingKey: CryptoKey;
let app: ReturnType<typeof createApp>;
let TEST_SUB = "user-default";

async function authHeaders(): Promise<Record<string, string>> {
  const jwt = await new jose.SignJWT({ token_use: "access", client_id: "test-client" })
    .setProtectedHeader({ alg: "ES256", kid: KID })
    .setIssuer(ISS)
    .setSubject(TEST_SUB)
    .setExpirationTime("1h")
    .sign(signingKey);
  return { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" };
}

describe("POST /chat SSE error event (mocked invokeAgentRuntime)", () => {
  const saved = { ...process.env };

  beforeAll(async () => {
    process.env.RATE_LIMIT_DISABLED = "1";
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
  });

  test("emits AGENTCORE_RUNTIME_ERROR + done with error; does not append assistant message", async () => {
    TEST_SUB = "user-sse-err";
    const res = await app.request("http://localhost/chat", {
      method: "POST",
      headers: await authHeaders(),
      body: JSON.stringify({
        message: "hello",
        sessionId: "sse_err_sess",
        agentId: "order-management",
      }),
    });
    expect(res.status).toBe(200);
    const body = await res.text();
    const events = parseSseResponse(body);
    const errEv = events.find((e) => e.event === "error");
    expect(errEv).toBeDefined();
    const errPayload = JSON.parse(errEv!.data) as {
      code: string;
      message: string;
      requestId: string;
    };
    expect(errPayload.code).toBe("AGENTCORE_RUNTIME_ERROR");
    expect(errPayload.message).toContain("mocked");
    expect(typeof errPayload.requestId).toBe("string");

    const doneEv = events.filter((e) => e.event === "done").pop();
    expect(doneEv).toBeDefined();
    const donePayload = JSON.parse(doneEv!.data) as {
      sessionId: string;
      messageId: string;
      error?: { code: string; message: string };
    };
    expect(donePayload.sessionId).toBe("sse_err_sess");
    expect(donePayload.error?.code).toBe("AGENTCORE_RUNTIME_ERROR");

    const hist = await app.request("http://localhost/sessions/sse_err_sess", {
      headers: await authHeaders(),
    });
    expect(hist.status).toBe(200);
    const j = (await hist.json()) as { messages: { role: string }[] };
    expect(j.messages.every((m) => m.role === "user")).toBe(true);
    expect(j.messages.length).toBe(1);
  });

  // ----------------------------------------------------------------------
  // Malformed payload contract: the chat handler must respond with a
  // structured JSON 400 (`INVALID_REQUEST`), NOT a 401 from auth, 500, or
  // generic text. The previous live test was fooled by a stale Cognito
  // token that turned a real 400 into a 401 before the validator ran.
  // Pinning the exact codes here guarantees:
  //
  //   1. Empty body, missing `message`, missing `sessionId`, wrong types,
  //      and non-JSON all return 400 INVALID_REQUEST (not 200, 401, 500).
  //   2. The `requestId` field is present so server logs can be joined
  //      to the failing client request.
  //   3. With the auth middleware in place, every test still presents a
  //      valid JWT so the failure is the validator's, not auth's.
  // ----------------------------------------------------------------------
  const malformed: Array<{ name: string; body: string; contentType?: string }> = [
    { name: "empty body", body: "" },
    { name: "non-JSON text", body: "this is not json" },
    { name: "missing message", body: JSON.stringify({ sessionId: "x" }) },
    { name: "missing sessionId", body: JSON.stringify({ message: "hi" }) },
    { name: "wrong type for message", body: JSON.stringify({ message: 42, sessionId: "x" }) },
    { name: "wrong type for sessionId", body: JSON.stringify({ message: "hi", sessionId: 42 }) },
    { name: "empty message string", body: JSON.stringify({ message: "", sessionId: "x" }) },
    { name: "empty sessionId string", body: JSON.stringify({ message: "hi", sessionId: "" }) },
  ];

  for (const c of malformed) {
    test(`POST /chat 400 INVALID_REQUEST on ${c.name}`, async () => {
      const headers = await authHeaders();
      if (c.contentType) headers["Content-Type"] = c.contentType;
      const res = await app.request("http://localhost/chat", {
        method: "POST",
        headers,
        body: c.body,
      });
      expect(res.status).toBe(400);
      const body = (await res.json()) as { error: { code: string; message: string; requestId: string } };
      expect(body.error.code).toBe("INVALID_REQUEST");
      expect(typeof body.error.message).toBe("string");
      expect(body.error.message.length).toBeGreaterThan(0);
      expect(typeof body.error.requestId).toBe("string");
      expect(body.error.requestId).toMatch(/^req_/);
    });
  }

  test("POST /chat 401 UNAUTHORIZED when no Bearer token is supplied", async () => {
    const res = await app.request("http://localhost/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message: "hi", sessionId: "x" }),
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("UNAUTHORIZED");
  });
});
