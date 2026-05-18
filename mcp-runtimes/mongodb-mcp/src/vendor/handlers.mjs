// MongoDB tool implementations — canonical home for the MongoDB MCP tools.
// Consumed by the AgentCore-Runtime-hosted MCP server
// (`mcp-runtimes/mongodb-mcp/src/server.ts`). The legacy Lambda host
// (`lambda/mongodb-mcp/`) has been deleted in CLIENT_REVIEW Phase 7e — the
// `parseEvent` matrix and host envelope helpers in this file are kept so a
// future host (Lambda rollback, alternative runtime, etc.) can re-import the
// `tools` object and dispatch with `(args, trace)`. Each host is still
// responsible for:
//   - building the per-call `trace` collector (createLambdaTrace())
//   - shaping the host-specific response envelope
//   - PII-safe logging of the inbound event
//
// Keep this file pure ESM (no TypeScript syntax) so any future host can import
// it as-is with no build step (the MCP runtime container's TypeScript build
// only compiles `server.ts` / `index.ts` and copies `vendor/` through).

import { MongoClient } from "mongodb";

import {
  MongoGuardError,
  parseBoolEnv,
  parseMaxLimit,
  validateMongoQueryInputs,
  assertCollection,
  assertNoDatabaseOverride,
  assertSafeFilter,
  assertSafePipeline,
  clampLimit,
} from "./guards.mjs";
import {
  diagnosticConfig,
  normalizeFilter,
  sampleSchema,
  buildSchemaSummary,
  runExplain,
  runEmptyResultDiagnostic,
} from "./diagnostics.mjs";

const URI = process.env.MONGODB_URI;
const DEFAULT_DB = process.env.MONGODB_DB || "bedrock_agents";
const ALLOW_WRITE = parseBoolEnv(process.env.MONGODB_ALLOW_WRITE);
const MAX_LIMIT = parseMaxLimit(process.env.MONGODB_MAX_LIMIT);

if (!URI) {
  console.error("MONGODB_URI not set — handler will fail on first invocation");
}

// ──────────────────────────────────────────────────────────────────────────────
// PII redaction for CloudWatch logs (P0-4)
//
// Tool args can carry PII (filter terms, document bodies, query vectors,
// customer emails embedded in `filter.email`, etc.). Anything that lands in
// CloudWatch is also visible to anyone with `logs:GetLogEvents` on the log
// group. We strip the high-risk fields before logging and replace them with a
// small summary so operators still know the call shape.
//
// Operators can opt back in to verbose logging *for one host* via
// MCP_LOG_RAW_ARGS=true if they need to debug a tricky tool call. Default is
// off; the deploy script never sets it.
// ──────────────────────────────────────────────────────────────────────────────
const REDACT_RAW_ARGS = process.env.MCP_LOG_RAW_ARGS !== "true";

const PII_ARG_KEYS = new Set([
  "filter",
  "query",
  "document",
  "documents",
  "update",
  "queryVector",
  "pipeline",
  "projection",
  "sort",
]);

function summariseValue(v) {
  if (v == null) return null;
  if (Array.isArray(v)) return `[array len=${v.length}]`;
  const t = typeof v;
  if (t === "string") return `[string len=${v.length}]`;
  if (t === "number" || t === "boolean") return `[${t}]`;
  if (t === "object") return `[object keys=${Object.keys(v).length}]`;
  return `[${t}]`;
}

export function redactArgsForLog(args) {
  if (!args || typeof args !== "object") return args;
  if (!REDACT_RAW_ARGS) return args;
  const out = {};
  for (const [k, v] of Object.entries(args)) {
    out[k] = PII_ARG_KEYS.has(k) ? summariseValue(v) : v;
  }
  return out;
}

export function redactEventForLog(event) {
  if (!event || typeof event !== "object") return event;
  if (!REDACT_RAW_ARGS) return event;
  const shallow = { ...event };
  for (const k of ["toolArguments", "arguments", "parameters", "input", "args"]) {
    if (shallow[k] && typeof shallow[k] === "object") shallow[k] = redactArgsForLog(shallow[k]);
  }
  if (shallow.body) {
    try {
      const body = typeof shallow.body === "string" ? JSON.parse(shallow.body) : shallow.body;
      if (body && body.params && body.params.arguments) {
        body.params = { ...body.params, arguments: redactArgsForLog(body.params.arguments) };
      }
      shallow.body = body;
    } catch {
      // body wasn't JSON; leave it alone
    }
  }
  return shallow;
}

