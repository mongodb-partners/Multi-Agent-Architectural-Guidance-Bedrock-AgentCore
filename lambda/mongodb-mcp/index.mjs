// AgentCore Gateway Lambda target — MongoDB MCP tools.
//
// Invoked by AgentCore Gateway when an agent calls one of the registered tools.
// Event shape depends on AgentCore runtime; we defensively extract toolName/params
// from several possible keys so this also works if Lambda is invoked directly
// (SAM CLI, curl to Function URL, etc.).
//
// Tools exposed:
//   - mongodb_query         { collection, operation?, filter/query?, projection?, sort?, limit?, pipeline?, update?, document? }
//   - mongodb_vector_search { collection, index, queryVector, path?, numCandidates?, limit? }
//   - mongodb_aggregate     { collection, pipeline }
//
// SAFETY MODEL — implemented in ./guards.mjs, shared with
// api/src/adapters/mongo-data.ts so both code paths apply identical rules.
//
// OBSERVABILITY — each invocation builds a per-call trace collector
// (./tracing.mjs) and emits `mongo.intent`, `mongo.query`, `mongo.schema`,
// `mongo.plan`, `mongo.result`, `mongo.diagnostic` events. Those events ride
// back to the API embedded in the MCP `content` envelope; the wrapper in
// api/src/adapters/mongodb-mcp-client.ts extracts them and replays them into
// the per-turn trace so they appear in the Trace Viewer with the same shape
// as the in-process path. The agent-runtime's nested-trace splice
// (api/src/adapters/agentcore-runtime.ts → trace.attachEventsNested) carries
// them through to the parent Hono API trace.

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
import { createLambdaTrace } from "./tracing.mjs";
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

// Reuse the MongoClient across invocations (Lambda warm starts).
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
// Event parsing — handles multiple invocation shapes
// ──────────────────────────────────────────────────────────────────────────────
function parseEvent(event) {
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
  throw new Error(`Unrecognized event shape: ${JSON.stringify(event).slice(0, 200)}`);
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

async function mongodb_vector_search(args, trace) {
  const {
    collection,
    index,
    queryVector,
    path = "embedding",
    numCandidates = 100,
    limit,
    filter,
    database,
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
      ? Math.min(Math.floor(numCandidates), 1000)
      : 100;

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

  const docs = await db
    .collection(collection)
    .aggregate([vectorStage, { $addFields: { _score: { $meta: "vectorSearchScore" } } }])
    .toArray();

  trace.event("mongo.result", {
    docCount: docs.length,
    latencyMs: Date.now() - t0,
    status: docs.length === 0 ? "empty" : "ok",
    sampleDocs: docs.slice(0, 3),
  });

  return { count: docs.length, documents: docs };
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

const tools = { mongodb_query, mongodb_vector_search, mongodb_aggregate };

// ──────────────────────────────────────────────────────────────────────────────
// Handler
// ──────────────────────────────────────────────────────────────────────────────

/**
 * The response envelope is intentionally dual-purpose:
 *   - `content[0].text` carries `JSON.stringify({ result, meta: { traces } })`
 *     because that's the only field AgentCore Gateway forwards to MCP clients.
 *     The API-side wrapper parses this, extracts the traces, then rewrites the
 *     text to plain `JSON.stringify(result)` before the LLM sees it.
 *   - `data` + `meta` at the top level let direct LambdaClient.invoke() callers
 *     (api/src/adapters/mongo-data.ts → invokeLambdaTool) read traces without
 *     parsing the content text.
 */
function buildSuccessResponse(result, traces, droppedTraces) {
  const meta = { traces };
  if (droppedTraces > 0) meta.tracesDropped = droppedTraces;
  return {
    statusCode: 200,
    content: [{ type: "text", text: JSON.stringify({ result, meta }) }],
    data: result,
    meta,
  };
}

function buildErrorResponse(err, traces, droppedTraces) {
  const isGuard = err instanceof MongoGuardError;
  const meta = { traces };
  if (droppedTraces > 0) meta.tracesDropped = droppedTraces;
  return {
    statusCode: isGuard ? 400 : 500,
    isError: true,
    content: [
      {
        type: "text",
        text: JSON.stringify({
          error: err.message,
          ...(isGuard ? { code: err.code } : {}),
          meta,
        }),
      },
    ],
    error: err.message,
    ...(isGuard ? { code: err.code } : {}),
    meta,
  };
}

export const handler = async (event) => {
  console.log("invocation event:", JSON.stringify(event).slice(0, 500));

  const trace = createLambdaTrace();

  try {
    const { tool, args } = parseEvent(event);
    const fn = tools[tool];
    if (!fn) {
      throw new Error(`Unknown tool '${tool}'. Available: ${Object.keys(tools).join(", ")}`);
    }
    const result = await fn(args, trace);
    return buildSuccessResponse(result, trace.events(), trace.dropped());
  } catch (err) {
    console.error("handler error:", err);
    return buildErrorResponse(err, trace.events(), trace.dropped());
  }
};
