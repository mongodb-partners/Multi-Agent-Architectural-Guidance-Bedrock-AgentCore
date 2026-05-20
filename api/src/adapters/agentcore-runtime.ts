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
import { recordAgentCoreInvoke } from "../lib/cw-metrics.ts";
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
  // Auth-scrubbed outbound headers. The bedrock-agentcore SDK injects auth
  // itself (sig-v4 against the IAM role) so we don't see those values here;
  // the allow list still reflects what the runtime *would* see on the wire.
  const requestHeadersPreview: Record<string, string> = {
    "content-type": "application/json",
    accept: "text/event-stream",
    "x-amz-target": "BedrockAgentCoreFrontEndService.InvokeAgentRuntime",
  };
  if (params.userJwt) requestHeadersPreview["authorization"] = "***";

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
      // Truncate to a sane preview — the per-event-type truncation table in
      // trace-collector.ts caps `payload` at 64 KB. Serializing the parsed
      // body (not the JSON string) keeps it human-readable in the dev panel.
      payload: payloadBody,
      requestHeadersPreview,
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
  // Manual retry loop so we can emit `agentcore.retry` per attempt. The
  // bedrock-agentcore SDK does its own retries via AWS SDK v3 (defaults
  // to 3 attempts on ThrottlingException / 5xx) but those are invisible
  // to our trace pipeline — replacing the SDK strategy and unwrapping
  // each retry inside `getClient().send(...)` would require either a
  // custom RetryStrategyV2 (mirrors resolve-model.ts) or a wrapper here.
  // We pick the wrapper because the bedrock-agentcore client is shared
  // process-wide via `_client`; per-call retry observability is local.
  const maxAttempts = envInt("AGENTCORE_MAX_ATTEMPTS", 3);
  let res;
  let lastErr: unknown;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      res = await getClient().send(command);
      break;
    } catch (err) {
      lastErr = err;
      const isLast = attempt === maxAttempts;
      const errClass = err instanceof Error ? err.constructor.name : "Error";
      const httpStatus =
        (err as { $metadata?: { httpStatusCode?: number } })?.$metadata?.httpStatusCode;
      const retryable = isRetryableAgentcoreError(errClass, httpStatus);
      if (isLast || !retryable) break;
      const backoffMs = attempt ** 2 * 100;
      if (trace) {
        trace.event("agentcore.retry", {
          arn,
          targetAgentId: params.agentId,
          mode,
          attempt,
          previousErrorClass: errClass,
          previousErrorMessage: err instanceof Error ? err.message : String(err),
          backoffMs,
          httpStatus,
        });
      }
      logger.warn("[agentcore-runtime] retryable invoke error, backing off", {
        arn,
        attempt,
        errorClass: errClass,
        backoffMs,
        httpStatus,
      });
      await new Promise((resolve) => setTimeout(resolve, backoffMs));
    }
  }
  if (!res) {
    const err = lastErr;
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
      // Surface the observability link even on failure so devs can grep
      // CloudWatch for the failed invocation by approximate timestamp.
      emitObservabilityLink(trace, arn, undefined);
    }
    logger.error("[agentcore-runtime] InvokeAgentRuntime failed", {
      arn,
      agentId: params.agentId,
      mode,
      latencyMs,
      errorClass: errClass,
      errorMessage: errMsg,
    });
    try {
      recordAgentCoreInvoke({
        agentId: params.agentId,
        mode,
        latencyMs,
        error: true,
        errorClass: errClass,
      });
    } catch {
      // metric emission must never destabilize the runtime call
    }
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
  // Capped responseBody accumulator. Real responses can be unbounded (long
  // streams of tokens), so we keep up to RESPONSE_PREVIEW_BYTES of summary
  // event payloads (everything except `trace` frames, which get spliced
  // separately, and `token` parts, which are too noisy to log raw). The
  // collector's per-event-type truncation table additionally caps the field
  // at 64 KB downstream.
  const RESPONSE_PREVIEW_BYTES = 16_384;
  const responsePreview: unknown[] = [];
  let responsePreviewBytes = 0;
  // Response headers — the bedrock-agentcore SDK abstracts these away so we
  // log the metadata that *is* observable (HTTP status, request id) under
  // a header-preview shape so the dev panel renders consistently.
  const responseHeadersPreview: Record<string, string> = {
    "content-type": "text/event-stream",
  };
  const runtimeRequestId =
    (res.$metadata?.requestId as string | undefined) ??
    (res.$metadata?.extendedRequestId as string | undefined);
  if (runtimeRequestId) responseHeadersPreview["x-amzn-requestid"] = runtimeRequestId;

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
      const evStr = JSON.stringify(ev);
      responseBytes += evStr.length;
      // Skip token parts (too noisy) and full trace events (spliced separately
      // via nestedEvents). Keep done/agent_active/skill/tool_call summaries.
      if (
        responsePreviewBytes < RESPONSE_PREVIEW_BYTES &&
        ev.kind !== "trace" &&
        !(ev.kind === "stream" && ev.part.type === "token")
      ) {
        responsePreview.push(ev);
        responsePreviewBytes += evStr.length;
      }
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
        correlationId: runtimeRequestId,
        responseBody: responsePreview,
        responseHeadersPreview,
      });
      // Always emit the observability link. The X-Ray / CloudWatch URLs need
      // region + (optional) runtimeRequestId; if we don't have the runtime's
      // request id we still emit the log-group reference so the dev panel can
      // render a "search by trace id" link instead of a deep-link.
      emitObservabilityLink(trace, arn, runtimeRequestId);
    }
    try {
      recordAgentCoreInvoke({
        agentId: params.agentId,
        mode,
        latencyMs,
        error: false,
      });
    } catch {
      // metric emission must never destabilize the runtime call
    }
  }
}

