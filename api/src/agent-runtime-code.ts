/**
 * AgentCore direct-code runtime entrypoint (Node.js 22).
 *
 * Implements AgentCore Runtime HTTP contract:
 *   GET  /ping
 *   POST /invocations
 *
 * This file is bundled to dist/agent-runtime-code.js and deployed as a
 * zip artifact through S3 codeConfiguration.
 */

import http, { IncomingMessage, ServerResponse } from "node:http";
import {
  BedrockAgentCoreClient,
  InvokeAgentRuntimeCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import { runChatStream } from "./lib/run-chat-stream.ts";
import { runSwarmChatStream } from "./lib/swarm-chat-stream.ts";
import { logger } from "./lib/logger.ts";
import type { ChatMessage } from "./lib/session-store.ts";

const PORT = 8080;
const AGENT_ID = (process.env.AGENT_ID ?? "orchestrator").trim();

const SPECIALIST_ARNS: Record<string, string | undefined> = {
  troubleshooting: process.env.AGENTCORE_RUNTIME_ARN_TROUBLESHOOTING,
  "order-management": process.env.AGENTCORE_RUNTIME_ARN_ORDER_MANAGEMENT,
  "product-recommendation": process.env.AGENTCORE_RUNTIME_ARN_PRODUCT_RECOMMENDATION,
};

let _acClient: BedrockAgentCoreClient | null = null;
function getAcClient(): BedrockAgentCoreClient {
  if (!_acClient) {
    _acClient = new BedrockAgentCoreClient({ region: process.env.AWS_REGION ?? "us-east-1" });
  }
  return _acClient;
}

function sendJson(res: ServerResponse, status: number, payload: unknown): void {
  const body = JSON.stringify(payload);
  res.statusCode = status;
  res.setHeader("content-type", "application/json");
  res.setHeader("content-length", Buffer.byteLength(body));
  res.end(body);
}

async function readRequestBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  return Buffer.concat(chunks).toString("utf-8");
}

async function invokeSpecialist(
  specialistId: string,
  payload: { message: string; sessionId: string; priorTurns?: ChatMessage[]; memoryContext?: string },
): Promise<string> {
  const arn = SPECIALIST_ARNS[specialistId];
  if (!arn) {
    throw new Error(
      `No ARN configured for specialist '${specialistId}'. ` +
        `Set AGENTCORE_RUNTIME_ARN_${specialistId.toUpperCase().replace(/-/g, "_")} on the orchestrator runtime.`,
    );
  }

  const runtimeSessionId = payload.sessionId.length >= 33
    ? payload.sessionId
    : payload.sessionId.padEnd(33, "0");

  const res = await getAcClient().send(
    new InvokeAgentRuntimeCommand({
      agentRuntimeArn: arn,
      runtimeSessionId,
      payload: JSON.stringify({ ...payload, agentId: specialistId }),
      contentType: "application/json",
      accept: "application/json",
      qualifier: "DEFAULT",
    }),
  );

  const raw = await res.response?.transformToString();
  if (!raw) throw new Error(`Empty response from specialist runtime '${specialistId}'`);

  const data = JSON.parse(raw) as { response?: string };
  return data.response ?? "";
}

async function handleOrchestrator(
  message: string,
  sessionId: string,
  priorTurns?: ChatMessage[],
  memoryContext?: string,
): Promise<{ response: string; handoffs?: string[] }> {
  let targetAgentId = "";

  // Use the swarm event stream to get the orchestrator's explicit handoff decision.
  // We stop as soon as the first handoff event appears and then invoke that specialist
  // via AgentCore Runtime (distributed runtime path).
  for await (const part of runSwarmChatStream({
    userMessage: message,
    priorTurns,
    memoryContext,
  })) {
    if (part.type === "handoff") {
      targetAgentId = part.to;
      break;
    }
    if (part.type === "stream_error") throw new Error(part.message);
  }

  if (!targetAgentId || !SPECIALIST_ARNS[targetAgentId]) {
    let fallback = "";
    for await (const part of runChatStream({
      agentId: "orchestrator",
      userMessage: message,
      priorTurns,
      memoryContext,
    })) {
      if (part.type === "token") fallback += part.text;
    }
    return { response: fallback };
  }

  logger.info("[runtime:orchestrator] routing to specialist", { targetAgentId, sessionId });
  const response = await invokeSpecialist(targetAgentId, { message, sessionId, priorTurns, memoryContext });
  return { response, handoffs: [targetAgentId] };
}

async function handleSpecialist(
  agentId: string,
  message: string,
  priorTurns?: ChatMessage[],
  memoryContext?: string,
): Promise<string> {
  let fullResponse = "";
  for await (const part of runChatStream({ agentId, userMessage: message, priorTurns, memoryContext })) {
    if (part.type === "token") fullResponse += part.text;
    if (part.type === "stream_error") throw new Error(part.message);
  }
  return fullResponse;
}

async function handleInvocations(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const text = await readRequestBody(req);

  let body: {
    message: string;
    sessionId: string;
    agentId?: string;
    priorTurns?: ChatMessage[];
    memoryContext?: string;
  };

  try {
    body = JSON.parse(text);
  } catch {
    sendJson(res, 400, { error: "Invalid JSON payload" });
    return;
  }

  const { message, sessionId, priorTurns, memoryContext } = body;
  if (!message?.trim()) {
    sendJson(res, 400, { error: "message is required" });
    return;
  }

  const runtimeSessionId = (req.headers["x-amzn-bedrock-agentcore-runtime-session-id"] as string) ?? sessionId;
  logger.info("[runtime] invocation", { agentId: AGENT_ID, sessionId: runtimeSessionId });

  try {
    if (AGENT_ID === "orchestrator") {
      const result = await handleOrchestrator(message, sessionId, priorTurns, memoryContext);
      sendJson(res, 200, {
        response: result.response,
        agentId: AGENT_ID,
        sessionId: runtimeSessionId,
        ...(result.handoffs?.length ? { handoffs: result.handoffs } : {}),
      });
      return;
    }

    const response = await handleSpecialist(AGENT_ID, message, priorTurns, memoryContext);
    sendJson(res, 200, { response, agentId: AGENT_ID, sessionId: runtimeSessionId });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    logger.error("[runtime] invocation failed", { agentId: AGENT_ID, error: msg });
    sendJson(res, 500, { error: msg });
  }
}

const server = http.createServer(async (req, res) => {
  const method = req.method ?? "";
  const url = req.url ?? "";

  if (method === "GET" && url === "/ping") {
    sendJson(res, 200, { status: "Healthy" });
    return;
  }

  if (method === "POST" && url === "/invocations") {
    await handleInvocations(req, res);
    return;
  }

  sendJson(res, 404, { error: "Not found" });
});

server.listen(PORT, "0.0.0.0", () => {
  logger.info(`[runtime] AgentCore direct-code runtime agent=${AGENT_ID} listening on :${PORT}`);
});
