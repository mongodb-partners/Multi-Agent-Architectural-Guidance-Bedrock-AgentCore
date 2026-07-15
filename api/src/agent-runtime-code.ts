/**
 * AgentCore direct-code runtime entrypoint (Node.js 22).
 *
 * Implements AgentCore Runtime HTTP contract:
 *   GET  /ping
 *   POST /invocations    (responds with `text/event-stream`)
 *
 * This file is bundled to dist/agent-runtime-code.js and deployed as a
 * zip artifact through S3 codeConfiguration.
 *
 * Streaming wire format: see `lib/runtime-sse.ts`. Each invocation opens an
 * SSE response immediately, writes per-token `event: stream` frames as
 * Strands yields tokens, mirrors trace events live as `event: trace`, and
 * terminates with a single `event: done` frame carrying summary metadata.
 *
 * The orchestrator container's swarm classifier still picks a specialist,
 * then the specialist runtime is invoked with `Accept: text/event-stream`
 * and its frames are forwarded verbatim — so end-to-end TTFB equals the
 * specialist's first Bedrock token, not the buffered full reply.
 */

import http, { IncomingMessage, ServerResponse } from "node:http";
import { context, SpanKind, SpanStatusCode } from "@opentelemetry/api";
import {
  BedrockAgentCoreClient,
  InvokeAgentRuntimeCommand,
} from "@aws-sdk/client-bedrock-agentcore";
import { runChatStream } from "./lib/run-chat-stream.ts";
import { runSwarmChatStream } from "./lib/swarm-chat-stream.ts";
import {
  runMultiSpecialistFlow,
  type SpecialistInvoker,
} from "./lib/multi-specialist-orchestrator.ts";
import { logger } from "./lib/logger.ts";
import { assertEmbeddingsProvider } from "./lib/assert-embeddings-provider.ts";
import type { ChatMessage } from "./lib/session-store.ts";
import { withGatewayJwt } from "./lib/gateway-auth-context.ts";
import { TraceCollector, tracingEnabled } from "./lib/trace-collector.ts";
import { withTrace } from "./lib/trace-context.ts";
import type { ChatStreamPart } from "./lib/chat-stream-types.ts";
import {
  formatSseFrame,
  parseRuntimeSseStream,
  type RuntimeDonePayload,
} from "./lib/runtime-sse.ts";
import { runStartupPrewarm } from "./lib/prewarm.ts";
import { initOtel, extractContextFromCarrier, tracer, injectTraceContextToCarrier } from "./lib/otel.ts";
import { installStrandsConsoleRedirect } from "./lib/strands-console-redirect.ts";

const PORT = 8080;
const AGENT_ID = (process.env.AGENT_ID ?? "orchestrator").trim();

initOtel({ serviceName: "mongodb-multiagent-agent-runtime" });
installStrandsConsoleRedirect();

function getSpecialistArn(agentId: string): string | undefined {
  const safeAgentId = agentId.toUpperCase().replace(/[^A-Z0-9]+/g, "_");
  return process.env[`AGENTCORE_RUNTIME_ARN_${safeAgentId}`]?.trim() ||
    process.env[`AGENTCORE_${safeAgentId}_ARN`]?.trim() ||
    undefined;
}

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
 * Stream from a remote specialist runtime as if it were a local generator.
 *
 * Opens an `Accept: text/event-stream` invocation against the specialist's
 * AgentCore Runtime ARN, parses each frame, and forwards stream + trace
 * events to the caller. Trace events are mirrored into the orchestrator's
 * own collector via `forwardTrace` so the API receives them on the outer
 * SSE channel.
 */
/**
 * Invoke a specialist runtime and yield raw `RuntimeStreamEvent`s.
 *
 * The orchestrator runtime path uses this same shape as the API path's
 * `invokeAgentRuntime(...)` so they can both feed
 * `runMultiSpecialistFlow(...)` through one `SpecialistInvoker` interface.
 *
 * The wrapper `agentcore.invoke` span is created here on the orchestrator
 * runtime's collector and reported via `params.onWrapperSpan(spanId)`.
 */
