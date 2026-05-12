import type { JSONValue } from "@strands-agents/sdk";
import { InvokeCommand, LambdaClient } from "@aws-sdk/client-lambda";
import { getMongoDb } from "../lib/mongo-client.ts";
import { logger } from "../lib/logger.ts";
import { bedrockGenerateEmbedding } from "./mock-retrieval.ts";
import { voyageGenerateEmbedding, isVoyageConfigured, getVoyageEndpoint } from "./voyage-embedding.ts";
import { currentTrace } from "../lib/trace-context.ts";
import {
  diagnosticConfig,
  normalizeFilter,
  buildSchemaSummary,
  runEmptyResultDiagnostic,
  scoreHistogram,
  type MongoLike,
} from "../lib/mongo-diagnostic.ts";
// Shared MongoDB MCP guards — single source of truth for the rules applied to
// `mongodb_query`. Lives in `lambda/mongodb-mcp/` because the Lambda zip uses
// it without a build step; the API also imports it for behavioral parity.
// `api/Dockerfile` COPYs the two files into the image so the relative path
// resolves at runtime as well as at type-check / esbuild time.
import {
  validateMongoQueryInputs,
  MongoGuardError,
  parseBoolEnv,
  parseMaxLimit,
  type NormalizedMongoQueryInputs,
} from "../../../lambda/mongodb-mcp/guards.mjs";

const asJSON = (v: unknown): JSONValue => v as JSONValue;
let _lambdaClient: LambdaClient | null = null;

function toolHostingMode(): string {
  return process.env.TOOL_HOSTING_MODE?.trim().toLowerCase() || "direct";
}

function isLambdaToolMode(): boolean {
  return toolHostingMode() === "lambda";
}

/**
 * Defense in depth for the mutually-exclusive tool-path contract. The agent
 * builder in `create-strands-agent.ts` already excludes the in-process Mongo
 * tools when `TOOL_HOSTING_MODE=gateway`, so this function should never reach
 * here in that mode. If it does, something has miswired the tool list — fail
 * loudly rather than silently bypassing the Gateway.
 */
function assertNotGatewayMode(callsite: string): void {
  if (toolHostingMode() === "gateway") {
    throw new Error(
      `${callsite} called with TOOL_HOSTING_MODE=gateway — programming error: ` +
        "agents in gateway mode must call Mongo tools via the AgentCore Gateway MCP target, " +
        "not via the in-process tool. Check create-strands-agent.ts tool composition.",
    );
  }
}

function getLambdaClient(): LambdaClient {
  if (!_lambdaClient) {
    _lambdaClient = new LambdaClient({ region: process.env.AWS_REGION ?? "us-east-1" });
  }
  return _lambdaClient;
}

async function invokeLambdaTool(tool: string, args: Record<string, unknown>): Promise<Record<string, unknown>> {
  const functionName = process.env.LAMBDA_MCP_FUNCTION_NAME?.trim() || process.env.LAMBDA_MCP_FUNCTION_ARN?.trim();
  if (!functionName) {
    return {
      status: "not_configured",
      hint: "Set LAMBDA_MCP_FUNCTION_NAME (or LAMBDA_MCP_FUNCTION_ARN) when TOOL_HOSTING_MODE=lambda.",
    };
  }

  const cmd = new InvokeCommand({
    FunctionName: functionName,
    InvocationType: "RequestResponse",
    Payload: new TextEncoder().encode(JSON.stringify({ tool, args })),
  });

  const res = await getLambdaClient().send(cmd);
  const raw = res.Payload ? new TextDecoder().decode(res.Payload) : "";
  if (!raw) return { status: "error", message: "Empty Lambda MCP response." };

  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    return { status: "error", message: `Lambda MCP returned non-JSON: ${raw.slice(0, 200)}` };
  }

  if (parsed.statusCode && Number(parsed.statusCode) >= 400) {
    return {
      status: "error",
      message: String(parsed.error || parsed.message || "Lambda MCP call failed"),
      detail: parsed,
    };
  }
  return parsed;
}

