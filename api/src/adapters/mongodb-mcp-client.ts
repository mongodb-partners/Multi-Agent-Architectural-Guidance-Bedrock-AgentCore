/**
 * MongoDB MCP Client adapter.
 *
 * Connects to the MongoDB MCP tool host over StreamableHTTP and exposes its
 * tools as McpTool instances ready to attach to any specialist agent.
 *
 * Endpoint resolution (cascade):
 *   deployed runtimes: `AGENTCORE_GATEWAY_URL` only.
 *   local development: `MCP_SERVER_URL` is allowed only when ENVIRONMENT=local,
 *   NODE_ENV=development, or DEV_MOCK_BACKENDS=1.
 *
 * Missing Gateway configuration is fatal. Do not fall back to localhost; that
 * masks deploy/runtime env drift and makes tool failures look like MCP bugs.
 *
 * Outbound auth:
 *   Gateway mode reads the caller's JWT from `currentGatewayJwt()` and sets it
 *   as `Authorization: Bearer <jwt>`.
 *
 * The client is initialised lazily on first call and cached for the process
 * lifetime to avoid reconnect overhead on every agent invocation. On a 401
 * from `callTool`, the cached client is reset and the call is retried once
 * (covers cold-start handshakes that ran before a JWT was in scope).
 */

import {
  McpClient,
  TextBlock,
  Tool,
  ToolResultBlock,
  type JSONValue,
  type ToolContext,
  type ToolSpec,
  type ToolStreamGenerator,
} from "@strands-agents/sdk";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { logger } from "../lib/logger.ts";
import { appendTraceContextHeaders } from "../lib/otel.ts";
import { currentTrace } from "../lib/trace-context.ts";
import { currentGatewayJwt } from "../lib/gateway-auth-context.ts";
import { currentUserId } from "../lib/user-id-context.ts";
import { embedQueryText, previewVector, type EmbedResult } from "../lib/embed-query.ts";

// Derive the tool type from the SDK without relying on McpTool being re-exported.
// McpClient["listTools"] returns Promise<McpTool[]>; Awaited<...>[number] gives McpTool.
type McpTool = Awaited<ReturnType<McpClient["listTools"]>>[number];

/**
 * Strip the AgentCore Gateway target-name prefix from an MCP tool name.
 *
 * Background: when the AgentCore Gateway is configured with a Lambda target
 * named `mongodb-mcp`, every tool the target exposes is published as
 * `mongodb-mcp___<originalName>` (the gateway namespaces tools by target).
 * Our agent personas (`config/agents/*.agent.md`) and `SKILL.md` instructions
 * reference the unprefixed names (`mongodb_query`, `mongodb_vector_search`,
 * `mongodb_aggregate`) — that is the contract the LLM is trained against.
 *
 * Without aliasing, the model emits tool calls under the unprefixed name,
 * Strands cannot find a matching tool, and the call silently no-ops (no
 * `mcp.call`, no `tool.mcp` trace event, no error to the model). The visible
 * symptom is the model reasoning out loud about wanting to call
 * `mongodb_query` and then giving up.
 *
 * The prefix is fixed by the Terraform module
 * (`deploy/terraform/modules/agentcore-gateway/main.tf` →
 * `target_name = "mongodb-mcp"`), so the regex is hard-coded here. If the
 * target name ever changes, update both places together.
 */
// Exported for the `mongodb-mcp-tool-alias.test.ts` unit test.
export const GATEWAY_TARGET_PREFIX = "mongodb-mcp___";

export function stripGatewayTargetPrefix(name: string): string | undefined {
  return name.startsWith(GATEWAY_TARGET_PREFIX)
    ? name.slice(GATEWAY_TARGET_PREFIX.length)
    : undefined;
}

/**
 * Tool wrapper that exposes an `aliasName` to the agent / model but routes
 * every actual MCP call through the underlying `McpTool` (which still carries
 * the gateway-prefixed name needed by `McpClient.callTool` to address the
 * remote tool). The Strands `Agent` keys its tool registry by `name`, so the
 * model sees `mongodb_query` and the gateway sees `mongodb-mcp___mongodb_query`.
 *
 * Exported for the `mongodb-mcp-tool-alias.test.ts` unit test.
 */
export class AliasedMcpTool extends Tool {
  readonly name: string;
  readonly description: string;
  readonly toolSpec: ToolSpec;
  private readonly underlying: McpTool;

  constructor(aliasName: string, underlying: McpTool) {
    super();
    this.name = aliasName;
    this.description = underlying.description;
    this.toolSpec = {
      name: aliasName,
      description: underlying.description,
      inputSchema: underlying.toolSpec.inputSchema,
    };
    this.underlying = underlying;
  }

  stream(toolContext: ToolContext): ToolStreamGenerator {
    return this.underlying.stream(toolContext);
  }
}

// ---------------------------------------------------------------------------
// mongodb_vector_search wrapper — query-time embedding
//
// The MongoDB MCP Lambda (`lambda/mongodb-mcp/index.mjs`) only accepts a
// pre-computed `queryVector`, but the agent personas / SKILL.md instructions
// are written around the more useful `queryText` API: pass a natural-language
// query and let the platform do the embedding. Without a bridge in between,
// the model either hallucinates a vector or the call gets rejected by the
// Lambda's `invalid_vector` guard.
//
// `VectorSearchEmbedTool` is that bridge:
//
//   1. Advertise a model-friendly schema (queryText optional but preferred,
//      indexName accepted as an alias for index, sensible default `index`
//      inferred from collection name).
//   2. On invocation: extract `queryText`, run `embedQueryText()` (Voyage →
//      Bedrock fallback), splice the resulting vector into the args under
//      `queryVector`, and forward to the underlying `McpTool` so the existing
//      MCP / gateway / Lambda trace plumbing still fires.
//   3. Emit a `mongo.vector_search` trace event with the embedding source,
//      query text, vector preview, and (when the call succeeds) per-doc
//      similarity scores so the Trace Viewer's vector-search panel populates.
//   4. Surface embedding failures as a `status: "error"` tool result (rather
//      than a thrown exception) so the LLM sees a clean message and can
//      gracefully fall back to keyword search via `mongodb_query`.
// ---------------------------------------------------------------------------

/**
 * Default Atlas vector index per known seeded collection.
 *
 * The four entries here mirror `db-seeding/seed-indexes.ts`. Adding a new
 * vector-searchable collection requires:
 *
 *   1. Append the embedding field at write time (see e.g. `chat_messages` and
 *      `agent_memory_facts` write paths).
 *   2. Create the Atlas Vector Search index named `<collection>-vector-index`
 *      via `seed-indexes.ts`.
 *   3. Add an entry here so the API-side wrapper can default the `index`
 *      argument the model is not required to know.
 *   4. (Hybrid mode) add a matching `<collection>-text-index` Atlas Search
 *      index and an entry in `DEFAULT_LEXICAL_INDEX_BY_COLLECTION` below.
 */
const DEFAULT_VECTOR_INDEX_BY_COLLECTION: Record<string, string> = {
  products: "products-vector-index",
  troubleshooting_docs: "troubleshooting-vector-index",
  agent_memory_facts: "agent_memory_facts-vector-index",
  chat_messages: "chat_messages-vector-index",
};

/**
 * Default Atlas Search (BM25) index + indexed text path for hybrid mode. Used
 * when the model (or the wrapper itself, for internal callers) requests
 * `hybrid: true`. Each entry pairs the lexical index name with the document
 * field that the index covers — both must agree with `seed-indexes.ts`.
 */
