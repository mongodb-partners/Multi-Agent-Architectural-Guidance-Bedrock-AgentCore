/**
 * Seed: generate and store embeddings for products and troubleshooting_docs.
 *
 * Strict provider selection — `EMBEDDINGS_PROVIDER` is mandatory and is the
 * single source of truth:
 *
 *   - `voyage` — uses Voyage AI on SageMaker via `VOYAGE_SAGEMAKER_ENDPOINT`.
 *     Exits non-zero if the endpoint env var is missing.
 *   - `titan`  — uses Amazon Bedrock via `EMBEDDING_MODEL_ID`. Exits non-zero
 *     if the model id is missing.
 *
 * There is no "pick by env presence" fallback any more — that was the bug
 * that let `chat_messages.embeddingModel` drift from `agent_memory_facts`
 * when both env vars were set on the same host.
 *
 * When switching providers (e.g. Titan → Voyage AI), run with REWIRE_EMBEDDINGS=1 to wipe
 * existing **seeder-owned** embeddings and regenerate everything from scratch with the new
 * model. Bedrock KB-managed chunks (rows carrying `bedrock_text_chunk` /
 * `bedrock_metadata`) are NEVER touched — they remain owned by the KB ingestion job.
 *
 * Failure semantics: this script exits non-zero if ANY row fails to embed, OR if a
 * post-run verification finds seeder-owned rows still missing `embedding`. The
 * legacy "log error and exit 0" path silently masked provider-config regressions
 * during deploy.
 *
 * Prerequisites:
 *   - MONGODB_URI set and collections already seeded
 *   - AWS credentials in environment
 *   - EMBEDDINGS_PROVIDER=voyage|titan (mandatory)
 *   - VOYAGE_SAGEMAKER_ENDPOINT=<endpoint-name>  (when EMBEDDINGS_PROVIDER=voyage)
 *     OR  EMBEDDING_MODEL_ID=<bedrock-model-id>  (when EMBEDDINGS_PROVIDER=titan)
 *   - VOYAGE_REQUEST_FORMAT=multimodal (default — voyage-multimodal-3) | legacy (voyage-3.5-lite)
 *
 * Run (Voyage AI multimodal-3):
 *   MONGODB_URI=... EMBEDDINGS_PROVIDER=voyage \
 *     VOYAGE_SAGEMAKER_ENDPOINT=mongodb-multiagent-voyage-multimodal-3-dev \
 *     REWIRE_EMBEDDINGS=1 node --experimental-strip-types db-seeding/seed-embeddings.ts
 *
 * Run (Bedrock / Titan):
 *   MONGODB_URI=... EMBEDDINGS_PROVIDER=titan \
 *     EMBEDDING_MODEL_ID=amazon.titan-embed-text-v2:0 \
 *     node --experimental-strip-types db-seeding/seed-embeddings.ts
 */

import {
  SageMakerRuntimeClient,
  InvokeEndpointCommand,
} from "@aws-sdk/client-sagemaker-runtime";
import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";
import type { Filter } from "mongodb";
import { connect } from "./connect.ts";

const DECLARED_PROVIDER = (process.env.EMBEDDINGS_PROVIDER ?? "").trim().toLowerCase();
const VOYAGE_ENDPOINT = process.env.VOYAGE_SAGEMAKER_ENDPOINT?.trim();
const BEDROCK_MODEL_ID = process.env.EMBEDDING_MODEL_ID?.trim();
const REWIRE = process.env.REWIRE_EMBEDDINGS === "1";
const BATCH_DELAY_MS = Number(process.env.EMBED_BATCH_DELAY_MS ?? 200);
const region = process.env.AWS_REGION ?? "us-east-1";

if (DECLARED_PROVIDER !== "voyage" && DECLARED_PROVIDER !== "titan") {
  console.error(
    `ERROR: EMBEDDINGS_PROVIDER='${DECLARED_PROVIDER}' is not recognised.\n` +
      "Set EMBEDDINGS_PROVIDER=voyage or EMBEDDINGS_PROVIDER=titan. Strict mode — no implicit default.",
  );
  process.exit(1);
}

if (DECLARED_PROVIDER === "voyage" && !VOYAGE_ENDPOINT) {
  console.error(
    "ERROR: EMBEDDINGS_PROVIDER=voyage but VOYAGE_SAGEMAKER_ENDPOINT is empty. " +
      "Refusing to fall back to Bedrock — the seed must use the same provider as the API runtime.",
  );
  process.exit(1);
}

if (DECLARED_PROVIDER === "titan" && !BEDROCK_MODEL_ID) {
  console.error(
    "ERROR: EMBEDDINGS_PROVIDER=titan but EMBEDDING_MODEL_ID is empty. " +
      "Refusing to fall back to Voyage — the seed must use the same provider as the API runtime.",
  );
  process.exit(1);
}

