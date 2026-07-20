# MongoDB Atlas Data Model — Reference

Every collection the system reads or writes, with its schema, indexes, TTLs, and access path. Source of truth is [`db-seeding/seed-indexes.ts`](../../db-seeding/seed-indexes.ts) plus the lazy `createIndex` calls in `api/src/lib/*-collection.ts`.

Run [`bun db-seeding/seed-indexes.ts`](../../db-seeding/seed-indexes.ts) once per cluster to seed every regular index, vector index, and Atlas Search index. The seeder is idempotent.

**Conventions:**

- All collections live in the database named by `MONGODB_DB` (default `bedrock_agents`; the `deploy/` scripts set this to `<project_slug>_<env>` via `ATLAS_DB_NAME`).
- "Lazy" indexes are also created on first write by the API. The seeder is **not** required for the API to run; it is required for fresh clusters to be ready for traffic before the first request lands.
- Vector + BM25 indexes are Atlas-only (`createSearchIndex`). On Community Server the seeder logs a JSON snippet and skips them.

---

## 1. Application data — seeded fixtures

These are the demo collections seeded by [`db-seeding/seed-all.ts`](../../db-seeding/seed-all.ts).

Embedding dimension for every vector index is the SSOT constant `VOYAGE_EMBEDDING_DIMS` in [`api/src/adapters/voyage-embedding.ts`](../../api/src/adapters/voyage-embedding.ts) — currently **1024**.

### 1a. Recruitment collections (current specialists)

### `career_paths`
| Field | Type | Notes |
|---|---|---|
| `pathId` | string | **Unique** human-readable ID; cite this in responses, not `_id` |
| `targetRole` | string | The role this path leads to |
| `fromRoles` | string[] | Typical starting roles this path applies to |
| `seniority` | string | `junior` \| `mid` \| `senior` \| `staff` (filterable) |
| `description` | string | Narrative of the transition |
| `requiredSkills` | object[] | `{ skillId, name, importance, note }[]`; `importance` is `core` \| `important` \| `nice` |
| `milestones` | object[] | `{ order, title, skills[], estimatedWeeks }[]` |
| `embeddingText` | string | Concatenated text the embedding is generated from |
| `embedding?` | number[] | 1024-d |

**Regular indexes:** `{ pathId: 1 }` (unique), `{ targetRole: 1 }`, `{ seniority: 1 }`.
**Vector index `career_paths_vector_index`:** `embedding` + filter on `seniority`.
**Atlas Search `career_paths_text_index`:** `description` + `targetRole` + `fromRoles` (string), `seniority` (token).
**Access:** `career-coach` skill → MCP `mongodb_vector_search` (hybrid, `lexicalPath: "description"`).

### `skills_taxonomy`
| Field | Type | Notes |
|---|---|---|
| `skillId` | string | **Unique**; matches `career_paths.requiredSkills[].skillId` |
| `name` | string | Lowercase skill name |
| `category` | string | `machine-learning` / `backend` / `leadership` / … (filterable) |
| `description` | string | |
| `prerequisites` | string[] | `skillId` values to learn first |
| `resourceType` | string | `course` \| `book` \| `project` \| `certification` |
| `resources` | object[] | `{ title, provider, url?, estimatedHours }[]` |
| `embedding?` | number[] | 1024-d |

**Regular indexes:** `{ skillId: 1 }` (unique), `{ name: 1 }`, `{ category: 1 }`.
**Vector index `skills_taxonomy_vector_index`:** `embedding` + filter on `category`.
**Access:** `career-coach` skill — usually `mongodb_query` → `find` on `skillId`/`name` (`$in`); vector search only for fuzzy skill descriptions.

### `compensation_data`
| Field | Type | Notes |
|---|---|---|
| `benchmarkId` | string | **Unique**; cite this in responses |
| `role` | string | Role title (BM25 lexical path) |
| `seniority` | string | `junior` \| `mid` \| `senior` \| `staff` (filterable) |
| `region` | string | `us-west` \| `us-south` \| `us-east` \| `us-central` \| `remote-us` \| `emea` \| `apac` (filterable) |
| `locationLabel` | string | Human-readable location |
| `currency` | string | ISO code; always stated with figures |
| `asOf` | string (date) | Benchmark date; flag if stale |
| `baseSalary` | object | `{ p25, p50, p75, p90 }` |
| `totalComp` | object | `{ p25, p50, p75, p90 }` incl. bonus/equity |
| `benefits` | string[] | Present verbatim |
| `equityNote` | string | Present verbatim |
| `sampleSize` | number | Small values warrant a lower-confidence note |
| `embedding?` | number[] | 1024-d |