const DEFAULT_LEXICAL_INDEX_BY_COLLECTION: Record<
  string,
  { index: string; path: string }
> = {
  products: { index: "products-text-index", path: "title" },
  troubleshooting_docs: { index: "troubleshooting-text-index", path: "title" },
  agent_memory_facts: { index: "agent_memory_facts-text-index", path: "fact" },
  chat_messages: { index: "chat_messages-text-index", path: "content" },
};

/**
 * Runtime-only MCP tools that the API-side wrapper invokes on behalf of an
 * agent-visible tool (e.g. the hybrid retrieval helper). They must be
 * filtered out of `tools/list` so the agent never sees them; the wrapper
 * reaches them through its own `McpClient` handle.
 */
const INTERNAL_ONLY_MCP_TOOL_NAMES = new Set(["mongodb_hybrid_search"]);

export function isInternalOnlyMcpTool(name: string): boolean {
  const stripped = stripGatewayTargetPrefix(name) ?? name;
  return INTERNAL_ONLY_MCP_TOOL_NAMES.has(stripped);
}

/**
 * Bytes the wrapper will record per `documents` sample / vector preview before
 * the trace collector's per-event byte cap kicks in. Kept conservative so
 * `mongo.vector_search` events fit alongside `mongo.result` for the same call.
 */
const MAX_TRACE_SCORES = 25;
const MAX_TRACE_DOCUMENT_PREVIEWS = 5;
const MAX_TRACE_DOC_FIELD_CHARS = 180;

/** Public-facing input schema for `mongodb_vector_search`. The McpTool's own
 *  schema (declared inline in `deploy/terraform/modules/agentcore-gateway/main.tf`
 *  for the Lambda target, or auto-derived from the MCP runtime's `tools/list`
 *  for the active `mcp_server` target) is replaced with this one in the model's
 *  tool list, so the LLM never sees the underlying `queryVector` requirement. */
export const VECTOR_SEARCH_TOOL_SPEC: ToolSpec = {
  name: "mongodb_vector_search",
  description:
    "Run an Atlas $vectorSearch on a MongoDB collection. Pass a natural-language `queryText` " +
    "and the embedding is computed server-side (Voyage AI primary, Bedrock fallback). " +
    "For known collections (`products`, `troubleshooting_docs`, `agent_memory_facts`, " +
    "`chat_messages`) the vector index is inferred from the collection name; pass `indexName` " +
    "to override. Set `hybrid: true` to fuse vector + Atlas Search BM25 results with " +
    "Reciprocal Rank Fusion for higher recall on rare keywords. Returns the matching " +
    "documents with a `_score` field per hit (RRF score in hybrid mode).",
  inputSchema: {
    type: "object",
    properties: {
      collection: {
        type: "string",
        description:
          "MongoDB collection name (e.g. `products`, `troubleshooting_docs`, `agent_memory_facts`, `chat_messages`).",
      },
      queryText: {
        type: "string",
        description:
          "Natural-language query. Embedded server-side using the configured embedding provider. " +
          "Prefer this over `queryVector`. Required for `hybrid: true`.",
      },
      indexName: {
        type: "string",
        description:
          "Optional Atlas vector index name. Defaults: products → products-vector-index, " +
          "troubleshooting_docs → troubleshooting-vector-index, " +
          "agent_memory_facts → agent_memory_facts-vector-index, " +
          "chat_messages → chat_messages-vector-index.",
      },
      limit: {
        type: "integer",
        description: "Max documents to return (default 5; clamped server-side).",
        minimum: 1,
        maximum: 50,
      },
      numCandidates: {
        type: "integer",
        description:
          "Number of nearest-neighbor candidates to consider before applying `limit` (default 200, max 1000).",
        minimum: 1,
        maximum: 1000,
      },
      filter: {
        type: "object",
        description:
          "Optional pre-filter. Each filtered field must be declared as a `filter` field in the vector index.",
      },
      path: {
        type: "string",
        description: "Document path to the embedding vector. Defaults to `embedding`.",
        default: "embedding",
      },
      queryVector: {
        type: "array",
        items: { type: "number" },
        description:
          "Pre-computed embedding. Advanced; usually omit and pass `queryText` instead.",
      },
      hybrid: {
        type: "boolean",
        description:
          "When true, fuse $vectorSearch (semantic) with an Atlas $search BM25 leg over the " +
          "collection's text-indexed field and merge with Reciprocal Rank Fusion. Lexical index " +
          "and path are inferred for known collections; pass `lexicalIndex` / `lexicalPath` to " +
          "override. Requires `queryText`.",
      },
      lexicalIndex: {
        type: "string",
        description:
          "Override the per-collection Atlas Search index used by the lexical leg in hybrid mode.",
      },
      lexicalPath: {
        type: "string",
        description:
          "Override the document field path searched by the lexical leg in hybrid mode.",
      },
      fetchK: {
        type: "integer",
        description:
          "Per-leg over-fetch before RRF merge in hybrid mode (default 32; clamped server-side).",
        minimum: 1,
        maximum: 100,
      },
      minScore: {
        type: "number",
        description:
          "Optional minimum score floor. In vector mode this filters by raw cosine score; in " +
          "hybrid mode it filters by the merged RRF score.",
      },
    },
    required: ["collection"],
  },
};

/** Result of `transformVectorSearchArgs`. Kept narrow so tests can pin shapes. */
export type VectorSearchTransform =
  | {
      ok: true;
      args: Record<string, JSONValue>;
      embed:
        | { source: "voyage" | "bedrock"; modelId: string }
        | { source: "model_supplied"; modelId: undefined };
      queryText: string;
      vectorPreview: { length: number; head: number[]; tail: number[] };
      /** Which MCP tool the wrapper should call: pure vector or hybrid fusion. */
      mode: "vector" | "hybrid";
      /** Tool name to invoke on the underlying MCP client (canonical, no gateway prefix). */
      targetToolName: "mongodb_vector_search" | "mongodb_hybrid_search";
    }
  | { ok: false; code: string; message: string; queryText: string };

/**
 * Pure args transformation: read whatever the model passed, normalise it into
 * the lambda's `{ collection, index, queryVector, ... }` shape, embedding
 * `queryText` along the way. Exported for unit tests.
 *
 * @param embed Injectable embedding function (defaults to `embedQueryText`).
 *              Tests pass a deterministic stub so we don't reach SageMaker.
 */
