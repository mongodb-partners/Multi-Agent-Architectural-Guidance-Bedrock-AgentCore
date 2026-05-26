/**
 * Unit tests for `writeLongTermMemory` (in `api/src/lib/long-term-memory.ts`).
 *
 * Strict-mode contract: when `embedDocumentText` returns `!ok` for a fact,
 *   1. the fact is still inserted via `bulkWrite` ($setOnInsert) — transcript /
 *      lexical search are preserved.
 *   2. the inserted doc has **no** `embedding` / `embeddingModel` keys.
 *   3. the `memory.long_term_write` trace event carries
 *      `embedding.skipped: <count>` and `embedding.skipReason: <code>`.
 *   4. the `Multiagent/Memory MemoryEmbeddingSkipped` EMF metric fires once
 *      with the dominant `code` dimension.
 *
 * Mocking strategy:
 *   - `setFactExtractorForTests(...)` (a test seam in long-term-memory.ts)
 *     lets us bypass the LLM extractor without mocking
 *     `@aws-sdk/client-bedrock-runtime` (which would leak to the Strands
 *     retry-contract test via Bun's process-global `mock.module`).
 *   - We mock `mongo-client.ts::getMongoDb` to capture bulkWrite ops.
 *   - We mock `embed-query.ts::embedDocumentText` to control per-fact
 *     embedding success/failure.
 *   - We DO NOT mock `cw-metrics.ts`; we observe its EMF stdout instead
 *     (same per-test interception technique as `cw-metrics.test.ts`).
 */

