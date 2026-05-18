/**
 * Seed: MongoDB indexes
 *
 * Creates:
 *   1. Regular indexes — for fast mongodb_query lookups (orderId, email, sku, docId)
 *      Includes unique `{ userId, factHash }` on `agent_memory_facts` so write-time
 *      dedup via bulkWrite upsert never inserts the same fact twice.
 *   2. Atlas Vector Search indexes — for `mongodb_vector_search` on:
 *        products, troubleshooting_docs, agent_memory_facts, chat_messages.
 *   3. Atlas Search (BM25/text) indexes — for the lexical leg of
 *      `mongodb_hybrid_search`:
 *        products(name+description), troubleshooting_docs(title+body),
 *        agent_memory_facts(fact), chat_messages(content).
 *   4. TTL index on agent_memory_facts (long-term memory expiry) — also
 *      created lazily by the API on first write; seeded here so a fresh
 *      cluster has it before traffic.
 *   5. chat_sessions — unique sessionId + userId/updatedAt for list queries.
 *   6. chat_messages — { sessionId, timestamp } + unique messageId +
 *      { userId, ts } for the chat-message mirror used by hybrid retrieval.
 *
 * Safe to re-run — createIndex / createSearchIndex are idempotent.
 * Set WAIT_FOR_ATLAS_SEARCH_INDEXES=1 to block until Atlas reports all search
 * indexes as READY/queryable. Deploy scripts use this so smoke tests do not
 * race asynchronous index builds.
 *
 * IMPORTANT for vector indexes:
 *   The `embedding` field must already exist on documents before the index is useful.
 *   Run seed-embeddings.ts after seeding products and troubleshooting_docs.
 *   For agent_memory_facts and chat_messages the embedding is populated at
 *   write time by the API, so no separate seeder step is required.
 *
 * Run:  MONGODB_URI=... bun db-seeding/seed-indexes.ts
 */

import { connect } from "./connect.ts";

const { client, db } = await connect();

const chatSessionsColl = process.env.CHAT_SESSIONS_COLLECTION?.trim() || "chat_sessions";
const chatMessagesColl = process.env.CHAT_MESSAGES_COLLECTION?.trim() || "chat_messages";

// ─────────────────────────────────────────────────────────────────────────────
// 1. Regular indexes
// ─────────────────────────────────────────────────────────────────────────────

const regularIndexes: { collection: string; spec: Record<string, 1 | -1>; options?: Record<string, unknown> }[] = [
  // orders
  { collection: "orders", spec: { orderId: 1 }, options: { unique: true } },
  { collection: "orders", spec: { customerEmail: 1 } },
  { collection: "orders", spec: { status: 1 } },
  { collection: "orders", spec: { customerEmail: 1, status: 1 } },
  // products
  { collection: "products", spec: { sku: 1 }, options: { unique: true } },
  { collection: "products", spec: { category: 1 } },
  { collection: "products", spec: { tags: 1 } },
  // customers
  { collection: "customers", spec: { email: 1 }, options: { unique: true } },
  // troubleshooting_docs — `docId` uniqueness is enforced ONLY for seed playbooks
  // that actually carry a docId. Bedrock KB ingestion writes chunk documents into
  // this same collection and they do not have a `docId` field; a plain
  // `{ unique: true }` index would treat the missing field as `docId: null` and
  // collide on the second chunk insert with E11000, surfacing inside Bedrock as
  // the cryptic "Write failure with error code -3" (see memory.md). The partial
  // filter scopes the unique constraint to documents that explicitly set docId.
  {
    collection: "troubleshooting_docs",
    spec: { docId: 1 },
    options: {
      unique: true,
      partialFilterExpression: { docId: { $exists: true, $type: "string" } },
    },
  },
  { collection: "troubleshooting_docs", spec: { errorCodes: 1 } },
  { collection: "troubleshooting_docs", spec: { affectedSkus: 1 } },
  // agent_memory_facts — TTL index (90 days default; override via MEMORY_TTL_DAYS).
  // The API also ensures the TTL index lazily on first write (see
  // `api/src/lib/long-term-memory.ts → ensureTtlIndex`); seeding here gives
  // a fresh cluster the index before any user traffic arrives.
  {
    collection: "agent_memory_facts",
    spec: { ts: 1 },
    options: {
      expireAfterSeconds: Math.round(Number(process.env.MEMORY_TTL_DAYS ?? 90) * 86400),
    },
  },
  { collection: "agent_memory_facts", spec: { userId: 1, agentId: 1 } },
  // Per-user dedup key: write-side bulkWrite upserts on { userId, factHash }
  // so the same fact never lands twice. The hash is computed from
  // normalized fact text (see `computeFactHash` in long-term-memory.ts).
  {
    collection: "agent_memory_facts",
    spec: { userId: 1, factHash: 1 },
    options: {
      unique: true,
      partialFilterExpression: { factHash: { $exists: true, $type: "string" } },
    },
  },
  // chat_sessions — API also ensures unique sessionId on first use; seed keeps prod DB aligned
  { collection: chatSessionsColl, spec: { sessionId: 1 }, options: { unique: true } },
  { collection: chatSessionsColl, spec: { userId: 1, updatedAt: -1 } },
  // chat_messages — vector-searchable mirror of individual chat turns. Auto-
  // ensured by the API on first write (`chat-messages-collection.ts`); seeded
  // here so fresh clusters are ready before traffic.
  { collection: chatMessagesColl, spec: { sessionId: 1, timestamp: 1 } },
  { collection: chatMessagesColl, spec: { messageId: 1 }, options: { unique: true } },
  { collection: chatMessagesColl, spec: { userId: 1, ts: -1 } },
];

