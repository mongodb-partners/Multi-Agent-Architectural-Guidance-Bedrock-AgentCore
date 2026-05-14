import { Hono, type Context } from "hono";
import {
  deleteSession,
  FORBIDDEN_SESSION,
  getSession,
  listSessions,
} from "../lib/session-store.ts";

export const sessionsRoutes = new Hono();

function unauthorized(c: Context) {
  return c.json(
    {
      error: {
        code: "UNAUTHORIZED",
        message: "Authenticated user required.",
        requestId: c.get("requestId") ?? "unknown",
      },
    },
    401,
  );
}

function notFound(c: Context, sessionId: string) {
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

sessionsRoutes.get("/sessions", async (c) => {
  const userId = c.get("jwtPayload")?.sub;
  if (!userId) return unauthorized(c);
  const sessions = await listSessions(userId);
  return c.json({ sessions });
});

sessionsRoutes.get("/sessions/:sessionId", async (c) => {
  const sessionId = c.req.param("sessionId");
  const userId = c.get("jwtPayload")?.sub;
  if (!userId) return unauthorized(c);
  const session = await getSession(sessionId, userId);
  if (!session || session === FORBIDDEN_SESSION) return notFound(c, sessionId);
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
  if (!userId) return unauthorized(c);
  const ok = await deleteSession(sessionId, userId);
  if (!ok) return notFound(c, sessionId);
  return c.body(null, 204);
});
