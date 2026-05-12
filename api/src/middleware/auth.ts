import type { MiddlewareHandler } from "hono";
import { isJwksAuthConfigured, verifyBearerJwt } from "../lib/jwt-verify.ts";

const allowUnauthenticated = () =>
  process.env.ALLOW_UNAUTHENTICATED === "true" ||
  process.env.ALLOW_UNAUTHENTICATED === "1" ||
  process.env.REQUIRE_AUTH !== "true";

export const authMiddleware: MiddlewareHandler = async (c, next) => {
  if (allowUnauthenticated()) {
    await next();
    return;
  }
  const auth = c.req.header("Authorization");
  if (!auth?.startsWith("Bearer ") || auth.length < 15) {
    return c.json(
      {
        error: {
          code: "UNAUTHORIZED",
          message: "Missing or invalid Authorization header.",
          requestId: c.get("requestId") ?? "unknown",
        },
      },
      401,
    );
  }
  const token = auth.slice(7).trim();
  if (!token) {
    return c.json(
      {
        error: {
          code: "UNAUTHORIZED",
          message: "Missing or invalid Authorization header.",
          requestId: c.get("requestId") ?? "unknown",
        },
      },
      401,
    );
  }

  if (isJwksAuthConfigured()) {
    try {
      const payload = await verifyBearerJwt(token);
      c.set("jwtPayload", payload);
      c.set("bearerToken", token);
    } catch {
      return c.json(
        {
          error: {
            code: "INVALID_TOKEN",
            message: "Invalid or expired token.",
            requestId: c.get("requestId") ?? "unknown",
          },
        },
        401,
      );
    }
  }

  await next();
};