let regularOk = 0;
for (const { collection, spec, options } of regularIndexes) {
  try {
    await db.collection(collection).createIndex(spec, { background: true, ...options });
    regularOk++;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    // IndexOptionsConflict means the same key exists with different options.
    // Heal it by dropping + recreating with the requested options. This is what
    // turns a stale plain-unique `docId_1` index into the partial-unique form so
    // Bedrock KB ingestion can coexist with seed playbooks.
    if (msg.includes("IndexOptionsConflict") || msg.includes("IndexKeySpecsConflict")) {
      const keyName = Object.entries(spec)
        .map(([k, v]) => `${k}_${v}`)
        .join("_");
      try {
        await db.collection(collection).dropIndex(keyName);
        await db.collection(collection).createIndex(spec, { background: true, ...options });
        console.log(`  ↺  ${collection}.${keyName} re-created with new options`);
        regularOk++;
      } catch (recreateErr) {
        const recreateMsg = recreateErr instanceof Error ? recreateErr.message : String(recreateErr);
        console.warn(`  ⚠️  ${collection} ${JSON.stringify(spec)} reconcile failed: ${recreateMsg}`);
      }
    } else if (msg.includes("already exists")) {
      regularOk++;
    } else {
      console.warn(`  ⚠️  ${collection} ${JSON.stringify(spec)}: ${msg}`);
    }
  }
}
console.log(`✅  Regular indexes: ${regularOk}/${regularIndexes.length} created/verified`);

// ─────────────────────────────────────────────────────────────────────────────
// 2. Atlas Vector Search indexes
//
// These require a MongoDB Atlas cluster with vector search enabled.
// The driver method `createSearchIndex` is only available on Atlas.
// On a local MongoDB or Community Server this will throw — that is expected.
// ─────────────────────────────────────────────────────────────────────────────

// voyage-3 = 1024d, voyage-3-lite = 512d, Titan v2 = 1536d
const EMBEDDING_DIMENSIONS = Number(process.env.EMBEDDING_DIMENSIONS ?? 1024);
const SIMILARITY = (process.env.VECTOR_SIMILARITY ?? "cosine") as "cosine" | "euclidean" | "dotProduct";
const WAIT_FOR_ATLAS_SEARCH_INDEXES = ["1", "true", "yes"].includes(
  (process.env.WAIT_FOR_ATLAS_SEARCH_INDEXES ?? "").trim().toLowerCase(),
);

function isExistingSearchIndexMessage(msg: string): boolean {
  return msg.includes("already exists") || msg.includes("Duplicate") || msg.includes("already defined");
}