export async function transformVectorSearchArgs(
  raw: unknown,
  embed: (text: string) => Promise<EmbedResult> = embedQueryText,
): Promise<VectorSearchTransform> {
  const input = (isPlainObject(raw) ? raw : {}) as Record<string, JSONValue>;

  const collection = typeof input.collection === "string" ? input.collection.trim() : "";
  if (!collection) {
    return {
      ok: false,
      code: "missing_collection",
      message: "`collection` is required",
      queryText: extractText(input.queryText),
    };
  }

  const queryText = extractText(input.queryText);
  const suppliedVector = isNumberArray(input.queryVector)
    ? (input.queryVector as number[])
    : undefined;
  const wantHybrid = input.hybrid === true;

  // Resolve the vector index: explicit `index`, then `indexName`, then the
  // per-collection default. We deliberately fail loud if none of these
  // produce a value — the lambda would reject `invalid_index` otherwise and
  // the LLM-visible error would be less helpful.
  const explicitIndex =
    (typeof input.index === "string" && input.index.trim()) ||
    (typeof input.indexName === "string" && input.indexName.trim()) ||
    DEFAULT_VECTOR_INDEX_BY_COLLECTION[collection];
  if (!explicitIndex) {
    return {
      ok: false,
      code: "missing_index",
      message:
        `No vector index configured for collection '${collection}'. ` +
        "Pass `indexName` explicitly (e.g. 'products-vector-index').",
      queryText,
    };
  }

  // Resolve hybrid-mode-only inputs up front so we can reject early if the
  // collection has no companion text index. (Lexical leg has no fallback —
  // it just runs against the named index, which must exist in Atlas.)
  let lexicalIndex: string | undefined;
  let lexicalPath: string | undefined;
  if (wantHybrid) {
    const explicitLex =
      typeof input.lexicalIndex === "string" && input.lexicalIndex.trim()
        ? input.lexicalIndex.trim()
        : undefined;
    const explicitLexPath =
      typeof input.lexicalPath === "string" && input.lexicalPath.trim()
        ? input.lexicalPath.trim()
        : undefined;
    const defaults = DEFAULT_LEXICAL_INDEX_BY_COLLECTION[collection];
    lexicalIndex = explicitLex ?? defaults?.index;
    lexicalPath = explicitLexPath ?? defaults?.path;
    if (!lexicalIndex || !lexicalPath) {
      return {
        ok: false,
        code: "missing_lexical_index",
        message:
          `Hybrid mode requested but no Atlas Search index configured for '${collection}'. ` +
          "Pass `lexicalIndex` and `lexicalPath` explicitly, or set hybrid: false.",
        queryText,
      };
    }
  }

  // Build the Lambda-shaped args object up front so we always emit a stable
  // `index` / `path` regardless of what the model passed in.
  const path =
    typeof input.path === "string" && input.path.trim() ? input.path.trim() : "embedding";
  const args: Record<string, JSONValue> = wantHybrid
    ? {
        collection,
        vectorIndex: explicitIndex,
        lexicalIndex: lexicalIndex!,
        lexicalPath: lexicalPath!,
        path,
      }
    : {
        collection,
        index: explicitIndex,
        path,
      };
  if (typeof input.limit === "number" && Number.isFinite(input.limit)) {
    args.limit = Math.max(1, Math.floor(input.limit));
  }
  if (typeof input.numCandidates === "number" && Number.isFinite(input.numCandidates)) {
    args.numCandidates = Math.max(1, Math.floor(input.numCandidates));
  }
  if (wantHybrid && typeof input.fetchK === "number" && Number.isFinite(input.fetchK)) {
    args.fetchK = Math.max(1, Math.floor(input.fetchK));
  }
  if (typeof input.minScore === "number" && Number.isFinite(input.minScore)) {
    args.minScore = input.minScore as JSONValue;
  }
  if (isPlainObject(input.filter)) {
    args.filter = input.filter as JSONValue;
  }

  const targetToolName: VectorSearchTransform extends infer T
    ? T extends { targetToolName: infer N }
      ? N
      : never
    : never = wantHybrid ? "mongodb_hybrid_search" : "mongodb_vector_search";
  const mode = wantHybrid ? ("hybrid" as const) : ("vector" as const);

  // Vector resolution. Pure-vector mode: prefer model-supplied `queryVector`
  // (advanced path — useful for callers that already cached an embedding),
  // else embed `queryText`. Hybrid mode: needs both queryText (for the
  // lexical leg) AND queryVector — if the caller already has a vector, we
  // reuse it and skip the embed; otherwise we embed `queryText`.
  if (!wantHybrid && suppliedVector) {
    args.queryVector = suppliedVector as unknown as JSONValue;
    return {
      ok: true,
      args,
      embed: { source: "model_supplied", modelId: undefined },
      queryText: queryText || "(supplied as queryVector)",
      vectorPreview: previewVector(suppliedVector),
      mode,
      targetToolName,
    };
  }

  if (!queryText) {
    return {
      ok: false,
      code: "missing_query",
      message: wantHybrid
        ? "Hybrid mode requires `queryText` (used for the lexical leg). Example: { collection: 'products', queryText: 'waterproof outdoor headphones', hybrid: true }."
        : "Pass `queryText` (preferred) or `queryVector`. Example: { collection: 'products', queryText: 'waterproof outdoor headphones' }.",
      queryText: "",
    };
  }

  if (wantHybrid && suppliedVector) {
    args.queryText = queryText;
    args.queryVector = suppliedVector as unknown as JSONValue;
    return {
      ok: true,
      args,
      embed: { source: "model_supplied", modelId: undefined },
      queryText,
      vectorPreview: previewVector(suppliedVector),
      mode,
      targetToolName,
    };
  }

  const embedResult = await embed(queryText);
  if (!embedResult.ok) {
    return {
      ok: false,
      code: embedResult.code,
      message: embedResult.message,
      queryText,
    };
  }

  args.queryVector = embedResult.vector as unknown as JSONValue;
  if (wantHybrid) {
    args.queryText = queryText;
  }
  return {
    ok: true,
    args,
    embed: { source: embedResult.source, modelId: embedResult.modelId },
    queryText,
    vectorPreview: previewVector(embedResult.vector),
    mode,
    targetToolName,
  };
}

/**
 * Inspect the MCP tool result envelope and pull out per-doc similarity scores
 * so the trace event can render a histogram. The MongoDB MCP server's
 * `mongodb_vector_search` returns content[0].text === JSON.stringify({result:
 * {count, documents: [{ _score, ... }]}}). After
 * `extractAndReplayMcpTraces` rewrites the text we still have
 * `documents[i]._score` available; we never reach into the LLM-visible JSON
 * for anything else.
 *
 * Exported so the unit test can pin the score-extraction contract.
 */
function extractDocumentsFromResult(result: ToolResultBlock): unknown[] {
  const blocks = result.content ?? [];
  for (const block of blocks) {
    // We only inspect text blocks: the MCP runtime always responds with a
    // single text block carrying the JSON envelope, even for empty results.
    if (!block || !["text", "textBlock"].includes(String((block as { type?: string }).type ?? ""))) continue;
    const text = (block as { text?: unknown }).text;
    if (typeof text !== "string") continue;
    try {
      const parsed = JSON.parse(text) as { documents?: unknown[]; result?: { documents?: unknown[] } };
      if (Array.isArray(parsed.documents)) return parsed.documents;
      if (parsed.result && Array.isArray(parsed.result.documents)) return parsed.result.documents;
    } catch {
      // Not JSON — could be the unembed-friendly "Tool execution completed…"
      // fallback. Keep iterating in case a later block is parseable.
    }
  }
  return [];
}

function extractScoresFromDocuments(docs: unknown[]): number[] {
  const scores: number[] = [];
  for (const d of docs) {
    if (d && typeof d === "object" && typeof (d as { _score?: unknown })._score === "number") {
      scores.push((d as { _score: number })._score);
    }
  }
  return scores;
}

export function extractScoresFromResult(result: ToolResultBlock): number[] {
  return extractScoresFromDocuments(extractDocumentsFromResult(result));
}