export function redactErrorForLog(err) {
  if (!err) return err;
  const message = err instanceof Error ? err.message : String(err);
  const truncated = message.length > 500 ? `${message.slice(0, 500)}…` : message;
  return { name: err && err.name, code: err && err.code, message: truncated };
}

// ──────────────────────────────────────────────────────────────────────────────
// Mongo client — pooled across invocations on both hosts.
// On Lambda this gives warm-start reuse; on the AgentCore Runtime container
// this gives per-microVM reuse for the lifetime of the container.
// ──────────────────────────────────────────────────────────────────────────────
let clientPromise = null;
function getClient() {
  if (!clientPromise) {
    clientPromise = MongoClient.connect(URI, {
      serverSelectionTimeoutMS: 8000,
      maxPoolSize: 5,
    }).catch((err) => {
      clientPromise = null;
      throw err;
    });
  }
  return clientPromise;
}

// ──────────────────────────────────────────────────────────────────────────────
// Event parsing — handles multiple invocation shapes (AgentCore Gateway
// `clientContext.custom`, MCP-style `body.params`, direct invoke `toolName /
// arguments`, etc.). Retained for any future Lambda-style host that re-uses
// this module; the active MCP runtime host does NOT call this — it gets
// `(toolName, args)` directly from the MCP protocol layer.
// ──────────────────────────────────────────────────────────────────────────────
export const GATEWAY_TARGET_PREFIX = "mongodb-mcp___";

export function parseEvent(event, context) {
  // AgentCore Gateway → Lambda: tool name on `context.clientContext.custom`,
  // args as the event body. Direct lambda:Invoke (legacy / debug) carries
  // `toolName` on the event itself or an MCP-style `body.method == "tools/call"`.
  const custom =
    context?.clientContext?.custom ?? context?.clientContext?.Custom;
  const gwName = custom?.bedrockAgentCoreToolName;
  if (typeof gwName === "string" && gwName.length > 0) {
    const tool = gwName.startsWith(GATEWAY_TARGET_PREFIX)
      ? gwName.slice(GATEWAY_TARGET_PREFIX.length)
      : gwName;
    return { tool, args: (event && typeof event === "object" ? event : {}) };
  }
  if (event && event.toolName) {
    return { tool: event.toolName, args: event.toolArguments || event.arguments || {} };
  }
  if (event && event.tool_name) {
    return { tool: event.tool_name, args: event.parameters || event.input || {} };
  }
  if (event && event.body) {
    try {
      const body = typeof event.body === "string" ? JSON.parse(event.body) : event.body;
      if (body.method === "tools/call" && body.params) {
        return { tool: body.params.name, args: body.params.arguments || {} };
      }
    } catch {
      // fall through
    }
  }
  if (event && event.tool) {
    return { tool: event.tool, args: event.args || {} };
  }
  throw new Error(
    `Unrecognized event shape: ${JSON.stringify(redactEventForLog(event)).slice(0, 200)}`,
  );
}

// ──────────────────────────────────────────────────────────────────────────────
// Tool implementations
// ──────────────────────────────────────────────────────────────────────────────