**Regular indexes:** `{ benchmarkId: 1 }` (unique), `{ role: 1, seniority: 1, region: 1 }`, `{ seniority: 1 }`, `{ region: 1 }`.
**Vector index `compensation_vector_index`:** `embedding` + filters on `seniority`, `region`.
**Atlas Search `compensation_text_index`:** `role` + `locationLabel` (string), `seniority` + `region` (token).
**Access:** `career-coach` skill (compensation workflow) → MCP `mongodb_vector_search` (hybrid, `lexicalPath: "role"`).

### `companies`
| Field | Type | Notes |
|---|---|---|
| `companyId` | string | **Unique**; cite this in responses |
| `name` | string | Company name (BM25 lexical path) |
| `industry` | string | Sector label (filterable) |
| `stage` | string | `Seed` \| `Series A`–`Series D` \| `Public` \| `Bootstrapped` (filterable) |
| `foundedYear` | number | |
| `headcount` | string | Employee band, e.g. `1,000–5,000` |
| `fundingTotal` | string | Display string; may be `null` |
| `headquarters` | string | |
| `description` | string | Narrative overview |
| `cultureSignals` | string[] | Present verbatim |
| `engineeringPractices` | string[] | Present verbatim |
| `sentimentSummary` | string | Balanced summary; present verbatim |
| `pros` / `cons` | string[] | Always presented together |
| `sentimentScore` | number | 1.0–5.0 |
| `asOf` | string (date) | Freshness; flag if stale |
| `embedding?` | number[] | 1024-d |

**Regular indexes:** `{ companyId: 1 }` (unique), `{ name: 1 }`, `{ industry: 1 }`, `{ stage: 1 }`.
**Vector index `companies_vector_index`:** `embedding` + filters on `industry`, `stage`.
**Atlas Search `companies_text_index`:** `name` + `industry` + `description` (string), `stage` (token).
**Access:** `company-intel` skill → MCP `mongodb_vector_search` (hybrid, `lexicalPath: "name"`) + `bedrock_kb_retrieve`.

### `jobs`, `candidates`, `interview_prep` — declared, not yet seeded

The `job-match` skill documents these three collections in [`config/skills/job-match/references/collections-schema.md`](../../config/skills/job-match/references/collections-schema.md), but `db-seeding/` has **no seeder and no index definitions** for them yet. Until seeders land, `job-match` has no data to search on a fresh cluster. See that skill reference for the intended schemas.

### 1b. Legacy demo collections (still seeded, no longer consumed)

These belong to the previous customer-support demo. `seed-all.ts` still creates and indexes them, but no agent in `config/agents/` reads them. They are safe to drop once the seeders are pruned.

### `products`
| Field | Type | Notes |
|---|---|---|
| `sku` | string | **Unique** identifier |
| `title` | string | Catalog title |
| `description` | string | Long-form description |
| `category` | string | `home` / `electronics` / … (filterable) |
| `tags` | string[] | Free-form tags (filterable) |
| `price` | number | USD |
| `stock` | number | Inventory count |
| `rating` | number | 0–5 |
| `specs` | object | Free-form (warranty, weight, …) |
| `replacedBy?` | string[] | Cross-sell hints |
| `similarTo?` | string[] | Cross-sell hints |
| `embedding?` | number[] | 1024-d (Voyage `voyage-multimodal-3` or Bedrock Titan v2). Populated by `seed-embeddings.ts` or by Atlas trigger |
| `embeddingModel?` | string | `"voyage"` \| `"bedrock:<modelId>"` |

**Regular indexes:** `{ sku: 1 }` (unique), `{ category: 1 }`, `{ tags: 1 }`.
**Vector index `products-vector-index`:** `embedding` (1024-d, cosine) + filters on `category`, `tags`, `price`.
**Atlas Search `products-text-index`:** `title` + `description` (string), `sku` + `category` (token).
**Access:** none — the legacy `product-recommendation` skill was removed.

### `orders`
| Field | Type | Notes |
|---|---|---|
| `orderId` | string | **Unique** |
| `status` | string | `placed` \| `shipped` \| `delivered` \| `cancelled` \| `returned` |
| `customerEmail` | string | Joins to `customers.email` |
| `orderDate` | Date | |
| `estimatedDelivery?` | Date | |
| `deliveredAt?` | Date | |
| `items` | object[] | `{ sku, title, qty, unitPrice, returnEligible? }[]` |
| `total` | number | USD |
| `trackingNumber?` | string | |
| `trackingUrl?` | string | |
| `shippingAddress?` | object | `{ line1, city, state, zip }` |
| `notes?` | string | Customer-service annotations |

**Regular indexes:** `{ orderId: 1 }` (unique), `{ customerEmail: 1 }`, `{ status: 1 }`, `{ customerEmail: 1, status: 1 }`.
**Access:** none — the legacy `order-management` skill was removed.