export type MongoQueryInput = {
  collection: string;
  operation: "find" | "findOne" | "aggregate" | "updateOne" | "insertOne";
  query?: Record<string, unknown>;
  projection?: Record<string, unknown>;
  sort?: Record<string, unknown>;
  limit?: number;
  /** Required for `updateOne`. */
  update?: Record<string, unknown>;
  /** Required for `insertOne`. */
  document?: Record<string, unknown>;
  /** Required for `aggregate`. */
  pipeline?: unknown[];
};

function allowWrites(): boolean {
  return parseBoolEnv(process.env.MONGODB_ALLOW_WRITE);
}

// Generous default to preserve historical behavior (the in-process path used
// `input.limit ?? 100`); the cap exists primarily as defense-in-depth.
const API_MAX_LIMIT_FALLBACK = 500;
const API_DEFAULT_FIND_LIMIT = 100;
const API_DEFAULT_AGGREGATE_LIMIT = 100;

// Per-turn schema-sampling cache lives on the collector to avoid double sampling.
const SCHEMA_CACHE_KEY = "__mongoSchemaSampled__";
async function maybeSampleSchema(
  collectionName: string,
  coll: { findOne: MongoLike["findOne"]; estimatedDocumentCount: () => Promise<number> },
): Promise<{ sample: Record<string, unknown> | null; estimatedCount: number }> {
  const trace = currentTrace();
  const cfg = diagnosticConfig();
  if (!cfg.schemaEnabled) return { sample: null, estimatedCount: 0 };
  if (trace) {
    const cache = (trace as unknown as Record<string, Set<string>>)[SCHEMA_CACHE_KEY] ??
      ((trace as unknown as Record<string, Set<string>>)[SCHEMA_CACHE_KEY] = new Set());
    if (cache.has(collectionName)) return { sample: null, estimatedCount: 0 };
    cache.add(collectionName);
  }
  try {
    const sample = await coll.findOne({}, { maxTimeMS: cfg.perProbeMs });
    const estimatedCount = await coll.estimatedDocumentCount();
    if (trace) {
      trace.event("mongo.schema", buildSchemaSummary(collectionName, sample, estimatedCount) as never);
    }
    return { sample, estimatedCount };
  } catch {
    return { sample: null, estimatedCount: 0 };
  }
}

function checkUserScoping(
  filter: Record<string, unknown> | undefined,
): "ok" | "missing_user_filter" {
  if (!diagnosticConfig().flagUserid) return "ok";
  if (!filter) return "missing_user_filter";
  const keys = Object.keys(filter);
  for (const k of keys) {
    const lower = k.toLowerCase();
    if (lower === "userid" || lower === "user_id" || lower === "customerid" || lower === "sub") {
      return "ok";
    }
  }
  return "missing_user_filter";
}

