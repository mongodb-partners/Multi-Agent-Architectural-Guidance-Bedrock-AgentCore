/**
 * Trace retrieval endpoints.
 *
 * Auth ownership matrix (auth is always required — see api/src/middleware/auth.ts):
 *  - When the trace has a `userId`, the caller's JWT `sub` must match — otherwise the
 *    response is 404 (treat unauthorized as "not found" to avoid leaking the existence
 *    of someone else's trace).
 *  - Traces written before user scoping was wired (no `userId` on the document) are
 *    treated as unscoped and visible to any authenticated caller. New traces always
 *    carry a `userId`.
 *
 * Endpoints:
 *  - `GET /traces/:traceId`        — fetch a complete trace document.
 *  - `GET /trace`                  — query by `sessionId` + `messageId`.
 *  - `GET /trace/mongo`            — narrower lens of mongo.* events
 *    (cheaper for the dashboard's MongoDB panel).
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

function userOwnsTrace(trace: Trace | undefined, userId: string | undefined): boolean {
  if (!trace) return false;
  if (!trace.userId) return true; // unscoped legacy trace — readable by any authenticated caller
  if (!userId) return false;
  return trace.userId === userId;
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

/** Lightweight listing for the sidebar metrics. */
traceRoutes.get("/traces", async (c) => {
  const userId = c.get("jwtPayload")?.sub;
  const limit = Math.max(1, Math.min(100, Number(c.req.query("limit") ?? 25)));
  const all = await listRecentTraces(limit);
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