const provider: "voyage-ai" | "bedrock" = DECLARED_PROVIDER === "voyage" ? "voyage-ai" : "bedrock";
const modelLabel = DECLARED_PROVIDER === "voyage" ? VOYAGE_ENDPOINT! : BEDROCK_MODEL_ID!;
// Stamp every seeder-owned row with an unambiguous provider tag so the
// preflight check can do an exact-match assertion (no fuzzy substring).
const EMBEDDING_MODEL_TAG = DECLARED_PROVIDER === "voyage"
  ? `voyage:${VOYAGE_ENDPOINT}`
  : `bedrock:${BEDROCK_MODEL_ID}`;

console.log(`Embedding provider: ${provider} (${modelLabel})`);
console.log(`Embedding model tag: ${EMBEDDING_MODEL_TAG}`);
if (REWIRE) console.log("REWIRE_EMBEDDINGS=1 — will wipe and regenerate seeder-owned embeddings");

// ---------------------------------------------------------------------------
// Per-collection ownership filters
//
// Bedrock KB ingestion writes its chunks into `troubleshooting_docs` (per
// bedrock-kb/variables.tf). Those rows carry `bedrock_text_chunk` /
// `bedrock_metadata` and are owned by the KB ingestion job — the seeder must
// NEVER touch them, otherwise REWIRE_EMBEDDINGS=1 would overwrite KB-managed
// embeddings with garbage (`. . . `-only text since KB rows have no title/body).
//
// `products` is fully seeder-owned. KB chunks for products live in a separate
// embeddings collection at the moment, so `{}` is correct.
// ---------------------------------------------------------------------------
type CollectionPlan = {
  name: string;
  /** Subset of rows the seeder is allowed to touch. */
  seederOwnedFilter: Filter<Record<string, unknown>>;
  /** Identifier field used in human-readable progress logs. */
  idField: string;
  /** Build the text to embed for a doc. */
  buildText: (doc: Record<string, unknown>) => string;
};

const PRODUCTS_PLAN: CollectionPlan = {
  name: "products",
  seederOwnedFilter: {},
  idField: "sku",
  buildText: (doc) => {
    const tags = Array.isArray(doc.tags) ? (doc.tags as unknown[]).map(String) : [];
    return [doc.title, doc.description, ...tags].filter(Boolean).join(". ");
  },
};

const TROUBLESHOOTING_PLAN: CollectionPlan = {
  name: "troubleshooting_docs",
  seederOwnedFilter: {
    bedrock_text_chunk: { $exists: false },
    bedrock_metadata: { $exists: false },
  },
  idField: "docId",
  buildText: (doc) => {
    const symptoms = Array.isArray(doc.symptoms) ? (doc.symptoms as unknown[]).map(String) : [];
    const errorCodes = Array.isArray(doc.errorCodes)
      ? (doc.errorCodes as unknown[]).map(String)
      : [];
    return [doc.title, doc.body, ...symptoms, ...errorCodes].filter(Boolean).join(". ");
  },
};

// ---------------------------------------------------------------------------
// Embedding functions
// ---------------------------------------------------------------------------

// voyage-multimodal-3 returns a fixed 1024-d vector (matches the Atlas index).
// voyage-3.5-lite (legacy) returns 2048-d by default and accepts output_dimension —
// keep VOYAGE_OUTPUT_DIM=1024 there too. Override via env if you rebuild the
// index for a different size.
const VOYAGE_OUTPUT_DIM = Number(process.env.VOYAGE_OUTPUT_DIM ?? 1024);
const VOYAGE_REQUEST_FORMAT = (process.env.VOYAGE_REQUEST_FORMAT ?? "multimodal")
  .trim()
  .toLowerCase() === "legacy"
  ? "legacy"
  : "multimodal";

function buildVoyageBody(text: string): string {
  const truncated = text.slice(0, 32_000);
  if (VOYAGE_REQUEST_FORMAT === "legacy") {
    return JSON.stringify({
      input: [truncated],
      input_type: "document",
      output_dimension: VOYAGE_OUTPUT_DIM,
    });
  }
  return JSON.stringify({
    inputs: [{ content: [{ type: "text", text: truncated }] }],
    input_type: "document",
    truncation: true,
    output_encoding: null,
  });
}

async function embedViaVoyage(text: string): Promise<number[]> {
  const client = new SageMakerRuntimeClient({ region });
  const cmd = new InvokeEndpointCommand({
    EndpointName: VOYAGE_ENDPOINT!,
    ContentType: "application/json",
    Accept: "application/json",
    Body: Buffer.from(buildVoyageBody(text)),
  });
  const res = await client.send(cmd);
  const decoded = JSON.parse(new TextDecoder().decode(res.Body)) as {
    data: { embedding: number[] }[];
  };
  return decoded.data[0].embedding;
}

async function embedViaBedrock(text: string): Promise<number[]> {
  const client = new BedrockRuntimeClient({ region });
  const body = JSON.stringify({ inputText: text.slice(0, 8192) });
  const cmd = new InvokeModelCommand({
    modelId: BEDROCK_MODEL_ID!,
    contentType: "application/json",
    accept: "application/json",
    body,
  });
  const res = await client.send(cmd);
  const parsed = JSON.parse(new TextDecoder().decode(res.body)) as { embedding: number[] };
  return parsed.embedding;
}

