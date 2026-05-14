# db-seeding

MongoDB seed scripts for the Bedrock Multi-Agent demo stack. Each script is standalone and idempotent (safe to re-run).

## Scripts

| Script | Collections touched | Notes |
|--------|--------------------|----|
| `seed-customers.ts` | `customers` | 5 demo customers (standard + premium tiers) |
| `seed-products.ts` | `products` | 9 SKUs across home / electronics / outdoor |
| `seed-troubleshooting.ts` | `troubleshooting_docs` | 7 diagnostic articles (power, connectivity, HW fault, firmware, smart-home) |
| `seed-orders.ts` | `orders` | 12 orders covering all status variants per customer |
| `seed-indexes.ts` | all + `agent_memory` + `chat_sessions` | Regular indexes + Atlas vector search indexes + TTL on agent_memory; **`chat_sessions`** unique `sessionId` + `userId`/`updatedAt` (collection name overridable via **`CHAT_SESSIONS_COLLECTION`**) |
| `seed-embeddings.ts` | `products`, `troubleshooting_docs` | Backfills `embedding` field via Bedrock; requires AWS creds |
| `seed-all.ts` | all (except embeddings) | Runs all of the above in order; run once per environment |

**Runtime collection `chat_sessions`:** optional **`seed-indexes.ts`** creates indexes (including unique `sessionId`) so ops can provision ahead of the API. When the API runs with **`PERSIST_CHAT_SESSIONS=1`**, it still ensures the unique `sessionId` index on first use if missing (same database as `MONGODB_DB`).

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
| `MONGODB_DB` | `<project>_<env>` (e.g. `mongodb_multiagent_dev`) | Target database name; project+env-derived by `env.sh` |
| `MEMORY_TTL_DAYS` | `90` | TTL for `agent_memory` documents (days) |
| `EMBEDDING_DIMENSIONS` | `1536` | Vector index dimensions (must match your embedding model) |
| `VECTOR_SIMILARITY` | `cosine` | `cosine` \| `euclidean` \| `dotProduct` |
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
      { "type": "vector", "path": "embedding", "numDimensions": 1536, "similarity": "cosine" },
      { "type": "filter", "path": "category" },
      { "type": "filter", "path": "tags" }
    ]
  }
}
```

## When to run

These seed scripts target the live Atlas deployment behind the AgentCore Gateway's MCP target Lambda. Run them once after `deploy/scripts/deploy.sh` provisions the cluster, and again whenever you change the `db-seeding/` fixtures.
