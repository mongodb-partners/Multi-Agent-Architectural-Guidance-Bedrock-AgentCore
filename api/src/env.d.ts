import "hono";
import type { JWTPayload } from "jose";

declare module "hono" {
  interface ContextVariableMap {
    requestId: string;
    /** Set by authMiddleware when REQUIRE_AUTH=true and JWKS is configured. */
    jwtPayload: JWTPayload | undefined;
    /** Raw bearer token from Authorization header (used for access-token enrichment). */
    bearerToken: string | undefined;
  }
}
