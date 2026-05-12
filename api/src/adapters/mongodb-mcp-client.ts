/**
 * MongoDB MCP Client adapter.
 *
 * Connects to the AgentCore Gateway (or any MCP server) using the Strands
 * SDK McpClient and returns the server's tools as McpTool instances ready
 * to attach to any specialist agent.
 *
 * Activation (mutually exclusive with `lambda` and `direct`):
 *   - `TOOL_HOSTING_MODE=gateway` → StreamableHTTP transport to the URL
 *     resolved by `resolveMcpServerUrl()` (cascade: `MCP_SERVER_URL` →
 *     `AGENTCORE_GATEWAY_URL` → `http://localhost:8080/mcp`).
 *   - Any other mode (`lambda` / `direct`) → `getMcpTools()` returns `[]`
 *     and no transport is constructed. Agents use in-process tools instead.
 *
 * Outbound auth: every HTTP request reads the caller's JWT from
 * `currentGatewayJwt()` (an AsyncLocalStorage populated by the runtime
 * container's `/invocations` handler or the Hono API's chat handler) and
 * sets it as `Authorization: Bearer <jwt>`. The cached client is therefore
 * safe across multiple users in one process — only the header is dynamic.
 *
 * The client is initialised lazily on first call and cached for the process
 * lifetime to avoid reconnect overhead on every agent invocation. On a 401
 * from `callTool`, the cached client is reset and the call is retried once
 * (covers cold-start handshakes that ran before a JWT was in scope).
 */

import { McpClient } from "@strands-agents/sdk";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { logger } from "../lib/logger.ts";
import { currentTrace } from "../lib/trace-context.ts";
import { currentGatewayJwt } from "../lib/gateway-auth-context.ts";

// Derive the tool type from the SDK without relying on McpTool being re-exported.
// McpClient["listTools"] returns Promise<McpTool[]>; Awaited<...>[number] gives McpTool.
type McpTool = Awaited<ReturnType<McpClient["listTools"]>>[number];

// ---------------------------------------------------------------------------
// Singleton client — created once, reused across all agent invocations.
// ---------------------------------------------------------------------------

let _mcpClient: McpClient | null = null;
let _mcpTools: McpTool[] | null = null;

/**
 * Resolve the MCP endpoint URL. In gateway mode `deploy.sh` sets
 * `MCP_SERVER_URL` to the AgentCore Gateway URL; the `AGENTCORE_GATEWAY_URL`
 * fallback catches older `.env.live` files that still expose it under that
 * name. Local dev / stdio falls back to the systemd sidecar port.
 */
function resolveMcpServerUrl(): string {
  return (
    process.env.MCP_SERVER_URL?.trim() ||
    process.env.AGENTCORE_GATEWAY_URL?.trim() ||
    "http://localhost:8080/mcp"
  );
}

// Backward-compatible alias for callers (and the logger output below).
function getMcpServerUrl(): string {
  return resolveMcpServerUrl();
}

function isMcpEnabled(): boolean {
  return process.env.TOOL_HOSTING_MODE?.trim().toLowerCase() === "gateway";
}

/**
 * Custom fetch used by the StreamableHTTP transport. Reads the per-invocation
 * JWT from `currentGatewayJwt()` on every call so a single cached client can
 * serve many users without leaking auth across them. Falls back to the global
 * `fetch` with no auth header when no JWT is in scope (covers stdio dev /
 * unauthenticated local MCP servers).
 */
/**
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

/**
 * Build a transport based on the environment:
 *   MCP_TRANSPORT=stdio  → StdioClientTransport (spawns mongodb-mcp-server as child)
 *   default              → StreamableHTTPClientTransport to resolveMcpServerUrl()
 *
 * The HTTP transport uses a JWT-injecting `fetch` so every outbound request
 * carries the active user's Cognito access token as the `Authorization`
 * header. AgentCore Gateway's customJWTAuthorizer validates it.
 */
function buildTransport() {
  const mode = process.env.MCP_TRANSPORT?.trim().toLowerCase();

  if (mode === "stdio") {
    // Spawn mongodb-mcp-server as a child process over stdio.
    // Requires `npx -y mongodb-mcp-server` or `bunx mongodb-mcp-server` in PATH.
    const cmd = process.env.MCP_STDIO_CMD?.trim() || "bunx";
    const args = (process.env.MCP_STDIO_ARGS?.trim() || "mongodb-mcp-server").split(" ");
    logger.info("[mcp] using stdio transport", { cmd, args });
    return new StdioClientTransport({ command: cmd, args });
  }

  const url = resolveMcpServerUrl();
  logger.info("[mcp] using streamable-HTTP transport", { url });
  return new StreamableHTTPClientTransport(new URL(url), {
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

  const transport = process.env.MCP_TRANSPORT?.trim().toLowerCase() === "stdio" ? "stdio" : "http";
  const serverLabel = transport === "stdio" ? "mongodb-mcp-server" : getMcpServerUrl();
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
      // Lambda packs trace events into the content envelope; extract them
      // first and rewrite the LLM-visible text, then emit tool.mcp with
      // the cleaned result.
      const nestedDropped = extractAndReplayLambdaTraces(result, trace);
      trace?.event("tool.mcp", {
        server: serverLabel,
        transport,
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
        transport,
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
 * Return the list of MCP tools exposed by the MCP server (AgentCore Gateway
 * in gateway mode). Cached for the process lifetime once a successful
 * `listTools` round-trip completes.
 *
 * Returns `[]` when `TOOL_HOSTING_MODE != "gateway"` so callers can safely
 * spread the result into an agent tool list without a mode check at every
 * call site.
 *
 * On a 401/403 the client cache is discarded and the call is retried once;
 * this handles the case where the cached singleton's `connect` handshake
 * happened with no JWT (cold start) or with an expired token.
 */
export async function getMcpTools(): Promise<McpTool[]> {
  if (!isMcpEnabled()) return [];
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
      _mcpTools = await client.listTools();
      logger.info("[mcp] loaded tools", {
        tools: _mcpTools.map((t) => t.name),
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
export async function probeMcpServer(): Promise<"connected" | "unreachable" | "not_configured"> {
  if (!isMcpEnabled()) return "not_configured";
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
// Nested trace extraction — counterpart to lambda/mongodb-mcp/index.mjs
// ---------------------------------------------------------------------------

/**
 * Shape the Lambda packs into each text content block:
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
 * Returns the number of dropped events the Lambda reported (for telemetry).
 * Silently no-ops on any content block that isn't our envelope shape, so this
 * is safe against future MCP tools that don't follow the convention.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function extractAndReplayLambdaTraces(result: any, trace: ReturnType<typeof currentTrace>): number {
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
