# db-seeding

MongoDB seed scripts for the Bedrock Multi-Agent demo stack. Each script is standalone and idempotent (safe to re-run).

## Scripts

| Script | Collections touched | Notes |
|--------|--------------------|----|
| `seed-customers.ts` | `customers` | 5 demo customers (standard + premium tiers) |
| `seed-products.ts` | `products` | 9 SKUs across home / electronics / outdoor |
| `seed-troubleshooting.ts` | `troubleshooting_docs` | 8 seeded diagnostic playbooks (power, connectivity, HW fault, returns, firmware, smart-home) |
| `seed-orders.ts` | `orders` | 12 orders covering shipped, processing, delivered, cancelled, and return-requested flows |
| `seed-indexes.ts` | all + `agent_memory_facts` + `chat_sessions` + `chat_messages` | Regular indexes (including unique `{userId, factHash}` for write-side dedup) + Atlas **vector** indexes for `products`, `troubleshooting_docs`, `agent_memory_facts`, `chat_messages` + Atlas **Search (BM25)** indexes for the same four collections (used by `mongodb_hybrid_search` and the LTM hybrid retriever) + TTL on `agent_memory_facts`. Collection name overridable via **`CHAT_SESSIONS_COLLECTION`** and **`CHAT_MESSAGES_COLLECTION`**. |
| `seed-embeddings.ts` | `products`, **seeder-owned rows of** `troubleshooting_docs` | Backfills `embedding` + `embeddingModel` fields via Voyage or Bedrock; requires AWS creds. **Auto-invoked by `deploy-project.sh` Phase 5b** and `deploy-local.sh` Phase 7 — manual invocation is only needed when iterating on the seeder. KB-managed rows in `troubleshooting_docs` (those carrying `bedrock_text_chunk` / `bedrock_metadata`) are explicitly skipped. `agent_memory_facts` and `chat_messages` embeddings are populated at write time by the API. Exits non-zero on any per-row failure or post-run gap. |
| `seed-all.ts` | all (except embeddings) | Runs all of the above in order; run once per environment |

### Provider switch (REWIRE_EMBEDDINGS=1)

When `EMBEDDINGS_PROVIDER` flips (e.g. titan ↔ voyage), the existing stored embeddings have the wrong dimension / wrong provider tag. The deploy-time wrapper auto-detects this via three independent signals:

- SSM `/<SHARED_VPC_NAME>/<region>/embeddings/dim` ≠ current `EMBEDDING_DIMENSIONS`
- A sampled seeder-owned row's `embedding.length` ≠ current `EMBEDDING_DIMENSIONS`
- A sampled seeder-owned row's `embeddingModel` doesn't start with the current provider prefix

Any one signal triggers `REWIRE_EMBEDDINGS=1` automatically. Operators can also force it manually:

```bash
REWIRE_EMBEDDINGS=1 bun db-seeding/seed-embeddings.ts
```

**KB-chunk safety:** the rewire only wipes seeder-owned rows. Bedrock KB-managed chunks in `troubleshooting_docs` are never touched. If you need to re-embed the KB side, re-run the KB ingestion job from the Bedrock console or `terraform apply` the `bedrock-kb` module.

**Empty-collection edge case:** when `deploy-project.sh` runs against a freshly-truncated database (no seeder-owned rows yet), the in-Mongo dimension/provider fingerprint signals return `null`. Only the SSM `embeddings/dim` signal contributes to REWIRE auto-detect. This is the correct behavior — there is nothing to re-embed — but be aware that flipping `EMBEDDINGS_PROVIDER` immediately after a truncate, before any documents exist, will *not* clear the SSM dim until the first successful seed run completes. If you hit a dimension mismatch in that exact window, force it with `REWIRE_EMBEDDINGS=1` on the next seed.

**Runtime collections `chat_sessions` + `chat_messages` + `agent_memory_facts`:** all three are also auto-ensured by the API on first write (`session-store.ts`, `chat-messages-collection.ts`, `long-term-memory.ts`). Seeding here is for cold starts where you want the indexes ready before the first request.

## Quick start

```bash
export MONGODB_URI="mongodb+srv://user:pass@cluster.mongodb.net"
export MONGODB_DB="mongodb_multiagent_dev"  # project+env-derived (underscored)

# Seed everything (customers → products → troubleshooting → orders → indexes)
bun db-seeding/seed-all.ts

# Then, once AWS credentials are available:
export AWS_REGION="us-east-1"
bun db-seeding/seed-embeddings.ts
```

## Running individual scripts

```bash
MONGODB_URI=... bun db-seeding/seed-orders.ts
MONGODB_URI=... bun db-seeding/seed-products.ts
# etc.
```

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MONGODB_URI` | *(required)* | Atlas connection string |
| `MONGODB_DB` | `<project>_<env>` (e.g. `mongodb_multiagent_dev`) | Target database name; project+env-derived by `.env` |
| `MEMORY_TTL_DAYS` | `90` | TTL for `agent_memory_facts` documents (days) |
| `CHAT_MESSAGES_COLLECTION` | `chat_messages` | Override the vector-searchable chat message mirror name |
| `EMBEDDING_DIMENSIONS` | `1024` | Vector index dimensions (must match your embedding model) |
| `VECTOR_SIMILARITY` | `cosine` | `cosine` \| `euclidean` \| `dotProduct` |
| `WAIT_FOR_ATLAS_SEARCH_INDEXES` | `0` | Set to `1` in deploy flows to wait until Atlas Search/vector indexes are queryable |
| `EMBEDDING_MODEL_ID` | `amazon.titan-embed-text-v2:0` | Bedrock model for embeddings |
| `EMBED_BATCH_DELAY_MS` | `200` | Delay between embedding API calls (throttle) |
| `AWS_REGION` | `us-east-1` | Required for `seed-embeddings.ts` |

## Atlas vector search indexes

`seed-indexes.ts` calls `createSearchIndex` which is Atlas-only.  
On a local/Community MongoDB server the script prints the JSON definition and skips — create the index manually in Atlas UI:

1. Navigate to **Atlas UI → Your Cluster → Search Indexes → Create Search Index**
2. Choose **JSON editor**
3. Paste the definition printed by `seed-indexes.ts`

### Example — products vector index

```json
{
  "name": "products-vector-index",
  "type": "vectorSearch",
  "definition": {
    "fields": [
      { "type": "vector", "path": "embedding", "numDimensions": 1024, "similarity": "cosine" },
      { "type": "filter", "path": "category" },
      { "type": "filter", "path": "tags" }
    ]
  }
}
```

## When to run

These seed scripts target the live Atlas deployment that the `mongodb-mcp-runtime` AgentCore Runtime talks to. `deploy/scripts/deploy-project.sh` and `deploy/deploy-api.sh` re-run `seed-indexes.ts` idempotently on every deploy so newly added Atlas Search/vector indexes are reconciled even when data seeding is skipped.

> **Critical:** `seed-indexes.ts` is the **only** place that creates the **partial-unique** index on `troubleshooting_docs.docId` (`partialFilterExpression: { docId: { $exists: true, $type: "string" } }`). Without this index, Bedrock KB ingestion fails every document with `E11000 duplicate key error on { docId: null }`. See [`docs/status/debugging.md` §5 → "Bedrock KB ingestion fails every doc with `Write failure with error code -3`"](../docs/status/debugging.md). The seeder also includes an `IndexOptionsConflict` heal path that drops + recreates a stale plain-unique `docId_1` if it exists.

> **Companion:** the canonical data-model reference is [`docs/reference/data-model.md`](../docs/reference/data-model.md) — schemas, indexes, retrieval contract.
