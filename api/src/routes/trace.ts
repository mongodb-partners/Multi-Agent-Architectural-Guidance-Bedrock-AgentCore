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
  const trace = await getTraceById(traceId);
  if (!trace || !userOwnsTrace(trace, userId)) return notFound(c, requestId);
  return c.json(trace);
});

traceRoutes.get("/trace", async (c) => {
  const sessionId = c.req.query("sessionId");
  const messageId = c.req.query("messageId");
  const requestId = c.get("requestId") ?? "unknown";
  const userId = c.get("jwtPayload")?.sub;
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
  return c.json(trace);
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

/** Lightweight listing for the sidebar metrics — scoped to the authenticated user. */
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
  // Pass userId into the store so both the ring-buffer and Mongo queries are
  // pre-filtered; userOwnsTrace is a final safety-net for any stale ring entries.
  const all = await listRecentTraces(limit, userId);
  const visible = all.filter((t) => userOwnsTrace(t, userId));
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
