/**
 * Unit tests for the shared retrieval primitives in
 * `api/src/lib/vector-retrieval.ts`. These helpers are pure (no I/O), so we
 * pin every public ranking surface here. If a future caller (LTM reader, MCP
 * hybrid wrapper, eval harness) depends on a property that isn't covered
 * below, add a test before changing the helper.
 */

import { describe, expect, test } from "bun:test";
import {
  applyCollectionWeights,
  applyRecencyDecay,
  buildLexicalSearchPipeline,
  buildVectorSearchPipeline,
  cosineSimilarity,
  mmrDiversify,
  rrfMerge,
  type MergedHit,
  type ScoredHit,
} from "../../src/lib/vector-retrieval.ts";

function hit(
  collection: string,
  id: string,
  rank: number,
  source: "vector" | "lexical",
  doc: Record<string, unknown> = {},
): ScoredHit {
  return { collection, id, rank, source, score: 1 / rank, doc: { _id: id, ...doc } };
}

function merged(
  collection: string,
  id: string,
  rrfScore: number,
  doc: Record<string, unknown> = {},
): MergedHit {
  return {
    collection,
    id,
    rank: 1,
    score: rrfScore,
    rrfScore,
    source: "vector",
    sources: ["vector"],
    doc: { _id: id, ...doc },
  };
}

describe("buildVectorSearchPipeline", () => {
  test("emits $vectorSearch with the supplied path/limit/numCandidates and an $addFields _score stage", () => {
    const pipeline = buildVectorSearchPipeline([1, 2, 3], {
      indexName: "products-vector-index",
      path: "embedding",
      numCandidates: 200,
      limit: 5,
    });
    expect(pipeline).toHaveLength(2);
    const stage = pipeline[0].$vectorSearch as Record<string, unknown>;
    expect(stage.index).toBe("products-vector-index");
    expect(stage.path).toBe("embedding");
    expect(stage.numCandidates).toBe(200);
    expect(stage.limit).toBe(5);
    expect(stage.queryVector).toEqual([1, 2, 3]);
    expect(pipeline[1].$addFields).toEqual({ _score: { $meta: "vectorSearchScore" } });
  });

  test("includes filter only when non-empty (skip empty objects)", () => {
    const empty = buildVectorSearchPipeline([1], {
      indexName: "x",
      numCandidates: 10,
      limit: 1,
      filter: {},
    });
    expect((empty[0].$vectorSearch as Record<string, unknown>).filter).toBeUndefined();

    const filled = buildVectorSearchPipeline([1], {
      indexName: "x",
      numCandidates: 10,
      limit: 1,
      filter: { userId: "u1" },
    });
    expect((filled[0].$vectorSearch as Record<string, unknown>).filter).toEqual({ userId: "u1" });
  });
});

describe("buildLexicalSearchPipeline", () => {
  test("wraps a text clause + filter clauses in compound and adds $addFields _score", () => {
    const pipeline = buildLexicalSearchPipeline("waterproof", {
      indexName: "products-text-index",
      path: "name",
      limit: 5,
      filter: { category: "audio", tags: ["outdoor", "sport"] },
    });
    const search = pipeline[0].$search as Record<string, unknown>;
    expect(search.index).toBe("products-text-index");
    const compound = search.compound as { must: unknown[]; filter?: unknown[] };
    expect(compound.must).toEqual([{ text: { query: "waterproof", path: "name" } }]);
    expect(compound.filter).toEqual([
      { equals: { path: "category", value: "audio" } },
      { in: { path: "tags", value: ["outdoor", "sport"] } },
    ]);
    expect(pipeline[1].$addFields).toEqual({ _score: { $meta: "searchScore" } });
    expect(pipeline[2].$limit).toBe(5);
  });

  test("omits compound.filter when filter is empty/absent", () => {
    const pipeline = buildLexicalSearchPipeline("hello", {
      indexName: "x",
      path: "content",
      limit: 3,
    });
    const compound = (pipeline[0].$search as Record<string, unknown>).compound as {
      must: unknown[];
      filter?: unknown[];
    };
    expect(compound.filter).toBeUndefined();
  });
});

