import { createApp } from "./app.ts";
import { resolveApiListenPort } from "./lib/environment-config.ts";

const app = createApp();

const port = resolveApiListenPort();

console.log(`API listening on http://localhost:${port}`);

export default {
  port,
  fetch: app.fetch,
  idleTimeout: 120, // seconds — prevent Bun from killing SSE streams during tool calls
};