/** Scores from MCP runtime trace events (`mongo.result.sampleDocs`). */
export function extractScoresFromMcpTraceEvents(
  traces: Array<{ type?: string; payload?: Record<string, unknown> } | null | undefined>,
): number[] {
  const scores: number[] = [];
  for (const ev of traces) {
    // Defensively skip null/undefined/non-object entries. AgentCore-forwarded
    // traces occasionally contain malformed envelope blocks (covered by the
    // "skips malformed trace event entries" integration test).
    if (!ev || typeof ev !== "object") continue;
    if (ev.type !== "mongo.result") continue;
    const sampleDocs = ev.payload?.sampleDocs;
    if (!Array.isArray(sampleDocs)) continue;
    scores.push(...extractScoresFromDocuments(sampleDocs));
  }
  return scores;
}

/**
 * When AgentCore forwards nested traces, `mongo.vector_search` is emitted by the
 * API wrapper after the MCP envelope is stripped — occasionally before scores
 * are re-parsed from the tool result. Backfill from sibling `mongo.result`
 * events (which carry `sampleDocs` with `_score` from the runtime).
 */
export function enrichVectorSearchTraceEvents<T extends { type: string; payload?: unknown }>(
  events: T[],
): T[] {
  const scoresByCollection = new Map<string, number[]>();
  let lastIntentCollection = "";
  for (const ev of events) {
    if (ev.type === "mongo.intent") {
      const coll = (ev.payload as { collection?: string } | undefined)?.collection;
      if (typeof coll === "string" && coll.trim()) lastIntentCollection = coll.trim();
      continue;
    }
    if (ev.type !== "mongo.result") continue;
    const payload = (ev.payload ?? {}) as { collection?: string; sampleDocs?: unknown[] };
    const coll =
      (typeof payload.collection === "string" && payload.collection.trim()) ||
      lastIntentCollection ||
      "";
    const scores = extractScoresFromDocuments(
      Array.isArray(payload.sampleDocs) ? payload.sampleDocs : [],
    );
    if (scores.length) scoresByCollection.set(coll, scores);
  }

  return events.map((ev) => {
    if (ev.type !== "mongo.vector_search") return ev;
    const payload = (ev.payload ?? {}) as {
      collection?: string;
      scores?: number[];
      scoreSummary?: { avg?: number };
    };
    const existing = Array.isArray(payload.scores) ? payload.scores : [];
    if (existing.length > 0 && payload.scoreSummary?.avg != null) return ev;
    const coll = typeof payload.collection === "string" ? payload.collection : "";
    const scores = (coll && scoresByCollection.get(coll)) || [];
    if (!scores.length) {
      const anyScores = [...scoresByCollection.values()].find((s) => s.length > 0);
      if (!anyScores?.length) return ev;
      return patchVectorSearchPayload(ev, anyScores);
    }
    return patchVectorSearchPayload(ev, scores);
  });
}

function patchVectorSearchPayload<T extends { type: string; payload?: unknown }>(
  ev: T,
  scores: number[],
): T {
  const payload = { ...(ev.payload as Record<string, unknown>) };
  payload.scores = scores.slice(0, MAX_TRACE_SCORES);
  payload.scoreSummary = summarizeScores(payload.scores as number[]);
  payload.histogram = scoreHistogram(payload.scores as number[]);
  return { ...ev, payload };
}

/** Set by `extractAndReplayMcpTraces` for the in-flight MCP tool call. */
let pendingMcpVectorScores: number[] | undefined;

export function takePendingMcpVectorScores(): number[] {
  const scores = pendingMcpVectorScores ?? [];
  pendingMcpVectorScores = undefined;
  return scores;
}

function previewString(value: unknown, max = MAX_TRACE_DOC_FIELD_CHARS): string | undefined {
  if (value === undefined || value === null) return undefined;
  const text = typeof value === "string" ? value : JSON.stringify(value);
  const trimmed = text.trim();
  if (!trimmed) return undefined;
  return trimmed.length > max ? `${trimmed.slice(0, max)}…` : trimmed;
}

function previewScalar(value: unknown): string | number | boolean | null | undefined {
  if (value === null) return null;
  if (["string", "number", "boolean"].includes(typeof value)) {
    if (typeof value === "string") return previewString(value);
    return value as number | boolean;
  }
  return previewString(value);
}

function stringList(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.map((v) => previewString(v, 80)).filter((v): v is string => !!v);
  }
  const single = previewString(value, 80);
  return single ? [single] : [];
}

function docId(doc: Record<string, unknown>): string | undefined {
  return previewString(doc._id ?? doc.id ?? doc.docId ?? doc.messageId ?? doc.sku, 120);
}

function mongoId(doc: Record<string, unknown>): string | undefined {
  return previewString(doc._id, 120);
}

function docTitle(doc: Record<string, unknown>): string | undefined {
  return previewString(doc.title ?? doc.name ?? doc.sku ?? doc.code ?? doc.fact ?? docId(doc), 120);
}

