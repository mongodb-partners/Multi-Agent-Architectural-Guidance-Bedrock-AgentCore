/**
 * AgentCore Runtime entry point — AGENT_ID-based dual mode.
 *
 * AgentCore Runtime invokes this container at:
 *   GET  /ping         — health check → { status: "Healthy" }
 *   POST /invocations  — agent execution; body arrives as raw binary
 *
 * Mode is selected by the AGENT_ID environment variable set at runtime creation:
 *
 *   AGENT_ID=orchestrator
 *     Classifies the message with Claude (no tools, pure LLM via orchestrator.agent.md),
 *     extracts the target specialist from the handoff event, then calls
 *     InvokeAgentRuntime on the appropriate specialist ARN.
 *     Specialist ARNs come from env vars injected by deploy.sh:
 *       AGENTCORE_RUNTIME_ARN_TROUBLESHOOTING
 *       AGENTCORE_RUNTIME_ARN_ORDER_MANAGEMENT
 *       AGENTCORE_RUNTIME_ARN_PRODUCT_RECOMMENDATION
 *
 *   AGENT_ID=troubleshooting | order-management | product-recommendation
 *     Runs a single Strands Agent with the full tool set (MCP via Gateway).
 *     No Swarm, no routing. Returns complete response string.
 *
 * Input  payload: { message, sessionId, agentId?, priorTurns?, memoryContext? }
 * Output payload: { response, agentId, sessionId }
 *
 * Port: 8080 (required by AgentCore Runtime; not configurable)
 * Session/memory management: EC2 Hono API proxy owns these — not this container.
 */

