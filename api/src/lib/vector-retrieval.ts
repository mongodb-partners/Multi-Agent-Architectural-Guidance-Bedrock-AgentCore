/**
 * Shared retrieval primitives + pure ranking helpers used by:
 *
 *   1. Long-term memory retrieval (`readLongTermMemoryContext`) — runs hybrid
 *      vector + lexical search directly against MongoDB Atlas for low latency.
 *      LTM is an internal API code path, not a chat-invoked tool.
 *   2. The `mongodb_vector_search` MCP wrapper (`VectorSearchEmbedTool`) when
 *      `hybrid: true` — orchestrates lists returned by the Mongo MCP runtime
 *      and applies the same RRF/MMR/recency post-processing.
 *
 * Boundary rule: chat-invoked Mongo tools must execute through the Mongo MCP
 * runtime. Pipeline builders here are intentionally side-effect free so the
 * exact same shape can be used either via `getMongoDb()` (LTM) or via an MCP
 * handler (chat tool). API-side wrappers must not run `$vectorSearch` /
 * `$search` aggregations directly for chat tool execution.
 *
 * All helpers are pure where possible; only `runVectorSearch` and
 * `runLexicalSearch` perform I/O, and they accept a pre-resolved `Db` so the
 * caller controls connection lifecycle.
 */

import type { Db, Document } from "mongodb";

// ---------------------------------------------------------------------------
// Pipeline builders (pure)
// ---------------------------------------------------------------------------

export type VectorSearchOptions = {
  /** Atlas Vector Search index name. */
  indexName: string;
  /** Document field that holds the embedding vector. Defaults to "embedding". */
  path?: string;
  /** kNN search width — Atlas guidance: at least 10× `limit`. */
  numCandidates: number;
  /** Max documents to return from `$vectorSearch`. */
  limit: number;
  /** Optional pre-filter; each field must be declared in the index. */
  filter?: Document;
  /** Hard server-side timeout for Atlas aggregation. */
  maxTimeMS?: number;
};

export type LexicalSearchOptions = {
  /** Atlas Search index name (NOT the vector index). */
  indexName: string;
  /** Document field that holds the indexed text. */
  path: string;
  /** Max documents to return from `$search`. */
  limit: number;
  /** Optional pre-filter compiled into the compound query as `equals`/`in` clauses. */
  filter?: Document;
  /** Hard server-side timeout for Atlas aggregation. */
  maxTimeMS?: number;
};

/**
 * Build an Atlas `$vectorSearch` aggregation pipeline. Shape mirrors the
 * Mongo MCP runtime handler in `mcp-runtimes/mongodb-mcp/src/vendor/handlers.mjs`
 * so both sides agree on stages and scoring metadata.
 */
export function buildVectorSearchPipeline(
  queryVector: number[],
  opts: VectorSearchOptions,
): Document[] {
  const stage: Document = {
    $vectorSearch: {
      index: opts.indexName,
      path: opts.path ?? "embedding",
      queryVector,
      numCandidates: opts.numCandidates,
      limit: opts.limit,
    },
  };
  if (opts.filter && Object.keys(opts.filter).length > 0) {
    (stage.$vectorSearch as Document).filter = opts.filter;
  }
  return [stage, { $addFields: { _score: { $meta: "vectorSearchScore" } } }];
}

/**
 * Build an Atlas `$search` BM25/text aggregation pipeline with an optional
 * pre-filter. The filter is rendered into the `compound.filter` clauses as
 * equals/in matches — typical for scoping by `userId`, `agentId`, `category`.
 */
export function buildLexicalSearchPipeline(
  queryText: string,
  opts: LexicalSearchOptions,
): Document[] {
  const compound: Document = {
    must: [{ text: { query: queryText, path: opts.path } }],
  };
  if (opts.filter && Object.keys(opts.filter).length > 0) {
    compound.filter = filterToCompoundClauses(opts.filter);
  }
  return [
    { $search: { index: opts.indexName, compound } },
    { $addFields: { _score: { $meta: "searchScore" } } },
    { $limit: opts.limit },
  ];
}

