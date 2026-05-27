/**
 * Unit tests for `api/src/lib/embed-query.ts` — strict-mode provider selection.
 *
 * Strict-mode contract (no cross-provider fallback under any circumstance):
 *   - EMBEDDINGS_PROVIDER=voyage  + voyage OK   → voyage modelId, bedrock NEVER called
 *   - EMBEDDINGS_PROVIDER=voyage  + voyage fail → voyage_strict_failed, bedrock NEVER called
 *   - EMBEDDINGS_PROVIDER=titan   + bedrock OK  → bedrock modelId, voyage NEVER called
 *   - EMBEDDINGS_PROVIDER=titan   + image input → titan_no_multimodal, neither called
 *   - EMBEDDINGS_PROVIDER unset/unknown → no_provider_configured, neither called
 *
 * Overload contract: `embedQueryText` / `embedDocumentText` accept either
 * a plain `string` (auto-wrapped via `textToMultimodal`) or a
 * `MultimodalItem` from a caller that needs image segments.
 */

import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

const realVoyage = await import("../../src/adapters/voyage-embedding.ts");
const realBedrockRetrieval = await import("../../src/adapters/bedrock-retrieval.ts");

let voyageCalls = 0;
let bedrockCalls = 0;
let lastVoyageItem: unknown = null;
let voyageImpl: (
  item: unknown,
  endpoint: string,
  inputType?: "query" | "document",
  abortSignal?: AbortSignal,
) => Promise<unknown> = async () => ({ status: "ok", embedding: [0.1, 0.2], model: "voyage-stub" });
let bedrockImpl: (text: string, modelId: string, abortSignal?: AbortSignal) => Promise<unknown> = async () => ({
  status: "ok",
  embedding: [0.3, 0.4],
  modelId: "bedrock-stub",
});

mock.module("../../src/adapters/voyage-embedding.ts", () => ({
  ...realVoyage,
  voyageGenerateEmbedding: ((item: unknown, endpoint: string, inputType?: "query" | "document", abortSignal?: AbortSignal) => {
    voyageCalls += 1;
    lastVoyageItem = item;
    return voyageImpl(item, endpoint, inputType, abortSignal);
  }) as typeof realVoyage.voyageGenerateEmbedding,
  isVoyageConfigured: () => Boolean(process.env.VOYAGE_SAGEMAKER_ENDPOINT?.trim()),
  getVoyageEndpoint: () => process.env.VOYAGE_SAGEMAKER_ENDPOINT?.trim() ?? "",
}));

mock.module("../../src/adapters/bedrock-retrieval.ts", () => ({
  ...realBedrockRetrieval,
  bedrockGenerateEmbedding: (...args: Parameters<typeof realBedrockRetrieval.bedrockGenerateEmbedding>) => {
    bedrockCalls += 1;
    return bedrockImpl(...args);
  },
}));

const { embedQueryText, embedDocumentText, previewVector } = await import("../../src/lib/embed-query.ts");

