/**
 * Seed: MongoDB indexes
 *
 * Creates:
 *   1. Regular indexes — for fast mongodb_query lookups (orderId, email, sku, docId)
 *   2. Atlas Vector Search indexes — for mongodb_vector_search (products, troubleshooting_docs)
 *   3. TTL index on agent_memory (long-term memory expiry)
 *   4. chat_sessions — unique sessionId + userId/updatedAt for list queries (when using PERSIST_CHAT_SESSIONS)
 *
 * Safe to re-run — createIndex / createSearchIndex are idempotent.
 *
 * IMPORTANT for vector indexes:
 *   The `embedding` field must already exist on documents before the index is useful.
 *   Run seed-embeddings.ts after seeding products and troubleshooting_docs.
 *
 * Run:  MONGODB_URI=... bun db-seeding/seed-indexes.ts
 */

import { connect } from "./connect.ts";

const { client, db } = await connect();

const chatSessionsColl = process.env.CHAT_SESSIONS_COLLECTION?.trim() || "chat_sessions";

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
  // agent_memory — TTL index (90 days default; override via MEMORY_TTL_DAYS)
  {
    collection: "agent_memory",
    spec: { ts: 1 },
    options: {
      expireAfterSeconds: Math.round(Number(process.env.MEMORY_TTL_DAYS ?? 90) * 86400),
    },
  },
  { collection: "agent_memory", spec: { userId: 1, agentId: 1 } },
  // chat_sessions — API also ensures unique sessionId on first use; seed keeps prod DB aligned
  { collection: chatSessionsColl, spec: { sessionId: 1 }, options: { unique: true } },
  { collection: chatSessionsColl, spec: { userId: 1, updatedAt: -1 } },
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

const vectorIndexes: { collection: string; name: string }[] = [
  { collection: "products", name: "products-vector-index" },
  { collection: "troubleshooting_docs", name: "troubleshooting-vector-index" },
];

// Atlas vector index definition shape
function vectorIndexDef(collection: string, indexName: string) {
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
        // Allow pre-filtering by category / affectedSkus in knnBeta queries
        ...(collection === "products"
          ? [{ type: "filter", path: "category" }, { type: "filter", path: "tags" }]
          : [{ type: "filter", path: "category" }, { type: "filter", path: "affectedSkus" }]),
      ],
    },
  };
}

let vectorOk = 0;
for (const { collection, name } of vectorIndexes) {
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (db.collection(collection) as any).createSearchIndex(
      vectorIndexDef(collection, name),
    );
    console.log(`  ✅  vector index '${name}' on ${collection} — creation initiated (Atlas will build asynchronously)`);
    vectorOk++;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("already exists") || msg.includes("Duplicate")) {
      console.log(`  ✅  vector index '${name}' on ${collection} — already exists`);
      vectorOk++;
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

await client.close();
