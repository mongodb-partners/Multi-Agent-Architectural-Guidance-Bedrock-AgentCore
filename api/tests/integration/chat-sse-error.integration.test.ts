import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { clearAllSessionsForTests } from "../../src/lib/session-store.ts";

/** Mock chat stream before `app` (and `chat` route) load so the route binds the stub. */
mock.module("../../src/lib/run-chat-stream.ts", () => ({
  runChatStream: async function* mockRunChatStream() {
    yield {
      type: "stream_error" as const,
      code: "TEST_STREAM_ERROR",
      message: "mocked stream failure",
    };
  },
}));

const { createApp } = await import("../../src/app.ts");
const { parseSseResponse } = await import("../helpers/sse-parse.ts");

const app = createApp();

describe("POST /chat SSE error event (mocked runChatStream)", () => {
  const saved = { ...process.env };

  beforeAll(() => {
    process.env.RATE_LIMIT_DISABLED = "1";
    delete process.env.ORCHESTRATOR_MODE;
  });

  afterAll(() => {
    process.env = { ...saved };
  });

  beforeEach(() => {
    clearAllSessionsForTests();
  });

  test("emits error + done with error; does not append assistant message", async () => {
    const res = await app.request("http://localhost/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
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
    expect(errPayload.code).toBe("TEST_STREAM_ERROR");
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
    expect(donePayload.error?.code).toBe("TEST_STREAM_ERROR");

    const hist = await app.request("http://localhost/sessions/sse_err_sess");
    expect(hist.status).toBe(200);
    const j = (await hist.json()) as { messages: { role: string }[] };
    expect(j.messages.every((m) => m.role === "user")).toBe(true);
    expect(j.messages.length).toBe(1);
  });
});
