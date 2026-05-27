/**
 * Unit tests for `mirrorMessageToMongo` (in `api/src/lib/session-store.ts`).
 *
 * Strict-mode contract: when `embedDocumentText` returns `!ok`, the chat row
 * still lands in `chat_messages` (without `embedding` / `embeddingModel`) but
 * carries an `embeddingError` marker, AND a `chat.mirror.embedding_failed`
 * trace event is emitted, AND the trace doc is re-persisted, AND a
 * `ChatMirrorEmbeddingSkipped` EMF metric is incremented.
 *
 * The mirror function is private; we drive it via the public
 * `appendUserMessage` API (which calls `scheduleMirror` internally) and
 * assert on the side effects observed through mocked dependencies.
 */

import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

// ---------------------------------------------------------------------------
// Mocks must be installed before importing the module under test.
// ---------------------------------------------------------------------------

const persistedDocs: Array<Record<string, unknown>> = [];
let embedImpl: (text: string) => Promise<
  | { ok: true; source: "voyage" | "bedrock"; modelId: string; vector: number[] }
  | { ok: false; code: string; message: string }
> = async () => ({ ok: false, code: "voyage_strict_failed", message: "test failure" });

// EMF metrics are observed via stdout interception (same technique as
// `cw-metrics.test.ts`). We intentionally do NOT `mock.module("cw-metrics")`
// because Bun's mock.module is process-global: stubbing
// `recordChatMirrorEmbeddingSkipped` here leaks into the cw-metrics
// lock-down test even after afterAll restoration (Bun captures the binding
// at file load time). Stdout interception is per-test and self-contained.
type EmfRecord = {
  _aws: { CloudWatchMetrics: Array<{ Namespace: string; Metrics: Array<{ Name: string }> }> };
  [k: string]: unknown;
};
const emfCaptured: EmfRecord[] = [];
const origStdoutWrite = process.stdout.write.bind(process.stdout);
function findEmf(metricName: string): EmfRecord | undefined {
  return emfCaptured.find((r) =>
    r._aws.CloudWatchMetrics[0].Metrics.some((m) => m.Name === metricName),
  );
}

mock.module("../../src/lib/chat-messages-collection.ts", () => ({
  chatMessagesCollectionName: () => "chat_messages",
  persistChatMessage: async (doc: Record<string, unknown>) => {
    persistedDocs.push(doc);
    return true;
  },
  deleteMessagesBySession: async () => 0,
  getChatMessagesCollection: async () => null,
}));

// Stub chat-sessions persistence so `appendUserMessage`'s `saveToMongo` doesn't
// try to open a real Mongo connection (the mirror still runs because
// `usePersistentChatSessions()` returns true).
mock.module("../../src/lib/chat-sessions-collection.ts", () => ({
  persistChatSessions: () => true,
  usePersistentChatSessions: () => true,
  chatSessionsCollectionName: () => "chat_sessions",
  getChatSessionsCollection: async () => null,
}));

// Preserve real exports (e.g. `previewVector` is imported transitively by
// mongodb-mcp-client.ts) and only replace the two embed functions used here.
const realEmbed = await import("../../src/lib/embed-query.ts");
mock.module("../../src/lib/embed-query.ts", () => ({
  ...realEmbed,
  embedDocumentText: (text: string) => embedImpl(text),
  embedQueryText: (text: string) => embedImpl(text),
}));

// Use a real TraceCollector so currentTrace()?.event(...) reaches a live
// collector and we can inspect emitted events via toJSON().
const { TraceCollector } = await import("../../src/lib/trace-collector.ts");
const { withTrace } = await import("../../src/lib/trace-context.ts");
const { _clearTraceStoreForTests, getTraceById } = await import("../../src/lib/trace-store.ts");

const {
  appendUserMessage,
  clearAllSessionsForTests,
} = await import("../../src/lib/session-store.ts");

// Wait for queued microtasks (mirror runs via queueMicrotask).
async function flushMicrotasks(): Promise<void> {
  // Two cycles cover the chained `await embedDocumentText(...) → persistChatMessage(...) → persistTrace(...)`.
  for (let i = 0; i < 5; i++) {
    await Promise.resolve();
    await new Promise((r) => setTimeout(r, 0));
  }
}

beforeEach(() => {
  persistedDocs.length = 0;
  emfCaptured.length = 0;
  clearAllSessionsForTests();
  _clearTraceStoreForTests();
  process.env.PERSIST_CHAT_SESSIONS = "1";
  (process.stdout.write as unknown) = (chunk: string | Uint8Array) => {
    const s = typeof chunk === "string" ? chunk : Buffer.from(chunk).toString("utf8");
    for (const line of s.split("\n")) {
      if (!line.trim()) continue;
      try {
        const obj = JSON.parse(line);
        if (obj && typeof obj === "object" && "_aws" in obj) {
          emfCaptured.push(obj as EmfRecord);
        }
      } catch {
        // not EMF — ignore
      }
    }
    return true;
  };
});

