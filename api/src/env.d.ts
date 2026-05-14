import "hono";
import type { JWTPayload } from "jose";

declare module "hono" {
  interface ContextVariableMap {
    requestId: string;
    /** Set by authMiddleware after the Bearer JWT has been verified against the configured JWKS. */
    jwtPayload: JWTPayload | undefined;
    /** Raw bearer token from Authorization header (used for access-token enrichment). */
    bearerToken: string | undefined;
  }
}