/** Run MongoDB operations directly against Atlas. Requires MONGODB_URI. */
export async function runMongoDataQuery(input: MongoQueryInput): Promise<JSONValue> {
  assertNotGatewayMode("runMongoDataQuery");
  const trace = currentTrace();
  const cfg = diagnosticConfig();

  // mongo.intent — best-effort. We don't know the triggering user message here,
  // but we still mark the collection so the dashboard can render a card.
  trace?.event("mongo.intent", { collection: input.collection });

  const normalizedFilter = input.query ? normalizeFilter(input.query) : undefined;
  const scoping = checkUserScoping(input.query);

  // Apply shared guards (op allowlist, write gate, denylists, limit clamp, …)
  // before either dispatch path. Same module the Lambda uses.
  let validated: NormalizedMongoQueryInputs;
  try {
    validated = validateMongoQueryInputs(input as Record<string, unknown>, {
      allowWrite: allowWrites(),
      maxLimit: parseMaxLimit(process.env.MONGODB_MAX_LIMIT, API_MAX_LIMIT_FALLBACK),
      defaultFindLimit: API_DEFAULT_FIND_LIMIT,
      defaultAggregateLimit: API_DEFAULT_AGGREGATE_LIMIT,
    });
  } catch (err) {
    if (err instanceof MongoGuardError) {
      trace?.event("mongo.result", {
        docCount: 0,
        latencyMs: 0,
        status: "error",
        errorClass: "MongoGuardError",
        errorMessage: err.message,
      });
      return asJSON({ status: "error", message: err.message, code: err.code });
    }
    throw err;
  }

  if (isLambdaToolMode()) {
    trace?.event("mongo.query", {
      mode: "lambda",
      collection: validated.collection,
      op: validated.operation,
      filter: validated.filter,
      normalizedFilter,
      projection: validated.projection,
      sort: validated.sort,
      limit: validated.limit,
      pipeline: validated.pipeline,
      scoping,
    });
    const t0 = Date.now();
    try {
      const payload = {
        collection: validated.collection,
        operation: validated.operation,
        query: validated.filter,
        filter: validated.filter,
        projection: validated.projection,
        sort: validated.sort,
        limit: validated.limit,
        pipeline: validated.pipeline,
        update: validated.update,
        document: validated.document,
      };
      const out = await invokeLambdaTool("mongodb_query", payload);
      const latencyMs = Date.now() - t0;
      // Lambda packs per-op trace events into out.meta.traces. Replay them so
      // mongo.schema / mongo.plan / mongo.diagnostic cards appear alongside the
      // API-emitted mongo.query / mongo.result events below. Symmetric with
      // the MCP wrapper in mongodb-mcp-client.ts (which handles the Path B
      // case where the Lambda response comes back through AgentCore Gateway).
      const lambdaMeta = (out.meta as { traces?: Array<{ type?: string; payload?: unknown }> } | undefined);
      if (lambdaMeta?.traces?.length && trace) {
        for (const ev of lambdaMeta.traces) {
          if (!ev || typeof ev !== "object" || typeof ev.type !== "string") continue;
          trace.event(ev.type as never, (ev.payload ?? {}) as never);
        }
      }
      if (out.status === "error" || out.status === "not_configured") {
        trace?.event("mongo.result", {
          docCount: 0,
          latencyMs,
          status: "error",
          errorMessage: String(out.message ?? out.hint ?? ""),
        });
        return asJSON(out);
      }
      const data = (out.data as Record<string, unknown> | undefined) ?? out;
      if (input.operation === "find") {
        const docs = (data.documents as unknown[]) ?? [];
        trace?.event("mongo.result", {
          docCount: docs.length,
          latencyMs,
          status: docs.length === 0 ? "empty" : "ok",
          sampleDocs: docs.slice(0, 3),
        });
        return asJSON({ status: "ok", operation: "find", count: docs.length, results: docs });
      }
      if (input.operation === "findOne") {
        const docs = (data.documents as unknown[]) ?? [];
        const docCount = docs[0] ? 1 : 0;
        trace?.event("mongo.result", {
          docCount,
          latencyMs,
          status: docCount === 0 ? "empty" : "ok",
          sampleDocs: docs.slice(0, 1),
        });
        return asJSON({ status: "ok", operation: "findOne", document: docs[0] ?? null });
      }
      if (input.operation === "aggregate") {
        const docs = (data.documents as unknown[]) ?? [];
        trace?.event("mongo.result", {
          docCount: docs.length,
          latencyMs,
          status: docs.length === 0 ? "empty" : "ok",
          sampleDocs: docs.slice(0, 3),
        });
        return asJSON({ status: "ok", operation: "aggregate", results: docs });
      }
      if (input.operation === "insertOne") {
        trace?.event("mongo.result", { docCount: 1, latencyMs, status: "ok" });
        return asJSON({ status: "ok", operation: "insertOne", insertedId: data.insertedId ?? null });
      }
      if (input.operation === "updateOne") {
        trace?.event("mongo.result", {
          docCount: Number(data.modifiedCount ?? 0),
          latencyMs,
          status: "ok",
        });
        return asJSON({
          status: "ok",
          operation: "updateOne",
          matched: Number(data.matchedCount ?? 0),
          modified: Number(data.modifiedCount ?? 0),
        });
      }
      trace?.event("mongo.result", { docCount: 0, latencyMs, status: "ok" });
      return asJSON({ status: "ok", operation: input.operation, result: data });
    } catch (err) {
      const latencyMs = Date.now() - t0;
      const msg = err instanceof Error ? err.message : String(err);
      const errClass = err instanceof Error ? err.constructor.name : "Error";
      logger.error("[mongo-data] lambda mcp query failed", { operation: input.operation, error: msg });
      trace?.event("mongo.result", {
        docCount: 0,
        latencyMs,
        status: "error",
        errorClass: errClass,
        errorMessage: msg,
      });
      return asJSON({ status: "error", message: msg });
    }
  }

  const db = await getMongoDb();
  if (!db) {
    return {
      status: "not_configured",
      hint: "Set MONGODB_URI to connect to MongoDB Atlas.",
    };
  }

  const coll = db.collection(input.collection);
  trace?.event("mongo.query", {
    mode: "direct",
    database: db.databaseName,
    collection: validated.collection,
    op: validated.operation,
    filter: validated.filter,
    normalizedFilter,
    projection: validated.projection,
    sort: validated.sort,
    limit: validated.limit,
    pipeline: validated.pipeline,
    scoping,
  });

  const t0 = Date.now();
  const runDiagnosticAfterEmpty = async (filter: Record<string, unknown>): Promise<void> => {
    if (!cfg.diagnosticEnabled || !trace) return;
    const { sample } = await maybeSampleSchema(input.collection, {
      findOne: ((f, o) => coll.findOne(f, o)) as MongoLike["findOne"],
      estimatedDocumentCount: () => coll.estimatedDocumentCount(),
    });
    const diag = await runEmptyResultDiagnostic({
      collection: input.collection,
      filter,
      resultCount: 0,
      sampleDoc: sample,
      coll: {
        countDocuments: (f, o) => coll.countDocuments(f, o),
        findOne: (f, o) => coll.findOne(f, o) as Promise<Record<string, unknown> | null>,
      },
    });
    trace.event("mongo.diagnostic", diag);
  };

  const maybeRunExplain = async (filter: Record<string, unknown>): Promise<void> => {
    if (!cfg.explainEnabled || !trace) return;
    try {
      const explain = await coll
        .find(filter)
        .explain("executionStats") as Record<string, unknown>;
      const exec = (explain.executionStats as Record<string, unknown>) ?? {};
      const winning = (explain.queryPlanner as Record<string, unknown>)?.winningPlan as Record<string, unknown>;
      const rejectedPlans =
        Array.isArray((explain.queryPlanner as Record<string, unknown>)?.rejectedPlans)
          ? ((explain.queryPlanner as Record<string, unknown>)?.rejectedPlans as unknown[]).length
          : undefined;
      const nReturned = Number(exec.nReturned ?? 0);
      const totalDocsExamined = Number(exec.totalDocsExamined ?? 0);
      const selectivity = totalDocsExamined > 0 ? nReturned / totalDocsExamined : undefined;
      const selectivityLow = selectivity !== undefined && selectivity < 0.1;
      const stage = winning?.stage as string | undefined;
      const indexMissing = stage === "COLLSCAN" ? Object.keys(filter)[0] : undefined;
      trace.event("mongo.plan", {
        mode: "direct",
        explainSupported: true,
        stage,
        indexName: (winning?.inputStage as Record<string, unknown>)?.indexName as string | undefined,
        nReturned,
        totalDocsExamined,
        totalKeysExamined: Number(exec.totalKeysExamined ?? 0),
        executionTimeMillis: Number(exec.executionTimeMillis ?? 0),
        rejectedPlans,
        selectivity,
        selectivity_low: selectivityLow,
        index_missing_suggested: indexMissing,
      });
    } catch {
      /* explain not supported / permission error — silent */
    }
  };

  try {
    switch (input.operation) {
      case "find": {
        const filter = validated.filter;
        let cursor = coll.find(filter);
        if (validated.sort) cursor = cursor.sort(validated.sort as Record<string, 1 | -1>);
        if (validated.projection) cursor = cursor.project(validated.projection);
        const results = await cursor.limit(validated.limit).toArray();
        const latencyMs = Date.now() - t0;
        trace?.event("mongo.result", {
          docCount: results.length,
          latencyMs,
          status: results.length === 0 ? "empty" : "ok",
          sampleDocs: results.slice(0, 3),
        });
        if (results.length === 0) await runDiagnosticAfterEmpty(filter);
        await maybeRunExplain(filter);
        return asJSON({ status: "ok", operation: "find", count: results.length, results });
      }
      case "findOne": {
        const filter = validated.filter;
        let cursor = coll.find(filter);
        if (validated.sort) cursor = cursor.sort(validated.sort as Record<string, 1 | -1>);
        if (validated.projection) cursor = cursor.project(validated.projection);
        const doc = await cursor.limit(1).next();
        const latencyMs = Date.now() - t0;
        const docCount = doc ? 1 : 0;
        trace?.event("mongo.result", {
          docCount,
          latencyMs,
          status: docCount === 0 ? "empty" : "ok",
          sampleDocs: doc ? [doc] : [],
        });
        if (docCount === 0) await runDiagnosticAfterEmpty(filter);
        return asJSON({ status: "ok", operation: "findOne", document: doc ?? null });
      }
      case "aggregate": {
        const raw = await coll
          .aggregate(validated.pipeline as Record<string, unknown>[])
          .toArray();
        const latencyMs = Date.now() - t0;
        const results = raw.slice(0, validated.limit);
        trace?.event("mongo.result", {
          docCount: results.length,
          latencyMs,
          status: results.length === 0 ? "empty" : "ok",
          sampleDocs: results.slice(0, 3),
        });
        return asJSON({ status: "ok", operation: "aggregate", results });
      }
      case "updateOne": {
        // Guards (write-gate, non-empty filter, $where/$function denylist) are
        // enforced up front by validateMongoQueryInputs.
        const r = await coll.updateOne(validated.filter, { $set: validated.update! });
        trace?.event("mongo.result", {
          docCount: r.modifiedCount,
          latencyMs: Date.now() - t0,
          status: "ok",
        });
        return { status: "ok", matched: r.matchedCount, modified: r.modifiedCount };
      }
      case "insertOne": {
        const doc = { ...validated.document!, createdAt: new Date() };
        const r = await coll.insertOne(doc);
        trace?.event("mongo.result", {
          docCount: 1,
          latencyMs: Date.now() - t0,
          status: "ok",
        });
        return { status: "ok", operation: "insertOne", insertedId: r.insertedId.toString() };
      }
      default:
        return { status: "error", message: `Unsupported operation: ${input.operation}` };
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const errClass = err instanceof Error ? err.constructor.name : "Error";
    trace?.event("mongo.result", {
      docCount: 0,
      latencyMs: Date.now() - t0,
      status: "error",
      errorClass: errClass,
      errorMessage: msg,
    });
    throw err;
  }
}

// ---------------------------------------------------------------------------
// Atlas Vector Search
// ---------------------------------------------------------------------------

export type AtlasVectorSearchInput = {
  collection: string;
  queryText: string;
  indexName: string;
  limit?: number;
  filter?: Record<string, unknown>;
};

/**
 * Run an Atlas Vector Search query against MongoDB Atlas.
 *
 * Prerequisites:
 *  - MONGODB_URI set to an Atlas M10+ cluster
 *  - An Atlas Vector Search index named `indexName` on the `embedding` field
 *  - EC2 / POC mode:   VOYAGE_SAGEMAKER_ENDPOINT set (Voyage AI multimodal-3)
 *  - Local mode:       EMBEDDING_MODEL_ID set (Titan fallback, no SageMaker needed)
 */
export async function runAtlasVectorSearch(input: AtlasVectorSearchInput): Promise<JSONValue> {
  assertNotGatewayMode("runAtlasVectorSearch");
  const trace = currentTrace();
  const cfg = diagnosticConfig();
  let queryVector: number[];
  let embeddingSource: "voyage" | "bedrock" | "mock" = "mock";
  let embeddingModelId: string | undefined;
  try {
    let embedResult: JSONValue;
    if (isVoyageConfigured()) {
      embeddingSource = "voyage";
      embedResult = await voyageGenerateEmbedding(input.queryText, getVoyageEndpoint(), "query");
    } else {
      embeddingModelId = process.env.EMBEDDING_MODEL_ID?.trim();
      if (!embeddingModelId) {
        return {
          status: "not_configured",
          hint: "Set VOYAGE_SAGEMAKER_ENDPOINT or EMBEDDING_MODEL_ID to enable Atlas vector search.",
        };
      }
      embeddingSource = "bedrock";
      embedResult = await bedrockGenerateEmbedding(input.queryText, embeddingModelId);
    }

    if (
      typeof embedResult === "object" &&
      embedResult !== null &&
      "status" in embedResult &&
      (embedResult as Record<string, unknown>).status === "ok" &&
      Array.isArray((embedResult as Record<string, unknown>).embedding)
    ) {
      queryVector = (embedResult as { embedding: number[] }).embedding;
    } else {
      return { status: "error", hint: "Failed to generate query embedding.", detail: embedResult };
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    logger.error("[mongo-data] embedding generation failed", { error: msg });
    return { status: "error", hint: "Embedding generation failed.", error: msg };
  }

  const lim = input.limit ?? 5;

  const queryVectorPreview = {
    length: queryVector.length,
    head: queryVector.slice(0, 4),
    tail: queryVector.slice(-4),
  };

  if (isLambdaToolMode()) {
    try {
      const out = await invokeLambdaTool("mongodb_vector_search", {
        collection: input.collection,
        index: input.indexName,
        queryVector,
        path: "embedding",
        numCandidates: lim * 10,
        limit: lim,
        filter: input.filter,
      });
      if (out.status === "error" || out.status === "not_configured") return asJSON(out);
      const data = (out.data as Record<string, unknown> | undefined) ?? out;
      const docs = (data.documents as unknown[]) ?? [];
      const scores = docs
        .map((d) => (typeof d === "object" && d !== null ? (d as { score?: unknown }).score : undefined))
        .filter((s): s is number => typeof s === "number");
      const { histogram, summary } = scoreHistogram(scores);
      trace?.event("mongo.vector_search", {
        embeddingSource,
        embeddingModelId,
        queryText: input.queryText,
        queryVectorPreview,
        numCandidates: lim * 10,
        limit: lim,
        filter: input.filter,
        scores,
        scoreSummary: summary,
        histogram,
      });
      return asJSON({
        status: "ok",
        source: "atlas_vector_search",
        indexName: input.indexName,
        results: docs,
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logger.error("[mongo-data] lambda vector search failed", {
        collection: input.collection,
        indexName: input.indexName,
        error: msg,
      });
      return { status: "error", source: "atlas_vector_search", error: msg };
    }
  }

  const db = await getMongoDb();
  if (!db) {
    return {
      status: "not_configured",
      hint: "Set MONGODB_URI for MongoDB Atlas vector search.",
    };
  }

  const coll = db.collection(input.collection);

  try {
    const pipeline: Record<string, unknown>[] = [
      {
        $vectorSearch: {
          index: input.indexName,
          path: "embedding",
          queryVector,
          numCandidates: lim * 10,
          limit: lim,
          ...(input.filter && Object.keys(input.filter).length > 0 ? { filter: input.filter } : {}),
        },
      },
      {
        $project: {
          embedding: 0,
          _id: 0,
          score: { $meta: "vectorSearchScore" },
        },
      },
    ];

    const results = await coll.aggregate(pipeline).toArray();
    const scores = results
      .map((d) => (typeof d === "object" && d !== null ? (d as { score?: unknown }).score : undefined))
      .filter((s): s is number => typeof s === "number");
    const { histogram, summary } = scoreHistogram(scores);

    // Optional: recall-without-filter comparison when MONGO_TRACE_VECTOR_DEBUG=1 and filter present.
    let recallWithoutFilter: number | undefined;
    if (cfg.vectorDebug && input.filter && Object.keys(input.filter).length > 0) {
      try {
        const unfilteredPipeline = [
          {
            $vectorSearch: {
              index: input.indexName,
              path: "embedding",
              queryVector,
              numCandidates: lim * 10,
              limit: lim,
            },
          },
          { $project: { _id: 0, embedding: 0, score: { $meta: "vectorSearchScore" } } },
        ];
        const unfiltered = await coll.aggregate(unfilteredPipeline).toArray();
        recallWithoutFilter = unfiltered.length;
      } catch {
        /* recall comparison best-effort */
      }
    }

    trace?.event("mongo.vector_search", {
      embeddingSource,
      embeddingModelId,
      queryText: input.queryText,
      queryVectorPreview,
      numCandidates: lim * 10,
      limit: lim,
      filter: input.filter,
      scores,
      scoreSummary: summary,
      histogram,
      recallWithoutFilter,
    });

    return { status: "ok", source: "atlas_vector_search", indexName: input.indexName, results };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    logger.error("[mongo-data] Atlas vector search failed", {
      collection: input.collection,
      indexName: input.indexName,
      error: msg,
    });
    return { status: "error", source: "atlas_vector_search", error: msg };
  }
}
