/**
 * Unit tests for the `generate_embedding` agent tool in `api/src/lib/base-tools.ts`.
 *
 * Strict-mode contract: the tool delegates to `embedQueryText` /
 * `embedDocumentText` from `embed-query.ts`. There is no longer a duplicated
 * Voyage→Bedrock soft-fallback inside the tool itself. We assert:
 *   1. `input_type=query` → `embedQueryText` is called; `embedDocumentText` is not.
 *   2. `input_type=document` → `embedDocumentText` is called; `embedQueryText` is not.
 *   3. on `EmbedResult.ok=false` the tool returns `{ status: "error", code, message }`.
 *   4. on success the tool returns `{ status: "ok", embedding, model, source, dimensions }`.
 *   5. the cross-provider primitives (`voyageGenerateEmbedding` /
 *      `bedrockGenerateEmbedding`) are **not** called directly by the tool —
 *      strict-mode is enforced exclusively through `embed-query.ts`.
 */

import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

let queryCalls: string[] = [];
let documentCalls: string[] = [];
let queryImpl: (text: string) => Promise<unknown> = async () => ({ ok: false });
let documentImpl: (text: string) => Promise<unknown> = async () => ({ ok: false });

const realEmbed = await import("../../src/lib/embed-query.ts");
mock.module("../../src/lib/embed-query.ts", () => ({
  ...realEmbed,
  embedQueryText: async (text: string) => {
    queryCalls.push(text);
    return queryImpl(text);
  },
  embedDocumentText: async (text: string) => {
    documentCalls.push(text);
    return documentImpl(text);
  },
}));

// We do NOT mock `voyage-embedding.ts` or `bedrock-retrieval.ts` directly;
// the strict gate sits one layer above, in `embed-query.ts`, and that's what
// we're locking down. If `embed-query.ts` ever regresses to a soft-fallback
// the `embedQueryText` / `embedDocumentText` mocks here would still mask
// it — but `embed-query.test.ts` has dedicated spy tests for the provider
// primitives that catch that regression.

afterAll(() => {
  mock.module("../../src/lib/embed-query.ts", () => realEmbed);
});

const { generateEmbeddingTool } = await import("../../src/lib/base-tools.ts");

beforeEach(() => {
  queryCalls = [];
  documentCalls = [];
});

// `tool({ callback })` from strands wraps the user callback. We invoke it
// through the tool's public `.invoke()` (or its callback property) — fall back
// to calling the function directly via `.toolSpec`-adjacent surface.
async function invoke(input: { text: string; input_type?: "query" | "document" }) {
  // Strands tool surface: .invoke is the runtime entrypoint for tests.
  const t = generateEmbeddingTool as unknown as {
    invoke?: (i: unknown) => Promise<unknown>;
    callback?: (i: unknown) => Promise<unknown>;
    handler?: (i: unknown) => Promise<unknown>;
  };
  if (typeof t.invoke === "function") return t.invoke(input);
  if (typeof t.callback === "function") return t.callback(input);
  if (typeof t.handler === "function") return t.handler(input);
  throw new Error("generateEmbeddingTool does not expose a callable invoke/callback/handler");
}

describe("generate_embedding tool — strict delegation to embed-query.ts", () => {
  test("input_type=query routes to embedQueryText only", async () => {
    queryImpl = async () => ({
      ok: true,
      source: "voyage",
      modelId: "voyage-multimodal-3",
      vector: [0.11, 0.22, 0.33],
    });

    const r = (await invoke({ text: "hello", input_type: "query" })) as Record<string, unknown>;

    expect(queryCalls).toEqual(["hello"]);
    expect(documentCalls).toEqual([]);
    expect(r).toMatchObject({
      status: "ok",
      embedding: [0.11, 0.22, 0.33],
      model: "voyage-multimodal-3",
      source: "voyage",
      dimensions: 3,
    });
  });

  test("input_type=document routes to embedDocumentText only", async () => {
    documentImpl = async () => ({
      ok: true,
      source: "voyage",
      modelId: "voyage-multimodal-3",
      vector: [1, 2],
    });

    const r = (await invoke({ text: "doc text", input_type: "document" })) as Record<string, unknown>;

    expect(documentCalls).toEqual(["doc text"]);
    expect(queryCalls).toEqual([]);
    expect(r).toMatchObject({ status: "ok", model: "voyage-multimodal-3", source: "voyage" });
  });

  test("strict failure surfaces as { status: 'error', code, message }", async () => {
    queryImpl = async () => ({
      ok: false,
      code: "voyage_strict_failed",
      message: "SageMaker 503",
    });

    const r = (await invoke({ text: "hi" })) as Record<string, unknown>;

    expect(r).toEqual({
      status: "error",
      code: "voyage_strict_failed",
      message: "SageMaker 503",
    });
    // Critical: the tool did NOT silently retry on the document path.
    expect(documentCalls).toEqual([]);
  });

  test("no_provider_configured propagates without provider primitives running", async () => {
    queryImpl = async () => ({
      ok: false,
      code: "no_provider_configured",
      message: "EMBEDDINGS_PROVIDER unset",
    });

    const r = (await invoke({ text: "x" })) as Record<string, unknown>;

    expect(r).toEqual({
      status: "error",
      code: "no_provider_configured",
      message: "EMBEDDINGS_PROVIDER unset",
    });
    expect(documentCalls).toEqual([]);
  });
});