async function* invokeSpecialistStream(
  specialistId: string,
  payload: {
    message: string;
    sessionId: string;
    priorTurns?: ChatMessage[];
    memoryContext?: string;
    userJwt?: string;
  },
  collector: TraceCollector | undefined,
  onWrapperSpan?: (spanId: string | undefined) => void,
): AsyncGenerator<import("./lib/runtime-sse.ts").RuntimeStreamEvent> {
  const arn = getSpecialistArn(specialistId);
  if (!arn) {
    throw new Error(
      `No ARN configured for specialist '${specialistId}'. ` +
        `Set AGENTCORE_RUNTIME_ARN_${specialistId.toUpperCase().replace(/-/g, "_")} on the orchestrator runtime.`,
    );
  }

  const runtimeSessionId = payload.sessionId.length >= 33
    ? payload.sessionId
    : payload.sessionId.padEnd(33, "0");

  const requestBody: Record<string, unknown> = {
    ...payload,
    agentId: specialistId,
    captureTrace: true,
  };
  const carrier: Record<string, string> = {};
  injectTraceContextToCarrier(carrier);
  if (Object.keys(carrier).length > 0) requestBody._trace = carrier;
  const requestPayload = JSON.stringify(requestBody);

  const wrapperId = collector?.start("agentcore.invoke", {
    arn,
    qualifier: "DEFAULT",
    runtimeSessionId,
    mode: "orchestrator_to_specialist",
    requestBytes: requestPayload.length,
    latencyMs: 0,
    targetAgentId: specialistId,
  });
  if (onWrapperSpan) {
    try {
      onWrapperSpan(wrapperId);
    } catch {
      // listener errors must never destabilize the runtime call
    }
  }

  const t0 = Date.now();
  let runtimeResponse;
  try {
    runtimeResponse = await getAcClient().send(
      new InvokeAgentRuntimeCommand({
        agentRuntimeArn: arn,
        runtimeSessionId,
        payload: requestPayload,
        contentType: "application/json",
        accept: "text/event-stream",
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

  const body = runtimeResponse.response;
  if (!body) {
    if (collector && wrapperId) {
      collector.end(wrapperId, {
        arn,
        mode: "orchestrator_to_specialist",
        targetAgentId: specialistId,
        latencyMs: Date.now() - t0,
        errorMessage: "empty response stream",
      });
    }
    throw new Error(`Empty response from specialist runtime '${specialistId}'`);
  }

  let bytesIn = 0;
  let lastDoneError: { code: string; message: string } | undefined;
  try {
    for await (const ev of parseRuntimeSseStream(body as AsyncIterable<Uint8Array>)) {
      if (ev.kind === "trace") bytesIn += JSON.stringify(ev.event).length;
      if (ev.kind === "done" && ev.payload.error) {
        lastDoneError = ev.payload.error;
      }
      yield ev;
    }
  } finally {
    const latencyMs = Date.now() - t0;
    if (collector && wrapperId) {
      collector.end(wrapperId, {
        arn,
        mode: "orchestrator_to_specialist",
        targetAgentId: specialistId,
        requestBytes: requestPayload.length,
        responseBytes: bytesIn,
        latencyMs,
        httpStatus: 200,
        ...(lastDoneError ? {
          errorClass: lastDoneError.code,
          errorMessage: lastDoneError.message,
        } : {}),
      });
    }
  }
}

async function* handleOrchestrator(
  message: string,
  sessionId: string,
  priorTurns: ChatMessage[] | undefined,
  memoryContext: string | undefined,
  collector: TraceCollector | undefined,
  forwardTrace: ((ev: import("./lib/trace-types.ts").TraceEvent) => void) | undefined,
  userJwt: string | undefined,
): AsyncGenerator<ChatStreamPart> {
  // Multi-specialist orchestration. Same helper as the Hono API path —
  // produces the same SSE/trace contract so `USE_ORCHESTRATOR_RUNTIME=1` is
  // externally indistinguishable from the production single-hop route.
  const invokeSpecialist: SpecialistInvoker = ({
    specialistId,
    message: msg,
    priorTurns: turns,
    memoryContext: ctx,
    onWrapperSpan,
  }) =>
    invokeSpecialistStream(
      specialistId,
      {
        message: msg,
        sessionId,
        priorTurns: turns,
        memoryContext: ctx,
        userJwt,
      },
      collector,
      onWrapperSpan,
    );

  const flow = runMultiSpecialistFlow({
    message,
    priorTurns,
    memoryContext,
    collector,
    invokeSpecialist,
  });

  while (true) {
    const next = await flow.next();
    if (next.done) {
      const result = next.value;
      logger.info("[runtime:orchestrator] multi-flow finished", {
        sessionId,
        pathTaken: result.pathTaken,
        successful: result.successfulSpecialists.length,
        failed: result.failedSpecialists.length,
      });
      // Fallback: classifier returned nothing. Try the legacy swarm
      // classifier as a last resort — only when there are zero successful
      // OR failed specialists (i.e. nothing was even attempted).
      if (
        result.pathTaken === "single" &&
        result.successfulSpecialists.length === 0 &&
        result.failedSpecialists.length === 0
      ) {
        let targetAgentId = "";
        let reasoning: string | undefined;
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
        if (targetAgentId && getSpecialistArn(targetAgentId)) {
          logger.info("[runtime:orchestrator] swarm-fallback routing", {
            sessionId,
            targetAgentId,
          });
          yield { type: "handoff", from: "orchestrator", to: targetAgentId, label: reasoning ?? "" };
          for await (const ev of invokeSpecialistStream(
            targetAgentId,
            { message, sessionId, priorTurns, memoryContext, userJwt },
            collector,
            undefined,
          )) {
            if (ev.kind === "stream") {
              yield ev.part;
            } else if (ev.kind === "trace") {
              forwardTrace?.(ev.event);
            }
          }
        }
      }
      return;
    }
    const ev = next.value;
    if (ev.kind === "specialist_started") {
      yield {
        type: "handoff",
        from: "orchestrator",
        to: ev.specialistId,
        label: `specialist ${ev.rank + 1} of multi-route`,
      };
      yield {
        type: "agent_active",
        agentId: ev.specialistId,
        agentName: ev.specialistName,
      };
    } else if (ev.kind === "specialist_stream") {
      yield ev.part;
    } else if (ev.kind === "specialist_trace") {
      forwardTrace?.(ev.event);
    } else if (ev.kind === "synthesis_started") {
      yield {
        type: "agent_active",
        agentId: "orchestrator",
        agentName: "Orchestrator",
      };
    } else if (ev.kind === "synthesis_stream") {
      yield ev.part;
    } else if (ev.kind === "stream_error") {
      yield { type: "stream_error", code: ev.code, message: ev.message };
    }
  }
}

async function* handleSpecialist(
  agentId: string,
  message: string,
  priorTurns: ChatMessage[] | undefined,
  memoryContext: string | undefined,
): AsyncGenerator<ChatStreamPart> {
  yield* runChatStream({ agentId, userMessage: message, priorTurns, memoryContext });
}

async function handleInvocations(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const text = await readRequestBody(req);

  type InvocationJson = {
    message: string;
    sessionId: string;
    agentId?: string;
    priorTurns?: ChatMessage[];
    memoryContext?: string;
    captureTrace?: boolean;
    userJwt?: string;
    _trace?: Record<string, string>;
  };

  let parsed: InvocationJson;
  try {
    parsed = JSON.parse(text) as InvocationJson;
  } catch {
    sendJson(res, 400, { error: "Invalid JSON payload" });
    return;
  }

  const { _trace: traceCarrier, ...rest } = parsed;
  const { message, sessionId, priorTurns, memoryContext, captureTrace, userJwt } = rest;
  if (!message?.trim()) {
    sendJson(res, 400, { error: "message is required" });
    return;
  }

  const parentCtx =
    traceCarrier && typeof traceCarrier === "object"
      ? extractContextFromCarrier(traceCarrier as Record<string, string | undefined>)
      : context.active();

  await context.with(parentCtx, async () => {
    await tracer().startActiveSpan(
      "runtime.invocation",
      {
        kind: SpanKind.SERVER,
        attributes: {
          "http.route": "/invocations",
          "agentcore.agent_id": AGENT_ID,
        },
      },
      async (span) => {
        const runtimeSessionId =
          (req.headers["x-amzn-bedrock-agentcore-runtime-session-id"] as string) ?? sessionId;
        logger.info("[runtime] invocation", {
          agentId: AGENT_ID,
          sessionId: runtimeSessionId,
          hasUserJwt: Boolean(userJwt),
          trace_id: span.spanContext().traceId,
        });

        const wantTrace = captureTrace !== false && tracingEnabled();
        const collector = wantTrace
          ? new TraceCollector({
              sessionId: runtimeSessionId,
              agentId: AGENT_ID,
              messageId: `runtime:${runtimeSessionId}`,
            })
          : undefined;
        if (collector) {
          span.setAttribute("trace.collector_id", collector.traceId);
        }
        const invocationStart = collector?.startTs ?? Date.now();

        res.statusCode = 200;
        res.setHeader("content-type", "text/event-stream");
        res.setHeader("cache-control", "no-cache, no-transform");
        res.setHeader("connection", "keep-alive");
        res.flushHeaders?.();
        collector?.event("latency.checkpoint", {
          name: "runtime.headers_flushed",
          elapsedMs: Date.now() - invocationStart,
          agentId: AGENT_ID,
        });

        const writeFrame = (event: string, data: unknown): void => {
          if (res.writableEnded) return;
          try {
            res.write(formatSseFrame(event, data));
          } catch (err) {
            logger.warn("[runtime] sse write failed", {
              agentId: AGENT_ID,
              error: err instanceof Error ? err.message : String(err),
            });
          }
        };

        const forwardTrace = (ev: import("./lib/trace-types.ts").TraceEvent): void => {
          writeFrame("trace", ev);
        };

        const unsubTrace = collector?.onEvent((ev) => writeFrame("trace", ev));

        const runScoped = <T,>(fn: () => Promise<T>): Promise<T> => {
          const wrapped = () => (collector ? withTrace(collector, fn) : fn());
          return Promise.resolve(withGatewayJwt(userJwt, wrapped));
        };

        const handoffs: string[] = [];
        let streamErrored: { code: string; message: string } | undefined;
        let firstStreamPartSent = false;
        let firstTokenSent = false;

        try {
          await runScoped(async () => {
            const generator =
              AGENT_ID === "orchestrator"
                ? handleOrchestrator(
                    message,
                    sessionId,
                    priorTurns,
                    memoryContext,
                    collector,
                    forwardTrace,
                    userJwt,
                  )
                : handleSpecialist(AGENT_ID, message, priorTurns, memoryContext);

            for await (const part of generator) {
              if (!firstStreamPartSent) {
                firstStreamPartSent = true;
                collector?.event("latency.checkpoint", {
                  name: "runtime.first_frame",
                  elapsedMs: Date.now() - invocationStart,
                  agentId: AGENT_ID,
                  partType: part.type,
                });
              }
              if (part.type === "token" && !firstTokenSent) {
                firstTokenSent = true;
                collector?.event("latency.checkpoint", {
                  name: "runtime.first_token",
                  elapsedMs: Date.now() - invocationStart,
                  agentId: AGENT_ID,
                });
              }
              if (part.type === "handoff") handoffs.push(part.to);
              if (part.type === "stream_error") {
                streamErrored = { code: part.code, message: part.message };
                writeFrame("stream", part);
                continue;
              }
              writeFrame("stream", part);
            }
          });
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          const klass = err instanceof Error ? err.constructor.name : "Error";
          logger.error("[runtime] invocation failed", { agentId: AGENT_ID, error: msg });
          collector?.event("error", { class: klass, message: msg, source: "runtime.invocation" });
          streamErrored = { code: "RUNTIME_INVOCATION_FAILED", message: msg };
          span.setStatus({
            code: SpanStatusCode.ERROR,
            message: msg,
          });
        } finally {
          unsubTrace?.();
          const donePayload: RuntimeDonePayload = {
            agentId: AGENT_ID,
            handoffs: handoffs.length ? handoffs : undefined,
            nestedTraceId: collector?.toJSON().traceId,
            nestedEventsDropped: collector?.toJSON().eventsDropped,
            error: streamErrored,
          };
          writeFrame("done", donePayload);
          res.end();
          span.setAttribute("http.response.status_code", res.statusCode);
          span.end();
        }
      },
    );
  });
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

// Pre-warm cold dependencies so the first invocation does not pay the
// MongoDB TLS handshake + MCP listTools + per-agent template build on the
// user's clock. Failures here are logged but never block boot.
void runStartupPrewarm({ source: `runtime:${AGENT_ID}` });

server.listen(PORT, "0.0.0.0", () => {
  logger.info(`[runtime] AgentCore direct-code runtime agent=${AGENT_ID} listening on :${PORT}`);
});