### `customers`
| Field | Type | Notes |
|---|---|---|
| `email` | string | **Unique** primary key |
| `name` | string | |
| `verified` | boolean | |
| `tier` | string | `standard` \| `premium` |
| `joinedAt` | Date | |
| `preferences` | object | `{ contactMethod, language }` |

**Regular index:** `{ email: 1 }` (unique).
**Access:** none — the legacy `order-management` skill was removed.

### `troubleshooting_docs`
Hosts both seed playbooks (with `docId`) and Bedrock KB chunked documents (without `docId`).

| Field | Type | Notes |
|---|---|---|
| `docId?` | string | Unique **only for seed playbooks** — the partial-unique index scopes uniqueness via `{ docId: { $exists: true, $type: "string" } }`. KB ingestion writes documents without `docId`; this prevents the `Write failure with error code -3` E11000 collision that historically broke KB ingest. |
| `title` | string | |
| `category` | string | `power` \| `connectivity` \| … |
| `errorCodes` | string[] | |
| `affectedSkus` | string[] | Joins to `products.sku` |
| `symptoms` | string[] | Lexical hints |
| `body` | string | Long-form playbook |
| `escalateTo?` | string | Cross-link to another `docId` |
| `embedding?` | number[] | 1024-d |
| `embeddingModel?` | string | |
| `updatedAt` | Date | |

**Regular indexes:** `{ docId: 1 }` (partial-unique), `{ errorCodes: 1 }`, `{ affectedSkus: 1 }`.
**Vector index `troubleshooting-vector-index`:** `embedding` (1024-d, cosine) + filters on `category`, `affectedSkus`.
**Atlas Search `troubleshooting-text-index`:** `title` + `body` (string), `category` (token).
**Access:** no agent reads this — the legacy `troubleshooting` skill was removed. Bedrock KB ingestion still writes here.

---

## 2. Memory + chat persistence (written at runtime)

These are auto-ensured by the API on first write (`createIndex` in `lib/*-collection.ts`) and also seeded by `seed-indexes.ts` so fresh clusters are ready before traffic.

### `chat_sessions` (override via `CHAT_SESSIONS_COLLECTION`)
Persistent mirror of every chat session for the Sessions page, audit/debug history, and cold-read fallback. In deployed AWS, **AgentCore Memory is the authoritative short-term memory backend**; this collection is not the authoritative short-term memory backend.

| Field | Type | Notes |
|---|---|---|
| `sessionId` | string | **Unique** |
| `userId?` | string | JWT `sub`; scopes `GET /sessions` + `DELETE /sessions/:id` |
| `createdAt` | string (ISO) | |
| `updatedAt` | string (ISO) | |
| `messages` | object[] | `[{ id, role, content, timestamp, agentId? }]` |

**Indexes:** `{ sessionId: 1 }` (unique, lazy via API), `{ userId: 1, updatedAt: -1 }` (seeded only — speeds `GET /sessions`).
**Persistence gate:** `MONGODB_URI` set AND `PERSIST_CHAT_SESSIONS != 0`.
**Memory role:** mirror/fallback only when `SHORT_TERM_MEMORY_BACKEND=agentcore`; primary short-term memory remains AgentCore.
**Access:** [`api/src/lib/session-store.ts`](../../api/src/lib/session-store.ts) + `routes/sessions.ts`.

### `chat_messages` (override via `CHAT_MESSAGES_COLLECTION`)
Flat, vector-searchable mirror of every individual chat turn. Atlas `$vectorSearch` does not operate cleanly on nested arrays inside `chat_sessions.messages[]`, so the API writes a copy here for hybrid retrieval.

| Field | Type | Notes |
|---|---|---|
| `messageId` | string | **Unique** — matches `chat_sessions.messages[].id` |
| `sessionId` | string | Joins to `chat_sessions.sessionId` |
| `userId?` | string | |
| `agentId?` | string | Assistant turns only |
| `role` | string | `user` \| `assistant` |
| `content` | string | |
| `timestamp` | string (ISO) | |
| `ts` | Date | Mirror of `timestamp` (used for recency decay + Atlas filter scope) |
| `embedding?` | number[] | 1024-d Voyage / Bedrock Titan v2 |
| `embeddingModel?` | string | |

**Indexes:** `{ messageId: 1 }` (unique), `{ sessionId: 1, timestamp: 1 }`, `{ userId: 1, ts: -1 }`.
**Vector index `chat_messages-vector-index`:** `embedding` (1024-d, cosine) + filters on `userId`, `sessionId`, `agentId`, `role`.
**Atlas Search `chat_messages-text-index`:** `content` (string), `userId` + `sessionId` + `role` (token).
**Cascade:** `DELETE /sessions/:id` calls `deleteMessagesBySession()` so the privacy contract holds.
**Access:** `lib/chat-messages-collection.ts` → `long-term-memory.ts` hybrid retrieval.