import { afterAll, afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

// ---------------------------------------------------------------------------
// Mock embed-query.ts (per-fact embed result).
// ---------------------------------------------------------------------------

let embedSequence: Array<
  | { ok: true; source: "voyage" | "bedrock"; modelId: string; vector: number[] }
  | { ok: false; code: string; message: string }
> = [];
let embedCursor = 0;

const realEmbed = await import("../../src/lib/embed-query.ts");
mock.module("../../src/lib/embed-query.ts", () => ({
  ...realEmbed,
  embedDocumentText: async (_text: string) => {
    const r = embedSequence[embedCursor] ?? embedSequence[embedSequence.length - 1];
    embedCursor += 1;
    return r;
  },
  embedQueryText: async (_text: string) => embedSequence[0],
}));

// ---------------------------------------------------------------------------
// Mock mongo-client.ts::getMongoDb to capture bulkWrite operations.
// ---------------------------------------------------------------------------

type BulkOp = {
  updateOne?: {
    filter: Record<string, unknown>;
    update: { $setOnInsert?: Record<string, unknown> };
    upsert?: boolean;
  };
};
const recordedOps: BulkOp[] = [];

const realMongoClient = await import("../../src/lib/mongo-client.ts");
mock.module("../../src/lib/mongo-client.ts", () => ({
  ...realMongoClient,
  getMongoDb: async () => ({
    collection: (_name: string) => ({
      createIndex: async () => undefined,
      bulkWrite: async (ops: BulkOp[], _opts?: unknown) => {
        recordedOps.push(...ops);
        return { upsertedCount: ops.length, modifiedCount: 0 };
      },
      countDocuments: async () => 0,
      find: () => ({
        sort: () => ({ limit: () => ({ toArray: async () => [] }) }),
      }),
    }),
  }),
}));

// ---------------------------------------------------------------------------
// EMF stdout interception (for cw-metrics.ts) — same technique as cw-metrics.test.ts.
// ---------------------------------------------------------------------------

type EmfRecord = {
  _aws: { CloudWatchMetrics: Array<{ Namespace: string; Metrics: Array<{ Name: string }> }> };
  [k: string]: unknown;
};
const emfCaptured: EmfRecord[] = [];
const origStdoutWrite = process.stdout.write.bind(process.stdout);

afterAll(() => {
  mock.module("../../src/lib/embed-query.ts", () => realEmbed);
  mock.module("../../src/lib/mongo-client.ts", () => realMongoClient);
});

const { TraceCollector } = await import("../../src/lib/trace-collector.ts");
const { withTrace } = await import("../../src/lib/trace-context.ts");
const {
  writeLongTermMemory,
  resetTtlIndexGuardForTests,
  setFactExtractorForTests,
  clearFactExtractorForTests,
} = await import("../../src/lib/long-term-memory.ts");

function findEmf(metricName: string): EmfRecord | undefined {
  return emfCaptured.find((r) =>
    r._aws.CloudWatchMetrics[0].Metrics.some((m) => m.Name === metricName),
  );
}

function fakeExtractor(facts: string[]) {
  return async () => ({
    accepted: facts,
    considered: facts.map((f) => ({
      text: f,
      matched: true,
      length: f.length,
      category: "preference",
    })),
    extractorModelId: "test-extractor",
    extractorLatencyMs: 1,
  });
}

beforeEach(() => {
  recordedOps.length = 0;
  emfCaptured.length = 0;
  embedSequence = [];
  embedCursor = 0;
  resetTtlIndexGuardForTests();
  delete process.env.AGENTCORE_MEMORY_STORE_ID;
  process.env.MEMORY_TRACE_VALUES = "1";
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
  delete process.env.MEMORY_TRACE_VALUES;
  clearFactExtractorForTests();
});

describe("writeLongTermMemory — strict-mode embedding skip", () => {
  test("two facts: one OK, one voyage_strict_failed → both rows inserted, only the OK one carries embedding fields, trace + metric reflect skipped count", async () => {
    setFactExtractorForTests(
      fakeExtractor(["I prefer dark mode", "My email is alice@example.com"]),
    );
    embedSequence = [
      { ok: true, source: "voyage", modelId: "voyage-multimodal-3", vector: [0.1, 0.2, 0.3] },
      { ok: false, code: "voyage_strict_failed", message: "SageMaker 503" },
    ];

    const collector = new TraceCollector({
      sessionId: "sess-ltm-1",
      messageId: "msg-1",
      agentId: "test-agent",
    });

    await withTrace(collector, async () => {
      await writeLongTermMemory(
        "user-ltm-1",
        "test-agent",
        "I prefer dark mode. My email is alice@example.com",
        "Got it, I'll remember.",
      );
    });

    expect(recordedOps).toHaveLength(2);

    const docOk = recordedOps[0]!.updateOne!.update.$setOnInsert!;
    const docSkipped = recordedOps[1]!.updateOne!.update.$setOnInsert!;
    expect(docOk).toHaveProperty("embedding");
    expect(docOk).toHaveProperty("embeddingModel", "voyage-multimodal-3");
    expect("embedding" in docSkipped).toBe(false);
    expect("embeddingModel" in docSkipped).toBe(false);
    expect(docOk).toHaveProperty("fact", "I prefer dark mode");
    expect(docSkipped).toHaveProperty("fact", "My email is alice@example.com");

    const trace = collector.toJSON();
    const writeEvent = trace.events.find((e) => e.type === "memory.long_term_write");
    expect(writeEvent).toBeDefined();
    const payload = writeEvent!.payload as Record<string, unknown>;
    expect(payload["embedding.skipped"]).toBe(1);
    expect(payload["embedding.skipReason"]).toBe("voyage_strict_failed");
    expect(payload.embeddedCount).toBe(1);

    const skip = findEmf("MemoryEmbeddingSkipped");
    expect(skip).toBeDefined();
    expect(skip!._aws.CloudWatchMetrics[0].Namespace).toBe("Multiagent/Memory");
    expect(skip!.MemoryEmbeddingSkipped).toBe(1);
    expect(skip!.code).toBe("voyage_strict_failed");
    expect(skip!.agentId).toBe("test-agent");
  });

  test("all facts embed successfully → no skip metric, no embedding.skipReason in trace", async () => {
    setFactExtractorForTests(fakeExtractor(["I work in Bangalore"]));
    embedSequence = [
      { ok: true, source: "voyage", modelId: "voyage-multimodal-3", vector: [0.1] },
    ];

    const collector = new TraceCollector({
      sessionId: "sess-ltm-ok",
      messageId: "msg-1",
      agentId: "test-agent",
    });

    await withTrace(collector, async () => {
      await writeLongTermMemory("user-ltm-ok", "test-agent", "I work in Bangalore", "OK");
    });

    expect(recordedOps).toHaveLength(1);
    expect(recordedOps[0]!.updateOne!.update.$setOnInsert!).toHaveProperty(
      "embeddingModel",
      "voyage-multimodal-3",
    );
    expect(findEmf("MemoryEmbeddingSkipped")).toBeUndefined();

    const trace = collector.toJSON();
    const writeEvent = trace.events.find((e) => e.type === "memory.long_term_write");
    const payload = writeEvent!.payload as Record<string, unknown>;
    expect(payload["embedding.skipped"]).toBe(0);
    expect(payload["embedding.skipReason"]).toBeUndefined();
  });

  test("all facts embed-failed (no_provider_configured) → all rows still inserted without embedding, skip metric count matches", async () => {
    setFactExtractorForTests(
      fakeExtractor(["I prefer email contact", "I work in Bangalore office"]),
    );
    embedSequence = [
      { ok: false, code: "no_provider_configured", message: "EMBEDDINGS_PROVIDER unset" },
      { ok: false, code: "no_provider_configured", message: "EMBEDDINGS_PROVIDER unset" },
    ];

    const collector = new TraceCollector({
      sessionId: "sess-ltm-noprov",
      messageId: "msg-1",
      agentId: "test-agent",
    });

    await withTrace(collector, async () => {
      await writeLongTermMemory(
        "user-ltm-noprov",
        "test-agent",
        "I prefer email contact. I work in Bangalore office.",
        "OK",
      );
    });

    expect(recordedOps).toHaveLength(2);
    for (const op of recordedOps) {
      const doc = op.updateOne!.update.$setOnInsert!;
      expect("embedding" in doc).toBe(false);
      expect("embeddingModel" in doc).toBe(false);
    }
    const skip2 = findEmf("MemoryEmbeddingSkipped");
    expect(skip2).toBeDefined();
    expect(skip2!.MemoryEmbeddingSkipped).toBe(2);
    expect(skip2!.code).toBe("no_provider_configured");
    const trace = collector.toJSON();
    const payload = trace.events.find((e) => e.type === "memory.long_term_write")!
      .payload as Record<string, unknown>;
    expect(payload["embedding.skipped"]).toBe(2);
    expect(payload["embedding.skipReason"]).toBe("no_provider_configured");
  });
});
