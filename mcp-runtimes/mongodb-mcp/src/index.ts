// AgentCore Runtime entrypoint — Streamable-HTTP MCP server on 0.0.0.0:8000/mcp.
// Conforms to the AgentCore MCP runtime contract:
// https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-mcp.html
//
// Stateless mode (sessionIdGenerator: undefined) is the recommended default for
// tool-only MCP servers — we have no multi-turn elicitation, sampling, or
// progress notifications, so we don't need stateful session affinity. AgentCore
// invokes MCP runtimes with `Accept: text/event-stream`, so we leave the SDK in
// its default streamable response mode rather than forcing JSON responses.

import express, { type Request, type Response } from "express";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";

import { mcpServerCreate } from "./server.js";

const PORT = Number.parseInt(process.env.PORT ?? "8000", 10);
const HOST = process.env.HOST ?? "0.0.0.0";

const app = express();
app.use(express.json({ limit: "4mb" }));

app.post("/mcp", async (req: Request, res: Response) => {
  const startedAt = Date.now();
  const method = typeof req.body?.method === "string" ? req.body.method : "unknown";
  const shouldLogRequest = method !== "ping";
  if (shouldLogRequest) {
    console.log(`MCP request start method=${method} session=${req.get("mcp-session-id") ?? "none"}`);
  }
  const server = mcpServerCreate();
  try {
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
    });
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
    res.on("close", () => {
      if (shouldLogRequest) {
        console.log(`MCP request close method=${method} durationMs=${Date.now() - startedAt}`);
      }
      transport.close();
      server.close();
    });
  } catch (err) {
    const msg = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
    console.error("MCP request error:", msg.slice(0, 500));
    if (!res.headersSent) {
      res.status(500).json({
        jsonrpc: "2.0",
        error: { code: -32603, message: "Internal server error" },
        id: null,
      });
    }
  }
});

app.get("/mcp", (_req: Request, res: Response) => {
  res
    .status(405)
    .json({
      jsonrpc: "2.0",
      error: { code: -32000, message: "Method not allowed." },
      id: null,
    });
});

// AgentCore Runtime sends synthetic `/ping` checks to the container's
// health endpoint. Streamable-HTTP MCP servers expose readiness as part of
// the protocol, but exposing a plain GET /ping keeps load balancers and
// `wget --spider` happy too.
app.get("/ping", (_req, res) => {
  res.status(200).json({ status: "ok" });
});

app.listen(PORT, HOST, () => {
  console.log(`mongodb-mcp Streamable-HTTP MCP server listening on ${HOST}:${PORT}/mcp`);
});