### `agent_memory_facts`
LLM-curated long-term memory. Activated when an agent has `memory.longTerm: true` and the request carries a `userId`.

| Field | Type | Notes |
|---|---|---|
| `userId` | string | JWT `sub` |
| `agentId` | string | Which agent learned the fact |
| `fact` | string | LLM-extracted natural-language fact |
| `source` | string | `user` \| `assistant` |
| `ts` | Date | Used for TTL + recency decay |
| `factHash` | string | sha256 of `{userId, agentId, normalizedFact}` — used as dedup upsert key |
| `embedding?` | number[] | 1024-d |
| `embeddingModel?` | string | |

**Indexes:**
- `{ ts: 1 }` with `expireAfterSeconds = MEMORY_TTL_DAYS * 86400` — **TTL index** (default 90 days; production deploy sets 30).
- `{ userId: 1, agentId: 1 }` — primary lookup.
- `{ userId: 1, factHash: 1 }` (partial-unique on `factHash` present) — write-side `bulkWrite` upsert key.

**Vector index `agent_memory_facts-vector-index`:** `embedding` (1024-d, cosine) + filters on `userId`, `agentId`, `source`.
**Atlas Search `agent_memory_facts-text-index`:** `fact` (string), `userId` + `agentId` (token).
**Access:** [`api/src/lib/long-term-memory.ts`](../../api/src/lib/long-term-memory.ts) — `readLongTermMemoryContext` (hybrid retrieval) + `writeLongTermMemory` (LLM fact extraction → embed → `bulkWrite` upsert on `{userId, factHash}`).

### `traces` (override via `TRACES_COLLECTION`)
Per-turn trace documents.

| Field | Type | Notes |
|---|---|---|
| `traceId` | string | **Unique** (UUID per turn) |
| `sessionId` | string | |
| `messageId` | string | |
| `userId?` | string | |
| `agentId?` | string | |
| `createdAt` | Date | TTL anchor |
| `events` | object[] | Discriminated union per `trace-types.ts` |
| `summary` | object | `eventsDropped`, `model.usage` cost rollup, etc. |
| `release?` | object | `{ gitSha, deployTs, env }` |

**Indexes:** `{ traceId: 1 }` (unique), `{ sessionId: 1, messageId: 1 }`, `{ createdAt: 1 }` with `expireAfterSeconds = TRACE_TTL_DAYS * 86400` (default 30 days).
**Persistence gate:** `MONGODB_URI` set AND tracing not disabled. Always written to the in-process ring buffer (size `TRACE_RING_BUFFER_SIZE`, default 100) as a fast read-through cache.
**Access:** [`api/src/lib/trace-store.ts`](../../api/src/lib/trace-store.ts) → `GET /traces/:id`, `GET /trace`, `GET /trace/mongo`, `GET /traces`.

---

## 3. Hybrid retrieval contract

The `mongodb_hybrid_search` MCP tool and `readLongTermMemoryContext` both compose:

- a `$vectorSearch` leg against the vector index (e.g. `agent_memory_facts-vector-index`),
- a `$search` (BM25 / lexical) leg against the matching text index (e.g. `agent_memory_facts-text-index`),
- fused with **Reciprocal Rank Fusion** (k=60), weighted (`MEMORY_WEIGHT_FACTS`, `MEMORY_WEIGHT_CHAT_MESSAGES`), recency-decayed (`MEMORY_RECENCY_HALFLIFE_DAYS`), and MMR-diversified (`MEMORY_MMR_LAMBDA`).

Shared retrieval primitives live in [`api/src/lib/vector-retrieval.ts`](../../api/src/lib/vector-retrieval.ts). See [`docs/long-term-memory-design.md`](../long-term-memory-design.md) for the full algorithm and [`docs/hybrid-search.md`](../hybrid-search.md) for the MCP-side API.

---

## 4. Embedding dimensions

- **Voyage `voyage-multimodal-3` / `voyage-multimodal-3.5` (default)**: 1024-d, cosine similarity. Configured via `VOYAGE_SAGEMAKER_ENDPOINT`; the multimodal request envelope is built by `buildVoyageRequestBody` (no env flag). See [`docs/reference/voyage.md`](voyage.md).
- **Bedrock Titan v2 fallback** (`EMBEDDINGS_PROVIDER=titan`): 1024-d via `output_dimension=1024` on the Titan request envelope — matches Voyage so no re-index is needed when switching providers.

Override via `EMBEDDING_DIMENSIONS` (passed to `seed-indexes.ts`) when seeding a different model. **All four vector indexes must use the same dimension** because the API picks the embedding provider at query time, not per-collection.

---

*Last verified: 2026-05-20 against `db-seeding/seed-indexes.ts`, `api/src/lib/{long-term-memory,chat-sessions-collection,chat-messages-collection,trace-store}.ts`, and the four seeders under `db-seeding/`.*
