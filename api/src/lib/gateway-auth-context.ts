/**
 * AsyncLocalStorage scope for the caller's Cognito JWT during a single
 * AgentCore Runtime `/invocations` request (or, in non-runtime deployments,
 * during a single Hono chat turn).
 *
 * Why this exists: the MCP transport in
 * `api/src/adapters/mongodb-mcp-client.ts` needs to inject
 * `Authorization: Bearer <jwt>` on every outbound HTTP request to the
 * AgentCore Gateway. The JWT arrives in the invocation payload, but the
 * transport is constructed once and reused across many users; passing the
 * JWT as a constructor arg would lock the singleton to one user.
 *
 * The pattern mirrors `trace-context.ts`: wrap the per-invocation handler in
 * `withGatewayJwt(jwt, fn)`, and the MCP transport's `fetch` reads the JWT
 * from `currentGatewayJwt()` on each call. The cached `McpClient` stays
 * sound across multiple invocations because only the headers vary.
 *
 * Tool functions never need to know about this — they call MCP tools as
 * usual and the transport handles the auth header transparently.
 */

import { AsyncLocalStorage } from "node:async_hooks";

const storage = new AsyncLocalStorage<{ jwt: string }>();

/** Run `fn` with `jwt` scoped as the active Gateway JWT for any MCP calls. */
export function withGatewayJwt<T>(jwt: string | undefined, fn: () => T): T {
  if (!jwt) return fn();
  return storage.run({ jwt }, fn);
}

/** Returns the JWT scoped by the nearest `withGatewayJwt(...)` ancestor, or undefined. */
export function currentGatewayJwt(): string | undefined {
  return storage.getStore()?.jwt;
}