async function embed(text: string): Promise<number[]> {
  return DECLARED_PROVIDER === "voyage" ? embedViaVoyage(text) : embedViaBedrock(text);
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

// ---------------------------------------------------------------------------
// Seed
// ---------------------------------------------------------------------------

const { client, db } = await connect();

type CollectionStats = {
  name: string;
  considered: number;
  attempted: number;
  done: number;
  failures: number;
  kbSkipped: number;
};

const stats: CollectionStats[] = [];

for (const plan of [PRODUCTS_PLAN, TROUBLESHOOTING_PLAN]) {
  const col = db.collection(plan.name);

  // How many rows the KB owns (skipped by us). For products this is 0; for
  // troubleshooting_docs this is the chunk count owned by the KB.
  const total = await col.countDocuments({});
  const seederOwned = await col.countDocuments(plan.seederOwnedFilter as never);
  const kbSkipped = total - seederOwned;
  if (kbSkipped > 0) {
    console.log(
      `\n${plan.name}: KB-owned rows (skipped): ${kbSkipped} of ${total} (seeder-owned: ${seederOwned})`,
    );
  }

  // Auto-stamp legacy seeder-owned rows that have `embedding` but no
  // `embeddingModel`. After this runs, every row in the seeder-owned subset
  // is either fully tagged or about to be re-embedded — letting the preflight
  // check enforce exact-match on `embeddingModel` without a fuzzy clause.
  const legacyResult = await col.updateMany(
    {
      ...(plan.seederOwnedFilter as never),
      embedding: { $exists: true },
      embeddingModel: { $exists: false },
    } as Filter<Record<string, unknown>>,
    { $set: { embeddingModel: EMBEDDING_MODEL_TAG } },
  );
  if (legacyResult.modifiedCount > 0) {
    console.log(
      `${plan.name}: auto-stamped ${legacyResult.modifiedCount} legacy rows with embeddingModel=${EMBEDDING_MODEL_TAG}`,
    );
  }

  if (REWIRE) {
    const wipe = await col.updateMany(
      plan.seederOwnedFilter as never,
      { $unset: { embedding: "", embeddingModel: "" } },
    );
    console.log(
      `${plan.name}: REWIRE_EMBEDDINGS=1 cleared ${wipe.modifiedCount} seeder-owned embeddings`,
    );
  }

  const findFilter: Filter<Record<string, unknown>> = {
    $and: [
      plan.seederOwnedFilter as Filter<Record<string, unknown>>,
      { embedding: { $exists: false } },
    ],
  };
  const docs = await col.find(findFilter as never).toArray();
  console.log(`${plan.name}: rows to embed: ${docs.length}`);

  let done = 0;
  let failures = 0;
  for (const doc of docs) {
    const text = plan.buildText(doc);
    const idLabel = String(doc[plan.idField] ?? doc._id);
    try {
      const embedding = await embed(text);
      await col.updateOne(
        { _id: doc._id },
        { $set: { embedding, embeddingModel: EMBEDDING_MODEL_TAG } },
      );
      done++;
      process.stdout.write(`  [${done}/${docs.length}] ${idLabel} ✓  (${embedding.length}d)\n`);
    } catch (err) {
      failures++;
      console.error(`  ❌  ${idLabel}: ${err instanceof Error ? err.message : err}`);
    }
    if (BATCH_DELAY_MS > 0) await sleep(BATCH_DELAY_MS);
  }

  console.log(`✅  ${plan.name}: ${done}/${docs.length} embeddings written (failures: ${failures})`);
  stats.push({
    name: plan.name,
    considered: total,
    attempted: docs.length,
    done,
    failures,
    kbSkipped,
  });
}

// Final cross-collection verification: every seeder-owned row in BOTH
// collections must have `embedding`. If not, we ran with partial provider
// access OR the rewire didn't catch all rows — exit non-zero so the deploy
// fails loud.
let postCheckMissing = 0;
const missingDetail: string[] = [];
for (const plan of [PRODUCTS_PLAN, TROUBLESHOOTING_PLAN]) {
  const col = db.collection(plan.name);
  const missing = await col.countDocuments({
    ...(plan.seederOwnedFilter as never),
    embedding: { $exists: false },
  } as never);
  if (missing > 0) {
    postCheckMissing += missing;
    missingDetail.push(`${plan.name}=${missing}`);
  }
}

await client.close();

const totalFailures = stats.reduce((acc, s) => acc + s.failures, 0);
if (totalFailures > 0 || postCheckMissing > 0) {
  console.error(
    `\n❌ Embedding seed incomplete: ${totalFailures} per-row failures, ${postCheckMissing} rows still missing embedding (${missingDetail.join(", ") || "n/a"}).`,
  );
  process.exit(2);
}

console.log(
  `\n✅ Embedding seed complete: ${stats
    .map((s) => `${s.name}=${s.done}/${s.attempted}`)
    .join(", ")} (provider=${EMBEDDING_MODEL_TAG})`,
);
