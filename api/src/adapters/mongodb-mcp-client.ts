/**
 * MongoDB MCP Client adapter.
 *
 * Connects to the MongoDB MCP tool host over StreamableHTTP and exposes its
 * tools as McpTool instances ready to attach to any specialist agent.
 *
 * Endpoint resolution (cascade):
 *   `MONGODB_MCP_RUNTIME_ARN` → `MCP_SERVER_URL` → `AGENTCORE_GATEWAY_URL` →
 *   `http://localhost:8080/mcp`.
 *
 * Outbound auth:
 *   - Direct AgentCore Runtime mode signs each MCP JSON-RPC call with the
 *     runtime role by using `InvokeAgentRuntime`.
 *   - Gateway mode reads the caller's JWT from `currentGatewayJwt()` and sets
 *     it as `Authorization: Bearer <jwt>`.
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
import { BedrockAgentCoreClient } from "@aws-sdk/client-bedrock-agentcore";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { Hash } from "@smithy/hash-node";
import { HttpRequest } from "@smithy/protocol-http";
import { SignatureV4 } from "@smithy/signature-v4";
import { logger } from "../lib/logger.ts";
import { currentTrace } from "../lib/trace-context.ts";
import { currentGatewayJwt } from "../lib/gateway-auth-context.ts";
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

/** Default Atlas vector index per known seeded collection. */
const DEFAULT_VECTOR_INDEX_BY_COLLECTION: Record<string, string> = {
  products: "products-vector-index",
  troubleshooting_docs: "troubleshooting-vector-index",
};

/**
 * Bytes the wrapper will record per `documents` sample / vector preview before
 * the trace collector's per-event byte cap kicks in. Kept conservative so
 * `mongo.vector_search` events fit alongside `mongo.result` for the same call.
 */
