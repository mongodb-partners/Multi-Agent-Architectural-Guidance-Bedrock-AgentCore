// Per-tool Zod input schemas for the MongoDB MCP runtime, extracted here
// so they can be imported by unit tests (api/tests/unit/mcp-meta-passthrough.test.ts)
// without dragging in the McpServer + handlers + Mongo driver from server.ts.
//
// MCP spec §2.4 reserves `_meta` on request params. The AgentCore Gateway
// proxies `tools/call` upstream with that field populated (correlation IDs,
// progress tokens, etc.) and AWS validates the forwarded arguments against
// our tool's `inputSchema`. Without `_meta` declared here, every
// gateway-routed call fails with:
//   `ValidationException - property '_meta' is not defined in the schema
//    and the schema does not allow additional properties`
// leaving agents unable to query Mongo through the gateway. The
// `dispatch()` function in server.ts strips `_meta` before invoking the
// underlying handler so per-tool guard code never sees the envelope key.
//
// Any new MCP runtime added to the gateway MUST apply the same passthrough
// on every tool's input schema — see docs/status/debugging.md "MongoDB MCP server
// schemas must allow MCP-spec `_meta` passthrough".

import { z } from "zod";

export const META_PASSTHROUGH = { _meta: z.record(z.string(), z.unknown()).optional() };

export const mongodbQueryInputSchema = {
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
  ...META_PASSTHROUGH,
};

export const mongodbVectorSearchInputSchema = {
  collection: z.string(),
  index: z.string(),
  queryVector: z.array(z.number()),
  path: z.string().optional(),
  numCandidates: z.number().int().optional(),
  limit: z.number().int().optional(),
  filter: z.record(z.string(), z.unknown()).optional(),
  minScore: z.number().optional(),
  ...META_PASSTHROUGH,
};

export const mongodbAggregateInputSchema = {
  collection: z.string(),
  pipeline: z.array(z.record(z.string(), z.unknown())),
  limit: z.number().int().optional(),
  ...META_PASSTHROUGH,
};

/**
 * Schema for the runtime-internal `mongodb_hybrid_search` helper. This tool
 * is NOT advertised to agents (the API-side `wrapGatewayTool` filters it
 * out of `tools/list`); it is invoked exclusively by `VectorSearchEmbedTool`
 * when the wrapper opts into hybrid mode. The fusion logic lives in
 * `vendor/handlers.mjs` so any future host (Lambda rollback, etc.) inherits
 * the same semantics for free.
 */
export const mongodbHybridSearchInputSchema = {
  collection: z.string(),
  vectorIndex: z.string(),
  lexicalIndex: z.string(),
  lexicalPath: z.string(),
  queryText: z.string(),
  queryVector: z.array(z.number()),
  path: z.string().optional(),
  filter: z.record(z.string(), z.unknown()).optional(),
  limit: z.number().int().optional(),
  fetchK: z.number().int().optional(),
  numCandidates: z.number().int().optional(),
  minScore: z.number().optional(),
  ...META_PASSTHROUGH,
};

/** Map of tool name → its full input-schema record. Used by tests that want
 *  to assert every advertised tool accepts the `_meta` passthrough field. */
export const ALL_TOOL_INPUT_SCHEMAS = {
  mongodb_query:          mongodbQueryInputSchema,
  mongodb_vector_search:  mongodbVectorSearchInputSchema,
  mongodb_aggregate:      mongodbAggregateInputSchema,
  mongodb_hybrid_search:  mongodbHybridSearchInputSchema,
} as const;
