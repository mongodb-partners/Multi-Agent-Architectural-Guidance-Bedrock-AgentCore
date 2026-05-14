import type { MiddlewareHandler } from "hono";
import { verifyBearerJwt } from "../lib/jwt-verify.ts";

/**
 * Bearer-JWT auth gate. Boot-time `assertJwksAuthConfigured()` (in api/src/index.ts) guarantees
 * `AUTH_JWKS_URI` + `AUTH_ISSUER` are set, so this middleware can require a verified payload
 * unconditionally. There is no `ALLOW_UNAUTHENTICATED` or `REQUIRE_AUTH=false` bypass — every
 * environment must present a valid Bearer token from the configured OIDC pool.
 */
export const authMiddleware: MiddlewareHandler = async (c, next) => {
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

  await next();
};