afterEach(() => {
  process.stdout.write = origStdoutWrite;
  clearAllSessionsForTests();
  _clearTraceStoreForTests();
  delete process.env.PERSIST_CHAT_SESSIONS;
});

describe("mirrorMessageToMongo — strict embedding failure", () => {
  test("voyage_strict_failed: row persisted, no embedding fields, embeddingError set, trace event emitted, metric incremented, trace re-persisted", async () => {
    const collector = new TraceCollector({
      sessionId: "sess-mirror-1",
      messageId: "msg-init",
      agentId: "test-agent",
    });
    embedImpl = async () => ({
      ok: false,
      code: "voyage_strict_failed",
      message: "SageMaker 503",
    });

    await withTrace(collector, async () => {
      await appendUserMessage("sess-mirror-1", "hello world", "user-mirror");
    });
    await flushMicrotasks();

    expect(persistedDocs).toHaveLength(1);
    const doc = persistedDocs[0]!;
    expect(doc.content).toBe("hello world");
    expect(doc.sessionId).toBe("sess-mirror-1");
    expect("embedding" in doc).toBe(false);
    expect("embeddingModel" in doc).toBe(false);
    expect(doc.embeddingError).toMatchObject({
      code: "voyage_strict_failed",
      message: "SageMaker 503",
    });
    expect((doc.embeddingError as { ts: Date }).ts).toBeInstanceOf(Date);

    const skipMetric = findEmf("ChatMirrorEmbeddingSkipped");
    expect(skipMetric).toBeDefined();
    expect(skipMetric!._aws.CloudWatchMetrics[0].Namespace).toBe("Multiagent/Chat");
    expect(skipMetric!.ChatMirrorEmbeddingSkipped).toBe(1);
    expect(skipMetric!.code).toBe("voyage_strict_failed");

    const trace = collector.toJSON();
    const event = trace.events.find((e) => e.type === "chat.mirror.embedding_failed");
    expect(event).toBeDefined();
    expect(event?.payload).toMatchObject({
      sessionId: "sess-mirror-1",
      code: "voyage_strict_failed",
    });
    const persistedTrace = await getTraceById(collector.traceId);
    expect(persistedTrace?.traceId).toBe(collector.traceId);
    expect(
      persistedTrace?.events.some((e) => e.type === "chat.mirror.embedding_failed"),
    ).toBe(true);
  });

  test("happy path: row persisted with embedding + model, no embeddingError, no trace event, no metric", async () => {
    const collector = new TraceCollector({
      sessionId: "sess-mirror-ok",
      messageId: "msg-init",
      agentId: "test-agent",
    });
    embedImpl = async () => ({
      ok: true,
      source: "voyage",
      modelId: "voyage-multimodal-3",
      vector: [0.1, 0.2, 0.3, 0.4],
    });

    await withTrace(collector, async () => {
      await appendUserMessage("sess-mirror-ok", "hello", "user-ok");
    });
    await flushMicrotasks();

    expect(persistedDocs).toHaveLength(1);
    const doc = persistedDocs[0]!;
    expect(doc.embedding).toEqual([0.1, 0.2, 0.3, 0.4]);
    expect(doc.embeddingModel).toBe("voyage-multimodal-3");
    expect("embeddingError" in doc).toBe(false);
    expect(findEmf("ChatMirrorEmbeddingSkipped")).toBeUndefined();

    const trace = collector.toJSON();
    expect(trace.events.find((e) => e.type === "chat.mirror.embedding_failed")).toBeUndefined();
  });

  test("embed throws: row persisted with embeddingError={code:embed_threw}, metric incremented, trace event present", async () => {
    const collector = new TraceCollector({
      sessionId: "sess-mirror-throw",
      messageId: "msg-init",
      agentId: "test-agent",
    });
    embedImpl = async () => {
      throw new Error("network reset");
    };

    await withTrace(collector, async () => {
      await appendUserMessage("sess-mirror-throw", "hello", "user-throw");
    });
    await flushMicrotasks();

    expect(persistedDocs).toHaveLength(1);
    const doc = persistedDocs[0]!;
    expect("embedding" in doc).toBe(false);
    expect((doc.embeddingError as { code: string }).code).toBe("embed_threw");
    const skip = findEmf("ChatMirrorEmbeddingSkipped");
    expect(skip).toBeDefined();
    expect(skip!.code).toBe("embed_threw");
    const trace = collector.toJSON();
    expect(trace.events.find((e) => e.type === "chat.mirror.embedding_failed")).toBeDefined();
  });
});
