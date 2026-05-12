import { Hono } from "hono";
import { deleteSession, getSession, listSessions } from "../lib/session-store.ts";

export const sessionsRoutes = new Hono();

sessionsRoutes.get("/sessions", async (c) => {
  const userId = c.get("jwtPayload")?.sub;
  const sessions = await listSessions(userId);
  return c.json({ sessions });
});

sessionsRoutes.get("/sessions/:sessionId", async (c) => {
  const sessionId = c.req.param("sessionId");
  const userId = c.get("jwtPayload")?.sub;
  const session = await getSession(sessionId);
  if (!session) {
    return c.json(
      {
        error: {
          code: "SESSION_NOT_FOUND",
          message: `No session with id '${sessionId}' exists.`,
          requestId: c.get("requestId") ?? "unknown",
        },
      },
      404,
    );
  }
  if (userId && session.userId && session.userId !== userId) {
    return c.json(
      {
        error: {
          code: "SESSION_NOT_FOUND",
          message: `No session with id '${sessionId}' exists.`,
          requestId: c.get("requestId") ?? "unknown",
        },
      },
      404,
    );
  }
  return c.json({
    sessionId: session.sessionId,
    userId: session.userId,
    createdAt: session.createdAt,
    messages: session.messages,
  });
});

sessionsRoutes.delete("/sessions/:sessionId", async (c) => {
  const sessionId = c.req.param("sessionId");
  const userId = c.get("jwtPayload")?.sub;
  const ok = await deleteSession(sessionId, userId);
  if (!ok) {
    return c.json(
      {
        error: {
          code: "SESSION_NOT_FOUND",
          message: `No session with id '${sessionId}' exists.`,
          requestId: c.get("requestId") ?? "unknown",
        },
      },
      404,
    );
  }
  return c.body(null, 204);
});
