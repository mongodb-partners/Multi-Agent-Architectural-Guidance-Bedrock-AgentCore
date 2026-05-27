/**
 * Backfill: re-embed `chat_messages` and `agent_memory_facts` rows whose
 * `embeddingModel` does not match the declared `EMBEDDINGS_PROVIDER`.
 *
 * Why this exists:
 *
 *   Before strict-mode enforcement (see `api/src/lib/embed-query.ts`), the API
 *   silently fell back from Voyage to Bedrock Titan whenever the Voyage
 *   SageMaker endpoint hiccupped. Rows from those failures landed in MongoDB
 *   with `embeddingModel: "amazon.titan-embed-text-v2:0"` even though `.env`
 *   declared `EMBEDDINGS_PROVIDER=voyage`. Because both Titan v2 and Voyage
 *   are 1024-d, vector search succeeded but returned semantically meaningless
 *   scores — the bug stayed silent.
 *
 *   This script walks the affected collections, finds rows whose
 *   `embeddingModel` has the wrong prefix for the declared provider, and
 *   re-embeds them with the correct provider.
 *
 *   Idempotent — safe to re-run after every provider switch.
 *
 * Usage:
 *
 *   bun db-seeding/reembed-mismatched.ts                 # dry-run (default)
 *   bun db-seeding/reembed-mismatched.ts --apply         # actually write
 *   bun db-seeding/reembed-mismatched.ts --apply --batch 50
 *
 * Env (same as seed-embeddings.ts):
 *   - MONGODB_URI, MONGODB_DB
 *   - EMBEDDINGS_PROVIDER=voyage|titan  (mandatory)
 *   - VOYAGE_SAGEMAKER_ENDPOINT  (when voyage)
 *   - EMBEDDING_MODEL_ID         (when titan)
 *   - AWS_REGION
 */

import {
  SageMakerRuntimeClient,
  InvokeEndpointCommand,
} from "@aws-sdk/client-sagemaker-runtime";
import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";
import type { Collection } from "mongodb";
import { connect } from "./connect.ts";
// Single source of truth for the Voyage request envelope. The historical
// local copy of buildVoyageBody here caused 'input' vs 'inputs' drift to land
// in the recovery path — the worst possible time. Multimodal-only after the
// voyage-multimodal-only-sagemaker PR; text inputs are wrapped via
// `textToMultimodal()` before crossing the typed adapter boundary.
import {
  buildVoyageRequestBody,
  textToMultimodal,
  getVoyageEndpoint,
  getVoyageModelName,
} from "../api/src/adapters/voyage-embedding.ts";

// ---------------------------------------------------------------------------
// Config + strict provider gate
// ---------------------------------------------------------------------------

const args = new Set(process.argv.slice(2));
const APPLY = args.has("--apply");
const DECLARED_PROVIDER = (process.env.EMBEDDINGS_PROVIDER ?? "").trim().toLowerCase();
const VOYAGE_ENDPOINT = getVoyageEndpoint();
const BEDROCK_MODEL_ID = process.env.EMBEDDING_MODEL_ID?.trim();
const region = process.env.AWS_REGION ?? "us-east-1";

let BATCH_SIZE = 100;
const batchIdx = process.argv.indexOf("--batch");
if (batchIdx !== -1 && process.argv[batchIdx + 1]) {
  const v = Number(process.argv[batchIdx + 1]);
  if (Number.isFinite(v) && v > 0) BATCH_SIZE = v;
}

if (DECLARED_PROVIDER !== "voyage" && DECLARED_PROVIDER !== "titan") {
  console.error(
    `ERROR: EMBEDDINGS_PROVIDER='${DECLARED_PROVIDER}' is not recognised.\n` +
      "Set EMBEDDINGS_PROVIDER=voyage or EMBEDDINGS_PROVIDER=titan. Strict mode — no implicit default.",
  );
  process.exit(1);
}

if (DECLARED_PROVIDER === "voyage" && !VOYAGE_ENDPOINT) {
  console.error("ERROR: EMBEDDINGS_PROVIDER=voyage but VOYAGE_SAGEMAKER_ENDPOINT is empty.");
  process.exit(1);
}