function docSourceUrl(doc: Record<string, unknown>): string | undefined {
  for (const field of ["sourceUrl", "url", "uri", "articleUrl"]) {
    const value = doc[field];
    if (typeof value === "string" && /^https?:\/\//i.test(value)) return value;
  }
  return undefined;
}

export function extractDocumentPreviewsFromResult(
  result: ToolResultBlock,
  collection?: string,
): Array<{
  rank: number;
  collection?: string;
  _id?: string;
  id?: string;
  score?: number;
  title?: string;
  snippet?: string;
  sourceUrl?: string;
  sources?: string[];
  fields?: Record<string, string | number | boolean | null>;
}> {
  const docs = extractDocumentsFromResult(result);
  const fieldNames = [
    "sku",
    "category",
    "brand",
    "status",
    "orderId",
    "customerEmail",
    "docId",
    "source",
    "sourceUrl",
    "url",
    "uri",
    "articleUrl",
    "role",
    "sessionId",
    "messageId",
  ];
  const snippetFields = ["content", "fact", "description", "summary", "body", "text", "answer"];

  return docs.slice(0, MAX_TRACE_DOCUMENT_PREVIEWS).flatMap((d, idx) => {
    if (!d || typeof d !== "object") return [];
    const doc = d as Record<string, unknown>;
    const fields: Record<string, string | number | boolean | null> = {};
    for (const name of fieldNames) {
      const value = previewScalar(doc[name]);
      if (value !== undefined) fields[name] = value;
    }
    const sources = [
      ...stringList(doc._sources),
      ...stringList(doc.source),
      ...stringList(doc.sourceUrl),
      ...stringList(doc.url),
      ...stringList(doc.uri),
      ...stringList(doc.articleUrl),
      ...stringList(doc.path),
    ].filter((v, i, arr) => arr.indexOf(v) === i);
    const snippet = snippetFields.map((name) => previewString(doc[name])).find(Boolean);
    return [
      {
        rank: idx + 1,
        collection,
        _id: mongoId(doc),
        id: docId(doc),
        score: typeof doc._score === "number" ? doc._score : undefined,
        title: docTitle(doc),
        snippet,
        sourceUrl: docSourceUrl(doc),
        sources: sources.length ? sources : undefined,
        fields: Object.keys(fields).length ? fields : undefined,
      },
    ];
  });
}

/** Compact summary of similarity scores for the trace UI. */
export function summarizeScores(scores: number[]):
  | undefined
  | { min: number; max: number; avg: number } {
  if (!scores.length) return undefined;
  let min = scores[0];
  let max = scores[0];
  let sum = 0;
  for (const s of scores) {
    if (s < min) min = s;
    if (s > max) max = s;
    sum += s;
  }
  return { min, max, avg: sum / scores.length };
}

/** Five-bucket histogram of scores in [0,1], for the dashboard's mini chart. */
export function scoreHistogram(scores: number[]): number[] {
  const bins = [0, 0, 0, 0, 0];
  for (const s of scores) {
    const b = Math.min(4, Math.max(0, Math.floor(s * 5)));
    bins[b] += 1;
  }
  return bins;
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

function isNumberArray(v: unknown): boolean {
  return (
    Array.isArray(v) &&
    v.length > 0 &&
    v.every((n) => typeof n === "number" && Number.isFinite(n))
  );
}

function extractText(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

/**
 * Tool wrapper for `mongodb_vector_search`. Replaces the raw MCP tool with
 * a queryText-friendly schema, embeds at call time, and emits the
 * `mongo.vector_search` trace event on success / failure.
 *
 * Constructed in `getMcpTools()` whenever the tool host exposes
 * `mongodb_vector_search` directly or through the Gateway's
 * `mongodb-mcp___mongodb_vector_search` namespace.
 *
 * When the model sets `hybrid: true`, the wrapper routes the rewritten args
 * through a second underlying `Tool` bound to the runtime's
 * `mongodb_hybrid_search` helper. That helper performs vector + lexical
 * Reciprocal Rank Fusion server-side and never appears in the agent-visible
 * tool list (filtered out in `loadMcpTools`).
 *
 * Boundary rule preserved: even hybrid retrieval routes through the Mongo
 * MCP runtime — the API never bypasses MCP for chat-invoked Mongo calls.
 *
 * Exported for the wrapper unit test.
 */
export class VectorSearchEmbedTool extends Tool {
  readonly name = "mongodb_vector_search";
  readonly description: string;
  readonly toolSpec: ToolSpec;
  private readonly vectorUnderlying: Tool;
  private readonly hybridUnderlying?: Tool;

  constructor(vectorUnderlying: Tool, hybridUnderlying?: Tool) {
    super();
    this.vectorUnderlying = vectorUnderlying;
    this.hybridUnderlying = hybridUnderlying;
    this.description = VECTOR_SEARCH_TOOL_SPEC.description;
    this.toolSpec = VECTOR_SEARCH_TOOL_SPEC;
  }

  async *stream(toolContext: ToolContext): ToolStreamGenerator {
    const trace = currentTrace();
    const toolUseId = toolContext.toolUse.toolUseId;
    const transform = await transformVectorSearchArgs(toolContext.toolUse.input);

    if (!transform.ok) {
      // Surface a structured tool result so the LLM can read the failure and
      // decide whether to retry, fall back to `mongodb_query`, or ask the
      // user to clarify. Do NOT throw — McpTool would catch and emit a
      // generic ToolError that hides the actual reason.
      trace?.event("mongo.vector_search", {
        embeddingSource: "none",
        queryText: transform.queryText,
        scores: [],
      });
      const body = JSON.stringify({
        status: "error",
        code: transform.code,
        message: transform.message,
      });
      return new ToolResultBlock({
        toolUseId,
        status: "error",
        content: [new TextBlock(body)],
      });
    }

    // Pick the underlying MCP tool based on the transform's mode. Hybrid mode
    // needs the runtime helper; if it is not exposed (older MCP runtime),
    // surface a clear error rather than silently downgrading.
    let underlying: Tool;
    if (transform.mode === "hybrid") {
      if (!this.hybridUnderlying) {
      trace?.event("mongo.vector_search", {
        collection: stringArg(transform.args.collection),
        embeddingSource: transform.embed.source,
        embeddingModelId: transform.embed.modelId,
        indexName: vectorIndexFromTransformArgs(transform.args),
        queryText: transform.queryText,
        queryVectorPreview: transform.vectorPreview,
        numCandidates: numericArg(transform.args.numCandidates),
        limit: numericArg(transform.args.limit),
        filter: transform.args.filter,
        scores: [],
      });
      return new ToolResultBlock({
        toolUseId,
        status: "error",
        content: [
          new TextBlock(
            JSON.stringify({
              status: "error",
              code: "hybrid_unsupported",
                message:
                  "Hybrid mode requires the mongodb_hybrid_search helper, which is not exposed by this MCP runtime. " +
                  "Retry with hybrid: false, or update the MongoDB MCP runtime.",
              }),
            ),
          ],
        });
      }
      underlying = this.hybridUnderlying;
    } else {
      underlying = this.vectorUnderlying;
    }

    // Forward the rewritten args to the underlying MCP tool. The McpClient
    // wrapper in `connectMcpClient` still emits `tool.mcp` and splices the
    // runtime's nested mongo.intent / mongo.result events into our trace, so
    // we only need to add the vector-specific event here.
    const innerCtx: ToolContext = {
      ...toolContext,
      toolUse: { ...toolContext.toolUse, input: transform.args as JSONValue },
    };

    const vsStart = Date.now();
    let result: ToolResultBlock;
    try {
      result = yield* underlying.stream(innerCtx);
    } catch (err) {
      // McpTool.stream() catches its own errors into createErrorResult, so we
      // shouldn't get here for normal failures. Defensive: still emit the
      // vector_search event so the trace doesn't lose context, then rethrow.
      trace?.event("mongo.vector_search", {
        collection: stringArg(transform.args.collection),
        embeddingSource: transform.embed.source,
        embeddingModelId: transform.embed.modelId,
        indexName: vectorIndexFromTransformArgs(transform.args),
        queryText: transform.queryText,
        queryVectorPreview: transform.vectorPreview,
        numCandidates: numericArg(transform.args.numCandidates),
        limit: numericArg(transform.args.limit),
        filter: transform.args.filter,
        scores: [],
        latencyMs: Date.now() - vsStart,
      });
      throw err;
    }

    let scores = extractScoresFromResult(result);
    if (!scores.length) scores = takePendingMcpVectorScores();
    scores = scores.slice(0, MAX_TRACE_SCORES);
    const collection = stringArg(transform.args.collection);
    trace?.event("mongo.vector_search", {
      collection,
      embeddingSource: transform.embed.source,
      embeddingModelId: transform.embed.modelId,
      indexName: vectorIndexFromTransformArgs(transform.args),
      queryText: transform.queryText,
      queryVectorPreview: transform.vectorPreview,
      numCandidates: numericArg(transform.args.numCandidates),
      limit: numericArg(transform.args.limit),
      filter: transform.args.filter,
      scores,
      scoreSummary: summarizeScores(scores),
      histogram: scoreHistogram(scores),
      hybrid: transform.mode === "hybrid",
      documentPreviews: extractDocumentPreviewsFromResult(result, collection),
      latencyMs: Date.now() - vsStart,
    });
    return result;
  }
}

function stringArg(v: JSONValue | undefined): string | undefined {
  return typeof v === "string" && v.trim() ? v.trim() : undefined;
}

function numericArg(v: JSONValue | undefined): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

/**
 * Surface the Atlas Vector Search / Atlas Search index name the wrapper
 * forwarded to the MCP runtime. The transform builds two shapes depending
 * on mode: `{ vectorIndex, lexicalIndex }` for hybrid, `{ index }` for pure
 * vector. The dev panel renders this as a chip so reviewers can confirm
 * the runtime is hitting the expected index (matches `db-seeding/seed-indexes.ts`).
 */
export function vectorIndexFromTransformArgs(args: Record<string, JSONValue | undefined>): string | undefined {
  return (
    stringArg(args.vectorIndex) ??
    stringArg(args.index) ??
    stringArg(args.indexName) ??
    undefined
  );
}

/**
 * Decide which Tool wrapper to use for a raw MCP tool.
 *
 *   - Gateway target prefix: `mongodb-mcp___mongodb_query` → `mongodb_query`.
 *   - Unprefixed local/dev MCP tools stay as-is.
 *   - `mongodb_vector_search` always gets the queryText embedding bridge,
 *     whether it arrived with or without a Gateway prefix. When the runtime
 *     also exposes `mongodb_hybrid_search`, the wrapper carries a second
 *     handle to that helper so `hybrid: true` calls route through MCP too.
 *
 * Exported so the test can verify the wrapping decision without a live MCP
 * connection. `hybridUnderlying` is optional so the test surface stays simple.
 */
export function wrapGatewayTool(raw: McpTool, hybridUnderlying?: Tool): Tool {
  const alias = stripGatewayTargetPrefix(raw.name);
  const exposedName = alias ?? raw.name;
  const exposed = alias ? new AliasedMcpTool(alias, raw) : raw;
  if (exposedName === "mongodb_vector_search") {
    return new VectorSearchEmbedTool(exposed, hybridUnderlying);
  }
  return exposed;
}

let _mcpClient: McpClient | null = null;
// Tools are exposed as `Tool[]` (the base class) because a subset is wrapped
// by `AliasedMcpTool` to strip the gateway target-name prefix; both subclasses
// satisfy `Tool` and that is the only thing Strands' `Agent` requires.
let _mcpTools: Tool[] | null = null;
let _mcpToolsPromise: Promise<Tool[]> | null = null;

type McpEndpoint = { mode: "gateway"; url: string };

function localMcpOverrideAllowed(): boolean {
  const environment = process.env.ENVIRONMENT?.trim().toLowerCase();
  const nodeEnv = process.env.NODE_ENV?.trim().toLowerCase();
  return (
    environment === "local" ||
    nodeEnv === "development" ||
    process.env.DEV_MOCK_BACKENDS === "1"
  );
}

function configuredMcpServerUrl(): string | undefined {
  const gatewayUrl = process.env.AGENTCORE_GATEWAY_URL?.trim();
  if (gatewayUrl) return gatewayUrl;

  const localOverride = process.env.MCP_SERVER_URL?.trim();
  if (localOverride && localMcpOverrideAllowed()) return localOverride;

  return undefined;
}

/**
 * Resolve the MCP endpoint. Production tool traffic always goes through the
 * AgentCore Gateway. The Gateway target then invokes the dedicated MongoDB MCP
 * AgentCore Runtime. We intentionally ignore MONGODB_MCP_RUNTIME_ARN here so a
 * runtime env var cannot silently bypass Gateway.
 */
function resolveMcpEndpoint(): McpEndpoint {
  const url = configuredMcpServerUrl();
  if (!url) {
    throw new Error(
      "AGENTCORE_GATEWAY_URL is required for MongoDB MCP tools; MCP_SERVER_URL is local-development only and localhost fallback is disabled.",
    );
  }
  return {
    mode: "gateway",
    url,
  };
}

function getMcpServerUrl(): string {
  return configuredMcpServerUrl() ?? "(missing AGENTCORE_GATEWAY_URL)";
}

/**
 * Custom fetch used by the StreamableHTTP transport. Reads the per-invocation
 * JWT from `currentGatewayJwt()` on every call so a single cached client can
 * serve many users without leaking auth across them. Falls back to the global
 * `fetch` with no auth header when no JWT is in scope (covers unauthenticated
 * local MCP servers).
 *
 * Exported only for integration testing
 * (`api/tests/integration/gateway-jwt-injection.integration.test.ts`).
 * Production code should not call this directly — it is wired into the
 * `StreamableHTTPClientTransport` constructor below.
 */
export const jwtInjectingFetch = (
  input: string | URL,
  init?: RequestInit,
): Promise<Response> => {
  const jwt = currentGatewayJwt();
  const headers = new Headers(init?.headers);
  if (jwt) {
    headers.set("Authorization", `Bearer ${jwt}`);
  }
  appendTraceContextHeaders(headers);
  return globalThis.fetch(input, { ...init, headers });
};

/**
 * Build the StreamableHTTP transport for the selected MongoDB MCP endpoint.
 * Gateway mode uses the caller JWT when one is in scope.
 */
function buildTransport() {
  const endpoint = resolveMcpEndpoint();
  logger.info("[mcp] using streamable-HTTP transport", {
    url: endpoint.url,
    mode: endpoint.mode,
  });
  return new StreamableHTTPClientTransport(new URL(endpoint.url), {
    fetch: jwtInjectingFetch,
  });
}

/** True when an error from `connect` / `callTool` / `listTools` looks like an auth failure. */
function isAuthError(err: unknown): boolean {
  const code = (err as { code?: unknown })?.code;
  if (code === 401 || code === 403) return true;
  const msg = (err instanceof Error ? err.message : String(err)).toLowerCase();
  return (
    msg.includes(" 401") ||
    msg.includes(" 403") ||
    msg.includes("unauthorized") ||
    msg.includes("forbidden") ||
    msg.includes("invalid token") ||
    msg.includes("expired")
  );
}

// ---------------------------------------------------------------------------
// userId / tenant predicate injection
//
// Every MongoDB MCP tool call is intercepted to inject `{ userId: jwt.sub }`
// into the filter (reads / updates / deletes) or document body (inserts) for
// non-public collections. This closes the design-level gap where the LLM
// could omit or misspecify the tenant predicate and accidentally read or write
// another user's data.
//
// "Public" collections — shared catalog / knowledge-base data that has no
// per-user ownership and must not be filtered by userId — are configured via
// the `MONGODB_PUBLIC_COLLECTIONS` env var (comma-separated, case-insensitive).
// Defaults: products, troubleshooting_docs.
// ---------------------------------------------------------------------------

function publicCollections(): Set<string> {
  const env = process.env.MONGODB_PUBLIC_COLLECTIONS?.trim();
  const raw = env
    ? env.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean)
    : ["products", "troubleshooting_docs"];
  return new Set(raw);
}

/** Tool names whose `filter` field should carry the userId predicate. */
const READ_FILTER_TOOLS = new Set([
  "mongodb_query",
  "mongodb_find",
  "mongodb_vector_search",
]);
/** Tool names whose `filter` field should carry the userId predicate (writes). */
const WRITE_FILTER_TOOLS = new Set([
  "mongodb_update_one",
  "mongodb_update_many",
  "mongodb_delete_one",
  "mongodb_delete_many",
  "mongodb_replace_one",
]);
/** Tool names whose `document`/`documents` field should carry the userId. */
const INSERT_TOOLS = new Set([
  "mongodb_insert_one",
  "mongodb_insert_many",
]);

/**
 * Inject the verified `userId` into the tool arguments before forwarding to
 * the MongoDB MCP runtime. This guarantees that even when the LLM omits or
 * incorrectly specifies the tenant predicate, every query is still bounded to
 * the current user's data.
 *
 * Strips the gateway-target prefix (`mongodb-mcp___`) from the tool name
 * before checking the known-tool sets.
 */
export function injectUserIdIntoArgs(
  toolName: string,
  args: unknown,
  userId: string,
): unknown {
  if (!isPlainObject(args)) return args;

  // Normalise away the gateway prefix for tool-name matching.
  const bare = toolName.startsWith(GATEWAY_TARGET_PREFIX)
    ? toolName.slice(GATEWAY_TARGET_PREFIX.length)
    : toolName;

  const collection =
    typeof (args as Record<string, unknown>).collection === "string"
      ? ((args as Record<string, unknown>).collection as string).toLowerCase()
      : "";

  // Public / shared collections are intentionally not user-scoped.
  if (collection && publicCollections().has(collection)) return args;

  const mutated = { ...args } as Record<string, unknown>;

  if (READ_FILTER_TOOLS.has(bare) || WRITE_FILTER_TOOLS.has(bare)) {
    const existing = isPlainObject(mutated.filter) ? mutated.filter : {};
    mutated.filter = { ...existing, userId };
  }

  if (INSERT_TOOLS.has(bare)) {
    if (isPlainObject(mutated.document)) {
      mutated.document = { ...(mutated.document as Record<string, unknown>), userId };
    }
    if (Array.isArray(mutated.documents)) {
      mutated.documents = (mutated.documents as unknown[]).map((d) =>
        isPlainObject(d) ? { ...(d as Record<string, unknown>), userId } : d,
      );
    }
  }

  // mongodb_aggregate: prepend a $match stage so the pipeline always starts
  // with a tenant predicate even if the LLM doesn't include one.
  if (bare === "mongodb_aggregate" && Array.isArray(mutated.pipeline)) {
    const firstStage = mutated.pipeline[0];
    const alreadyScoped =
      isPlainObject(firstStage) &&
      isPlainObject((firstStage as Record<string, unknown>)["$match"]) &&
      typeof ((firstStage as Record<string, unknown>)["$match"] as Record<string, unknown>).userId !== "undefined";
    if (!alreadyScoped) {
      mutated.pipeline = [{ $match: { userId } }, ...mutated.pipeline];
    }
  }

  return mutated;
}

/**
 * Build and connect an `McpClient` against the configured transport, then
 * wrap its `callTool` to:
 *  (a) inject the verified JWT `sub` (userId) into every query filter /
 *      document body for non-public collections — enforcing tenant isolation
 *      even when the LLM omits the predicate.
 *  (b) emit `tool.mcp` trace events per invocation.
 *  (c) splice nested trace events the Lambda MCP target packed into the
 *      response envelope (see `lambda/mongodb-mcp/index.mjs`).
 *
 * Connection is deferred until first use (rather than at module load) so the
 * `connect` handshake runs inside a `withGatewayJwt(...)` scope and the
 * initial request carries the user's JWT.
 */
async function connectMcpClient(): Promise<McpClient> {
  const client = new McpClient({ transport: buildTransport() });
  await client.connect();
  logger.info("[mcp] connected", { url: getMcpServerUrl() });

  const serverLabel = getMcpServerUrl();
  const originalCallTool = client.callTool.bind(client);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (client as { callTool: unknown }).callTool = async function wrappedCallTool(
    tool: { name: string },
    args: unknown,
  ) {
    const trace = currentTrace();

    // Inject the verified userId into the query/filter/document fields so
    // the database always enforces tenant isolation regardless of what the
    // LLM generated. currentUserId() reads from the AsyncLocalStorage scope
    // established by withCurrentUserId(userId, ...) in chat.ts.
    const uid = currentUserId();
    const scopedArgs = uid ? injectUserIdIntoArgs(tool.name, args, uid) : args;

    if (uid && scopedArgs !== args) {
      logger.debug("[mcp] userId predicate injected", {
        toolName: tool.name,
        userId: uid,
      });
    }

    logger.audit().info("[mcp] callTool", {
      toolName: tool.name,
      argPreview:
        typeof args === "object" && args !== null
          ? JSON.stringify(scopedArgs).slice(0, 400)
          : String(scopedArgs).slice(0, 400),
    });
    const mcpCallStart = Date.now();
    try {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const result = await originalCallTool(tool as any, scopedArgs as any);
      const mcpCallLatencyMs = Date.now() - mcpCallStart;
      // The MongoDB MCP runtime packs trace events into the content envelope;
      // extract them first and rewrite the LLM-visible text, then emit
      // tool.mcp with the cleaned result.
      const nestedDropped = extractAndReplayMcpTraces(result, trace, { mcpCallLatencyMs });
      trace?.event("tool.mcp", {
        server: serverLabel,
        toolName: tool.name,
        args: scopedArgs,
        result,
        latencyMs: mcpCallLatencyMs,
        ...(nestedDropped > 0 ? { nestedTracesDropped: nestedDropped } : {}),
      });
      return result;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      const errClass = err instanceof Error ? err.constructor.name : "Error";
      trace?.event("tool.mcp", {
        server: serverLabel,
        toolName: tool.name,
        args: scopedArgs,
        errorClass: errClass,
        errorMessage: errMsg,
      });
      if (isAuthError(err)) {
        // Token expired or rejected mid-conversation. Invalidate the singleton
        // so the next call (next user turn, which carries a fresh JWT) goes
        // through a new connect/listTools handshake with the new credentials.
        // The current call still surfaces the error to the chat — by design,
        // we don't retry inline because the same JWT would just 401 again.
        logger.warn("[mcp] callTool auth error — invalidating client cache", {
          toolName: tool.name,
        });
        _mcpClient = null;
        _mcpTools = null;
      }
      throw err;
    }
  };

  return client;
}

/** Get-or-create the singleton client. Resets the cache on auth failure and retries once. */
async function ensureMcpClient(): Promise<McpClient | null> {
  if (_mcpClient) return _mcpClient;
  try {
    _mcpClient = await connectMcpClient();
    return _mcpClient;
  } catch (err) {
    if (isAuthError(err)) {
      // Cold-start handshake without a JWT in scope; reset and let the next
      // call (presumably wrapped in withGatewayJwt) try again.
      logger.warn("[mcp] connect failed with auth error — will retry on next call", {
        error: err instanceof Error ? err.message : String(err),
      });
      _mcpClient = null;
      return null;
    }
    throw err;
  }
}

/**
 * Return the list of MCP tools exposed by the AgentCore Gateway. Cached for
 * the process lifetime once a successful `listTools` round-trip completes.
 *
 * On a 401/403 the client cache is discarded and the call is retried once;
 * this handles the case where the cached singleton's `connect` handshake
 * happened with no JWT (cold start) or with an expired token.
 */
/**
 * Decision helper: should `getMcpTools()` discard an in-flight singleton
 * result and start a fresh load? Pure function, exported for regression
 * tests around the prewarm-singleton-race pitfall
 * (docs/status/debugging.md "MongoDB MCP prewarm singleton race").
 *
 * Returns `true` only when both conditions hold:
 *   1. The in-flight load resolved to an empty tool list (typically the
 *      boot-time prewarm that connected before any JWT was in scope and
 *      was rejected by the gateway with `Missing Bearer token`).
 *   2. The current caller has a JWT in scope (so a fresh load has a
 *      reasonable chance of succeeding against the gateway authorizer).
 *
 * When either condition is false we return the in-flight result as-is:
 *   * non-empty result → real tools, ship them
 *   * empty result + no JWT → re-load would fail the same way, don't
 *     thrash the singleton
 */
export function shouldRetryDegradedMcpSingleton(
  inflightResult: Tool[],
  hasJwtInScope: boolean,
): boolean {
  return inflightResult.length === 0 && hasJwtInScope;
}

export async function getMcpTools(): Promise<Tool[]> {
  if (_mcpTools) return _mcpTools;
  if (_mcpToolsPromise) {
    const inflight = await _mcpToolsPromise;
    if (!shouldRetryDegradedMcpSingleton(inflight, Boolean(currentGatewayJwt()))) {
      return inflight;
    }
    // The in-flight load was a JWT-less degraded singleton (boot prewarm or
    // similar). The current caller has a JWT — start a fresh load so a
    // single bad boot connect doesn't lock the runtime into a degraded
    // template for the lifetime of the process.
  }

  _mcpToolsPromise = loadMcpTools();
  try {
    return await _mcpToolsPromise;
  } finally {
    _mcpToolsPromise = null;
  }
}

async function loadMcpTools(): Promise<Tool[]> {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const client = await ensureMcpClient();
      if (!client) {
        // ensureMcpClient swallowed an auth error and reset the cache.
        // Loop will retry; if the second attempt also fails the catch below
        // logs a warning and returns [].
        continue;
      }
      const rawTools = await client.listTools();
      // The runtime exposes `mongodb_hybrid_search` as a helper that the
      // wrapper invokes for `hybrid: true` calls. It must NOT appear in the
      // model's tool list — agents call `mongodb_vector_search` by name and
      // the wrapper routes hybrid mode behind the scenes. Build an aliased
      // handle to the hybrid helper first, then filter it out.
      const hybridRaw = rawTools.find(
        (t) => (stripGatewayTargetPrefix(t.name) ?? t.name) === "mongodb_hybrid_search",
      );
      const hybridAliased = hybridRaw
        ? stripGatewayTargetPrefix(hybridRaw.name)
          ? new AliasedMcpTool("mongodb_hybrid_search", hybridRaw)
          : (hybridRaw as Tool)
        : undefined;
      // Replace each gateway-prefixed tool with an alias bound to the unprefixed
      // name. Tools that don't carry the prefix (e.g. future targets, custom
      // gateway tools) pass through unchanged. `mongodb_vector_search` gets a
      // richer wrapper that re-specs the schema to accept `queryText` and
      // performs the embedding before forwarding to the gateway.
      _mcpTools = rawTools
        .filter((t) => !isInternalOnlyMcpTool(t.name))
        .map((t) => wrapGatewayTool(t, hybridAliased));
      logger.info("[mcp] loaded tools", {
        tools: _mcpTools.map((t) => t.name),
        gatewayNames: rawTools.map((t) => t.name),
        hybridHelperAvailable: Boolean(hybridAliased),
      });
      return _mcpTools;
    } catch (err) {
      const last = attempt === 1;
      if (!last) {
        logger.warn("[mcp] listTools failed — resetting client and retrying once", {
          error: err instanceof Error ? err.message : String(err),
        });
        _mcpClient = null;
        continue;
      }
      logger.warn("[mcp] failed to load tools — agents will run without MCP tools", {
        error: err instanceof Error ? err.message : String(err),
        url: getMcpServerUrl(),
      });
      _mcpClient = null;
      return [];
    }
  }
  return [];
}