const vectorIndexes: { collection: string; name: string }[] = [
  { collection: "products", name: "products-vector-index" },
  { collection: "troubleshooting_docs", name: "troubleshooting-vector-index" },
  { collection: "agent_memory_facts", name: "agent_memory_facts-vector-index" },
  { collection: chatMessagesColl, name: "chat_messages-vector-index" },
];

// Atlas vector index definition shape
function vectorIndexDef(collection: string, indexName: string) {
  let filterFields: Array<{ type: "filter"; path: string }>;
  switch (collection) {
    case "products":
      filterFields = [
        { type: "filter", path: "category" },
        { type: "filter", path: "tags" },
        { type: "filter", path: "price" },
      ];
      break;
    case "troubleshooting_docs":
      filterFields = [
        { type: "filter", path: "category" },
        { type: "filter", path: "affectedSkus" },
      ];
      break;
    case "agent_memory_facts":
      // Scope by user (mandatory) + agent (often) at retrieval time.
      filterFields = [
        { type: "filter", path: "userId" },
        { type: "filter", path: "agentId" },
        { type: "filter", path: "source" },
      ];
      break;
    case chatMessagesColl:
      filterFields = [
        { type: "filter", path: "userId" },
        { type: "filter", path: "sessionId" },
        { type: "filter", path: "agentId" },
        { type: "filter", path: "role" },
      ];
      break;
    default:
      filterFields = [];
  }
  return {
    name: indexName,
    type: "vectorSearch",
    definition: {
      fields: [
        {
          type: "vector",
          path: "embedding",
          numDimensions: EMBEDDING_DIMENSIONS,
          similarity: SIMILARITY,
        },
        ...filterFields,
      ],
    },
  };
}

let vectorOk = 0;
const expectedAtlasSearchIndexes: Array<{ collection: string; name: string }> = [];
for (const { collection, name } of vectorIndexes) {
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (db.collection(collection) as any).createSearchIndex(
      vectorIndexDef(collection, name),
    );
    console.log(`  ✅  vector index '${name}' on ${collection} — creation initiated (Atlas will build asynchronously)`);
    vectorOk++;
    expectedAtlasSearchIndexes.push({ collection, name });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (isExistingSearchIndexMessage(msg)) {
      console.log(`  ✅  vector index '${name}' on ${collection} — already exists`);
      vectorOk++;
      expectedAtlasSearchIndexes.push({ collection, name });
    } else if (msg.includes("not supported") || msg.includes("AtlasOnly") || msg.includes("MongoServerError")) {
      console.warn(
        `  ⚠️  vector index '${name}' skipped — createSearchIndex is only available on Atlas clusters.\n` +
        `     Create this index manually in Atlas UI (Search Indexes > Create Search Index > JSON editor):\n` +
        JSON.stringify(vectorIndexDef(collection, name), null, 6)
          .split("\n")
          .map((l) => "     " + l)
          .join("\n"),
      );
    } else {
      console.warn(`  ⚠️  vector index '${name}' on ${collection}: ${msg}`);
    }
  }
}
console.log(`✅  Vector search indexes: ${vectorOk}/${vectorIndexes.length} created/verified`);

// ─────────────────────────────────────────────────────────────────────────────
// 3. Atlas Search (BM25 / text) indexes
//
// Used by `mongodb_hybrid_search` (the lexical leg of hybrid mode) and by the
// direct-Mongo LTM hybrid retriever (`readLongTermMemoryContext`). Each index
// covers the human-readable text field(s) for its collection plus a couple of
// scoping fields so the compound `filter` clauses can be applied without
// loading the doc.
// ─────────────────────────────────────────────────────────────────────────────

type LexicalIndexSpec = {
  collection: string;
  name: string;
  fields: Array<{ type: "string"; path: string } | { type: "token"; path: string }>;
};

