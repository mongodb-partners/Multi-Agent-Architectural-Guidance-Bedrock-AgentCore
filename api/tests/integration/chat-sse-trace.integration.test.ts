import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { clearAllSessionsForTests } from "../../src/lib/session-store.ts";
import { _clearTraceStoreForTests } from "../../src/lib/trace-store.ts";

// Mock the chat stream to yield a tiny deterministic payload. The trace
// collector still fires chat.turn.start / chat.turn.end around the stream.
mock.module("../../src/lib/run-chat-stream.ts", () => ({
  runChatStream: async function* mockRunChatStream() {
    yield { type: "token" as const, text: "Hello!" };
  },
}));

const { createApp } = await import("../../src/app.ts");
const { parseSseResponse } = await import("../helpers/sse-parse.ts");

const app = createApp();

describe("POST /chat — SSE trace events", () => {
  const saved = { ...process.env };

  beforeAll(() => {
    process.env.RATE_LIMIT_DISABLED = "1";
    process.env.TRACING_ENABLED = "1";
    delete process.env.ORCHESTRATOR_MODE;
  });

  afterAll(() => {
    process.env = { ...saved };
  });

  beforeEach(() => {
    clearAllSessionsForTests();
    _clearTraceStoreForTests();
  });

  test("emits trace events including chat.turn.start and chat.turn.end; persists trace; tags message", async () => {
    const res = await app.request("http://localhost/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        message: "hi there",
        sessionId: "trace_sess",
        agentId: "order-management",
      }),
    });
    expect(res.status).toBe(200);
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
    const trace = await app.request(`http://localhost/traces/${donePayload.traceId}`);
    expect(trace.status).toBe(200);

    const hist = await app.request("http://localhost/sessions/trace_sess");
    const j = (await hist.json()) as { messages: Array<{ role: string; traceId?: string }> };
    const asst = j.messages.find((m) => m.role === "assistant");
    expect(asst?.traceId).toBe(donePayload.traceId);
  });
});