/** Convert a simple `{ field: value | { $in: [...] } }` filter into Atlas Search compound filter clauses. */
function filterToCompoundClauses(filter: Document): Document[] {
  const clauses: Document[] = [];
  for (const [field, value] of Object.entries(filter)) {
    if (Array.isArray(value)) {
      clauses.push({ in: { path: field, value } });
      continue;
    }
    if (value && typeof value === "object") {
      const v = value as Document;
      if (Array.isArray(v.$in)) {
        clauses.push({ in: { path: field, value: v.$in } });
        continue;
      }
      if (v.$eq !== undefined) {
        clauses.push({ equals: { path: field, value: v.$eq as never } });
        continue;
      }
    }
    clauses.push({ equals: { path: field, value: value as never } });
  }
  return clauses;
}

// ---------------------------------------------------------------------------
// Execution (I/O) — used only by internal callers (e.g. LTM reader)
// ---------------------------------------------------------------------------

export type ScoredHit = {
  /** Mongo `_id` as a string for stable de-duplication across lists. */
  id: string;
  /** Source collection name. */
  collection: string;
  /** Raw `_score` from `$vectorSearch` / `$search`. */
  score: number;
  /** Source rank within its own ranked list (1-based). Used by RRF. */
  rank: number;
  /** Where the hit came from. */
  source: "vector" | "lexical";
  /** The full document (callers may project before passing in). */
  doc: Document;
};

export async function runVectorSearch(
  db: Db,
  collection: string,
  queryVector: number[],
  opts: VectorSearchOptions,
): Promise<ScoredHit[]> {
  const pipeline = buildVectorSearchPipeline(queryVector, opts);
  const aggregateOpts = aggregateTimeoutOptions(opts.maxTimeMS);
  try {
  const docs = (await db
    .collection(collection)
    .aggregate(pipeline, aggregateOpts.options)
    .toArray()) as Document[];
  return docs.map((d, i) => ({
    id: stringifyId(d._id),
    collection,
    score: typeof d._score === "number" ? d._score : 0,
    rank: i + 1,
    source: "vector",
    doc: d,
  }));
  } finally {
    aggregateOpts.clear();
  }
}

export async function runLexicalSearch(
  db: Db,
  collection: string,
  queryText: string,
  opts: LexicalSearchOptions,
): Promise<ScoredHit[]> {
  const pipeline = buildLexicalSearchPipeline(queryText, opts);
  const aggregateOpts = aggregateTimeoutOptions(opts.maxTimeMS);
  try {
  const docs = (await db
    .collection(collection)
    .aggregate(pipeline, aggregateOpts.options)
    .toArray()) as Document[];
  return docs.map((d, i) => ({
    id: stringifyId(d._id),
    collection,
    score: typeof d._score === "number" ? d._score : 0,
    rank: i + 1,
    source: "lexical",
    doc: d,
  }));
  } finally {
    aggregateOpts.clear();
  }
}

function aggregateTimeoutOptions(maxTimeMS?: number): {
  options: { maxTimeMS?: number; signal?: AbortSignal } | undefined;
  clear: () => void;
} {
  if (!maxTimeMS || maxTimeMS <= 0) {
    return { options: undefined, clear: () => undefined };
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), maxTimeMS);
  return {
    options: { maxTimeMS, signal: controller.signal },
    clear: () => clearTimeout(timer),
  };
}

function stringifyId(id: unknown): string {
  if (id === undefined || id === null) return "";
  if (typeof id === "string") return id;
  if (typeof id === "number") return String(id);
  // ObjectId, UUID Binary, etc. — `toString()` produces a stable hex/string form.
  try {
    return String(id);
  } catch {
    return JSON.stringify(id);
  }
}

// ---------------------------------------------------------------------------
// Pure ranking helpers
// ---------------------------------------------------------------------------

/**
 * Reciprocal Rank Fusion across N ranked lists. Solves the
 * cosine-score-vs-BM25-score distribution mismatch cleanly — fuses by rank
 * position only, so absolute score magnitudes do not matter.
 *
 * For each item, the merged score is `Σ 1 / (k + rank_in_list)` across every
 * list that contains it. `k=60` is the value from the original Cormack/Lynam
 * paper and works well as a default.
 *
 * Items are identified by `(collection, id)`. Duplicates across lists collapse
 * to one entry; the entry's `source` becomes `"hybrid"` when it appeared in
 * more than one list.
 */
