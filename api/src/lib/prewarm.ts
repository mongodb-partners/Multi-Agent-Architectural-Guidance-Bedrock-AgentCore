/**
 * Boot-time pre-warm for the API + runtime container.
 *
 * Cold-path latencies that used to land on the user's first chat:
 *   - MongoDB Atlas TLS handshake + topology discovery (~300-800 ms)
 *   - MCP `connect()` + `listTools()` round-trip (~150-400 ms)
 *   - AWS SDK Bedrock client init + first signing-key derivation
 *   - Per-agent Strands template construction (registry, tools, system prompt)
 *
 * `runStartupPrewarm()` fires all of these in parallel as dangling promises
 * and never blocks boot. Each task logs a warning on failure so a cold
 * dependency doesn't hide. Failures are non-fatal: the lazy paths in each
 * adapter still work the first time they're called.
 */

import { getMongoDb } from "./mongo-client.ts";
import { getMcpTools } from "../adapters/mongodb-mcp-client.ts";
import { warmAgentCache } from "./create-strands-agent.ts";
import { logger } from "./logger.ts";

export type PrewarmOptions = {
  /** Pre-build templates for every agent in `config/agents/`. Default true. */
  agents?: boolean;
  /** Open MongoDB connection. Default true (skipped when MONGODB_URI is unset). */
  mongo?: boolean;
  /** Connect to the MongoDB MCP runtime / gateway. Default true. */
  mcp?: boolean;
  /** Source label for the structured log. */
  source?: string;
};

export function runStartupPrewarm(opts: PrewarmOptions = {}): Promise<unknown[]> {
  const source = opts.source ?? "api";
  const t0 = Date.now();

  // Phase 1 — tool/data loaders that the agent templates depend on. These
  // MUST resolve before warmAgentCache() runs so the cached templates see
  // a populated MCP tool list. Previously these ran in parallel with
  // warmAgentCache(); a slow MCP connect at cold start could land the
  // agent cache before getMcpTools() resolved, baking an empty tool list
  // into the cache for the lifetime of the process. See plan
  // fix_mcp_tool_registry_failure.
  const phase1: Promise<unknown>[] = [];
  if (opts.mongo !== false) {
    phase1.push(
      getMongoDb().catch((e) => {
        logger.warn(`[${source}:prewarm] mongo connect failed`, {
          error: e instanceof Error ? e.message : String(e),
        });
      }),
    );
  }
  // Note: MCP prewarm is intentionally NOT fired at boot. The AgentCore
  // Gateway authorizer demands a Cognito JWT on every connect, but boot has
  // no caller in scope. A prewarm attempt fails with `Missing Bearer token`
  // and — because `getMcpTools()` reuses an in-flight promise — leaks the
  // empty result to the first real chat turn that arrives during the same
  // ~100 ms window, locking the runtime into a degraded template. The first
  // chat turn now connects MCP lazily inside its own `withGatewayJwt(...)`
  // scope, which is fast enough (~150–400 ms) to not need a separate prewarm.
  // See docs/status/debugging.md "MongoDB MCP prewarm singleton race".
  //
  // `opts.mcp` is retained on the type for backward compatibility, but is a
  // no-op. Log a deprecation when callers explicitly pass `mcp: true` so the
  // silent change of behaviour does not hide an incorrect assumption (the
  // value silently being ignored, with callers later wondering why their
  // first chat turn is ~400 ms slower than they expected).
  if (opts.mcp === true) {
    logger.warn(
      `[${source}:prewarm] opts.mcp=true is deprecated and now a no-op — MCP connects lazily on the first JWT-scoped chat turn (~150–400 ms). See docs/status/debugging.md "MongoDB MCP prewarm singleton race".`,
    );
  }
  void getMcpTools;

  return Promise.allSettled(phase1).then((phase1Results) => {
    const phase2: Promise<unknown>[] = [];
    if (opts.agents !== false) {
      phase2.push(
        warmAgentCache().catch((e) => {
          logger.warn(`[${source}:prewarm] warmAgentCache failed`, {
            error: e instanceof Error ? e.message : String(e),
          });
        }),
      );
    }
    return Promise.allSettled(phase2).then((phase2Results) => {
      const results = [...phase1Results, ...phase2Results];
      logger.info(`[${source}:prewarm] complete`, {
        durationMs: Date.now() - t0,
        taskCount: phase1.length + phase2.length,
        failed: results.filter((r) => r.status === "rejected").length,
      });
      return results;
    });
  });
}
