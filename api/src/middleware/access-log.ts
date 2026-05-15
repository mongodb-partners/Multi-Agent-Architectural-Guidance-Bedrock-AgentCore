import type { MiddlewareHandler } from "hono";
import { logger } from "../lib/logger.ts";

/**
 * Structured access log middleware.
 *
 * Logs one JSON line per request after the response is sent:
 *   { level: "info", ts, msg: "request", requestId, method, path, status, durationMs }
 *
 * Must be registered AFTER requestIdMiddleware so requestId is available.
 * Skips health-check paths at LOG_LEVEL=info to avoid noise (still logged at debug).
 */

const HEALTH_PATH = /^\/health/;
const PROBE_PATHS =
  /^\/(agents|skills|traces|trace|demo-prompts|http-tools)(\/|$)/;

export const accessLogMiddleware: MiddlewareHandler = async (c, next) => {
  const start = Date.now();
  await next();
  const durationMs = Date.now() - start;
  const requestId = c.get("requestId") ?? "unknown";
  const method = c.req.method;
  const path = new URL(c.req.url).pathname;
  const status = c.res.status;

  // Suppress noisy probe paths at info — still emit at debug.
  const isProbe = HEALTH_PATH.test(path) || PROBE_PATHS.test(path);
  const level = isProbe ? "debug" : "info";
  logger[level]("request", { requestId, method, path, status, durationMs });
};