export type MergedHit = ScoredHit & { rrfScore: number; sources: Array<"vector" | "lexical"> };

export function rrfMerge(lists: ScoredHit[][], k = 60): MergedHit[] {
  const merged = new Map<string, MergedHit>();
  for (const list of lists) {
    for (const hit of list) {
      const key = `${hit.collection}:${hit.id}`;
      const existing = merged.get(key);
      const contribution = 1 / (k + hit.rank);
      if (existing) {
        existing.rrfScore += contribution;
        if (!existing.sources.includes(hit.source)) existing.sources.push(hit.source);
        // Prefer the higher-confidence per-source rank for telemetry.
        if (hit.rank < existing.rank) existing.rank = hit.rank;
      } else {
        merged.set(key, {
          ...hit,
          rrfScore: contribution,
          sources: [hit.source],
        });
      }
    }
  }
  return Array.from(merged.values()).sort((a, b) => b.rrfScore - a.rrfScore);
}

/**
 * Apply exponential recency decay: `score * exp(-Δdays / halfLifeDays)`.
 *
 * - `tsField` is the field name on the document that holds an ISO timestamp.
 * - Documents with no usable timestamp are left at their original score (no decay).
 * - `halfLifeDays <= 0` disables decay.
 */
export function applyRecencyDecay<T extends MergedHit>(
  items: T[],
  tsField: string,
  halfLifeDays: number,
  nowMs = Date.now(),
): T[] {
  if (halfLifeDays <= 0) return items;
  const halfLifeMs = halfLifeDays * 86_400_000;
  for (const item of items) {
    const raw = item.doc?.[tsField];
    const ms = parseTimestampMs(raw);
    if (ms === undefined) continue;
    const ageMs = Math.max(0, nowMs - ms);
    const decay = Math.exp(-ageMs / halfLifeMs);
    item.rrfScore = item.rrfScore * decay;
  }
  return items.sort((a, b) => b.rrfScore - a.rrfScore);
}

function parseTimestampMs(raw: unknown): number | undefined {
  if (raw instanceof Date) return raw.getTime();
  if (typeof raw === "number" && Number.isFinite(raw)) return raw;
  if (typeof raw === "string") {
    const n = Date.parse(raw);
    return Number.isFinite(n) ? n : undefined;
  }
  return undefined;
}

/**
 * Apply per-collection weight multipliers to merged hits. Used to prefer
 * LLM-curated facts over raw chat messages when fused scores tie.
 */
export function applyCollectionWeights<T extends MergedHit>(
  items: T[],
  weights: Record<string, number>,
): T[] {
  for (const item of items) {
    const w = weights[item.collection];
    if (typeof w === "number" && Number.isFinite(w) && w !== 1) {
      item.rrfScore = item.rrfScore * w;
    }
  }
  return items.sort((a, b) => b.rrfScore - a.rrfScore);
}

/**
 * Maximum Marginal Relevance diversification. Greedily pick `topK` items that
 * balance relevance (rrfScore) against novelty vs already-selected items.
 *
 * `lambda` ∈ [0, 1]: 1 = pure relevance (no diversification), 0 = pure
 * diversity. Default 0.7 retains most relevance while breaking up near-
 * duplicate runs. Embeddings are read from `embeddingField` on the doc; items
 * missing an embedding are scored purely by relevance.
 */
export function mmrDiversify<T extends MergedHit>(
  items: T[],
  lambda: number,
  topK: number,
  embeddingField = "embedding",
): T[] {
  if (items.length <= topK) return items;
  const remaining = [...items];
  const selected: T[] = [];

  // Pick the highest-scoring item first.
  remaining.sort((a, b) => b.rrfScore - a.rrfScore);
  const first = remaining.shift();
  if (!first) return [];
  selected.push(first);

  while (selected.length < topK && remaining.length > 0) {
    let bestIdx = 0;
    let bestScore = -Infinity;
    for (let i = 0; i < remaining.length; i++) {
      const cand = remaining[i];
      const candVec = cand.doc?.[embeddingField];
      let maxSim = 0;
      if (Array.isArray(candVec)) {
        for (const sel of selected) {
          const selVec = sel.doc?.[embeddingField];
          if (!Array.isArray(selVec)) continue;
          const sim = cosineSimilarity(candVec as number[], selVec as number[]);
          if (sim > maxSim) maxSim = sim;
        }
      }
      const mmr = lambda * cand.rrfScore - (1 - lambda) * maxSim;
      if (mmr > bestScore) {
        bestScore = mmr;
        bestIdx = i;
      }
    }
    selected.push(remaining.splice(bestIdx, 1)[0]);
  }
  return selected;
}

