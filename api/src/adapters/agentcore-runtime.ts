/**
 * AgentCore Runtime invocation adapter.
 *
 * The Hono API always calls InvokeAgentRuntime against the orchestrator
 * runtime ARN; the runtime container handles the full agent loop (Strands
 * Swarm + specialist hand-off) and returns a complete response.
 *
 * Session management and long-term memory stay in the Hono API — the runtime
 * is stateless and receives full context (priorTurns, memoryContext) on each call.
 */

import {
  BedrockAgentCoreClient,
  InvokeAgentRuntimeCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import { logger } from "../lib/logger.ts";
import type { ChatMessage } from "../lib/session-store.ts";
import { currentTrace } from "../lib/trace-context.ts";
import type { TraceEvent } from "../lib/trace-types.ts";

let _client: BedrockAgentCoreClient | null = null;

function getClient(): BedrockAgentCoreClient {
  if (!_client) {
    _client = new BedrockAgentCoreClient({
      region: process.env.AWS_REGION ?? "us-east-1",
    });
  }
  return _client;
}

export function agentcoreOrchestratorArn(): string | undefined {
  // Accept the legacy AGENTCORE_RUNTIME_ARN name for older .env.live files.
  return process.env.AGENTCORE_ORCHESTRATOR_ARN?.trim() ||
    process.env.AGENTCORE_RUNTIME_ARN?.trim() ||
    undefined;
}

/**
 * Throw if the orchestrator runtime ARN is not configured. Called once at
 * startup (see `api/src/index.ts`) so the API never silently boots without
 * a runtime to delegate chat turns to.
 */
export function assertAgentcoreOrchestratorArn(): string {
  const arn = agentcoreOrchestratorArn();
  if (!arn) {
    throw new Error(
      "AGENTCORE_ORCHESTRATOR_ARN is required. Set it (or the legacy " +
        "AGENTCORE_RUNTIME_ARN) to the orchestrator AgentCore Runtime ARN.",
    );
  }
  return arn;
}

export type RuntimeInvokeParams = {
  message: string;
  agentId: string;
  sessionId: string;
  priorTurns?: ChatMessage[];
  memoryContext?: string;
  /**
   * Caller's Cognito access token (raw `Bearer <jwt>` value, no prefix).
   * Forwarded into the runtime invocation payload so the runtime injects it
   * as the Authorization header on outbound AgentCore Gateway MCP calls.
   */
  userJwt?: string;
};

export type RuntimeInvokeResult = {
  response: string;
  agentId: string;
  handoffs?: string[];
  /** Nested trace events captured inside the runtime container. */
  traceEvents?: TraceEvent[];
  /** AgentCore-side trace id, if the runtime container generated one. */
  nestedTraceId?: string;
};

/**
 * Invoke the AgentCore Runtime and return the complete response.
 *
 * runtimeSessionId must be ≥ 33 characters (AgentCore requirement).
 * We pad the sessionId with a fixed suffix if needed.
 */
export async function invokeAgentRuntime(
  params: RuntimeInvokeParams,
): Promise<RuntimeInvokeResult> {
  const arn = assertAgentcoreOrchestratorArn();

  const runtimeSessionId = params.sessionId.length >= 33
    ? params.sessionId
    : params.sessionId.padEnd(33, "0");

  const payloadBody = {
    message: params.message,
    agentId: params.agentId,
    sessionId: params.sessionId,
    ...(params.priorTurns?.length ? { priorTurns: params.priorTurns } : {}),
    ...(params.memoryContext ? { memoryContext: params.memoryContext } : {}),
    ...(params.userJwt ? { userJwt: params.userJwt } : {}),
    // Ask the runtime container to attach trace events into its response.
    captureTrace: true,
  };
  const payload = JSON.stringify(payloadBody);

  logger.info("[agentcore-runtime] invoking runtime", {
    arn,
    agentId: params.agentId,
    sessionId: runtimeSessionId,
  });

  const trace = currentTrace();
  const wrapperId = trace?.start(
    "agentcore.invoke",
    {
      arn,
      region: process.env.AWS_REGION,
      qualifier: "DEFAULT",
      runtimeSessionId,
      mode: "ec2_to_orchestrator",
      requestBytes: payload.length,
      latencyMs: 0,
      targetAgentId: params.agentId,
    },
  );

  const command = new InvokeAgentRuntimeCommand({
    agentRuntimeArn: arn,
    runtimeSessionId,
    payload,
    contentType: "application/json",
    accept: "application/json",
    qualifier: "DEFAULT",
  });

  const t0 = Date.now();
  let res;
  try {
    res = await getClient().send(command);
  } catch (err) {
    const latencyMs = Date.now() - t0;
    const errMsg = err instanceof Error ? err.message : String(err);
    const errClass = err instanceof Error ? err.constructor.name : "Error";
    if (trace && wrapperId) {
      trace.end(wrapperId, {
        arn,
        mode: "ec2_to_orchestrator",
        targetAgentId: params.agentId,
        requestBytes: payload.length,
        latencyMs,
        errorClass: errClass,
        errorMessage: errMsg,
      });
    }
    throw err;
  }

  const raw = await res.response?.transformToString();
  const latencyMs = Date.now() - t0;
  if (!raw) {
    if (trace && wrapperId) {
      trace.end(wrapperId, {
        arn,
        mode: "ec2_to_orchestrator",
        targetAgentId: params.agentId,
        requestBytes: payload.length,
        latencyMs,
        errorMessage: "empty response",
      });
    }
    throw new Error("Empty response from AgentCore Runtime");
  }

  let data: RuntimeInvokeResult;
  try {
    data = JSON.parse(raw);
  } catch {
    if (trace && wrapperId) {
      trace.end(wrapperId, {
        arn,
        mode: "ec2_to_orchestrator",
        targetAgentId: params.agentId,
        requestBytes: payload.length,
        responseBytes: raw.length,
        latencyMs,
        errorMessage: "non-JSON response",
      });
    }
    throw new Error(`AgentCore Runtime returned non-JSON: ${raw.slice(0, 200)}`);
  }

  logger.info("[agentcore-runtime] response received", {
    agentId: data.agentId,
    responseLength: data.response?.length,
    nestedTraceEvents: data.traceEvents?.length,
  });

  if (trace && wrapperId) {
    trace.end(wrapperId, {
      arn,
      mode: "ec2_to_orchestrator",
      targetAgentId: params.agentId,
      requestBytes: payload.length,
      responseBytes: raw.length,
      latencyMs,
      httpStatus: 200,
    });
    // Splice nested events into our collector.
    if (data.traceEvents?.length) {
      trace.attachEventsNested(data.traceEvents, wrapperId, {
        logger: { warn: (msg, ctx) => logger.warn(msg, ctx as Record<string, unknown> | undefined) },
      });
      trace.event("agentcore.nested_trace", {
        nestedTraceId: data.nestedTraceId,
        nestedRuntimeArn: arn,
        eventCount: data.traceEvents.length,
      });
    }
  }

  return data;
}

// Backward-compatible aliases to avoid breaking imports while renaming.
export const agentcoreRuntimeArn = agentcoreOrchestratorArn;
