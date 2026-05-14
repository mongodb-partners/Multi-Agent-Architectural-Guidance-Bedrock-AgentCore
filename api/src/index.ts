import { createApp } from "./app.ts";
import { resolveApiListenPort } from "./lib/environment-config.ts";
import { assertAgentcoreOrchestratorArn } from "./adapters/agentcore-runtime.ts";
import { assertJwksAuthConfigured } from "./lib/jwt-verify.ts";
import { assertShortTermBackendConfigured } from "./lib/short-term-memory.ts";
import { assertEmbeddingsProvider } from "./lib/assert-embeddings-provider.ts";

assertJwksAuthConfigured();
assertShortTermBackendConfigured();
assertAgentcoreOrchestratorArn();
assertEmbeddingsProvider();

const app = createApp();

const port = resolveApiListenPort();

console.log(`API listening on http://localhost:${port}`);

export default {
  port,
  fetch: app.fetch,
  idleTimeout: 120, // seconds — prevent Bun from killing SSE streams during tool calls
};