async function mongodb_query(rawArgs, trace) {
  const input = validateMongoQueryInputs(rawArgs, {
    allowWrite: ALLOW_WRITE,
    defaultDb: DEFAULT_DB,
    maxLimit: MAX_LIMIT,
    defaultFindLimit: 10,
  });

  const cfg = diagnosticConfig();

  trace.event("mongo.intent", { collection: input.collection });
  trace.event("mongo.query", {
    mode: "lambda",
    collection: input.collection,
    op: input.operation,
    filter: input.filter,
    normalizedFilter: normalizeFilter(input.filter),
    projection: input.projection,
    sort: input.sort,
    limit: input.limit,
    pipeline: input.pipeline,
  });

  const client = await getClient();
  const coll = client.db(DEFAULT_DB).collection(input.collection);
  const projOpt = input.projection ? { projection: input.projection } : undefined;
  const t0 = Date.now();

  let schemaSample = null;
  if (cfg.schemaEnabled && (input.operation === "find" || input.operation === "findOne" || input.operation === "aggregate")) {
    const { sample, estimatedCount } = await sampleSchema(coll, cfg.perProbeMs);
    schemaSample = sample;
    trace.event("mongo.schema", buildSchemaSummary(input.collection, sample, estimatedCount));
  }

  let result;
  try {
    switch (input.operation) {
      case "find": {
        let cursor = coll.find(input.filter, projOpt);
        if (input.sort) cursor = cursor.sort(input.sort);
        const docs = await cursor.limit(input.limit).toArray();
        result = { operation: "find", count: docs.length, documents: docs };
        trace.event("mongo.result", {
          docCount: docs.length,
          latencyMs: Date.now() - t0,
          status: docs.length === 0 ? "empty" : "ok",
          sampleDocs: docs.slice(0, 3),
        });
        if (docs.length === 0 && cfg.diagnosticEnabled) {
          const diag = await runEmptyResultDiagnostic({
            collection: input.collection,
            filter: input.filter,
            resultCount: 0,
            sampleDoc: schemaSample,
            coll,
          });
          trace.event("mongo.diagnostic", diag);
        }
        if (cfg.explainEnabled) {
          const plan = await runExplain(coll, input.filter);
          if (plan) trace.event("mongo.plan", plan);
        }
        break;
      }
      case "findOne": {
        let cursor = coll.find(input.filter, projOpt);
        if (input.sort) cursor = cursor.sort(input.sort);
        const doc = await cursor.limit(1).next();
        result = { operation: "findOne", count: doc ? 1 : 0, documents: doc ? [doc] : [] };
        trace.event("mongo.result", {
          docCount: doc ? 1 : 0,
          latencyMs: Date.now() - t0,
          status: doc ? "ok" : "empty",
          sampleDocs: doc ? [doc] : [],
        });
        if (!doc && cfg.diagnosticEnabled) {
          const diag = await runEmptyResultDiagnostic({
            collection: input.collection,
            filter: input.filter,
            resultCount: 0,
            sampleDoc: schemaSample,
            coll,
          });
          trace.event("mongo.diagnostic", diag);
        }
        break;
      }
      case "aggregate": {
        const docs = await coll.aggregate(input.pipeline).toArray();
        const sliced = docs.slice(0, input.limit);
        result = { operation: "aggregate", count: sliced.length, documents: sliced };
        trace.event("mongo.result", {
          docCount: sliced.length,
          latencyMs: Date.now() - t0,
          status: sliced.length === 0 ? "empty" : "ok",
          sampleDocs: sliced.slice(0, 3),
        });
        break;
      }
      case "insertOne": {
        const res = await coll.insertOne({ ...input.document, createdAt: new Date() });
        result = { operation: "insertOne", insertedId: String(res.insertedId) };
        trace.event("mongo.result", {
          docCount: 1,
          latencyMs: Date.now() - t0,
          status: "ok",
        });
        break;
      }
      case "updateOne": {
        const res = await coll.updateOne(input.filter, { $set: input.update });
        result = {
          operation: "updateOne",
          matchedCount: res.matchedCount,
          modifiedCount: res.modifiedCount,
        };
        trace.event("mongo.result", {
          docCount: res.modifiedCount,
          latencyMs: Date.now() - t0,
          status: "ok",
        });
        break;
      }
      default:
        // Unreachable — validateMongoQueryInputs would have thrown.
        throw new MongoGuardError(`unsupported operation '${input.operation}'`, "unsupported_operation");
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const errClass = err instanceof Error ? err.constructor.name : "Error";
    trace.event("mongo.result", {
      docCount: 0,
      latencyMs: Date.now() - t0,
      status: "error",
      errorClass: errClass,
      errorMessage: msg,
    });
    throw err;
  }

  return result;
}

/**
 * Default kNN candidate width for `$vectorSearch`. Atlas guidance says
 * `numCandidates >= 10 * limit`; with limit=5 the prior default of 100 only
 * gave us 20x headroom and was a real source of recall drops on collections
 * with skewed embedding distributions (e.g. cluster boundaries between
 * troubleshooting categories). Bumped to 200 so the default top-5 sits at
 * 40× headroom — still well inside the 1000 cap and within Atlas's M30
 * latency budget.
 */
const DEFAULT_NUM_CANDIDATES = 200;
const MAX_NUM_CANDIDATES = 1000;

async function mongodb_vector_search(args, trace) {
  const {
    collection,
    index,
    queryVector,
    path = "embedding",
    numCandidates = DEFAULT_NUM_CANDIDATES,
    limit,
    filter,
    database,
    minScore,
  } = args || {};

  assertCollection(collection);
  assertNoDatabaseOverride(database, DEFAULT_DB);
  if (!index || typeof index !== "string") {
    throw new MongoGuardError("mongodb_vector_search: 'index' is required", "invalid_index");
  }
  if (!Array.isArray(queryVector) || queryVector.length === 0) {
    throw new MongoGuardError(
      "mongodb_vector_search: 'queryVector' must be a non-empty array",
      "invalid_vector",
    );
  }
  assertSafeFilter(filter, "filter");

  const lim = clampLimit(limit, 5, MAX_LIMIT);
  const cand =
    Number.isFinite(numCandidates) && numCandidates > 0
      ? Math.min(Math.floor(numCandidates), MAX_NUM_CANDIDATES)
      : DEFAULT_NUM_CANDIDATES;
  const minScoreNum =
    Number.isFinite(minScore) && minScore > 0 ? Number(minScore) : undefined;

  const client = await getClient();
  const db = client.db(DEFAULT_DB);
  const t0 = Date.now();
  trace.event("mongo.intent", { collection });

  const vectorStage = {
    $vectorSearch: {
      index,
      path,
      queryVector,
      numCandidates: cand,
      limit: lim,
      ...(filter ? { filter } : {}),
    },
  };

  const pipeline = [vectorStage, { $addFields: { _score: { $meta: "vectorSearchScore" } } }];
  if (minScoreNum !== undefined) {
    pipeline.push({ $match: { _score: { $gte: minScoreNum } } });
  }

  const docs = await db.collection(collection).aggregate(pipeline).toArray();

  trace.event("mongo.result", {
    docCount: docs.length,
    latencyMs: Date.now() - t0,
    status: docs.length === 0 ? "empty" : "ok",
    sampleDocs: docs.slice(0, 3),
  });

  return { count: docs.length, documents: docs };
}

// ──────────────────────────────────────────────────────────────────────────────
// mongodb_hybrid_search — vector + lexical fusion with Reciprocal Rank Fusion
//
// Used by the API-side `VectorSearchEmbedTool` wrapper when the caller (or the
// agent persona) opts into hybrid mode via `hybrid: true`. The wrapper still
// goes through the Mongo MCP runtime so the boundary rule ("chat-invoked Mongo
// tools must execute through the MCP runtime") is preserved. This handler is
// NOT advertised in the agent-visible tool list — it is a runtime helper only.
//
// Inputs:
//   collection         string (required)
//   queryText          string (required, used for the lexical leg)
//   queryVector        number[] (required, used for the vector leg)
//   vectorIndex        string (required)
//   lexicalIndex       string (required)
//   lexicalPath        string (required) — text-indexed field for $search
//   path               string (default "embedding")
//   filter             object — optional; rendered into $vectorSearch.filter
//                              AND into the compound.filter clauses of $search
//   limit              integer (default 5)
//   fetchK             integer (default 32) — per-leg over-fetch before merge
//   numCandidates      integer (default DEFAULT_NUM_CANDIDATES)
//   minScore           number  — drop merged items below this rrfScore
//
// Returns:
//   { count, documents: [{ ... , _score, _sources: ["vector"|"lexical", ...] }] }
//
// Each document carries the merged RRF score and the list of legs it appeared
// in. The API-side wrapper extracts these to build its `mongo.vector_search`
// trace event.
// ──────────────────────────────────────────────────────────────────────────────

const HYBRID_RRF_K = 60;

async function mongodb_hybrid_search(args, trace) {
  const {
    collection,
    queryText,
    queryVector,
    vectorIndex,
    lexicalIndex,
    lexicalPath,
    path = "embedding",
    filter,
    limit,
    fetchK,
    numCandidates,
    minScore,
    database,
  } = args || {};

  assertCollection(collection);
  assertNoDatabaseOverride(database, DEFAULT_DB);
  if (!vectorIndex || typeof vectorIndex !== "string") {
    throw new MongoGuardError("mongodb_hybrid_search: 'vectorIndex' is required", "invalid_index");
  }
  if (!lexicalIndex || typeof lexicalIndex !== "string") {
    throw new MongoGuardError("mongodb_hybrid_search: 'lexicalIndex' is required", "invalid_index");
  }
  if (!lexicalPath || typeof lexicalPath !== "string") {
    throw new MongoGuardError("mongodb_hybrid_search: 'lexicalPath' is required", "invalid_path");
  }
  if (!Array.isArray(queryVector) || queryVector.length === 0) {
    throw new MongoGuardError(
      "mongodb_hybrid_search: 'queryVector' must be a non-empty array",
      "invalid_vector",
    );
  }
  if (typeof queryText !== "string" || !queryText.trim()) {
    throw new MongoGuardError(
      "mongodb_hybrid_search: 'queryText' must be a non-empty string",
      "invalid_query",
    );
  }
  assertSafeFilter(filter, "filter");

  const lim = clampLimit(limit, 5, MAX_LIMIT);
  const fK = Number.isFinite(fetchK) && fetchK > 0 ? Math.min(Math.floor(fetchK), MAX_LIMIT) : 32;
  const cand =
    Number.isFinite(numCandidates) && numCandidates > 0
      ? Math.min(Math.floor(numCandidates), MAX_NUM_CANDIDATES)
      : Math.max(DEFAULT_NUM_CANDIDATES, fK * 10);
  const minScoreNum =
    Number.isFinite(minScore) && minScore > 0 ? Number(minScore) : undefined;

  const client = await getClient();
  const db = client.db(DEFAULT_DB);
  const t0 = Date.now();
  trace.event("mongo.intent", { collection });

  const vectorStage = {
    $vectorSearch: {
      index: vectorIndex,
      path,
      queryVector,
      numCandidates: cand,
      limit: fK,
      ...(filter ? { filter } : {}),
    },
  };
  const vectorPromise = db
    .collection(collection)
    .aggregate([vectorStage, { $addFields: { _score: { $meta: "vectorSearchScore" } } }])
    .toArray();

  const compound = { must: [{ text: { query: queryText, path: lexicalPath } }] };
  if (filter && typeof filter === "object") {
    const clauses = [];
    for (const [field, value] of Object.entries(filter)) {
      if (Array.isArray(value)) {
        clauses.push({ in: { path: field, value } });
        continue;
      }
      if (value && typeof value === "object" && Array.isArray(value.$in)) {
        clauses.push({ in: { path: field, value: value.$in } });
        continue;
      }
      clauses.push({ equals: { path: field, value } });
    }
    if (clauses.length > 0) compound.filter = clauses;
  }
  const lexicalPromise = db
    .collection(collection)
    .aggregate([
      { $search: { index: lexicalIndex, compound } },
      { $addFields: { _score: { $meta: "searchScore" } } },
      { $limit: fK },
    ])
    .toArray()
    .catch((err) => {
      // Lexical leg failure shouldn't kill hybrid — log via trace and return [].
      trace.event("mongo.diagnostic", {
        ranProbes: 0,
        budgetMs: 0,
        offendingClause: undefined,
        valueTypeWarnings: [],
        index_missing_suggested: lexicalIndex,
        schemaMismatch: false,
        hybridLegFailed: "lexical",
        errorMessage: err instanceof Error ? err.message : String(err),
      });
      return [];
    });

  const [vectorDocs, lexicalDocs] = await Promise.all([vectorPromise, lexicalPromise]);

  // RRF merge over the two ranked lists.
  const merged = new Map();
  const ingest = (docs, source) => {
    for (let i = 0; i < docs.length; i++) {
      const d = docs[i];
      const key = String(d._id);
      const contribution = 1 / (HYBRID_RRF_K + (i + 1));
      const existing = merged.get(key);
      if (existing) {
        existing._score += contribution;
        if (!existing._sources.includes(source)) existing._sources.push(source);
      } else {
        merged.set(key, { ...d, _score: contribution, _sources: [source] });
      }
    }
  };
  ingest(vectorDocs, "vector");
  ingest(lexicalDocs, "lexical");

  let fused = Array.from(merged.values()).sort((a, b) => b._score - a._score);
  if (minScoreNum !== undefined) {
    fused = fused.filter((d) => d._score >= minScoreNum);
  }
  fused = fused.slice(0, lim);

  trace.event("mongo.result", {
    docCount: fused.length,
    latencyMs: Date.now() - t0,
    status: fused.length === 0 ? "empty" : "ok",
    sampleDocs: fused.slice(0, 3),
    perStageReturned: [vectorDocs.length, lexicalDocs.length],
  });

  return {
    count: fused.length,
    documents: fused,
    meta: {
      vectorCount: vectorDocs.length,
      lexicalCount: lexicalDocs.length,
      rrfMergedCount: merged.size,
    },
  };
}

async function mongodb_aggregate(args, trace) {
  const { collection, pipeline, database, limit } = args || {};
  assertCollection(collection);
  assertNoDatabaseOverride(database, DEFAULT_DB);
  assertSafePipeline(pipeline);

  const client = await getClient();
  const t0 = Date.now();
  trace.event("mongo.intent", { collection });

  const docs = await client.db(DEFAULT_DB).collection(collection).aggregate(pipeline).toArray();
  const lim = clampLimit(limit, docs.length, MAX_LIMIT);
  const sliced = docs.slice(0, lim);

  trace.event("mongo.result", {
    docCount: sliced.length,
    latencyMs: Date.now() - t0,
    status: sliced.length === 0 ? "empty" : "ok",
    sampleDocs: sliced.slice(0, 3),
  });

  return { count: sliced.length, documents: sliced };
}

export const tools = {
  mongodb_query,
  mongodb_vector_search,
  mongodb_aggregate,
  mongodb_hybrid_search,
};

/**
 * Tool names that exist purely as MCP runtime helpers for API-side wrappers
 * (e.g. the `VectorSearchEmbedTool` hybrid path). They MUST be filtered out
 * before the MCP `tools/list` is shown to an agent — chat-invoked tools must
 * be model-callable by name from the agent persona, and these are not. The
 * API-side `wrapGatewayTool` enforces the same filter in case the runtime
 * advertises them.
 */
export const INTERNAL_ONLY_TOOL_NAMES = new Set(["mongodb_hybrid_search"]);

// ──────────────────────────────────────────────────────────────────────────────
// Tool schemas — published to the AgentCore Gateway as the MCP runtime's
// `tools/list` response. The gateway introspects the runtime on registration,
// so this object is the single source of truth for the schema the Strands
// agents see. (The legacy Lambda host previously also pinned an
// `inline_payload` copy in `agentcore-gateway/main.tf`; that variant is gone
// after Phase 7e — restore from git history if rolling back.)
// ──────────────────────────────────────────────────────────────────────────────
export const toolSchemas = [
  {
    name: "mongodb_query",
    description:
      "Find documents in a MongoDB collection. Supports find, findOne, aggregate, insertOne, updateOne (writes are gated by MONGODB_ALLOW_WRITE).",
    inputSchema: {
      type: "object",
      properties: {
        collection: { type: "string" },
        operation: {
          type: "string",
          enum: ["find", "findOne", "aggregate", "insertOne", "updateOne"],
        },
        filter: { type: "object" },
        projection: { type: "object" },
        sort: { type: "object" },
        limit: { type: "integer" },
        pipeline: { type: "array" },
        update: { type: "object" },
        document: { type: "object" },
      },
      required: ["collection"],
    },
  },
  {
    name: "mongodb_vector_search",
    description:
      "Run an Atlas $vectorSearch aggregation against the given collection + index using a pre-computed queryVector.",
    inputSchema: {
      type: "object",
      properties: {
        collection: { type: "string" },
        index: { type: "string" },
        queryVector: { type: "array", items: { type: "number" } },
        path: { type: "string" },
        numCandidates: { type: "integer" },
        limit: { type: "integer" },
        filter: { type: "object" },
        minScore: { type: "number" },
      },
      required: ["collection", "index", "queryVector"],
    },
  },
  {
    name: "mongodb_aggregate",
    description: "Run an arbitrary MongoDB aggregation pipeline.",
    inputSchema: {
      type: "object",
      properties: {
        collection: { type: "string" },
        pipeline: { type: "array" },
        limit: { type: "integer" },
      },
      required: ["collection", "pipeline"],
    },
  },
  {
    name: "mongodb_hybrid_search",
    description:
      "INTERNAL — API-side wrapper helper. Runs vector + lexical retrieval against an Atlas collection and fuses with Reciprocal Rank Fusion. Not exposed to agents directly; chat tools must call mongodb_vector_search (which will route to this handler when hybrid=true).",
    inputSchema: {
      type: "object",
      properties: {
        collection: { type: "string" },
        vectorIndex: { type: "string" },
        lexicalIndex: { type: "string" },
        lexicalPath: { type: "string" },
        queryText: { type: "string" },
        queryVector: { type: "array", items: { type: "number" } },
        path: { type: "string" },
        filter: { type: "object" },
        limit: { type: "integer" },
        fetchK: { type: "integer" },
        numCandidates: { type: "integer" },
        minScore: { type: "number" },
      },
      required: [
        "collection",
        "vectorIndex",
        "lexicalIndex",
        "lexicalPath",
        "queryText",
        "queryVector",
      ],
    },
  },
];
