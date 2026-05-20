/**
 * `vectorIndexFromTransformArgs` is the helper that surfaces the Atlas
 * Vector Search / Atlas Search index name forwarded to the MongoDB MCP
 * runtime. The Developer details panel renders this as a chip so reviewers
 * can confirm the runtime is hitting the expected index (and not silently
 * falling back to a default that won't match `db-seeding/seed-indexes.ts`).
 *
 * The Strands tool wrapper supports three operand shapes — `index`,
 * `indexName`, or the hybrid `vectorIndex` — and `mongo.vector_search.indexName`
 * is meant to carry whichever the caller provided.
 */

import { describe, expect, test } from "bun:test";
import { vectorIndexFromTransformArgs } from "../../src/adapters/mongodb-mcp-client.ts";

describe("vectorIndexFromTransformArgs", () => {
  test("returns vectorIndex when the hybrid shape is in use (preferred)", () => {
    expect(
      vectorIndexFromTransformArgs({
        vectorIndex: "products-vector-index",
        lexicalIndex: "products-text-index",
      }),
    ).toBe("products-vector-index");
  });

  test("falls back to index when only `index` is set (pure vector shape)", () => {
    expect(vectorIndexFromTransformArgs({ index: "products_vector" })).toBe(
      "products_vector",
    );
  });

  test("accepts indexName as the alias of last resort", () => {
    expect(vectorIndexFromTransformArgs({ indexName: "chat_messages_vector" })).toBe(
      "chat_messages_vector",
    );
  });

  test("vectorIndex wins over index and indexName when all three are present", () => {
    expect(
      vectorIndexFromTransformArgs({
        vectorIndex: "alpha",
        index: "beta",
        indexName: "gamma",
      }),
    ).toBe("alpha");
  });

  test("returns undefined when none of the three index hints are provided", () => {
    expect(vectorIndexFromTransformArgs({})).toBeUndefined();
    expect(vectorIndexFromTransformArgs({ unrelated: "x" } as never)).toBeUndefined();
  });

  test("ignores non-string values (defensive against malformed callers)", () => {
    expect(
      vectorIndexFromTransformArgs({
        vectorIndex: 42 as never,
        index: { nested: true } as never,
        indexName: null as never,
      }),
    ).toBeUndefined();
  });
});
