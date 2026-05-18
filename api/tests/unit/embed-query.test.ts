/**
 * Unit tests for `api/src/lib/embed-query.ts`.
 *
 * The module wraps `voyageGenerateEmbedding` (Voyage AI on SageMaker, primary)
 * and `bedrockGenerateEmbedding` (Titan / Cohere fallback) with a uniform
 * `EmbedResult` shape. We mock both adapters so the tests never reach AWS.
 *
 * Provider-priority contract (pinned here so a careless change doesn't flip
 * the order silently and start spending Bedrock dollars when Voyage is up):
 *   - VOYAGE_SAGEMAKER_ENDPOINT set & call succeeds  → voyage
 *   - VOYAGE_SAGEMAKER_ENDPOINT set & call fails     → bedrock fallback
 *   - VOYAGE_SAGEMAKER_ENDPOINT unset                → bedrock direct
 *   - Neither configured                             → typed error, no throw
 */

import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

const realVoyage = await import("../../src/adapters/voyage-embedding.ts");
const realBedrockRetrieval = await import("../../src/adapters/bedrock-retrieval.ts");

let voyageImpl: (
  text: string,
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
  voyageGenerateEmbedding: (...args: Parameters<typeof realVoyage.voyageGenerateEmbedding>) =>
    voyageImpl(...args),
  isVoyageConfigured: () => Boolean(process.env.VOYAGE_SAGEMAKER_ENDPOINT?.trim()),
  getVoyageEndpoint: () => process.env.VOYAGE_SAGEMAKER_ENDPOINT?.trim() ?? "",
}));

mock.module("../../src/adapters/bedrock-retrieval.ts", () => ({
  ...realBedrockRetrieval,
  bedrockGenerateEmbedding: (...args: Parameters<typeof realBedrockRetrieval.bedrockGenerateEmbedding>) =>
    bedrockImpl(...args),
}));

const { embedQueryText, previewVector } = await import("../../src/lib/embed-query.ts");

describe("embedQueryText provider order", () => {
  beforeEach(() => {
    voyageImpl = async () => ({ status: "ok", embedding: [0.1, 0.2, 0.3, 0.4], model: "voyage-3.5-lite" });
    bedrockImpl = async () => ({ status: "ok", embedding: [0.5, 0.6, 0.7, 0.8], modelId: "amazon.titan-embed-text-v2:0" });
    delete process.env.VOYAGE_SAGEMAKER_ENDPOINT;
    delete process.env.EMBEDDING_MODEL_ID;
  });

  afterEach(() => {
    delete process.env.VOYAGE_SAGEMAKER_ENDPOINT;
    delete process.env.EMBEDDING_MODEL_ID;
  });

  test("uses Voyage when VOYAGE_SAGEMAKER_ENDPOINT is set", async () => {
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    let voyageCalls = 0;
    voyageImpl = async () => {
      voyageCalls += 1;
      return { status: "ok", embedding: [1, 2, 3, 4], model: "voyage-3.5-lite" };
    };
    const r = await embedQueryText("hello world");
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.source).toBe("voyage");
      expect(r.modelId).toBe("voyage-3.5-lite");
      expect(r.vector).toEqual([1, 2, 3, 4]);
    }
    expect(voyageCalls).toBe(1);
  });

  test("falls back to Bedrock when Voyage throws and EMBEDDING_MODEL_ID is set", async () => {
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    voyageImpl = async () => {
      throw new Error("SageMaker timeout");
    };
    let bedrockCalls = 0;
    bedrockImpl = async () => {
      bedrockCalls += 1;
      return { status: "ok", embedding: [9, 9, 9, 9], modelId: "amazon.titan-embed-text-v2:0" };
    };
    const r = await embedQueryText("hello");
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.source).toBe("bedrock");
      expect(r.modelId).toBe("amazon.titan-embed-text-v2:0");
    }
    expect(bedrockCalls).toBe(1);
  });

  test("falls back to Bedrock when Voyage returns an unrecognized shape", async () => {
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    voyageImpl = async () => ({ status: "error", error: "unknown" });
    const r = await embedQueryText("hello");
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.source).toBe("bedrock");
  });

  test("uses Bedrock directly when Voyage is unconfigured", async () => {
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    let voyageCalls = 0;
    voyageImpl = async () => {
      voyageCalls += 1;
      return { status: "ok", embedding: [1, 1, 1] };
    };
    const r = await embedQueryText("hello");
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.source).toBe("bedrock");
    expect(voyageCalls).toBe(0); // never tried
  });

  test("returns no_provider_configured when neither is set", async () => {
    const r = await embedQueryText("hello");
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.code).toBe("no_provider_configured");
      expect(r.message).toMatch(/VOYAGE_SAGEMAKER_ENDPOINT|EMBEDDING_MODEL_ID/);
    }
  });

  test("returns voyage_failed_no_fallback when Voyage fails and Bedrock is unconfigured", async () => {
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    voyageImpl = async () => {
      throw new Error("SageMaker 503");
    };
    const r = await embedQueryText("hello");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.code).toBe("voyage_failed_no_fallback");
  });

  test("returns bedrock_failed when Bedrock returns an error envelope", async () => {
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    bedrockImpl = async () => ({ status: "error", error: "throttled" });
    const r = await embedQueryText("hello");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.code).toBe("bedrock_failed");
  });

  test("rejects empty / whitespace queryText with a typed error (no provider call)", async () => {
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "voyage-endpoint";
    let voyageCalls = 0;
    voyageImpl = async () => {
      voyageCalls += 1;
      return { status: "ok", embedding: [1] };
    };
    for (const empty of ["", "   ", "\n\t"]) {
      const r = await embedQueryText(empty);
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.code).toBe("no_provider_configured");
    }
    expect(voyageCalls).toBe(0);
  });

  test("rejects vectors containing non-numeric / non-finite values", async () => {
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    bedrockImpl = async () => ({ status: "ok", embedding: [0.1, NaN, 0.3] });
    const r = await embedQueryText("hello");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.code).toBe("bedrock_failed");
  });
});

describe("previewVector", () => {
  test("captures length, head, and tail (rounded to 6dp)", () => {
    const v = Array.from({ length: 1024 }, (_, i) => i / 1024);
    const p = previewVector(v);
    expect(p.length).toBe(1024);
    expect(p.head).toHaveLength(4);
    expect(p.tail).toHaveLength(4);
    // Last value before rounding: 1023/1024 = 0.99902343…
    expect(p.tail[3]).toBeCloseTo(0.999023, 5);
  });

  test("omits tail for short vectors (<= 8 entries) to avoid duplicate samples", () => {
    expect(previewVector([1, 2, 3, 4]).tail).toEqual([]);
    expect(previewVector([1, 2, 3, 4, 5, 6, 7, 8]).tail).toEqual([]);
    expect(previewVector([1, 2, 3, 4, 5, 6, 7, 8, 9]).tail).toEqual([6, 7, 8, 9]);
  });
});
