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

export const accessLogMiddleware: MiddlewareHandler = async (c, next) => {
  const start = Date.now();
  await next();
  const durationMs = Date.now() - start;
  const requestId = c.get("requestId") ?? "unknown";
  const method = c.req.method;
  const path = new URL(c.req.url).pathname;
  const status = c.res.status;

  // Suppress /health at info level — only emit at debug to avoid poll noise.
  const isHealth = HEALTH_PATH.test(path);
  const level = isHealth ? "debug" : "info";
  logger[level]("request", { requestId, method, path, status, durationMs });
};
