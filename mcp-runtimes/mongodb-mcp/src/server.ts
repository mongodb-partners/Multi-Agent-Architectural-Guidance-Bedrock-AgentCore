// MCP server factory for the MongoDB tool host.
//
// Wraps the `tools` object exported from `./vendor/handlers.mjs` — the
// canonical home for the MongoDB MCP tool semantics after CLIENT_REVIEW
// Phase 7e (the legacy `lambda/mongodb-mcp/` host has been deleted; restore
// from git history if rolling back). Trace events
// (`mongo.intent`, `mongo.query`, `mongo.schema`, `mongo.plan`, `mongo.result`,
// `mongo.diagnostic`) keep their original shapes so the API-side wrapper in
// `api/src/adapters/mongodb-mcp-client.ts` can extract them unchanged.
//
// Response envelope contract (consumed by extractAndReplayMcpTraces):
//   - On success: content[0].text is `JSON.stringify({ result, meta: { traces } })`
//   - On error:   isError=true, content[0].text is `JSON.stringify({ error, code?, meta: { traces } })`

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

// Vendored handlers — bundled into the container under `dist/vendor/` at
// Docker build time (see Dockerfile). During local typecheck the .mjs files
// are auto-resolved via tsconfig allowJs.
import { tools, redactArgsForLog, redactErrorForLog } from "./vendor/handlers.mjs";
import { createLambdaTrace } from "./vendor/tracing.mjs";
import { MongoGuardError } from "./vendor/guards.mjs";
import { logger } from "./lib/logger.js";

type ToolFn = (args: Record<string, unknown>, trace: unknown) => Promise<unknown>;
type TraceCollector = {
  events: () => unknown[];
  dropped: () => number;
};

const toolMap = tools as Record<string, ToolFn>;

// Zod schemas mirror the JSON Schemas in `./vendor/handlers.mjs.toolSchemas`.
// Kept lenient on optional fields because the LLM occasionally leaves them
// out — the per-tool guards in `./vendor/guards.mjs` are the authoritative
// validation layer.
const mongodbQueryInputSchema = {
  collection: z.string(),
  operation: z
    .enum(["find", "findOne", "aggregate", "insertOne", "updateOne"])
    .optional(),
  filter: z.record(z.string(), z.unknown()).optional(),
  projection: z.record(z.string(), z.unknown()).optional(),
  sort: z.record(z.string(), z.unknown()).optional(),
  limit: z.number().int().optional(),
  pipeline: z.array(z.record(z.string(), z.unknown())).optional(),
  update: z.record(z.string(), z.unknown()).optional(),
  document: z.record(z.string(), z.unknown()).optional(),
};

const mongodbVectorSearchInputSchema = {
  collection: z.string(),
  index: z.string(),
  queryVector: z.array(z.number()),
  path: z.string().optional(),
  numCandidates: z.number().int().optional(),
  limit: z.number().int().optional(),
  filter: z.record(z.string(), z.unknown()).optional(),
};

const mongodbAggregateInputSchema = {
  collection: z.string(),
  pipeline: z.array(z.record(z.string(), z.unknown())),
  limit: z.number().int().optional(),
};

function buildSuccess(result: unknown, trace: TraceCollector) {
  const meta: Record<string, unknown> = { traces: trace.events() };
  const dropped = trace.dropped();
  if (dropped > 0) meta.tracesDropped = dropped;
  return {
    content: [
      { type: "text" as const, text: JSON.stringify({ result, meta }) },
    ],
  };
}

function buildError(err: unknown, trace: TraceCollector) {
  const isGuard = err instanceof MongoGuardError;
  const meta: Record<string, unknown> = { traces: trace.events() };
  const dropped = trace.dropped();
  if (dropped > 0) meta.tracesDropped = dropped;
  const message = err instanceof Error ? err.message : String(err);
  const payload: Record<string, unknown> = { error: message, meta };
  if (isGuard && (err as { code?: string }).code) {
    payload.code = (err as { code: string }).code;
  }
  return {
    isError: true,
    content: [
      { type: "text" as const, text: JSON.stringify(payload) },
    ],
  };
}

async function dispatch(toolName: string, args: Record<string, unknown>) {
  logger.info("mongodb tool invocation", {
    toolName,
    argsPreview: JSON.stringify(redactArgsForLog(args)).slice(0, 500),
  });

  const fn = toolMap[toolName];
  const trace = createLambdaTrace() as TraceCollector;
  if (!fn) {
    return buildError(
      new Error(`Unknown tool '${toolName}'. Available: ${Object.keys(toolMap).join(", ")}`),
      trace,
    );
  }
  try {
    const result = await fn(args ?? {}, trace);
    return buildSuccess(result, trace);
  } catch (err) {
    const redactedErr = redactErrorForLog(err);
    logger.error("mongodb tool error", {
      toolName,
      message: `${redactedErr?.name || "Error"}: ${redactedErr?.message || String(err)}`,
    });
    return buildError(err, trace);
  }
}

export function mcpServerCreate(): McpServer {
  const server = new McpServer({
    name: "mongodb-mcp",
    version: "1.0.0",
  });

  server.registerTool(
    "mongodb_query",
    {
      title: "MongoDB query",
      description:
        "Find documents in a MongoDB collection. Supports find, findOne, aggregate, insertOne, updateOne (writes are gated by MONGODB_ALLOW_WRITE).",
      inputSchema: mongodbQueryInputSchema,
    },
    async (args) => dispatch("mongodb_query", args as Record<string, unknown>),
  );

  server.registerTool(
    "mongodb_vector_search",
    {
      title: "MongoDB vector search",
      description:
        "Run an Atlas $vectorSearch aggregation against the given collection + index using a pre-computed queryVector.",
      inputSchema: mongodbVectorSearchInputSchema,
    },
    async (args) => dispatch("mongodb_vector_search", args as Record<string, unknown>),
  );

  server.registerTool(
    "mongodb_aggregate",
    {
      title: "MongoDB aggregate",
      description: "Run an arbitrary MongoDB aggregation pipeline.",
      inputSchema: mongodbAggregateInputSchema,
    },
    async (args) => dispatch("mongodb_aggregate", args as Record<string, unknown>),
  );

  return server;
}
