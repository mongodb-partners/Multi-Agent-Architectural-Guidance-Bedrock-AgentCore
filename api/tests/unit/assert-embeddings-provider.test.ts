/**
 * Boot-guard tests for `api/src/lib/assert-embeddings-provider.ts`.
 *
 * Strict-only — empty / unrecognised values throw, so the API container
 * fails to start instead of serving silently-degraded embeddings.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";

import { assertEmbeddingsProvider } from "../../src/lib/assert-embeddings-provider.ts";

describe("assertEmbeddingsProvider — strict mode", () => {
  beforeEach(() => {
    delete process.env.EMBEDDINGS_PROVIDER;
    delete process.env.VOYAGE_SAGEMAKER_ENDPOINT;
    delete process.env.EMBEDDING_MODEL_ID;
  });

  afterEach(() => {
    delete process.env.EMBEDDINGS_PROVIDER;
    delete process.env.VOYAGE_SAGEMAKER_ENDPOINT;
    delete process.env.EMBEDDING_MODEL_ID;
  });

  test("empty EMBEDDINGS_PROVIDER throws (no escape hatch)", () => {
    expect(() => assertEmbeddingsProvider()).toThrow(/EMBEDDINGS_PROVIDER is required/);
  });

  test("whitespace-only EMBEDDINGS_PROVIDER throws", () => {
    process.env.EMBEDDINGS_PROVIDER = "   ";
    expect(() => assertEmbeddingsProvider()).toThrow(/EMBEDDINGS_PROVIDER is required/);
  });

  test("unrecognised value throws with helpful message", () => {
    process.env.EMBEDDINGS_PROVIDER = "openai";
    expect(() => assertEmbeddingsProvider()).toThrow(/not recognised|voyage|titan/);
  });

  test("voyage without endpoint throws", () => {
    process.env.EMBEDDINGS_PROVIDER = "voyage";
    expect(() => assertEmbeddingsProvider()).toThrow(
      /VOYAGE_SAGEMAKER_ENDPOINT/,
    );
  });

  test("voyage with endpoint passes (case-insensitive)", () => {
    process.env.EMBEDDINGS_PROVIDER = "VOYAGE";
    process.env.VOYAGE_SAGEMAKER_ENDPOINT = "endpoint-name";
    expect(() => assertEmbeddingsProvider()).not.toThrow();
  });

  test("titan without model id throws", () => {
    process.env.EMBEDDINGS_PROVIDER = "titan";
    expect(() => assertEmbeddingsProvider()).toThrow(/EMBEDDING_MODEL_ID/);
  });

  test("titan with model id passes", () => {
    process.env.EMBEDDINGS_PROVIDER = "titan";
    process.env.EMBEDDING_MODEL_ID = "amazon.titan-embed-text-v2:0";
    expect(() => assertEmbeddingsProvider()).not.toThrow();
  });
});
