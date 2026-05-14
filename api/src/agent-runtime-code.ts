/**
 * AgentCore direct-code runtime entrypoint (Node.js 22).
 *
 * Implements AgentCore Runtime HTTP contract:
 *   GET  /ping
 *   POST /invocations
 *
 * This file is bundled to dist/agent-runtime-code.js and deployed as a
 * zip artifact through S3 codeConfiguration.
 *
 * Tracing: every invocation creates a per-call `TraceCollector`, scopes it
 * via `withTrace(...)`, and ships the collected events back in the response
 * as `traceEvents` + `nestedTraceId`. The Hono adapter
 * (`api/src/adapters/agentcore-runtime.ts`) splices those events into the
 * parent trace via `trace.attachEventsNested(...)` so the Trace Viewer sees
 * `mongo.*`, `tool.*`, `mcp.*`, and Strands `model.*` events from inside the
 * runtime container, not just an opaque `agentcore.invoke` wrapper.
 */

import http, { IncomingMessage, ServerResponse } from "node:http";
import {
  BedrockAgentCoreClient,
  InvokeAgentRuntimeCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import { runChatStream } from "./lib/run-chat-stream.ts";
import { runSwarmChatStream } from "./lib/swarm-chat-stream.ts";
import { logger } from "./lib/logger.ts";
import { assertEmbeddingsProvider } from "./lib/assert-embeddings-provider.ts";
import type { ChatMessage } from "./lib/session-store.ts";
import { withGatewayJwt } from "./lib/gateway-auth-context.ts";
import { TraceCollector, tracingEnabled } from "./lib/trace-collector.ts";
import { withTrace } from "./lib/trace-context.ts";
import type { TraceEvent } from "./lib/trace-types.ts";

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

/**
 * Cap nested trace events shipped in the response so a chatty turn cannot
 * blow the 1 MiB AgentCore Runtime response limit. Events are kept in
 * arrival order; the rest are dropped and the caller is told how many.
 */
function capNestedEvents(events: TraceEvent[]): { kept: TraceEvent[]; dropped: number } {
  const maxBytes = Number(process.env.AGENTCORE_NESTED_TRACE_MAX_BYTES ?? 200_000);
  let total = 0;
  const kept: TraceEvent[] = [];
  for (const e of events) {
    const sz = JSON.stringify(e).length;
    if (total + sz > maxBytes) break;
    total += sz;
    kept.push(e);
  }
  return { kept, dropped: events.length - kept.length };
}

async function invokeSpecialist(
  specialistId: string,
  payload: {
    message: string;
    sessionId: string;
    priorTurns?: ChatMessage[];
    memoryContext?: string;
    captureTrace?: boolean;
    userJwt?: string;
  },
  collector?: TraceCollector,
): Promise<{ response: string; traceEvents?: TraceEvent[] }> {
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

  const requestPayload = JSON.stringify({
    ...payload,
    agentId: specialistId,
    captureTrace: payload.captureTrace !== false,
  });

  const wrapperId = collector?.start("agentcore.invoke", {
    arn,
    qualifier: "DEFAULT",
    runtimeSessionId,
    mode: "orchestrator_to_specialist",
    requestBytes: requestPayload.length,
    latencyMs: 0,
    targetAgentId: specialistId,
  });

  const t0 = Date.now();
  let runtimeResponse;
  try {
    runtimeResponse = await getAcClient().send(
      new InvokeAgentRuntimeCommand({
        agentRuntimeArn: arn,
        runtimeSessionId,
        payload: requestPayload,
        contentType: "application/json",
        accept: "application/json",
        qualifier: "DEFAULT",
      }),
    );
  } catch (err) {
    if (collector && wrapperId) {
      collector.end(wrapperId, {
        arn,
        mode: "orchestrator_to_specialist",
        targetAgentId: specialistId,
        latencyMs: Date.now() - t0,
        errorClass: err instanceof Error ? err.constructor.name : "Error",
        errorMessage: err instanceof Error ? err.message : String(err),
      });
    }
    throw err;
  }

  const raw = await runtimeResponse.response?.transformToString();
  const latencyMs = Date.now() - t0;
  if (!raw) throw new Error(`Empty response from specialist runtime '${specialistId}'`);

  const data = JSON.parse(raw) as { response?: string; traceEvents?: TraceEvent[]; nestedTraceId?: string };

  if (collector && wrapperId) {
    collector.end(wrapperId, {
      arn,
      mode: "orchestrator_to_specialist",
      targetAgentId: specialistId,
      requestBytes: requestPayload.length,
      responseBytes: raw.length,
      latencyMs,
      httpStatus: 200,
    });
    if (data.traceEvents?.length) {
      collector.attachEventsNested(data.traceEvents, wrapperId, {
        logger: { warn: (msg, ctx) => logger.warn(msg, ctx as Record<string, unknown> | undefined) },
      });
      collector.event("agentcore.nested_trace", {
        nestedTraceId: data.nestedTraceId,
        nestedRuntimeArn: arn,
        eventCount: data.traceEvents.length,
      });
    }
  }

  return { response: data.response ?? "", traceEvents: data.traceEvents };
}

async function handleOrchestrator(
  message: string,
  sessionId: string,
  priorTurns?: ChatMessage[],
  memoryContext?: string,
  collector?: TraceCollector,
  userJwt?: string,
): Promise<{ response: string; handoffs?: string[] }> {
  let targetAgentId = "";
  let reasoning: string | undefined;
  const classifyStart = Date.now();

  for await (const part of runSwarmChatStream({
    userMessage: message,
    priorTurns,
    memoryContext,
  })) {
    if (part.type === "handoff") {
      targetAgentId = part.to;
      reasoning = part.label || undefined;
      break;
    }
    if (part.type === "stream_error") throw new Error(part.message);
  }

  if (collector && targetAgentId) {
    collector.event("agentcore.classification", {
      inputMessage: message.slice(0, 500),
      chosenSpecialist: targetAgentId,
      reasoning,
      latencyMs: Date.now() - classifyStart,
    });
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
  const { response } = await invokeSpecialist(
    targetAgentId,
    { message, sessionId, priorTurns, memoryContext, userJwt },
    collector,
  );
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
    captureTrace?: boolean;
    userJwt?: string;
  };

  try {
    body = JSON.parse(text);
  } catch {
    sendJson(res, 400, { error: "Invalid JSON payload" });
    return;
  }

  const { message, sessionId, priorTurns, memoryContext, captureTrace, userJwt } = body;
  if (!message?.trim()) {
    sendJson(res, 400, { error: "message is required" });
    return;
  }

  const runtimeSessionId = (req.headers["x-amzn-bedrock-agentcore-runtime-session-id"] as string) ?? sessionId;
  logger.info("[runtime] invocation", {
    agentId: AGENT_ID,
    sessionId: runtimeSessionId,
    hasUserJwt: Boolean(userJwt),
  });

  // Per-invocation trace collector. Disabled when the caller opted out via
  // captureTrace=false or when `tracingEnabled()` says the configured log
  // level is below the threshold. Without this scope, every
  // `mongo.*`/`tool.*`/`mcp.*`/`model.*` event emitted inside the runtime is
  // dropped on the floor and the parent Hono trace shows `toolCalls: 0` /
  // `mongoQueries: 0` even when the agent successfully pulled real data.
  const wantTrace = captureTrace !== false && tracingEnabled();
  const collector = wantTrace
    ? new TraceCollector({
        sessionId: runtimeSessionId,
        agentId: AGENT_ID,
        messageId: `runtime:${runtimeSessionId}`,
      })
    : undefined;

  // Scope the caller's JWT so the cached MCP client can still authenticate
  // any Gateway-backed fallback/tool calls. The active MongoDB path uses
  // direct AgentCore Runtime invocation, but the Gateway path remains
  // available for non-Mongo tools and local compatibility.
  const runScoped = <T,>(fn: () => Promise<T>): Promise<T> => {
    const wrapped = () => (collector ? withTrace(collector, fn) : fn());
    return Promise.resolve(withGatewayJwt(userJwt, wrapped));
  };

  try {
    if (AGENT_ID === "orchestrator") {
      const result = await runScoped(() =>
        handleOrchestrator(message, sessionId, priorTurns, memoryContext, collector, userJwt)
      );
      const nestedTraceId = collector?.toJSON().traceId;
      const traceEvents = collector?.getEvents();
      const { kept, dropped } = traceEvents ? capNestedEvents(traceEvents) : { kept: [], dropped: 0 };
      sendJson(res, 200, {
        response: result.response,
        agentId: AGENT_ID,
        sessionId: runtimeSessionId,
        ...(result.handoffs?.length ? { handoffs: result.handoffs } : {}),
        ...(collector ? { traceEvents: kept, nestedTraceId, nestedEventsDropped: dropped } : {}),
      });
      return;
    }

    const response = await runScoped(() => handleSpecialist(AGENT_ID, message, priorTurns, memoryContext));
    const traceEvents = collector?.getEvents();
    const nestedTraceId = collector?.toJSON().traceId;
    const { kept, dropped } = traceEvents ? capNestedEvents(traceEvents) : { kept: [], dropped: 0 };
    sendJson(res, 200, {
      response,
      agentId: AGENT_ID,
      sessionId: runtimeSessionId,
      ...(collector ? { traceEvents: kept, nestedTraceId, nestedEventsDropped: dropped } : {}),
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const klass = err instanceof Error ? err.constructor.name : "Error";
    logger.error("[runtime] invocation failed", { agentId: AGENT_ID, error: msg });
    collector?.event("error", { class: klass, message: msg, source: "runtime.invocation" });
    sendJson(res, 500, {
      error: msg,
      ...(collector ? { traceEvents: collector.getEvents(), nestedTraceId: collector.toJSON().traceId } : {}),
    });
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

assertEmbeddingsProvider();

server.listen(PORT, "0.0.0.0", () => {
  logger.info(`[runtime] AgentCore direct-code runtime agent=${AGENT_ID} listening on :${PORT}`);
});