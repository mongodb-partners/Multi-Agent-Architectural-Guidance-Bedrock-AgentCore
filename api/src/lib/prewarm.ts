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
  const tasks: Promise<unknown>[] = [];

  if (opts.mongo !== false) {
    tasks.push(
      getMongoDb().catch((e) => {
        logger.warn(`[${source}:prewarm] mongo connect failed`, {
          error: e instanceof Error ? e.message : String(e),
        });
      }),
    );
  }
  if (opts.mcp !== false) {
    tasks.push(
      getMcpTools().catch((e) => {
        logger.warn(`[${source}:prewarm] mcp listTools failed`, {
          error: e instanceof Error ? e.message : String(e),
        });
      }),
    );
  }
  if (opts.agents !== false) {
    tasks.push(
      warmAgentCache().catch((e) => {
        logger.warn(`[${source}:prewarm] warmAgentCache failed`, {
          error: e instanceof Error ? e.message : String(e),
        });
      }),
    );
  }

  const t0 = Date.now();
  return Promise.allSettled(tasks).then((results) => {
    logger.info(`[${source}:prewarm] complete`, {
      durationMs: Date.now() - t0,
      taskCount: tasks.length,
      failed: results.filter((r) => r.status === "rejected").length,
    });
    return results;
  });
}