if (DECLARED_PROVIDER === "titan" && !BEDROCK_MODEL_ID) {
  console.error("ERROR: EMBEDDINGS_PROVIDER=titan but EMBEDDING_MODEL_ID is empty.");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Predicate: rows that should be re-embedded.
//
// In voyage mode we re-embed any row tagged with a Bedrock model id (or with
// no `embeddingModel` at all if it has an `embedding`) — those are leftovers
// from the silent-fallback era. In titan mode the converse: anything tagged
// `voyage…`. We also re-embed rows that have an `embeddingError` marker (the
// strict mode now sets this when the provider failed at write time).
// ---------------------------------------------------------------------------

const wrongPrefix =
  DECLARED_PROVIDER === "voyage"
    ? /^amazon\.|^bedrock:|^titan/i
    : /^voyage/i;

const reembedFilter = {
  $or: [
    { embeddingModel: { $regex: wrongPrefix } },
    { embeddingError: { $exists: true } },
  ],
};

// ---------------------------------------------------------------------------
// Embedding adapters (mirror seed-embeddings.ts so this script doesn't depend
// on the API runtime). Both providers return 1024-d vectors.
// ---------------------------------------------------------------------------

// Body builder imported from the api adapter — DO NOT inline a third
// copy here. Multimodal-only; text is wrapped via `textToMultimodal`.

async function embedViaVoyage(text: string): Promise<{ vector: number[]; model: string }> {
  const client = new SageMakerRuntimeClient({ region });
  const cmd = new InvokeEndpointCommand({
    EndpointName: VOYAGE_ENDPOINT!,
    ContentType: "application/json",
    Accept: "application/json",
    Body: Buffer.from(buildVoyageRequestBody([textToMultimodal(text)], "document")),
  });
  const res = await client.send(cmd);
  const decoded = JSON.parse(new TextDecoder().decode(res.Body)) as {
    data?: { embedding: number[]; index: number }[];
    embedding?: number[];
    model?: string;
  };
  const vector = decoded.data?.[0]?.embedding ?? decoded.embedding;
  if (!Array.isArray(vector)) {
    throw new Error(`Voyage returned no embedding: ${JSON.stringify(decoded).slice(0, 200)}`);
  }
  const model = decoded.model ?? getVoyageModelName();
  return { vector, model };
}

async function embedViaBedrock(text: string): Promise<{ vector: number[]; model: string }> {
  const client = new BedrockRuntimeClient({ region });
  const cmd = new InvokeModelCommand({
    modelId: BEDROCK_MODEL_ID!,
    contentType: "application/json",
    accept: "application/json",
    body: JSON.stringify({ inputText: text.slice(0, 32_000) }),
  });
  const res = await client.send(cmd);
  const parsed = JSON.parse(new TextDecoder().decode(res.body)) as { embedding: number[] };
  if (!Array.isArray(parsed.embedding)) {
    throw new Error(`Bedrock returned no embedding: ${JSON.stringify(parsed).slice(0, 200)}`);
  }
  return { vector: parsed.embedding, model: BEDROCK_MODEL_ID! };
}

async function embed(text: string): Promise<{ vector: number[]; model: string }> {
  return DECLARED_PROVIDER === "voyage" ? embedViaVoyage(text) : embedViaBedrock(text);
}

// ---------------------------------------------------------------------------
// Per-collection plans
// ---------------------------------------------------------------------------

type Plan = {
  collection: string;
  /** Field that holds the source text to re-embed. */
  textField: "content" | "fact";
  /** Stable identifier for log lines. */
  idField: string;
};

const PLANS: Plan[] = [
  { collection: process.env.CHAT_MESSAGES_COLLECTION?.trim() || "chat_messages", textField: "content", idField: "messageId" },
  { collection: "agent_memory_facts", textField: "fact", idField: "factHash" },
];

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function processCollection(plan: Plan, db: Awaited<ReturnType<typeof connect>>["db"]): Promise<{
  matched: number;
  reembedded: number;
  failed: number;
}> {
  const coll: Collection = db.collection(plan.collection);
  const matched = await coll.countDocuments(reembedFilter);
  console.log(`[${plan.collection}] mismatched rows: ${matched}`);
  if (matched === 0 || !APPLY) {
    return { matched, reembedded: 0, failed: 0 };
  }

  let reembedded = 0;
  let failed = 0;
  const cursor = coll.find(reembedFilter).batchSize(BATCH_SIZE);
  while (await cursor.hasNext()) {
    const doc = await cursor.next();
    if (!doc) break;
    const text = String(doc[plan.textField] ?? "").trim();
    const id = String(doc[plan.idField] ?? doc._id ?? "?");
    if (!text) {
      console.warn(`[${plan.collection}] skipping ${id} — empty ${plan.textField}`);
      continue;
    }
    try {
      const { vector, model } = await embed(text);
      await coll.updateOne(
        { _id: doc._id },
        {
          $set: { embedding: vector, embeddingModel: model },
          $unset: { embeddingError: "" },
        },
      );
      reembedded++;
      if (reembedded % 25 === 0) console.log(`[${plan.collection}] re-embedded ${reembedded}/${matched}`);
    } catch (err) {
      failed++;
      console.error(
        `[${plan.collection}] re-embed FAILED for ${id}: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }
  return { matched, reembedded, failed };
}

(async () => {
  console.log(`Backfill: EMBEDDINGS_PROVIDER=${DECLARED_PROVIDER}, mode=${APPLY ? "apply" : "dry-run"}`);
  const { client, db } = await connect();
  try {
    let totalMatched = 0;
    let totalReembedded = 0;
    let totalFailed = 0;
    for (const plan of PLANS) {
      const r = await processCollection(plan, db);
      totalMatched += r.matched;
      totalReembedded += r.reembedded;
      totalFailed += r.failed;
    }
    console.log(
      `\nSummary: matched=${totalMatched} reembedded=${totalReembedded} failed=${totalFailed} mode=${APPLY ? "apply" : "dry-run"}`,
    );
    if (!APPLY && totalMatched > 0) {
      console.log("Re-run with --apply to write the new embeddings.");
    }
    if (totalFailed > 0) process.exit(1);
  } finally {
    await client.close();
  }
})().catch((err) => {
  console.error("FATAL", err);
  process.exit(1);
});
