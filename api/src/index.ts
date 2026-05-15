import { initOtel } from "./lib/otel.ts";
import { installStrandsConsoleRedirect } from "./lib/strands-console-redirect.ts";
import { createApp } from "./app.ts";
import { resolveApiListenPort } from "./lib/environment-config.ts";
import { assertAgentcoreOrchestratorArn } from "./adapters/agentcore-runtime.ts";
import { assertJwksAuthConfigured } from "./lib/jwt-verify.ts";
import { assertShortTermBackendConfigured } from "./lib/short-term-memory.ts";
import { assertEmbeddingsProvider } from "./lib/assert-embeddings-provider.ts";
import { runStartupPrewarm } from "./lib/prewarm.ts";
import { logger } from "./lib/logger.ts";

assertJwksAuthConfigured();
assertShortTermBackendConfigured();
assertAgentcoreOrchestratorArn();
assertEmbeddingsProvider();

initOtel({ serviceName: "mongodb-multiagent-api" });
installStrandsConsoleRedirect();

// Pre-warm cold dependencies so the very first chat does not pay the Mongo
// TLS handshake + MCP listTools + per-agent template build on the user's
// clock. Fire-and-forget; never blocks boot.
void runStartupPrewarm({ source: "api" });

const app = createApp();

const port = resolveApiListenPort();

logger.info("api listening", { port });

export default {
  port,
  fetch: app.fetch,
  idleTimeout: 120, // seconds — prevent Bun from killing SSE streams during tool calls
};