const MAX_TRACE_SCORES = 25;

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
    "For known collections (`products`, `troubleshooting_docs`) the vector index is inferred " +
    "from the collection name; pass `indexName` to override. Returns the matching documents " +
    "with a `_score` field per hit.",
  inputSchema: {
    type: "object",
    properties: {
      collection: {
        type: "string",
        description: "MongoDB collection name (e.g. `products`, `troubleshooting_docs`).",
      },
      queryText: {
        type: "string",
        description:
          "Natural-language query. Embedded server-side using the configured embedding provider. " +
          "Prefer this over `queryVector`.",
      },
      indexName: {
        type: "string",
        description:
          "Optional Atlas vector index name. Defaults: products → products-vector-index, " +
          "troubleshooting_docs → troubleshooting-vector-index.",
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
          "Number of nearest-neighbor candidates to consider before applying `limit` (default 100, max 1000).",
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

  // Build the Lambda-shaped args object up front so we always emit a stable
  // `index` / `path` regardless of what the model passed in.
  const args: Record<string, JSONValue> = {
    collection,
    index: explicitIndex,
    path: typeof input.path === "string" && input.path.trim() ? input.path.trim() : "embedding",
  };
  if (typeof input.limit === "number" && Number.isFinite(input.limit)) {
    args.limit = Math.max(1, Math.floor(input.limit));
  }
  if (typeof input.numCandidates === "number" && Number.isFinite(input.numCandidates)) {
    args.numCandidates = Math.max(1, Math.floor(input.numCandidates));
  }
  if (isPlainObject(input.filter)) {
    args.filter = input.filter as JSONValue;
  }

  // Vector resolution: prefer model-supplied `queryVector` (advanced path —
  // useful for callers that already cached an embedding), else embed
  // `queryText`. If neither is present we can't run the search.
  if (suppliedVector) {
    args.queryVector = suppliedVector as unknown as JSONValue;
    return {
      ok: true,
      args,
      embed: { source: "model_supplied", modelId: undefined },
      queryText: queryText || "(supplied as queryVector)",
      vectorPreview: previewVector(suppliedVector),
    };
  }

  if (!queryText) {
    return {
      ok: false,
      code: "missing_query",
      message:
        "Pass `queryText` (preferred) or `queryVector`. Example: { collection: 'products', queryText: 'waterproof outdoor headphones' }.",
      queryText: "",
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
  return {
    ok: true,
    args,
    embed: { source: embedResult.source, modelId: embedResult.modelId },
    queryText,
    vectorPreview: previewVector(embedResult.vector),
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
export function extractScoresFromResult(result: ToolResultBlock): number[] {
  const blocks = result.content ?? [];
  for (const block of blocks) {
    // We only inspect text blocks: the MCP runtime always responds with a
    // single text block carrying the JSON envelope, even for empty results.
    if (!block || (block as { type?: string }).type !== "textBlock") continue;
    const text = (block as { text?: unknown }).text;
    if (typeof text !== "string") continue;
    try {
      const parsed = JSON.parse(text) as { documents?: unknown[]; count?: number };
      const docs = Array.isArray(parsed.documents) ? parsed.documents : [];
      const scores: number[] = [];
      for (const d of docs) {
        if (d && typeof d === "object" && typeof (d as { _score?: unknown })._score === "number") {
          scores.push((d as { _score: number })._score);
        }
      }
      return scores;
    } catch {
      // Not JSON — could be the unembed-friendly "Tool execution completed…"
      // fallback. Keep iterating in case a later block is parseable.
    }
  }
  return [];
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
 * Exported for the wrapper unit test.
 */
export class VectorSearchEmbedTool extends Tool {
  readonly name = "mongodb_vector_search";
  readonly description: string;
  readonly toolSpec: ToolSpec;
  private readonly underlying: Tool;

  constructor(underlying: Tool) {
    super();
    this.underlying = underlying;
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

    // Forward the rewritten args to the underlying MCP tool. The McpClient
    // wrapper in `connectMcpClient` still emits `tool.mcp` and splices the
    // lambda's nested mongo.intent / mongo.result events into our trace, so
    // we only need to add the vector-specific event here.
    const innerCtx: ToolContext = {
      ...toolContext,
      toolUse: { ...toolContext.toolUse, input: transform.args as JSONValue },
    };

    let result: ToolResultBlock;
    try {
      result = yield* this.underlying.stream(innerCtx);
    } catch (err) {
      // McpTool.stream() catches its own errors into createErrorResult, so we
      // shouldn't get here for normal failures. Defensive: still emit the
      // vector_search event so the trace doesn't lose context, then rethrow.
      trace?.event("mongo.vector_search", {
        embeddingSource: transform.embed.source,
        embeddingModelId: transform.embed.modelId,
        queryText: transform.queryText,
        queryVectorPreview: transform.vectorPreview,
        numCandidates: numericArg(transform.args.numCandidates),
        limit: numericArg(transform.args.limit),
        filter: transform.args.filter,
        scores: [],
      });
      throw err;
    }

    const scores = extractScoresFromResult(result).slice(0, MAX_TRACE_SCORES);
    trace?.event("mongo.vector_search", {
      embeddingSource: transform.embed.source,
      embeddingModelId: transform.embed.modelId,
      queryText: transform.queryText,
      queryVectorPreview: transform.vectorPreview,
      numCandidates: numericArg(transform.args.numCandidates),
      limit: numericArg(transform.args.limit),
      filter: transform.args.filter,
      scores,
      scoreSummary: summarizeScores(scores),
      histogram: scoreHistogram(scores),
    });
    return result;
  }
}

function numericArg(v: JSONValue | undefined): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

/**
 * Decide which Tool wrapper to use for a raw MCP tool.
 *
 *   - Gateway mode: `mongodb-mcp___mongodb_query` → `mongodb_query`.
 *   - Direct runtime mode: `mongodb_query` stays `mongodb_query`.
 *   - `mongodb_vector_search` always gets the queryText embedding bridge,
 *     whether it arrived through Gateway or direct runtime.
 *
 * Exported so the test can verify the wrapping decision without a live MCP
 * connection.
 */
export function wrapGatewayTool(raw: McpTool): Tool {
  const alias = stripGatewayTargetPrefix(raw.name);
  const exposedName = alias ?? raw.name;
  const exposed = alias ? new AliasedMcpTool(alias, raw) : raw;
  if (exposedName === "mongodb_vector_search") return new VectorSearchEmbedTool(exposed);
  return exposed;
}

let _mcpClient: McpClient | null = null;
// Tools are exposed as `Tool[]` (the base class) because a subset is wrapped
// by `AliasedMcpTool` to strip the gateway target-name prefix; both subclasses
// satisfy `Tool` and that is the only thing Strands' `Agent` requires.
let _mcpTools: Tool[] | null = null;
let _agentCoreClient: BedrockAgentCoreClient | null = null;
const DIRECT_RUNTIME_SESSION_ID =
  `mongodb-mcp-runtime-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;

type McpEndpoint =
  | { mode: "agentcore-runtime"; url: string; runtimeArn: string }
  | { mode: "http"; url: string };

type AwsCredentials = {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken?: string;
};

/**
 * Resolve the MCP endpoint. Production prefers the dedicated MongoDB MCP
 * AgentCore Runtime; `MCP_SERVER_URL` / `AGENTCORE_GATEWAY_URL` remain the
 * fallback for local servers and future non-Mongo Gateway targets.
 */
function resolveMcpEndpoint(): McpEndpoint {
  const runtimeArn = process.env.MONGODB_MCP_RUNTIME_ARN?.trim();
  if (runtimeArn) {
    return {
      mode: "agentcore-runtime",
      runtimeArn,
      url: process.env.MONGODB_MCP_RUNTIME_ENDPOINT?.trim() ||
        buildAgentCoreRuntimeEndpoint(runtimeArn),
    };
  }

  return {
    mode: "http",
    url: process.env.MCP_SERVER_URL?.trim() ||
      process.env.AGENTCORE_GATEWAY_URL?.trim() ||
      "http://localhost:8080/mcp",
  };
}

function getMcpServerUrl(): string {
  return resolveMcpEndpoint().url;
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
  if (!jwt) return globalThis.fetch(input, init);
  const headers = new Headers(init?.headers);
  // Always overwrite — the SDK may pre-populate Authorization from its own
  // OAuthClientProvider; we own the auth surface in gateway mode.
  headers.set("Authorization", `Bearer ${jwt}`);
  return globalThis.fetch(input, { ...init, headers });
};

function getAgentCoreClient(): BedrockAgentCoreClient {
  if (!_agentCoreClient) {
    _agentCoreClient = new BedrockAgentCoreClient({
      region: process.env.AWS_REGION ?? "us-east-1",
    });
  }
  return _agentCoreClient;
}

function buildAgentCoreRuntimeEndpoint(runtimeArn: string): string {
  const region = process.env.AWS_REGION ?? "us-east-1";
  return `https://bedrock-agentcore.${region}.amazonaws.com/runtimes/${encodeURIComponent(runtimeArn)}/invocations?qualifier=DEFAULT`;
}

function directRuntimeSessionId(): string {
  const configured = process.env.MONGODB_MCP_RUNTIME_SESSION_ID?.trim();
  const sessionId = configured || DIRECT_RUNTIME_SESSION_ID;
  return sessionId.length >= 33 ? sessionId : sessionId.padEnd(33, "0");
}

async function bodyToString(body: RequestInit["body"]): Promise<string> {
  if (body === undefined || body === null) return "";
  if (typeof body === "string") return body;
  if (body instanceof Uint8Array) return new TextDecoder().decode(body);
  if (body instanceof ArrayBuffer) return new TextDecoder().decode(body);
  if (body instanceof URLSearchParams) return body.toString();
  if (typeof Blob !== "undefined" && body instanceof Blob) return await body.text();
  return String(body);
}

async function resolveAwsCredentials(): Promise<AwsCredentials> {
  const provider = getAgentCoreClient().config.credentials;
  const credentials = typeof provider === "function" ? await provider() : provider;
  if (!credentials?.accessKeyId || !credentials.secretAccessKey) {
    throw new Error("AWS credentials are required for direct AgentCore Runtime MCP calls");
  }
  return credentials;
}

async function signAgentCoreRequest(
  input: string | URL,
  init?: RequestInit,
): Promise<{ url: URL; init: RequestInit }> {
  const url = new URL(input.toString());
  const region = process.env.AWS_REGION ?? "us-east-1";
  const method = (init?.method ?? "POST").toUpperCase();
  const body = await bodyToString(init?.body);
  const headers = new Headers(init?.headers);

  headers.set("host", url.host);
  if (!headers.has("x-amzn-bedrock-agentcore-runtime-session-id")) {
    headers.set("x-amzn-bedrock-agentcore-runtime-session-id", directRuntimeSessionId());
  }
  if (!headers.has("mcp-protocol-version")) {
    headers.set("mcp-protocol-version", "2025-06-18");
  }

  const request = new HttpRequest({
    protocol: url.protocol,
    hostname: url.hostname,
    port: url.port ? Number.parseInt(url.port, 10) : undefined,
    method,
    path: url.pathname,
    query: Object.fromEntries(url.searchParams.entries()),
    headers: Object.fromEntries(headers.entries()),
    body: method === "GET" || method === "HEAD" ? undefined : body,
  });
  const signer = new SignatureV4({
    credentials: resolveAwsCredentials,
    region,
    service: "bedrock-agentcore",
    sha256: Hash.bind(null, "sha256"),
  });
  const signed = await signer.sign(request);

  return {
    url,
    init: {
      ...init,
      method,
      ...(method === "GET" || method === "HEAD" ? {} : { body }),
      headers: Object.fromEntries(
        Object.entries(signed.headers).filter(([k]) => k.toLowerCase() !== "host"),
      ),
    },
  };
}

/**
 * StreamableHTTP transport hook for direct MongoDB MCP Runtime calls. The MCP
 * SDK owns the streaming request lifecycle; this adapter only adds SigV4 so
 * AgentCore Runtime accepts the HTTPS MCP request under the EC2/runtime role.
 */
function buildAgentCoreRuntimeFetch(_runtimeArn: string): typeof jwtInjectingFetch {
  return async (input: string | URL, init?: RequestInit): Promise<Response> => {
    const signed = await signAgentCoreRequest(input, init);
    return globalThis.fetch(signed.url, signed.init);
  };
}

/**
 * Build the StreamableHTTP transport for the selected MongoDB MCP endpoint.
 * Direct runtime mode uses IAM via `InvokeAgentRuntime`; HTTP/Gateway mode uses
 * the caller JWT when one is in scope.
 */
function buildTransport() {
  const endpoint = resolveMcpEndpoint();
  logger.info("[mcp] using streamable-HTTP transport", {
    url: endpoint.url,
    mode: endpoint.mode,
  });
  return new StreamableHTTPClientTransport(new URL(endpoint.url), {
    fetch: endpoint.mode === "agentcore-runtime"
      ? buildAgentCoreRuntimeFetch(endpoint.runtimeArn)
      : jwtInjectingFetch,
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

/**
 * Build and connect an `McpClient` against the configured transport, then
 * wrap its `callTool` to (a) emit `tool.mcp` trace events per invocation and
 * (b) splice nested trace events the Lambda MCP target packed into the
 * response envelope (see `lambda/mongodb-mcp/index.mjs`).
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
    try {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const result = await originalCallTool(tool as any, args as any);
      // The MongoDB MCP runtime packs trace events into the content envelope;
      // extract them first and rewrite the LLM-visible text, then emit
      // tool.mcp with the cleaned result.
      const nestedDropped = extractAndReplayMcpTraces(result, trace);
      trace?.event("tool.mcp", {
        server: serverLabel,
        toolName: tool.name,
        args,
        result,
        ...(nestedDropped > 0 ? { nestedTracesDropped: nestedDropped } : {}),
      });
      return result;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      const errClass = err instanceof Error ? err.constructor.name : "Error";
      trace?.event("tool.mcp", {
        server: serverLabel,
        toolName: tool.name,
        args,
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
export async function getMcpTools(): Promise<Tool[]> {
  if (_mcpTools) return _mcpTools;

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
      // Replace each gateway-prefixed tool with an alias bound to the unprefixed
      // name. Tools that don't carry the prefix (e.g. future targets, custom
      // gateway tools) pass through unchanged. `mongodb_vector_search` gets a
      // richer wrapper that re-specs the schema to accept `queryText` and
      // performs the embedding before forwarding to the gateway.
      _mcpTools = rawTools.map((t) => wrapGatewayTool(t));
      logger.info("[mcp] loaded tools", {
        tools: _mcpTools.map((t) => t.name),
        gatewayNames: rawTools.map((t) => t.name),
      });
      return _mcpTools;
    } catch (err) {
      const last = attempt === 1;
      if (isAuthError(err) && !last) {
        logger.warn("[mcp] listTools auth error — resetting client and retrying once", {
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
 * Probe: check if the MCP server is reachable without loading tools.
 * Used by the health endpoint.
 */
export async function probeMcpServer(): Promise<"connected" | "unreachable"> {
  try {
    const tools = await getMcpTools();
    return tools.length >= 0 ? "connected" : "unreachable";
  } catch {
    return "unreachable";
  }
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
export function extractAndReplayMcpTraces(result: any, trace: ReturnType<typeof currentTrace>): number {
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
    for (const ev of meta.traces) {
      if (!ev || typeof ev !== "object") continue;
      const e = ev as { type?: string; payload?: unknown };
      if (typeof e.type !== "string") continue;
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      trace?.event(e.type as never, (e.payload ?? {}) as any);
    }
    if (typeof meta.tracesDropped === "number") dropped += meta.tracesDropped;
    // Rewrite text to just the result so the LLM doesn't see `meta`.
    block.text = "result" in env ? JSON.stringify(env.result) : block.text;
  }
  return dropped;
}