/**
 * Probe: check if the MCP server is reachable (connect + listTools handshake).
 * Used by the health endpoint. Does not rely on the tool cache — a prior failed
 * loadMcpTools() can leave `_mcpTools` unset while still returning [] without
 * throwing, which must not be reported as connected.
 */
export async function probeMcpServer(): Promise<"connected" | "unreachable"> {
  try {
    return await Promise.race([
      probeMcpServerInner(),
      new Promise<"unreachable">((resolve) => {
        setTimeout(() => resolve("unreachable"), PING_MS);
      }),
    ]);
  } catch (err) {
    logger.warn("[health] MCP probe failed", {
      error: err instanceof Error ? err.message : String(err),
      url: getMcpServerUrl(),
    });
    return "unreachable";
  }
}

const PING_MS = 2500;

async function probeMcpServerInner(): Promise<"connected" | "unreachable"> {
  const client = await ensureMcpClient();
  if (!client) return "unreachable";
  await client.listTools();
  return "connected";
}

/** Reset the cached client (for tests). */
export function resetMcpClientForTests(): void {
  _mcpClient = null;
  _mcpTools = null;
}

// ---------------------------------------------------------------------------
// Nested trace extraction — counterpart to mcp-runtimes/mongodb-mcp/src/server.ts
// ---------------------------------------------------------------------------