function envInt(name: string, fallback: number): number {
  const v = process.env[name];
  if (!v) return fallback;
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

/**
 * Retryable AgentCore Runtime errors. Mirrors the AWS SDK v3 defaults plus
 * the AgentCore-specific stream errors that surface as transient hiccups.
 */
export function isRetryableAgentcoreError(errClass: string, httpStatus: number | undefined): boolean {
  if (
    errClass === "ThrottlingException" ||
    errClass === "TooManyRequestsException" ||
    errClass === "ServiceUnavailableException" ||
    errClass === "InternalServerException" ||
    errClass === "ModelStreamErrorException" ||
    errClass === "TimeoutError"
  ) {
    return true;
  }
  if (httpStatus !== undefined && (httpStatus === 429 || (httpStatus >= 500 && httpStatus < 600))) {
    return true;
  }
  return false;
}

/**
 * Emit `agentcore.observability_link` with X-Ray + CloudWatch deep-link URLs.
 * Called from the wrapper span's `finally` so the dev panel always has a
 * link (even on errored invocations). Wrapped in try/catch because URL
 * construction must never destabilize the chat path.
 */
function emitObservabilityLink(
  trace: NonNullable<ReturnType<typeof currentTrace>>,
  arn: string,
  runtimeRequestId: string | undefined,
): void {
  try {
    const region = process.env.AWS_REGION ?? "us-east-1";
    const runtimeName = arn.split("/").pop() ?? "agentcore-runtime";
    // CloudWatch log group convention for AgentCore Runtime: per-runtime,
    // per-version log group. We can't know the version at this layer (we
    // pass qualifier=DEFAULT) so we link to the runtime's log-group prefix.
    const logGroup = `/aws/bedrock-agentcore/runtimes/${runtimeName}`;
    const cloudwatchLogGroupUrl =
      `https://${region}.console.aws.amazon.com/cloudwatch/home?region=${region}` +
      `#logsV2:log-groups/log-group/${encodeURIComponent(logGroup)}`;
    const xrayUrl = runtimeRequestId
      ? `https://${region}.console.aws.amazon.com/cloudwatch/home?region=${region}` +
        `#xray:traces/${encodeURIComponent(runtimeRequestId)}`
      : `https://${region}.console.aws.amazon.com/cloudwatch/home?region=${region}#xray:traces`;
    trace.event("agentcore.observability_link", {
      xrayUrl,
      cloudwatchLogGroup: logGroup,
      cloudwatchLogStreamUrl: cloudwatchLogGroupUrl,
      runtimeRequestId,
    });
  } catch {
    // observability link emission must never destabilize the runtime call
  }
}

// Backward-compatible aliases to avoid breaking imports while renaming.
export const agentcoreRuntimeArn = agentcoreOrchestratorArn;