const lexicalIndexes: LexicalIndexSpec[] = [
  {
    collection: "products",
    name: "products-text-index",
    fields: [
      { type: "string", path: "name" },
      { type: "string", path: "description" },
      { type: "token", path: "sku" },
      { type: "token", path: "category" },
    ],
  },
  {
    collection: "troubleshooting_docs",
    name: "troubleshooting-text-index",
    fields: [
      { type: "string", path: "title" },
      { type: "string", path: "body" },
      { type: "token", path: "category" },
    ],
  },
  {
    collection: "agent_memory_facts",
    name: "agent_memory_facts-text-index",
    fields: [
      { type: "string", path: "fact" },
      { type: "token", path: "userId" },
      { type: "token", path: "agentId" },
    ],
  },
  {
    collection: chatMessagesColl,
    name: "chat_messages-text-index",
    fields: [
      { type: "string", path: "content" },
      { type: "token", path: "userId" },
      { type: "token", path: "sessionId" },
      { type: "token", path: "role" },
    ],
  },
];

function lexicalIndexDef(spec: LexicalIndexSpec) {
  // Atlas Search dynamic mapping is convenient but indexes every field; we
  // declare an explicit static mapping so BM25 only touches the fields the
  // retriever actually queries (cheaper + faster cold start).
  const fields: Record<string, unknown> = {};
  for (const f of spec.fields) {
    fields[f.path] = { type: f.type };
  }
  return {
    name: spec.name,
    type: "search",
    definition: {
      mappings: { dynamic: false, fields },
    },
  };
}

let lexicalOk = 0;
for (const spec of lexicalIndexes) {
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (db.collection(spec.collection) as any).createSearchIndex(lexicalIndexDef(spec));
    console.log(`  ✅  text index '${spec.name}' on ${spec.collection} — creation initiated`);
    lexicalOk++;
    expectedAtlasSearchIndexes.push({ collection: spec.collection, name: spec.name });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (isExistingSearchIndexMessage(msg)) {
      console.log(`  ✅  text index '${spec.name}' on ${spec.collection} — already exists`);
      lexicalOk++;
      expectedAtlasSearchIndexes.push({ collection: spec.collection, name: spec.name });
    } else if (msg.includes("not supported") || msg.includes("AtlasOnly") || msg.includes("MongoServerError")) {
      console.warn(
        `  ⚠️  text index '${spec.name}' skipped — createSearchIndex is only available on Atlas clusters.\n` +
        `     Create this index manually in Atlas UI (Search Indexes > Create Search Index > JSON editor):\n` +
        JSON.stringify(lexicalIndexDef(spec), null, 6)
          .split("\n")
          .map((l) => "     " + l)
          .join("\n"),
      );
    } else {
      console.warn(`  ⚠️  text index '${spec.name}' on ${spec.collection}: ${msg}`);
    }
  }
}
console.log(`✅  Atlas Search text indexes: ${lexicalOk}/${lexicalIndexes.length} created/verified`);

if (WAIT_FOR_ATLAS_SEARCH_INDEXES && expectedAtlasSearchIndexes.length > 0) {
  await waitForAtlasSearchIndexes(expectedAtlasSearchIndexes);
}

await client.close();

async function waitForAtlasSearchIndexes(
  expected: Array<{ collection: string; name: string }>,
): Promise<void> {
  const deadline = Date.now() + Number(process.env.ATLAS_SEARCH_INDEX_WAIT_MS ?? 10 * 60 * 1000);
  const sleepMs = Number(process.env.ATLAS_SEARCH_INDEX_POLL_MS ?? 15_000);
  console.log(`⏳ Waiting for ${expected.length} Atlas Search indexes to become queryable...`);

  while (Date.now() < deadline) {
    const pending: string[] = [];
    for (const { collection, name } of expected) {
      try {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const indexes = await (db.collection(collection) as any).listSearchIndexes(name).toArray();
        const idx = indexes.find((i: Record<string, unknown>) => i.name === name);
        if (!idx || (idx.status !== "READY" && idx.queryable !== true)) {
          pending.push(`${collection}.${name}:${String(idx?.status ?? "missing")}`);
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        pending.push(`${collection}.${name}:${msg}`);
      }
    }

    if (pending.length === 0) {
      console.log("✅  Atlas Search indexes are READY/queryable");
      return;
    }

    console.log(`  … waiting on ${pending.join(", ")}`);
    await new Promise((resolve) => setTimeout(resolve, sleepMs));
  }

  throw new Error("Timed out waiting for Atlas Search indexes to become queryable");
}