/**
 * Shape the MongoDB MCP runtime packs into each text content block:
 *
 *   { "result": <tool result>, "meta": { "traces": [{type, payload, ts}, ...], "tracesDropped"?: n } }
 *
 * On the API side we:
 *   1. Parse each text content block.
 *   2. Replay each trace event into the per-turn collector so the Trace Viewer
 *      shows mongo.schema / mongo.plan / mongo.diagnostic cards alongside the
 *      in-process ones.
 *   3. Rewrite the content text to just `JSON.stringify(parsed.result)` so the
 *      LLM-visible portion is clean of trace noise.
 *
 * Returns the number of dropped events the MCP runtime reported (for telemetry).
 * Silently no-ops on any content block that isn't our envelope shape, so this
 * is safe against future MCP tools that don't follow the convention.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function extractAndReplayMcpTraces(
  result: any,
  trace: ReturnType<typeof currentTrace>,
  opts: { mcpCallLatencyMs?: number } = {},
): number {
  if (!result || !Array.isArray(result.content)) return 0;
  let dropped = 0;
  for (const block of result.content) {
    if (!block || block.type !== "text" || typeof block.text !== "string") continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(block.text);
    } catch {
      continue;
    }
    if (!parsed || typeof parsed !== "object") continue;
    const env = parsed as { result?: unknown; meta?: { traces?: unknown; tracesDropped?: number } };
    const meta = env.meta;
    if (!meta || !Array.isArray(meta.traces)) continue;
    const traceList = meta.traces as Array<{ type?: string; payload?: Record<string, unknown> }>;
    const resultDocs = Array.isArray((env.result as { documents?: unknown[] } | undefined)?.documents)
      ? ((env.result as { documents: unknown[] }).documents)
      : [];
    let scoresFromMeta = extractScoresFromDocuments(resultDocs);
    if (!scoresFromMeta.length) scoresFromMeta = extractScoresFromMcpTraceEvents(traceList);
    if (scoresFromMeta.length) pendingMcpVectorScores = scoresFromMeta;
    for (const ev of traceList) {
      if (!ev || typeof ev !== "object") continue;
      const e = ev as { type?: string; payload?: Record<string, unknown> };
      if (typeof e.type !== "string") continue;
      let payload = (e.payload ?? {}) as Record<string, unknown>;
      // mongo.vector_search events from the MongoDB MCP server don't carry
      // latencyMs (the MCP server traces the result shape, not wall-clock time).
      // Stamp with the MCP round-trip duration so maybeEmitMetric can emit
      // VectorSearchLatencyMs for the MCP tool path (AgentCore runtime).
      if (e.type === "mongo.vector_search" && typeof payload.latencyMs !== "number" && typeof opts.mcpCallLatencyMs === "number") {
        payload = { ...payload, latencyMs: opts.mcpCallLatencyMs };
      }
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      trace?.event(e.type as never, payload as any);
    }
    if (typeof meta.tracesDropped === "number") dropped += meta.tracesDropped;
    // Rewrite text to just the result so the LLM doesn't see `meta`.
    block.text = "result" in env ? JSON.stringify(env.result) : block.text;
  }
  return dropped;
}
