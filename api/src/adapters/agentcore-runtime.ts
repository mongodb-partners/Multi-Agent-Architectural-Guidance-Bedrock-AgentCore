/**
 * AgentCore Runtime invocation adapter.
 *
 * The Hono API always calls `InvokeAgentRuntime` against the orchestrator
 * runtime ARN. The runtime container responds with `text/event-stream` so
 * tokens reach the client as soon as Bedrock produces them — no buffering
 * at any hop.
 *
 * Session management and long-term memory stay in the Hono API; the runtime
 * receives full context (priorTurns, memoryContext) on each call.
 */

import {
  BedrockAgentCoreClient,
  InvokeAgentRuntimeCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import { logger } from "../lib/logger.ts";
import { injectTraceContextToCarrier } from "../lib/otel.ts";
import type { ChatMessage } from "../lib/session-store.ts";
import { currentTrace } from "../lib/trace-context.ts";
import {
  parseRuntimeSseStream,
  type RuntimeStreamEvent,
} from "../lib/runtime-sse.ts";

let _client: BedrockAgentCoreClient | null = null;
let specialistArnOverrides: Record<string, string> | undefined;

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

/** ARN for a specific specialist runtime (used when classifier picks one and
 *  Phase 2's direct-routing path is enabled). Returns `undefined` for unknown
 *  specialists. */
export function agentcoreSpecialistArn(agentId: string): string | undefined {
  const override = specialistArnOverrides?.[agentId]?.trim();
  if (override) return override;
  const safeAgentId = agentId.toUpperCase().replace(/[^A-Z0-9]+/g, "_");
  return process.env[`AGENTCORE_RUNTIME_ARN_${safeAgentId}`]?.trim() ||
    process.env[`AGENTCORE_${safeAgentId}_ARN`]?.trim() ||
    undefined;
}

export function setAgentcoreSpecialistArnOverrides(arns: Record<string, string> | undefined): void {
  specialistArnOverrides = arns ? { ...arns } : undefined;
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
  /**
   * Optional override of the runtime ARN. When omitted the orchestrator
   * runtime ARN is used. Phase 2 routes directly to a specialist by setting
   * this so the orchestrator hop is skipped entirely.
   */
  runtimeArn?: string;
  /**
   * Mode tag for the wrapper trace span. Defaults to `ec2_to_orchestrator`.
   * Use `ec2_to_specialist` when calling a specialist runtime directly.
   */
  invokeMode?: "ec2_to_orchestrator" | "ec2_to_specialist";
};

/**
 * Invoke the AgentCore Runtime and return its streaming response.
 *
 * The returned generator yields `RuntimeStreamEvent`s as the runtime
 * produces them. The caller is responsible for forwarding `stream` parts to
 * the client SSE channel and for accumulating `trace` events to splice into
 * the parent collector via `attachEventsNested(...)` once the stream ends.
 *
 * `runtimeSessionId` must be ≥ 33 characters (AgentCore requirement); we
 * pad it with `0`s when the caller's session id is shorter.
 */
export async function* invokeAgentRuntime(
  params: RuntimeInvokeParams,
): AsyncGenerator<RuntimeStreamEvent> {
  const arn = params.runtimeArn?.trim() || assertAgentcoreOrchestratorArn();
  const mode = params.invokeMode ?? "ec2_to_orchestrator";

  const runtimeSessionId = params.sessionId.length >= 33
    ? params.sessionId
    : params.sessionId.padEnd(33, "0");

  const carrier: Record<string, string> = {};
  injectTraceContextToCarrier(carrier);

  const payloadBody = {
    message: params.message,
    agentId: params.agentId,
    sessionId: params.sessionId,
    ...(params.priorTurns?.length ? { priorTurns: params.priorTurns } : {}),
    ...(params.memoryContext ? { memoryContext: params.memoryContext } : {}),
    ...(params.userJwt ? { userJwt: params.userJwt } : {}),
    captureTrace: true,
    ...(Object.keys(carrier).length > 0 ? { _trace: carrier } : {}),
  };
  const payload = JSON.stringify(payloadBody);

  logger.info("[agentcore-runtime] invoking runtime", {
    arn,
    agentId: params.agentId,
    sessionId: runtimeSessionId,
    mode,
  });

  const trace = currentTrace();
  const wrapperId = trace?.start(
    "agentcore.invoke",
    {
      arn,
      region: process.env.AWS_REGION,
      qualifier: "DEFAULT",
      runtimeSessionId,
      mode,
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
    accept: "text/event-stream",
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
        mode,
        targetAgentId: params.agentId,
        requestBytes: payload.length,
        latencyMs,
        errorClass: errClass,
        errorMessage: errMsg,
      });
    }
    logger.error("[agentcore-runtime] InvokeAgentRuntime failed", {
      arn,
      agentId: params.agentId,
      mode,
      latencyMs,
      errorClass: errClass,
      errorMessage: errMsg,
    });
    throw err;
  }

  const body = res.response;
  if (!body) {
    if (trace && wrapperId) {
      trace.end(wrapperId, {
        arn,
        mode,
        targetAgentId: params.agentId,
        requestBytes: payload.length,
        latencyMs: Date.now() - t0,
        errorMessage: "empty response",
      });
    }
    throw new Error("Empty response from AgentCore Runtime");
  }

  let responseBytes = 0;
  let firstByteAt: number | undefined;
  try {
    for await (const ev of parseRuntimeSseStream(body as AsyncIterable<Uint8Array>)) {
      if (firstByteAt === undefined) {
        firstByteAt = Date.now();
        trace?.event("latency.checkpoint", {
          name: "api.runtime.first_frame",
          elapsedMs: firstByteAt - t0,
          agentId: params.agentId,
          eventKind: ev.kind,
          partType: ev.kind === "stream" ? ev.part.type : undefined,
        });
      }
      responseBytes += JSON.stringify(ev).length;
      yield ev;
    }
  } finally {
    const latencyMs = Date.now() - t0;
    if (trace && wrapperId) {
      trace.end(wrapperId, {
        arn,
        mode,
        targetAgentId: params.agentId,
        requestBytes: payload.length,
        responseBytes,
        latencyMs,
        httpStatus: 200,
        ...(firstByteAt !== undefined ? { timeToFirstByteMs: firstByteAt - t0 } : {}),
      });
    }
  }
}

// Backward-compatible aliases to avoid breaking imports while renaming.
export const agentcoreRuntimeArn = agentcoreOrchestratorArn;
