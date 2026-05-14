/**
 * Seed: generate and store embeddings for products and troubleshooting_docs.
 *
 * Embedding provider (in priority order):
 *   1. Voyage AI via SageMaker  — when VOYAGE_SAGEMAKER_ENDPOINT is set
 *      (default: voyage-multimodal-3, 1024-d, multimodal request envelope)
 *   2. Amazon Bedrock           — when EMBEDDING_MODEL_ID is set (Titan 1536-d / Cohere 1024-d)
 *
 * When switching providers (e.g. Titan → Voyage AI), run with REWIRE_EMBEDDINGS=1 to wipe
 * existing embeddings and regenerate everything from scratch with the new model.
 *
 * Prerequisites:
 *   - MONGODB_URI set and collections already seeded
 *   - AWS credentials in environment
 *   - VOYAGE_SAGEMAKER_ENDPOINT=<endpoint-name>  OR  EMBEDDING_MODEL_ID=<bedrock-model-id>
 *   - VOYAGE_REQUEST_FORMAT=multimodal (default — voyage-multimodal-3) | legacy (voyage-3.5-lite)
 *
 * Run (Voyage AI multimodal-3):
 *   MONGODB_URI=... VOYAGE_SAGEMAKER_ENDPOINT=mongodb-multiagent-voyage-multimodal-3-dev \
 *     REWIRE_EMBEDDINGS=1 node --experimental-strip-types db-seeding/seed-embeddings.ts
 *
 * Run (Bedrock / Titan):
 *   MONGODB_URI=... EMBEDDING_MODEL_ID=amazon.titan-embed-text-v2:0 \
 *     node --experimental-strip-types db-seeding/seed-embeddings.ts
 */

import {
  SageMakerRuntimeClient,
  InvokeEndpointCommand,
} from "@aws-sdk/client-sagemaker-runtime";
import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";
import { connect } from "./connect.ts";

const VOYAGE_ENDPOINT = process.env.VOYAGE_SAGEMAKER_ENDPOINT?.trim();
const BEDROCK_MODEL_ID = process.env.EMBEDDING_MODEL_ID?.trim();
const REWIRE = process.env.REWIRE_EMBEDDINGS === "1";
const BATCH_DELAY_MS = Number(process.env.EMBED_BATCH_DELAY_MS ?? 200);
const region = process.env.AWS_REGION ?? "us-east-1";

if (!VOYAGE_ENDPOINT && !BEDROCK_MODEL_ID) {
  console.error("ERROR: Set VOYAGE_SAGEMAKER_ENDPOINT or EMBEDDING_MODEL_ID");
  process.exit(1);
}

const provider = VOYAGE_ENDPOINT ? "voyage-ai" : "bedrock";
const modelLabel = VOYAGE_ENDPOINT ?? BEDROCK_MODEL_ID!;
console.log(`Embedding provider: ${provider} (${modelLabel})`);
if (REWIRE) console.log("REWIRE_EMBEDDINGS=1 — will wipe and regenerate all embeddings");

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
  return VOYAGE_ENDPOINT ? embedViaVoyage(text) : embedViaBedrock(text);
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

// ---------------------------------------------------------------------------
// Seed
// ---------------------------------------------------------------------------

const { client, db } = await connect();

// When rewiring, wipe existing embeddings so we regenerate all docs.
const filter = REWIRE ? {} : { embedding: { $exists: false } };

// ── products ─────────────────────────────────────────────────────────────────
{
  const col = db.collection("products");
  if (REWIRE) {
    await col.updateMany({}, { $unset: { embedding: "" } });
    console.log("\nCleared existing product embeddings (REWIRE_EMBEDDINGS=1)");
  }
  const docs = await col.find(filter).toArray();
  console.log(`\nProducts to embed: ${docs.length}`);
  let done = 0;
  for (const doc of docs) {
    const text = [doc.title, doc.description, ...(doc.tags ?? [])].join(". ");
    try {
      const embedding = await embed(text);
      await col.updateOne({ _id: doc._id }, { $set: { embedding } });
      done++;
      process.stdout.write(`  [${done}/${docs.length}] ${doc.sku} ✓  (${embedding.length}d)\n`);
    } catch (err) {
      console.error(`  ❌  ${doc.sku}: ${err instanceof Error ? err.message : err}`);
    }
    if (BATCH_DELAY_MS > 0) await sleep(BATCH_DELAY_MS);
  }
  console.log(`✅  products: ${done}/${docs.length} embeddings written`);
}

// ── troubleshooting_docs ──────────────────────────────────────────────────────
// NOTE: troubleshooting_docs are also indexed by the Bedrock KB (Titan, 1536-d).
// When REWIRE_EMBEDDINGS=1, the Bedrock KB ingestion job must be re-run after
// this script to restore KB-managed embeddings (or the KB can be recreated).
// For Voyage AI migration, the `mongodb_vector_search` tool will use the
// Voyage AI `embedding` field while `bedrock_kb_retrieve` uses the KB index.
{
  const col = db.collection("troubleshooting_docs");
  if (REWIRE) {
    await col.updateMany({}, { $unset: { embedding: "" } });
    console.log("\nCleared existing troubleshooting_docs embeddings (REWIRE_EMBEDDINGS=1)");
  }
  const docs = await col.find(filter).toArray();
  console.log(`\nTroubleshooting docs to embed: ${docs.length}`);
  let done = 0;
  for (const doc of docs) {
    const text = [
      doc.title,
      doc.body,
      ...(doc.symptoms ?? []),
      ...(doc.errorCodes ?? []),
    ].join(". ");
    try {
      const embedding = await embed(text);
      await col.updateOne({ _id: doc._id }, { $set: { embedding } });
      done++;
      process.stdout.write(`  [${done}/${docs.length}] ${doc.docId} ✓  (${embedding.length}d)\n`);
    } catch (err) {
      console.error(`  ❌  ${doc.docId}: ${err instanceof Error ? err.message : err}`);
    }
    if (BATCH_DELAY_MS > 0) await sleep(BATCH_DELAY_MS);
  }
  console.log(`✅  troubleshooting_docs: ${done}/${docs.length} embeddings written`);
}

await client.close();