export function cosineSimilarity(a: number[], b: number[]): number {
  const n = Math.min(a.length, b.length);
  if (n === 0) return 0;
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < n; i++) {
    const ai = a[i];
    const bi = b[i];
    dot += ai * bi;
    na += ai * ai;
    nb += bi * bi;
  }
  const denom = Math.sqrt(na) * Math.sqrt(nb);
  return denom === 0 ? 0 : dot / denom;
}

// ---------------------------------------------------------------------------
// High-level orchestrator
// ---------------------------------------------------------------------------

export type HybridCollectionSpec = {
  collection: string;
  vectorIndex: string;
  vectorPath?: string;
  lexicalIndex: string;
  lexicalPath: string;
  filter?: Document;
  /** Per-collection weight applied after RRF merge. Default 1.0. */
  weight?: number;
};

export type HybridRetrieveOptions = {
  /** Query text used for the lexical leg (and for telemetry). */
  queryText: string;
  /** Pre-embedded query vector used for the vector leg. */
  queryVector: number[];
  /** Collections to search across in parallel. */
  collections: HybridCollectionSpec[];
  /** Per-collection over-fetch before merge. Default 32. */
  fetchK?: number;
  /** Final top-K after RRF + recency + MMR. Default 8. */
  topK?: number;
  /** `$vectorSearch.numCandidates`. Default 200. */
  numCandidates?: number;
  /** Drop merged items below this `rrfScore` (after recency/weight). Default 0. */
  minScore?: number;
  /** MMR diversity trade-off (1 = pure relevance, 0 = pure diversity). Default 0.7. */
  mmrLambda?: number;
  /** Exponential recency decay half-life (days). 0 disables decay. Default 30. */
  recencyHalfLifeDays?: number;
  /** Document field that holds an ISO timestamp for recency decay. Default "ts". */
  recencyTsField?: string;
  /** Mode toggle: "hybrid" (default) | "vector" | "lexical". */
  mode?: "hybrid" | "vector" | "lexical";
  /** Hard server-side timeout for each Atlas aggregation leg. Default 8000ms. */
  maxTimeMS?: number;
};

export type HybridRetrieveResult = {
  items: MergedHit[];
  meta: {
    mode: "hybrid" | "vector" | "lexical";
    vectorHits: number;
    lexicalHits: number;
    rrfMergedCount: number;
    perCollection: Array<{
      collection: string;
      vectorReturned: number;
      lexicalReturned: number;
      error?: string;
    }>;
  };
};

/**
 * Execute hybrid retrieval across N collections in parallel. Direct-DB
 * variant used by the LTM reader. Chat-tool hybrid mode runs the same shape
 * inside the Mongo MCP runtime; callers should not invoke this directly for
 * chat tool execution.
 */
