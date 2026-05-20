/**
 * Trace retrieval endpoints.
 *
 * Auth ownership matrix (auth is always required — see api/src/middleware/auth.ts):
 *  - The caller's JWT `sub` must exactly match `trace.userId`. Traces with no
 *    `userId` are denied (returned as 404) to any caller — the same treatment as
 *    a foreign-owned trace.  This closes the legacy-unscoped bypass and enforces
 *    the SOW requirement that jwt.sub is the sole tenant key everywhere.
 *
 * Endpoints:
 *  - `GET /traces/:traceId`        — fetch a complete trace document.
 *  - `GET /trace`                  — query by `sessionId` + `messageId`.
 *  - `GET /trace/mongo`            — narrower lens of mongo.* events
 *    (cheaper for the dashboard's MongoDB panel).
 *  - `GET /traces`                 — recent traces for the authenticated user only.
 */

import { Hono, type Context } from "hono";
import {
  getTraceById,
  getTraceForMessage,
  listRecentTraces,
} from "../lib/trace-store.ts";
import type { Trace, TraceEvent } from "../lib/trace-types.ts";
import { parseIncludeMode, projectTraceForInclude } from "../lib/trace-projection.ts";
import { logger } from "../lib/logger.ts";

export const traceRoutes = new Hono();

const MONGO_TYPES = new Set([
  "mongo.intent",
  "mongo.query",
  "mongo.plan",
  "mongo.result",
  "mongo.diagnostic",
  "mongo.vector_search",
  "mongo.schema",
] as const);

/**
 * Strict ownership: the trace must be explicitly bound to `userId` and that
 * userId must match the caller's JWT sub. Traces with no userId are denied —
 * the same as a foreign-owned trace — so unscoped legacy rows are not leaked
 * to any authenticated user.
 */
function userOwnsTrace(trace: Trace | undefined, userId: string | undefined): boolean {
  if (!trace) return false;
  if (!userId) return false;
  return !!trace.userId && trace.userId === userId;
}

function notFound(c: Context, requestId: string) {
  return c.json(
    {
      error: {
        code: "TRACE_NOT_FOUND",
        message: "Trace not found",
        requestId,
      },
    },
    404,
  );
}

traceRoutes.get("/traces/:traceId", async (c) => {
  const traceId = c.req.param("traceId");
  const userId = c.get("jwtPayload")?.sub;
  const requestId = c.get("requestId") ?? "unknown";
  // ?include=core|dev|full — server default is `full` for back-compat with
  // `verify-trace-ui-shape.py` and any pre-PR2 UI build. The Streamlit Trace
  // Viewer opts into `core` (initial load) / `dev` (on-demand) explicitly.
  const include = parseIncludeMode(c.req.query("include"));
  const trace = await getTraceById(traceId);
  if (!trace || !userOwnsTrace(trace, userId)) return notFound(c, requestId);
  // SOC2 audit: who fetched which trace at which projection level. Filter
  // on `channel=audit && msg="[trace] fetch"` in CloudWatch Logs Insights.
  logger.audit().info("[trace] fetch", { traceId, userId, requestId, include });
  const projected = projectTraceForInclude(trace, include);
  c.header("X-Trace-Include", include);
  return c.json(projected);
});

traceRoutes.get("/trace", async (c) => {
  const sessionId = c.req.query("sessionId");
  const messageId = c.req.query("messageId");
  const requestId = c.get("requestId") ?? "unknown";
  const userId = c.get("jwtPayload")?.sub;
  const include = parseIncludeMode(c.req.query("include"));
  if (!sessionId || !messageId) {
    return c.json(
      {
        error: {
          code: "MISSING_QUERY",
          message: "sessionId and messageId query params are required",
          requestId,
        },
      },
      400,
    );
  }
  const trace = await getTraceForMessage(sessionId, messageId);
  if (!trace || !userOwnsTrace(trace, userId)) return notFound(c, requestId);
  logger.audit().info("[trace] fetch", {
    traceId: trace.traceId,
    userId,
    requestId,
    include,
    via: "session+message",
  });
  const projected = projectTraceForInclude(trace, include);
  c.header("X-Trace-Include", include);
  return c.json(projected);
});

traceRoutes.get("/trace/mongo", async (c) => {
  const requestId = c.get("requestId") ?? "unknown";
  const userId = c.get("jwtPayload")?.sub;
  const traceId = c.req.query("traceId");
  const sessionId = c.req.query("sessionId");
  const messageId = c.req.query("messageId");
  let trace: Trace | undefined;
  if (traceId) trace = await getTraceById(traceId);
  else if (sessionId && messageId) trace = await getTraceForMessage(sessionId, messageId);
  else {
    return c.json(
      {
        error: {
          code: "MISSING_QUERY",
          message: "Provide either traceId or both sessionId+messageId",
          requestId,
        },
      },
      400,
    );
  }
  if (!trace || !userOwnsTrace(trace, userId)) return notFound(c, requestId);
  const mongoEvents: TraceEvent[] = trace.events.filter((e) =>
    MONGO_TYPES.has(e.type as (typeof MONGO_TYPES) extends Set<infer T> ? T : never),
  );
  return c.json({
    traceId: trace.traceId,
    sessionId: trace.sessionId,
    messageId: trace.messageId,
    agentId: trace.agentId,
    summary: trace.summary,
    events: mongoEvents,
  });
});

/**
 * Lightweight listing for the sidebar metrics — scoped to the authenticated user.
 *
 * Optional filters:
 *   `?sessionId=...`       — restrict to a single session (powers the Trace
 *                            Viewer's prev/next-turn-in-session arrows).
 *   `?excludeTraceId=...`  — drop a specific trace from the list (handy when
 *                            the UI already shows the current turn).
 *
 * When `sessionId` is set we over-fetch (4× requested limit, capped at 500)
 * and post-filter in-process. The trace ring-buffer + Mongo TTL window are
 * small enough that this stays cheap, and adding a `sessionId` index path
 * through `listRecentTraces` would require touching the store API for marginal
 * benefit. Same `userOwnsTrace` enforcement applies.
 */
traceRoutes.get("/traces", async (c) => {
  const userId = c.get("jwtPayload")?.sub;
  const requestId = c.get("requestId") ?? "unknown";
  if (!userId) {
    return c.json(
      { error: { code: "UNAUTHORIZED", message: "Authenticated user required.", requestId } },
      401,
    );
  }
  const limit = Math.max(1, Math.min(100, Number(c.req.query("limit") ?? 25)));
  const sessionIdFilter = c.req.query("sessionId")?.trim() || undefined;
  const excludeTraceId = c.req.query("excludeTraceId")?.trim() || undefined;
  // When filtering by session, over-fetch so we have a chance of finding all
  // matches even when the ring buffer has many concurrent sessions ahead of
  // the requested one.
  const fetchLimit = sessionIdFilter ? Math.min(500, limit * 4) : limit;
  const all = await listRecentTraces(fetchLimit, userId);
  let visible = all.filter((t) => userOwnsTrace(t, userId));
  if (sessionIdFilter) {
    visible = visible.filter((t) => t.sessionId === sessionIdFilter);
  }
  if (excludeTraceId) {
    visible = visible.filter((t) => t.traceId !== excludeTraceId);
  }
  visible = visible.slice(0, limit);
  return c.json({
    traces: visible.map((t) => ({
      traceId: t.traceId,
      sessionId: t.sessionId,
      messageId: t.messageId,
      agentId: t.agentId,
      createdAt: t.createdAt,
      summary: t.summary,
      truncated: t.truncated,
      eventsDropped: t.eventsDropped,
    })),
  });
});
