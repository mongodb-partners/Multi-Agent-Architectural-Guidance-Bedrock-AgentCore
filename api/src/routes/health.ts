import { Hono } from "hono";
import { buildHealthPayload } from "../lib/health-status.ts";
import { withGatewayJwt } from "../lib/gateway-auth-context.ts";
import { deepProbeMcpQuery } from "../adapters/mongodb-mcp-client.ts";
import { logger } from "../lib/logger.ts";

export const healthRoutes = new Hono();

function optionalBearerToken(authHeader: string | undefined): string | undefined {
  if (!authHeader?.startsWith("Bearer ")) return undefined;
  const token = authHeader.slice(7).trim();
  return token || undefined;
}

healthRoutes.get("/health", async (c) => {
  const body = await buildHealthPayload({
    gatewayJwt: optionalBearerToken(c.req.header("Authorization")),
  });
  return c.json(body, body.status === "degraded" ? 503 : 200);
});

/**
 * `/health/deep` — authenticated end-to-end probe of the MCP tool path.
 *
 * Issues a real `mongodb_query` for products.findOne via the AgentCore Gateway,
 * exercising the same code path as a chat-driven tool call but without an LLM.
 * Designed to be hit by the deploy-time smoke (Phase 9a3) so a broken MCP
 * runtime / Gateway target wiring fails the deploy with a precise diagnosis
 * before the LLM-dependent Phase 9b chat smoke even starts.
 *
 * Requires a Bearer JWT (same Cognito pool as the rest of the API). Without
 * the JWT the Gateway authorizer rejects the call and the probe reports
 * `unreachable`.
 */
healthRoutes.get("/health/deep", async (c) => {
  const jwt = optionalBearerToken(c.req.header("Authorization"));
  if (!jwt) {
    return c.json(
      {
        mcpProbe: "unreachable" as const,
        latencyMs: 0,
        gatewayUrl: "",
        error: "missing Bearer token (this route requires a Cognito JWT)",
      },
      401,
    );
  }
  const probe = await withGatewayJwt(jwt, () => deepProbeMcpQuery());
  logger.info("[health-deep] mongo probe via gateway", {
    mcpProbe: probe.mcpProbe,
    latencyMs: probe.latencyMs,
    error: probe.error,
  });
  return c.json(probe, probe.mcpProbe === "connected" ? 200 : 503);
});