describe("embedQueryText — strict-mode provider selection", () => {
  beforeEach(() => {
    voyageCalls = 0;
    bedrockCalls = 0;
    lastVoyageItem = null;
    voyageImpl = async () => ({ status: "ok", embedding: [0.1, 0.2, 0.3, 0.4], model: "voyage-multimodal-3" });
    bedrockImpl = async () => ({
      status: "ok",
      embedding: [0.5, 0.6, 0.7, 0.8],
      modelId: "amazon.titan-embed-text-v2:0",
    });
    delete process.env.EMBEDDINGS_PROVIDER;
    delete process.env.VOYAGE_SAGEMAKER_ENDPOINT;
    delete process.env.EMBEDDING_MODEL_ID;
    delete process.env.VOYAGE_MODEL_NAME;
    delete process.env.VOYAGE_MARKETPLACE_MODEL;
  });

  afterEach(() => {
    delete process.env.EMBEDDINGS_PROVIDER;
    delete process.env.VOYAGE_SAGEMAKER_ENDPOINT;
    delete process.env.EMBEDDING_MODEL_ID;
    delete process.env.VOYAGE_MODEL_NAME;
    delete process.env.VOYAGE_MARKETPLACE_MODEL;
  });

  // -----------------------------------------------------------------
  // EMBEDDINGS_PROVIDER=voyage
  // -----------------------------------------------------------------

  test("voyage mode: returns voyage vector, NEVER calls bedrock", async () => {
    process.env.EMBEDDINGS_PROVIDER = "voyage";
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    voyageImpl = async () => ({ status: "ok", embedding: [1, 2, 3, 4], model: "voyage-multimodal-3" });

    const r = await embedQueryText("hello world");

    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.source).toBe("voyage");
      expect(r.modelId).toBe("voyage-multimodal-3");
      expect(r.vector).toEqual([1, 2, 3, 4]);
    }
    expect(voyageCalls).toBe(1);
    expect(bedrockCalls).toBe(0);
    // string was auto-wrapped to MultimodalItem before crossing the adapter boundary.
    expect(lastVoyageItem).toEqual([{ type: "text", text: "hello world" }]);
  });

  test("voyage mode: voyage throws → voyage_strict_failed, bedrock NEVER called", async () => {
    process.env.EMBEDDINGS_PROVIDER = "voyage";
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    voyageImpl = async () => {
      throw new Error("SageMaker 503");
    };

    const r = await embedQueryText("hello");

    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.code).toBe("voyage_strict_failed");
      expect(r.message).toMatch(/SageMaker 503/);
    }
    expect(bedrockCalls).toBe(0);
  });

  test("voyage mode: voyage returns unrecognized shape → voyage_strict_failed", async () => {
    process.env.EMBEDDINGS_PROVIDER = "voyage";
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    voyageImpl = async () => ({ status: "error", error: "unknown" });

    const r = await embedQueryText("hello");

    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.code).toBe("voyage_strict_failed");
    expect(bedrockCalls).toBe(0);
  });

  test("voyage mode without VOYAGE_SAGEMAKER_ENDPOINT → voyage_strict_failed (no calls)", async () => {
    process.env.EMBEDDINGS_PROVIDER = "voyage";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";

    const r = await embedQueryText("hello");

    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.code).toBe("voyage_strict_failed");
    expect(voyageCalls).toBe(0);
    expect(bedrockCalls).toBe(0);
  });

  test("voyage mode falls back voyage modelId to env override or default", async () => {
    process.env.EMBEDDINGS_PROVIDER = "voyage";
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    voyageImpl = async () => ({ status: "ok", embedding: [1, 2, 3, 4] }); // no `model` field

    const r1 = await embedQueryText("hello");
    expect(r1.ok).toBe(true);
    if (r1.ok) expect(r1.modelId).toBe("voyage-multimodal-3");

    process.env.VOYAGE_MARKETPLACE_MODEL = "voyage-multimodal-3.5";
    const r2 = await embedQueryText("hello");
    expect(r2.ok).toBe(true);
    if (r2.ok) expect(r2.modelId).toBe("voyage-multimodal-3.5");
  });

  // -----------------------------------------------------------------
  // string | MultimodalItem overload
  // -----------------------------------------------------------------

  test("voyage mode: MultimodalItem with image_url is forwarded unchanged", async () => {
    process.env.EMBEDDINGS_PROVIDER = "voyage";
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    voyageImpl = async () => ({ status: "ok", embedding: [1, 2], model: "voyage-multimodal-3" });

    const item = [
      { type: "text", text: "describe" },
      { type: "image_url", image_url: "https://example.com/x.jpg" },
    ] as const;
    const r = await embedDocumentText(item as never);

    expect(r.ok).toBe(true);
    expect(lastVoyageItem).toEqual(item as unknown as Record<string, unknown>[]);
  });

  // -----------------------------------------------------------------
  // EMBEDDINGS_PROVIDER=titan
  // -----------------------------------------------------------------

  test("titan mode: returns bedrock vector, NEVER calls voyage", async () => {
    process.env.EMBEDDINGS_PROVIDER = "titan";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";

    const r = await embedQueryText("hello");

    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.source).toBe("bedrock");
      expect(r.modelId).toBe("amazon.titan-embed-text-v2:0");
    }
    expect(voyageCalls).toBe(0);
    expect(bedrockCalls).toBe(1);
  });

  test("titan + image segment → titan_no_multimodal (NEITHER provider called)", async () => {
    process.env.EMBEDDINGS_PROVIDER = "titan";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";

    const r = await embedQueryText([
      { type: "text", text: "describe" },
      { type: "image_url", image_url: "https://example.com/x.jpg" },
    ]);

    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.code).toBe("titan_no_multimodal");
    expect(voyageCalls).toBe(0);
    expect(bedrockCalls).toBe(0);
  });

  test("titan mode: bedrock returns error envelope → titan_strict_failed", async () => {
    process.env.EMBEDDINGS_PROVIDER = "titan";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    bedrockImpl = async () => ({ status: "error", error: "throttled" });

    const r = await embedQueryText("hello");

    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.code).toBe("titan_strict_failed");
    expect(voyageCalls).toBe(0);
  });

  test("titan mode without EMBEDDING_MODEL_ID → titan_strict_failed (no calls)", async () => {
    process.env.EMBEDDINGS_PROVIDER = "titan";
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";

    const r = await embedQueryText("hello");

    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.code).toBe("titan_strict_failed");
    expect(voyageCalls).toBe(0);
    expect(bedrockCalls).toBe(0);
  });

  test("titan mode rejects vectors containing non-finite values", async () => {
    process.env.EMBEDDINGS_PROVIDER = "titan";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    bedrockImpl = async () => ({ status: "ok", embedding: [0.1, NaN, 0.3] });

    const r = await embedQueryText("hello");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.code).toBe("titan_strict_failed");
  });

  // -----------------------------------------------------------------
  // EMBEDDINGS_PROVIDER unset / unknown
  // -----------------------------------------------------------------

  test("unset provider → no_provider_configured (no calls)", async () => {
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";

    const r = await embedQueryText("hello");

    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.code).toBe("no_provider_configured");
    expect(voyageCalls).toBe(0);
    expect(bedrockCalls).toBe(0);
  });

  test("unrecognised provider value → no_provider_configured", async () => {
    process.env.EMBEDDINGS_PROVIDER = "openai";
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";

    const r = await embedQueryText("hello");

    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.code).toBe("no_provider_configured");
    expect(voyageCalls).toBe(0);
    expect(bedrockCalls).toBe(0);
  });

  // -----------------------------------------------------------------
  // Empty input always rejected (regression)
  // -----------------------------------------------------------------

  test("rejects empty / whitespace text with a typed error (no provider call)", async () => {
    process.env.EMBEDDINGS_PROVIDER = "voyage";
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    for (const empty of ["", "   ", "\n\t"]) {
      const r = await embedQueryText(empty);
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.code).toBe("no_provider_configured");
    }
    expect(voyageCalls).toBe(0);
    expect(bedrockCalls).toBe(0);
  });
});

describe("previewVector", () => {
  test("captures length, head, and tail (rounded to 6dp)", () => {
    const v = Array.from({ length: 1024 }, (_, i) => i / 1024);
    const p = previewVector(v);
    expect(p.length).toBe(1024);
    expect(p.head).toHaveLength(4);
    expect(p.tail).toHaveLength(4);
    expect(p.tail[3]).toBeCloseTo(0.999023, 5);
  });

  test("omits tail for short vectors (<= 8 entries) to avoid duplicate samples", () => {
    expect(previewVector([1, 2, 3, 4]).tail).toEqual([]);
    expect(previewVector([1, 2, 3, 4, 5, 6, 7, 8]).tail).toEqual([]);
    expect(previewVector([1, 2, 3, 4, 5, 6, 7, 8, 9]).tail).toEqual([6, 7, 8, 9]);
  });
});
