/**
 * Retrieval ranking eval — a deterministic, fixture-driven comparison of
 * pure-vector ranking vs hybrid (vector + BM25 + RRF + recency + collection
 * weights) ranking over the same synthetic memory documents.
 *
 * Goal: lock in the qualitative wins the hybrid layer adds over the
 * vector-only baseline. These are not retrieval-quality benchmarks
 * (no external corpus, no embedding model), but they pin the ranking
 * behaviour the LTM read path relies on so a regression in
 * `vector-retrieval.ts` shows up as a test failure rather than a silent
 * recall drop.
 *
 * Scenarios pinned:
 *   1. Polarity / negation: a pure-vector retriever puts "I love pasta" and
 *      "I do NOT like pasta" almost on top of each other; the lexical leg
 *      gives a query that mentions "NOT" enough weight to push the negated
 *      row up. The hybrid retriever surfaces the negated row earlier than a
 *      vector-only retriever does.
 *   2. Rare entity: a 6-month-old "User lives in Berlin" can outrank
 *      yesterday's "Just moved to Lisbon" in pure-vector ranking when the
 *      query is paraphrased. Recency decay restores the newer row to the
 *      top.
 *   3. Collection weight: facts and chat messages tie on the vector leg;
 *      the per-collection weight (MEMORY_WEIGHT_FACTS > MEMORY_WEIGHT_CHAT_MESSAGES)
 *      breaks the tie in favour of the LLM-curated fact.
 */

import { describe, expect, test } from "bun:test";
import {
  applyCollectionWeights,
  applyRecencyDecay,
  rrfMerge,
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

describe("retrieval ranking eval", () => {
  test("polarity: hybrid surfaces the negated row higher than vector-only", () => {
    // Fixture: a vector retriever sees both rows as near-identical (the
    // negation barely moves the embedding), but the lexical leg over a
    // query like "don't like pasta" ranks the negated row first.
    const vectorList: ScoredHit[] = [
      hit("agent_memory_facts", "love", 1, "vector", { fact: "I love pasta" }),
      hit("agent_memory_facts", "dislike", 2, "vector", { fact: "I do NOT like pasta" }),
    ];
    const lexicalList: ScoredHit[] = [
      hit("agent_memory_facts", "dislike", 1, "lexical", { fact: "I do NOT like pasta" }),
      hit("agent_memory_facts", "love", 4, "lexical", { fact: "I love pasta" }),
    ];

    // Pure-vector ranking puts the wrong-polarity row first.
    expect(vectorList[0].id).toBe("love");

    // Hybrid RRF lets the lexical signal pull the negated row up.
    const hybrid = rrfMerge([vectorList, lexicalList]);
    expect(hybrid[0].id).toBe("dislike");
    // The wrong-polarity row is still present (we never want to drop it),
    // it just isn't winning anymore.
    expect(hybrid.map((h) => h.id)).toContain("love");
  });

  test("recency: decay pulls the newer row above a near-tied older row", () => {
    const now = Date.UTC(2026, 4, 17);
    const sixMonthsAgo = new Date(now - 180 * 86_400_000).toISOString();
    const yesterday = new Date(now - 86_400_000).toISOString();

    // Pure-vector ranks the older row first because the query is closer
    // semantically to "User lives in Berlin" than the new Lisbon move.
    const vectorList: ScoredHit[] = [
      hit("agent_memory_facts", "berlin", 1, "vector", { fact: "User lives in Berlin", ts: sixMonthsAgo }),
      hit("agent_memory_facts", "lisbon", 2, "vector", { fact: "Just moved to Lisbon", ts: yesterday }),
    ];
    // No lexical match in this fixture — the query is paraphrased.
    const lexicalList: ScoredHit[] = [];

    const fused = rrfMerge([vectorList, lexicalList]);
    // Without decay, Berlin still wins.
    expect(fused[0].id).toBe("berlin");

    const decayed = applyRecencyDecay(fused, "ts", 30, now);
    expect(decayed[0].id).toBe("lisbon");
    // Older row is still recallable, just demoted.
    expect(decayed.map((h) => h.id)).toContain("berlin");
  });

  test("collection weight: facts win a vector-tie against chat messages", () => {
    // Two retrievals at the same rank from different collections.
    const vectorList: ScoredHit[] = [
      hit("agent_memory_facts", "fact-1", 1, "vector", { fact: "User prefers concise replies" }),
      hit("chat_messages", "msg-99", 1, "vector", { content: "give me a quick answer" }),
    ];

    const fused = rrfMerge([vectorList]);
    // Tie on rrfScore (both have rank 1 from the single list); insertion
    // order would have facts first, but that's fragile — we rely on the
    // weight, not insertion order, to break the tie.
    const weighted = applyCollectionWeights(fused, {
      agent_memory_facts: 1.0,
      chat_messages: 0.6,
    });
    expect(weighted[0].collection).toBe("agent_memory_facts");
    expect(weighted[0].id).toBe("fact-1");
    expect(weighted[1].collection).toBe("chat_messages");
  });

  test("hybrid is strictly additive: every vector-only winner is still recallable", () => {
    // Property: hybrid may re-rank, but it must never drop a row that
    // pure-vector would have returned. This guards against an accidental
    // filter that silently shrinks recall.
    const vectorList: ScoredHit[] = [
      hit("agent_memory_facts", "a", 1, "vector"),
      hit("agent_memory_facts", "b", 2, "vector"),
      hit("agent_memory_facts", "c", 3, "vector"),
    ];
    const lexicalList: ScoredHit[] = [
      hit("agent_memory_facts", "d", 1, "lexical"),
      hit("agent_memory_facts", "e", 2, "lexical"),
    ];

    const merged = rrfMerge([vectorList, lexicalList]);
    const mergedIds = new Set(merged.map((h) => h.id));
    for (const v of vectorList) {
      expect(mergedIds.has(v.id)).toBe(true);
    }
    // Lexical-only hits are added on top, never dropped.
    for (const l of lexicalList) {
      expect(mergedIds.has(l.id)).toBe(true);
    }
  });
});