import { Hono } from "hono";
import {
  BedrockAgentCoreClient,
  InvokeAgentRuntimeCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import { runChatStream } from "./lib/run-chat-stream.ts";
import { runSwarmChatStream } from "./lib/swarm-chat-stream.ts";
import { logger } from "./lib/logger.ts";
import type { ChatMessage } from "./lib/session-store.ts";
import { TraceCollector, tracingEnabled } from "./lib/trace-collector.ts";
import { withTrace } from "./lib/trace-context.ts";
import { withGatewayJwt } from "./lib/gateway-auth-context.ts";
import type { TraceEvent } from "./lib/trace-types.ts";

const PORT   = 8080;
const AGENT_ID = (process.env.AGENT_ID ?? "orchestrator").trim();

// Specialist ARNs — injected into the orchestrator runtime by deploy.sh
const SPECIALIST_ARNS: Record<string, string | undefined> = {
  "troubleshooting":       process.env.AGENTCORE_RUNTIME_ARN_TROUBLESHOOTING,
  "order-management":      process.env.AGENTCORE_RUNTIME_ARN_ORDER_MANAGEMENT,
  "product-recommendation": process.env.AGENTCORE_RUNTIME_ARN_PRODUCT_RECOMMENDATION,
};

// Singleton AgentCore client for orchestrator → specialist calls
let _acClient: BedrockAgentCoreClient | null = null;
function getAcClient(): BedrockAgentCoreClient {
  if (!_acClient) {
    _acClient = new BedrockAgentCoreClient({ region: process.env.AWS_REGION ?? "us-east-1" });
  }
  return _acClient;
}

// ── Invoke a specialist runtime (orchestrator → specialist) ──────────────────
async function invokeSpecialist(
  specialistId: string,
  payload: {
    message: string;
    sessionId: string;
    priorTurns?: ChatMessage[];
    memoryContext?: string;
    captureTrace?: boolean;
    /** Forwarded from the orchestrator's invocation body — required by the
     * specialist when TOOL_HOSTING_MODE=gateway so it can authenticate to the
     * AgentCore Gateway. Ignored in lambda mode. */
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
  let res;
  try {
    res = await getAcClient().send(
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

  const raw = await res.response?.transformToString();
  const latencyMs = Date.now() - t0;
  if (!raw) {
    if (collector && wrapperId) {
      collector.end(wrapperId, {
        arn,
        mode: "orchestrator_to_specialist",
        targetAgentId: specialistId,
        latencyMs,
        errorMessage: "empty response",
      });
    }
    throw new Error(`Empty response from specialist runtime '${specialistId}'`);
  }

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

// ── Orchestrator: classify → extract target → invoke specialist ──────────────
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
    if (part.type === "stream_error") {
      throw new Error(part.message);
    }
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

// ── Specialist: run single Strands agent ─────────────────────────────────────
async function handleSpecialist(
  agentId: string,
  message: string,
  priorTurns?: ChatMessage[],
  memoryContext?: string,
): Promise<string> {
  let fullResponse = "";
  for await (const part of runChatStream({ agentId, userMessage: message, priorTurns, memoryContext })) {
    if (part.type === "token")        fullResponse += part.text;
    if (part.type === "stream_error") throw new Error(part.message);
  }
  return fullResponse;
}

/** Cap trace events shipped back in the response (orchestrator → caller). */
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

// ── HTTP server ───────────────────────────────────────────────────────────────
const app = new Hono();

app.get("/ping", (c) => c.json({ status: "Healthy" }));

app.post("/invocations", async (c) => {
  // AgentCore sends body as raw binary/octet-stream
  const raw  = await c.req.arrayBuffer();
  const text = new TextDecoder().decode(raw);

  let body: {
    message:      string;
    sessionId:    string;
    agentId?:     string;
    priorTurns?:  ChatMessage[];
    memoryContext?: string;
    captureTrace?: boolean;
    /** Caller's Cognito access token, forwarded from the Hono API. Used to
     * authenticate outbound AgentCore Gateway calls when
     * TOOL_HOSTING_MODE=gateway. Ignored in lambda mode. */
    userJwt?:     string;
  };

  try {
    body = JSON.parse(text);
  } catch {
    return c.json({ error: "Invalid JSON payload" }, 400);
  }

  const { message, sessionId, priorTurns, memoryContext, captureTrace, userJwt } = body;

  if (!message?.trim()) return c.json({ error: "message is required" }, 400);

  const runtimeSessionId =
    c.req.header("x-amzn-bedrock-agentcore-runtime-session-id") ?? sessionId;

  logger.info("[runtime] invocation", { agentId: AGENT_ID, sessionId: runtimeSessionId });

  const wantTrace = captureTrace !== false && tracingEnabled();
  const collector = wantTrace
    ? new TraceCollector({ sessionId: runtimeSessionId, agentId: AGENT_ID, messageId: `runtime:${runtimeSessionId}` })
    : undefined;

  // Scope the caller's JWT for the entire invocation. The MCP transport in
  // mongodb-mcp-client.ts reads currentGatewayJwt() on every outbound HTTP
  // request to the AgentCore Gateway. In lambda/direct mode this is a no-op.
  const runScoped = <T>(fn: () => Promise<T>): Promise<T> => {
    const wrapped = () => (collector ? withTrace(collector, fn) : fn());
    return Promise.resolve(withGatewayJwt(userJwt, wrapped));
  };

  try {
    if (AGENT_ID === "orchestrator") {
      const result = await runScoped(() =>
        handleOrchestrator(message, sessionId, priorTurns, memoryContext, collector, userJwt),
      );
      const nestedTraceId = collector?.toJSON().traceId;
      const traceEvents = collector?.getEvents();
      const { kept, dropped } = traceEvents ? capNestedEvents(traceEvents) : { kept: [], dropped: 0 };
      return c.json({
        response: result.response,
        agentId: AGENT_ID,
        sessionId: runtimeSessionId,
        ...(result.handoffs?.length ? { handoffs: result.handoffs } : {}),
        ...(collector ? { traceEvents: kept, nestedTraceId, nestedEventsDropped: dropped } : {}),
      });
    } else {
      const response = await runScoped(() => handleSpecialist(AGENT_ID, message, priorTurns, memoryContext));
      const nestedTraceId = collector?.toJSON().traceId;
      const traceEvents = collector?.getEvents();
      const { kept, dropped } = traceEvents ? capNestedEvents(traceEvents) : { kept: [], dropped: 0 };
      return c.json({
        response,
        agentId: AGENT_ID,
        sessionId: runtimeSessionId,
        ...(collector ? { traceEvents: kept, nestedTraceId, nestedEventsDropped: dropped } : {}),
      });
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const klass = err instanceof Error ? err.constructor.name : "Error";
    logger.error("[runtime] invocation failed", { agentId: AGENT_ID, error: msg });
    collector?.event("error", { class: klass, message: msg, source: "runtime.invocation" });
    return c.json({
      error: msg,
      ...(collector ? { traceEvents: collector.getEvents() } : {}),
    }, 500);
  }
});

logger.info(`[runtime] AgentCore Runtime agent=${AGENT_ID} listening on :${PORT}`);

export default {
  port: PORT,
  fetch: app.fetch,
  // Bun.serve requires idleTimeout <= 255 seconds.
  idleTimeout: 120,
};