export async function hybridRetrieve(
  db: Db,
  opts: HybridRetrieveOptions,
): Promise<HybridRetrieveResult> {
  const mode = opts.mode ?? "hybrid";
  const fetchK = opts.fetchK ?? 32;
  const topK = opts.topK ?? 8;
  const numCandidates = opts.numCandidates ?? Math.max(200, fetchK * 10);
  const minScore = opts.minScore ?? 0;
  const mmrLambda = opts.mmrLambda ?? 0.7;
  const halfLife = opts.recencyHalfLifeDays ?? 30;
  const tsField = opts.recencyTsField ?? "ts";
  const maxTimeMS = opts.maxTimeMS ?? 8000;

  type Leg = Promise<ScoredHit[]>;
  const perCollection: HybridRetrieveResult["meta"]["perCollection"] = [];
  const allLists: ScoredHit[][] = [];

  await Promise.all(
    opts.collections.map(async (spec) => {
      const weights = spec.weight;
      const legs: Leg[] = [];
      if (mode !== "lexical") {
        legs.push(
          runVectorSearch(db, spec.collection, opts.queryVector, {
            indexName: spec.vectorIndex,
            path: spec.vectorPath,
            numCandidates,
            limit: fetchK,
            filter: spec.filter,
            maxTimeMS,
          }).catch((err) => {
            perCollection.push({
              collection: spec.collection,
              vectorReturned: 0,
              lexicalReturned: 0,
              error: `vector: ${err instanceof Error ? err.message : String(err)}`,
            });
            return [] as ScoredHit[];
          }),
        );
      }
      if (mode !== "vector") {
        legs.push(
          runLexicalSearch(db, spec.collection, opts.queryText, {
            indexName: spec.lexicalIndex,
            path: spec.lexicalPath,
            limit: fetchK,
            filter: spec.filter,
            maxTimeMS,
          }).catch((err) => {
            perCollection.push({
              collection: spec.collection,
              vectorReturned: 0,
              lexicalReturned: 0,
              error: `lexical: ${err instanceof Error ? err.message : String(err)}`,
            });
            return [] as ScoredHit[];
          }),
        );
      }
      const settled = await Promise.all(legs);
      let vecCount = 0;
      let lexCount = 0;
      for (const list of settled) {
        if (!list.length) continue;
        if (list[0].source === "vector") vecCount = list.length;
        else lexCount = list.length;
        // Tag with weight so the merged item inherits it.
        if (typeof weights === "number") {
          for (const item of list) {
            (item as ScoredHit & { _weight?: number })._weight = weights;
          }
        }
        allLists.push(list);
      }
      // Always record an entry per collection (even if both legs are 0).
      perCollection.push({
        collection: spec.collection,
        vectorReturned: vecCount,
        lexicalReturned: lexCount,
      });
    }),
  );

  // RRF across all (collection × source) lists.
  let merged = rrfMerge(allLists);
  const totals = {
    vector: allLists
      .filter((l) => l[0]?.source === "vector")
      .reduce((acc, l) => acc + l.length, 0),
    lexical: allLists
      .filter((l) => l[0]?.source === "lexical")
      .reduce((acc, l) => acc + l.length, 0),
  };

  // Apply per-collection weights (defaults to 1.0 when missing).
  const weights: Record<string, number> = {};
  for (const spec of opts.collections) {
    if (typeof spec.weight === "number") weights[spec.collection] = spec.weight;
  }
  if (Object.keys(weights).length > 0) {
    merged = applyCollectionWeights(merged, weights);
  }

  // Recency decay against doc[tsField] (no-op when halfLife <= 0).
  merged = applyRecencyDecay(merged, tsField, halfLife);

  // Min-score floor (after weight + recency normalization).
  if (minScore > 0) {
    merged = merged.filter((m) => m.rrfScore >= minScore);
  }

  // MMR diversification + final top-K trim.
  const finalItems = mmrDiversify(merged, mmrLambda, topK);

  return {
    items: finalItems,
    meta: {
      mode,
      vectorHits: totals.vector,
      lexicalHits: totals.lexical,
      rrfMergedCount: merged.length,
      perCollection: dedupePerCollection(perCollection),
    },
  };
}

function dedupePerCollection(
  rows: HybridRetrieveResult["meta"]["perCollection"],
): HybridRetrieveResult["meta"]["perCollection"] {
  const byColl = new Map<string, HybridRetrieveResult["meta"]["perCollection"][number]>();
  for (const r of rows) {
    const existing = byColl.get(r.collection);
    if (!existing) {
      byColl.set(r.collection, { ...r });
      continue;
    }
    existing.vectorReturned = Math.max(existing.vectorReturned, r.vectorReturned);
    existing.lexicalReturned = Math.max(existing.lexicalReturned, r.lexicalReturned);
    if (r.error) existing.error = [existing.error, r.error].filter(Boolean).join("; ");
  }
  return Array.from(byColl.values());
}
