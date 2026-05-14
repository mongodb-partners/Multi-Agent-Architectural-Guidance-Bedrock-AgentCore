import {
  createRemoteJWKSet,
  jwtVerify,
  type JWTVerifyGetKey,
  type JWTPayload,
} from "jose";

/** True when `AUTH_JWKS_URI` and `AUTH_ISSUER` are set — JWT signature and claims are verified. */
export function isJwksAuthConfigured(): boolean {
  const jwks = process.env.AUTH_JWKS_URI?.trim();
  const iss = process.env.AUTH_ISSUER?.trim();
  return Boolean(jwks && iss);
}

/**
 * Boot-time guard: refuse to start the API if JWKS auth is not configured.
 *
 * Called from `api/src/index.ts` so the process exits before any HTTP listener binds when
 * `AUTH_JWKS_URI` or `AUTH_ISSUER` is missing. There is no `ALLOW_UNAUTHENTICATED` /
 * `REQUIRE_AUTH=false` escape hatch — every environment must point at a real OIDC pool.
 */
export function assertJwksAuthConfigured(): void {
  if (isJwksAuthConfigured()) return;
  const jwks = process.env.AUTH_JWKS_URI?.trim();
  const iss = process.env.AUTH_ISSUER?.trim();
  const missing: string[] = [];
  if (!jwks) missing.push("AUTH_JWKS_URI");
  if (!iss) missing.push("AUTH_ISSUER");
  throw new Error(
    `[boot] JWKS auth is not configured: missing ${missing.join(", ")}. ` +
      `Every environment (including local dev) must set AUTH_JWKS_URI + AUTH_ISSUER ` +
      `to a real Cognito (or other OIDC) pool. There is no unauthenticated mode.`,
  );
}

function normalizeIssuer(iss: string): string {
  return iss.replace(/\/+$/, "");
}

let cachedJwksUri: string | null = null;
let cachedRemoteJwks: JWTVerifyGetKey | null = null;

/**
 * Test-only override. When set, `verifyBearerJwt` skips `createRemoteJWKSet` and uses the
 * supplied resolver instead. Production code never calls this; integration tests inject a
 * local JWKS so they don't need a live Cognito pool.
 */
let testJwksResolver: JWTVerifyGetKey | null = null;
export function _setJwksResolverForTests(resolver: JWTVerifyGetKey | null): void {
  testJwksResolver = resolver;
}

function getRemoteJwks(jwksUri: string): JWTVerifyGetKey {
  if (testJwksResolver) return testJwksResolver;
  if (cachedJwksUri === jwksUri && cachedRemoteJwks) return cachedRemoteJwks;
  cachedJwksUri = jwksUri;
  cachedRemoteJwks = createRemoteJWKSet(new URL(jwksUri));
  return cachedRemoteJwks;
}

function assertOptionalCognitoStyleClaims(
  payload: JWTPayload,
  opts: { appClientId?: string; tokenUse?: string },
): void {
  if (opts.appClientId) {
    const aud = payload.aud;
    const cid = typeof payload.client_id === "string" ? payload.client_id : undefined;
    const audOk =
      aud === opts.appClientId ||
      (Array.isArray(aud) && aud.includes(opts.appClientId));
    const cidOk = cid === opts.appClientId;
    if (!audOk && !cidOk) {
      throw new Error("JWT audience/client_id mismatch");
    }
  }
  if (opts.tokenUse) {
    if (payload.token_use !== opts.tokenUse) {
      throw new Error("JWT token_use mismatch");
    }
  }
}

/**
 * Verify Cognito-style (or any OIDC) JWT using remote JWKS.
 * Requires `AUTH_JWKS_URI`, `AUTH_ISSUER`. Optional `AUTH_APP_CLIENT_ID` (matches `aud` or `client_id`).
 * Optional `AUTH_TOKEN_USE` (e.g. `access` for Cognito access tokens).
 */
export async function verifyBearerJwt(token: string): Promise<JWTPayload> {
  const jwksUri = process.env.AUTH_JWKS_URI?.trim();
  const issuerRaw = process.env.AUTH_ISSUER?.trim();
  if (!jwksUri || !issuerRaw) {
    throw new Error("JWKS auth misconfigured");
  }
  const issuer = normalizeIssuer(issuerRaw);
  const JWKS = getRemoteJwks(jwksUri);
  const { payload } = await jwtVerify(token, JWKS, {
    issuer,
    clockTolerance: 30,
  });
  assertOptionalCognitoStyleClaims(payload, {
    appClientId: process.env.AUTH_APP_CLIENT_ID?.trim(),
    tokenUse: process.env.AUTH_TOKEN_USE?.trim(),
  });
  return payload;
}

/**
 * Test helper: same claim checks as production, but with an explicit JWKS resolver (e.g. `createLocalJWKSet`).
 */
export async function verifyJwtWithJwksResolver(
  token: string,
  getKey: JWTVerifyGetKey,
  issuer: string,
  opts?: { appClientId?: string; tokenUse?: string },
): Promise<JWTPayload> {
  const { payload } = await jwtVerify(token, getKey, {
    issuer: normalizeIssuer(issuer),
    clockTolerance: 30,
  });
  assertOptionalCognitoStyleClaims(payload, opts ?? {});
  return payload;
}