describe("rrfMerge", () => {
  test("fuses two ranked lists by Σ 1 / (k + rank)", () => {
    // Two lists, both with the same item at rank 1, plus distinct extras.
    const vec: ScoredHit[] = [
      hit("c", "shared", 1, "vector"),
      hit("c", "v-only", 2, "vector"),
    ];
    const lex: ScoredHit[] = [
      hit("c", "shared", 1, "lexical"),
      hit("c", "l-only", 2, "lexical"),
    ];
    const merged = rrfMerge([vec, lex], 60);
    const byId = Object.fromEntries(merged.map((m) => [m.id, m]));

    expect(byId.shared.rrfScore).toBeCloseTo(2 / 61, 6);
    expect(byId["v-only"].rrfScore).toBeCloseTo(1 / 62, 6);
    expect(byId["l-only"].rrfScore).toBeCloseTo(1 / 62, 6);
    expect(byId.shared.sources).toEqual(["vector", "lexical"]);
    expect(merged[0].id).toBe("shared");
  });

  test("dedups by (collection, id) — same id under different collections stays separate", () => {
    const a = [hit("facts", "x", 1, "vector")];
    const b = [hit("messages", "x", 1, "vector")];
    const out = rrfMerge([a, b]);
    expect(out).toHaveLength(2);
  });
});

describe("applyRecencyDecay", () => {
  test("scales rrfScore by exp(-Δdays / halfLifeDays); recent docs ranked first", () => {
    const now = Date.parse("2025-01-31T00:00:00Z");
    const day = 86_400_000;
    const recent = merged("c", "recent", 1, { ts: new Date(now - 1 * day).toISOString() });
    const week = merged("c", "week", 1, { ts: new Date(now - 7 * day).toISOString() });
    const month = merged("c", "month", 1, { ts: new Date(now - 30 * day).toISOString() });
    const result = applyRecencyDecay([month, week, recent], "ts", 30, now);
    // Ranking: recent > week > month, all positive.
    expect(result[0].id).toBe("recent");
    expect(result[1].id).toBe("week");
    expect(result[2].id).toBe("month");
    expect(result[0].rrfScore).toBeCloseTo(Math.exp(-1 / 30), 5);
  });

  test("noop when halfLifeDays <= 0 OR doc has no usable ts", () => {
    const a = merged("c", "a", 0.5, { ts: "not-a-date" });
    const b = merged("c", "b", 0.4);
    expect(applyRecencyDecay([a, b], "ts", 0)[0].rrfScore).toBeCloseTo(0.5, 5);
    const passthrough = applyRecencyDecay([a, b], "ts", 30);
    expect(passthrough.find((m) => m.id === "a")!.rrfScore).toBeCloseTo(0.5, 5);
    expect(passthrough.find((m) => m.id === "b")!.rrfScore).toBeCloseTo(0.4, 5);
  });
});

describe("applyCollectionWeights", () => {
  test("multiplies rrfScore by per-collection weight (default 1.0 left untouched)", () => {
    const facts = merged("facts", "f", 1);
    const msgs = merged("messages", "m", 1);
    const out = applyCollectionWeights([facts, msgs], { facts: 2, messages: 0.5 });
    expect(out[0].id).toBe("f");
    expect(out[0].rrfScore).toBeCloseTo(2, 5);
    expect(out[1].id).toBe("m");
    expect(out[1].rrfScore).toBeCloseTo(0.5, 5);
  });
});

describe("cosineSimilarity", () => {
  test("identical vectors → 1; orthogonal → 0; empty → 0", () => {
    expect(cosineSimilarity([1, 0, 0], [1, 0, 0])).toBeCloseTo(1, 6);
    expect(cosineSimilarity([1, 0], [0, 1])).toBeCloseTo(0, 6);
    expect(cosineSimilarity([], [])).toBe(0);
    expect(cosineSimilarity([0, 0], [1, 1])).toBe(0);
  });
});

describe("mmrDiversify", () => {
  test("returns the input when it fits in topK", () => {
    const items = [merged("c", "a", 1), merged("c", "b", 0.5)];
    expect(mmrDiversify(items, 0.7, 5)).toHaveLength(2);
  });

  test("picks the highest-scoring item first; then prefers a diverse second pick", () => {
    // Three candidates. `a` (highest score) sits very close in embedding space
    // to `b` (second-highest). `c` is lower-scored but orthogonal. With
    // lambda < 1 we should pick `a` then `c`, skipping `b` for redundancy.
    const a = merged("c", "a", 1, { embedding: [1, 0] });
    const b = merged("c", "b", 0.9, { embedding: [0.99, 0.14] });
    const cItem = merged("c", "c", 0.5, { embedding: [0, 1] });
    const picked = mmrDiversify([a, b, cItem], 0.3, 2);
    expect(picked.map((p) => p.id)).toEqual(["a", "c"]);
  });

  test("falls back to pure relevance when documents have no embedding", () => {
    const items = [merged("c", "a", 1), merged("c", "b", 0.5), merged("c", "c", 0.25)];
    expect(mmrDiversify(items, 0.7, 2).map((p) => p.id)).toEqual(["a", "b"]);
  });
});
