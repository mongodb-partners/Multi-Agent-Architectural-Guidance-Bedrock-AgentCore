import { Hono } from "hono";
import { streamSSE } from "hono/streaming";
import { z } from "zod";
import { getAgent } from "../lib/config-scan.ts";
import {
  appendAssistantMessage,
  appendUserMessage,
  FORBIDDEN_SESSION,
  getSession,
  setLastTraceId,
} from "../lib/session-store.ts";
import {
  tryReadShortTermMessages,
  tryWriteShortTermAssistantMessage,
  tryWriteShortTermUserMessage,
  useAgentcoreShortTermMemory,
} from "../lib/short-term-memory.ts";
import {
  readLongTermMemoryContext,
  writeLongTermMemory,
} from "../lib/long-term-memory.ts";
import { logger } from "../lib/logger.ts";
import {
  invokeAgentRuntime,
  agentcoreSpecialistArn,
} from "../adapters/agentcore-runtime.ts";
import { enrichVectorSearchTraceEvents } from "../adapters/mongodb-mcp-client.ts";
import { buildAuthenticatedUserContext } from "../lib/auth-user-context.ts";
import { TraceCollector, tracingEnabled } from "../lib/trace-collector.ts";
import { recordChatTurn } from "../lib/cw-metrics.ts";
import { withTrace } from "../lib/trace-context.ts";
import { withGatewayJwt } from "../lib/gateway-auth-context.ts";
import { withCurrentUserId } from "../lib/user-id-context.ts";
import { persistTrace } from "../lib/trace-store.ts";
import {
  runMultiSpecialistFlow,
  type SpecialistInvoker,
} from "../lib/multi-specialist-orchestrator.ts";
import { runOrchestratorClarification } from "../lib/orchestrator-clarify.ts";
import type { TraceEvent } from "../lib/trace-types.ts";

const bodySchema = z.object({
  message: z.string().min(1),
  sessionId: z.string().min(1),
  agentId: z.string().optional(),
});

export const chatRoutes = new Hono();

/** True when the orchestrator runtime hop should be used. Defaults to false
 *  so direct-routing is the production path; set USE_ORCHESTRATOR_RUNTIME=1
 *  to roll back to the Phase 1 behavior (orchestrator runtime classifies +
 *  forwards). */
function useOrchestratorRuntime(): boolean {
  const v = process.env.USE_ORCHESTRATOR_RUNTIME?.trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

chatRoutes.post("/chat", async (c) => {
  let body: z.infer<typeof bodySchema>;
  try {
    const json = await c.req.json();
    body = bodySchema.parse(json);
  } catch {
    return c.json(
      {
        error: {
          code: "INVALID_REQUEST",
          message: "Expected JSON body with non-empty message and sessionId.",
          requestId: c.get("requestId"),
        },
      },
      400,
    );
  }

  const requestedAgentId = body.agentId ?? "orchestrator";
  const requestedAgent = getAgent(requestedAgentId);
  if (!requestedAgent) {
    return c.json(
      {
        error: {
          code: "AGENT_NOT_FOUND",
          message: `No agent with id '${requestedAgentId}' exists.`,
          requestId: c.get("requestId"),
        },
      },
      404,
    );
  }

  const userId = c.get("jwtPayload")?.sub;
  if (!userId) {
    // Should be unreachable — authMiddleware guarantees a verified JWT before we reach this
    // handler. Return 401 defensively in case the middleware is mis-wired.
    return c.json(
      {
        error: {
          code: "UNAUTHORIZED",
          message: "Authenticated user required.",
          requestId: c.get("requestId"),
        },
      },
      401,
    );
  }
  const useAgentcoreShortTerm = useAgentcoreShortTermMemory(userId);
  const sessionLookup = await getSession(body.sessionId, userId);
  if (sessionLookup === FORBIDDEN_SESSION) {
    return c.json(
      {
        error: {
          code: "SESSION_NOT_FOUND",
          message: `No session with id '${body.sessionId}' exists.`,
          requestId: c.get("requestId"),
        },
      },
      404,
    );
  }
  let priorTurns;
  if (useAgentcoreShortTerm) {
    const acTurns = await tryReadShortTermMessages(body.sessionId, userId);
    priorTurns = acTurns.length > 0 ? acTurns : sessionLookup ? sessionLookup.messages : [];
  } else {
    priorTurns = sessionLookup ? sessionLookup.messages : [];
  }

  const appended = await appendUserMessage(body.sessionId, body.message, userId);
  if (appended === FORBIDDEN_SESSION) {
    return c.json(
      {
        error: {
          code: "SESSION_NOT_FOUND",
          message: `No session with id '${body.sessionId}' exists.`,
          requestId: c.get("requestId"),
        },
      },
      404,
    );
  }
  if (useAgentcoreShortTerm) {
    await tryWriteShortTermUserMessage(body.sessionId, userId, body.message);
  }

  // Per-turn tracing — one TraceCollector per chat turn, replayed as SSE `trace`.
  // Create it before auth/memory context so those lookups are persisted too.
  const messageId = `msg_${crypto.randomUUID().slice(0, 12)}`;
  const requestId = c.get("requestId");
  const reqLog = logger.child({
    requestId,
    userId,
    sessionId: body.sessionId,
    requestedAgent: requestedAgentId,
  });

  const tracingOn = tracingEnabled();
  reqLog.info("[chat] turn start", {
    messageLen: body.message.length,
    tracing: tracingOn,
  });
  const collector = tracingOn
    ? new TraceCollector({
        sessionId: body.sessionId,
        messageId,
        agentId: requestedAgentId,
        userId,
        requestId,
      })
    : undefined;

  // Populate release + correlation metadata on the collector right away so
  // `toJSON()` always carries them. Auth headers are *not* recorded; only an
  // allow-listed subset of inbound headers ends up in the trace doc. The dev
  // panel's "copy curl to reproduce" block reads from `chat.turn.start.
  // requestHeadersPreview`; SOC2-relevant correlation lands on `trace.correlation`.
  if (collector) {
    collector.setRelease({
      gitSha: process.env.GIT_SHA?.trim() || undefined,
      deployTs: process.env.DEPLOY_TS?.trim() || undefined,
      nodeVersion: process.versions.node,
      bunVersion: typeof Bun !== "undefined" ? Bun.version : undefined,
      env: process.env.DEPLOY_ENV?.trim() || process.env.NODE_ENV?.trim() || undefined,
    });
    collector.setCorrelation({
      requestId,
      apiClientIp:
        c.req.raw.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
        c.req.raw.headers.get("x-real-ip") ||
        undefined,
      userAgent: c.req.raw.headers.get("user-agent") || undefined,
    });
  }

  // Build auth + memory context. The two lookups are independent — run them
  // in parallel so we shave one RTT off TTFB compared to awaiting each in
  // sequence. Long-term memory is retrieved via hybrid vector + lexical
  // search against `agent_memory_facts` and `chat_messages` in a single
  // direct-Mongo call (see `readLongTermMemoryContext` in
  // `lib/long-term-memory.ts`).
  let memoryContext: string | undefined;
  if (userId) {
    const contextUserId = userId;
    const contextAgent = requestedAgent;
    const buildContext = async (): Promise<void> => {
      const wantsScoped = Boolean(contextAgent.memory?.longTerm);
      const [authCtx, ltm] = await Promise.all([
        buildAuthenticatedUserContext(
          contextUserId,
          c.get("jwtPayload"),
          c.get("bearerToken"),
        ),
        wantsScoped
          ? readLongTermMemoryContext(contextUserId, body.message, {
              agentId: requestedAgentId,
              sessionId: body.sessionId,
              priorTurns,
            })
          : Promise.resolve(null),
      ]);

      const blocks: string[] = [];
      if (authCtx) blocks.push(authCtx);
      if (wantsScoped && ltm) {
        blocks.push(`## Relevant prior context\n\n${ltm}`);
        reqLog.debug("[chat] injecting long-term memory", {
          userId,
          agentId: requestedAgentId,
        });
      }
      if (blocks.length > 0) memoryContext = blocks.join("\n\n");
    };
    await (collector ? withTrace(collector, buildContext) : buildContext());
  }

  reqLog.info("[chat] memory phase done", {
    hasMemoryContext: Boolean(memoryContext),
    memoryBytes: memoryContext ? Buffer.byteLength(memoryContext, "utf8") : 0,
  });

  // Routing.
  //
  // Three paths:
  //   1. `orchestrator` + `!USE_ORCHESTRATOR_RUNTIME`  → multi-specialist
  //      orchestration runs IN-API (inside streamSSE below). Classification
  //      and specialist invocation are handled by `runMultiSpecialistFlow`.
  //   2. `orchestrator` + `USE_ORCHESTRATOR_RUNTIME=1` → fall through to the
  //      orchestrator AgentCore Runtime (rollback path). The runtime
  //      container's `handleOrchestrator` does its own classification.
  //   3. Explicit specialist agent id → invoke that specialist's runtime
  //      directly. No classifier hop.
  //
  // `routeAgentId` is the *current* agent for SSE `agent_info` and trace
  // turn start. For path (1) it stays `"orchestrator"` because the multi
  // flow runs under the orchestrator persona; specialist activation events
  // are emitted by the flow as it iterates ranked specialists.
  const useMultiSpecialistOrchestrator =
    requestedAgentId === "orchestrator" && !useOrchestratorRuntime();
  let routeAgentId = requestedAgentId;
  let runtimeArn: string | undefined;
  let invokeMode: "ec2_to_orchestrator" | "ec2_to_specialist" = "ec2_to_orchestrator";

  if (!useMultiSpecialistOrchestrator && requestedAgentId !== "orchestrator") {
    const specialistArn = agentcoreSpecialistArn(requestedAgentId);
    if (specialistArn) {
      runtimeArn = specialistArn;
      invokeMode = "ec2_to_specialist";
    }
  }

  return streamSSE(c, async (stream) => {
    // Trace event subscription. Throttle high-volume `model.text_delta_batch`
    // forwarding so the SSE channel never contends with token frames; the
    // full batch still lands in the persisted trace via the collector. Other
    // event types are forwarded immediately. Subscribe BEFORE the first
    // event fires so chat.turn.start is captured.
    const TRACE_THROTTLE_MS = Number(process.env.TRACE_SSE_THROTTLE_MS ?? 100);
    let lastDeltaForwardTs = 0;
    const unsubTrace = collector?.onEvent(async (ev) => {
      if (stream.aborted) return;
      if (ev.type === "model.text_delta_batch") {
        const now = Date.now();
        if (now - lastDeltaForwardTs < TRACE_THROTTLE_MS) return;
        lastDeltaForwardTs = now;
      }
      try {
        await stream.writeSSE({ event: "trace", data: JSON.stringify(ev) });
      } catch {
        // Stream may have closed; swallow to avoid destabilizing the collector.
      }
    });

    collector?.event("chat.turn.start", {
      sessionId: body.sessionId,
      messageId,
      agentId: routeAgentId,
      userId,
      requestId,
      startTs: Date.now(),
      requestHeadersPreview: previewRequestHeaders(c.req.raw.headers),
    });
    // One-shot Environment snapshot for the Developer details panel. Cheap,
    // fixed-size; surfaces "why is this turn behaving like a mock" without
    // the dev having to grep ENV in process logs.
    collector?.emitEnvironment();
    collector?.event("latency.checkpoint", {
      name: "api.stream.opened",
      elapsedMs: collector ? Date.now() - collector.startTs : 0,
      agentId: routeAgentId,
    });

    // Scope the caller's JWT and verified userId for the entire turn so:
    //  - AgentCore Runtime forwards the JWT (as `userJwt`)
    //  - In-process MCP transport injects it as `Authorization: Bearer <jwt>`
    //  - MongoDB MCP callTool wrapper injects jwt.sub into every query filter
    const bearerToken = c.get("bearerToken") as string | undefined;
    const runWithTrace = <T>(fn: () => Promise<T>): Promise<T> => {
      const traced = () => (collector ? withTrace(collector, fn) : fn());
      const withJwt = () => withGatewayJwt(bearerToken, traced);
      return Promise.resolve(withCurrentUserId(userId, withJwt));
    };

    await runWithTrace(async () => {
      await stream.writeSSE({
        event: "agent_info",
        data: JSON.stringify({ agentId: routeAgentId, agentName: requestedAgent.name }),
      });

      let fullReply = "";
      /**
       * `finalAgentId` is the agentId persisted with the assistant message
       * and used by `setFinalAgentId(...)` for the trace summary. For the
       * single-specialist fast path it becomes the routed specialist; for
       * the synthesis path it stays `"orchestrator"` (the synthesizer agent
       * is an internal construct — the user-visible final answer agent
       * remains the orchestrator).
       */
      let finalAgentId = routeAgentId;
      let streamFailed: { code: string; message: string } | undefined;
      // True once the orchestrator has streamed a clarification reply (vague
      // message path). The clarification text is accumulated directly into
      // `fullReply`, so the generator's empty `finalAnswer` must not overwrite it.
      let clarificationEmitted = false;
      const handoffsSeen: string[] = [];
      const nestedTraceEvents: TraceEvent[] = [];
      let nestedTraceId: string | undefined;
      let nestedEventsDropped = 0;
      let firstClientTokenSent = false;

      // SSE keepalive heartbeat — writes a `: keepalive` comment frame every
      // SSE_KEEPALIVE_MS while waiting on the AgentCore Runtime invocation.
      // SSE comments (lines starting with `:`) are silently ignored by every
      // conformant client (browser EventSource, Streamlit, curl -N, our smoke
      // parse_sse), but they keep the TCP connection warm. Without this,
      // cold-start runtime invokes (60-150s of silence between the initial
      // `handoff`/`agent_info` burst and the final nested-trace flush) get
      // their connection dropped by AWS NLB / NAT / ISP idle timeouts (some as
      // low as 60s), and downstream clients see `IncompleteRead` even though
      // the server completed successfully. The interval is cleared in
      // `finally` so it can't outlive the request.
      const SSE_KEEPALIVE_MS = Number(process.env.SSE_KEEPALIVE_MS ?? 15000);
      let keepaliveTimer: ReturnType<typeof setInterval> | undefined;
      if (SSE_KEEPALIVE_MS > 0) {
        keepaliveTimer = setInterval(() => {
          if (stream.aborted || stream.closed) return;
          // stream.write writes raw bytes; SSE comment line + double-newline
          // is a complete frame that browsers / curl treat as a no-op.
          stream.write(`: keepalive ${Date.now()}\n\n`).catch(() => {
            // Client closed mid-heartbeat; let the main loop detect it.
          });
        }, SSE_KEEPALIVE_MS);
      }

      // Helper: forward a runtime trace event to the UI's SSE `trace`
      // channel. Used by both the single-runtime path and the multi-flow's
      // specialist trace pipe.
      const forwardRuntimeTrace = async (ev: TraceEvent): Promise<void> => {
        nestedTraceEvents.push(ev);
        const enrichedNested = enrichVectorSearchTraceEvents(nestedTraceEvents);
        nestedTraceEvents.length = 0;
        nestedTraceEvents.push(...(enrichedNested as TraceEvent[]));
        const traceToForward = enrichedNested[enrichedNested.length - 1] ?? ev;
        if (traceToForward.type === "model.text_delta_batch") {
          const now = Date.now();
          if (now - lastDeltaForwardTs < TRACE_THROTTLE_MS) return;
          lastDeltaForwardTs = now;
        }
        if (!stream.aborted) {
          try {
            await stream.writeSSE({ event: "trace", data: JSON.stringify(traceToForward) });
          } catch {
            // Client closed; persistence below still runs.
          }
        }
      };

      try {
        reqLog.info("[chat] routing to AgentCore Runtime", {
          agentId: routeAgentId,
          requestId,
          mode: invokeMode,
          hasRuntimeOverride: Boolean(runtimeArn),
          useMultiSpecialistOrchestrator,
          traceCollectorId: collector?.traceId,
          sseKeepaliveMs: SSE_KEEPALIVE_MS,
        });

        if (useMultiSpecialistOrchestrator) {
          // Multi-specialist orchestration. The helper:
          //   - classifies the message via `classifyAgents(...)`
          //   - sequentially invokes each ranked specialist using the
          //     adapter below (`invokeSpecialist`)
          //   - emits `orchestrator.multi_route_decision`, per-specialist
          //     `orchestrator.specialist_draft`, and (multi path only)
          //     `orchestrator.synthesis` trace events
          //   - on the single-specialist fast path, the specialist's
          //     tokens become the persisted assistant message
          //   - on the synthesis path, the synthesizer agent's tokens are
          //     persisted instead, and specialist tokens carry
          //     `phase: "specialist"` so the UI renders them as drafts only
          const invokeSpecialist: SpecialistInvoker = ({
            specialistId,
            message,
            priorTurns: turns,
            memoryContext: ctx,
            onWrapperSpan,
          }) => {
            const arn = agentcoreSpecialistArn(specialistId);
            if (!arn) {
              throw new Error(
                `No runtime ARN configured for specialist '${specialistId}'.`,
              );
            }
            return invokeAgentRuntime({
              message,
              agentId: specialistId,
              sessionId: body.sessionId,
              priorTurns: turns,
              memoryContext: ctx,
              userJwt: bearerToken,
              runtimeArn: arn,
              invokeMode: "ec2_to_specialist",
              onWrapperSpan,
            });
          };

          const flow = runMultiSpecialistFlow({
            message: body.message,
            priorTurns,
            memoryContext,
            collector,
            invokeSpecialist,
          });

          while (true) {
            const next = await flow.next();
            if (next.done) {
              const result = next.value;
              // On the clarification path the reply was already accumulated into
              // `fullReply` and `finalAgentId` set to "orchestrator"; the
              // generator returns an empty `finalAnswer`, so don't clobber it.
              if (clarificationEmitted) {
                break;
              }
              fullReply = result.finalAnswer;
              // The persisted assistant agentId is `"orchestrator"` on the
              // synthesis path (the user-visible final answer agent) and
              // the routed specialist on the single-specialist fast path.
              if (result.pathTaken === "single") {
                const single = result.successfulSpecialists[0]
                  ?? result.failedSpecialists[0];
                if (single) {
                  finalAgentId = single.agentId;
                  handoffsSeen.push(single.agentId);
                }
              } else {
                finalAgentId = "orchestrator";
              }
              break;
            }
            const ev = next.value;
            if (ev.kind === "specialist_started") {
              // Emit handoff + agent_active so the UI can render an
              // attributed draft block immediately.
              handoffsSeen.push(ev.specialistId);
              await stream.writeSSE({
                event: "handoff",
                data: JSON.stringify({
                  from: "orchestrator",
                  to: ev.specialistId,
                  label: `specialist ${ev.rank + 1} of multi-route`,
                }),
              });
              await stream.writeSSE({
                event: "agent_active",
                data: JSON.stringify({
                  agentId: ev.specialistId,
                  agentName: ev.specialistName,
                }),
              });
            } else if (ev.kind === "specialist_stream") {
              const part = ev.part;
              if (part.type === "token") {
                if (collector && !firstClientTokenSent) {
                  firstClientTokenSent = true;
                  collector.event("latency.checkpoint", {
                    name: "api.client.first_token",
                    elapsedMs: Date.now() - collector.startTs,
                    agentId: ev.specialistId,
                  });
                }
                // Phase metadata rides along on the SSE token frame so
                // the UI can render specialist drafts vs final answer.
                await stream.writeSSE({
                  event: "token",
                  data: JSON.stringify({
                    text: part.text,
                    ...(part.phase ? { phase: part.phase } : {}),
                    ...(part.specialistId ? { specialistId: part.specialistId } : {}),
                    ...(part.specialistName ? { specialistName: part.specialistName } : {}),
                    ...(part.rank !== undefined ? { rank: part.rank } : {}),
                  }),
                });
              } else if (part.type === "skill_loaded") {
                await stream.writeSSE({
                  event: "skill_loaded",
                  data: JSON.stringify({ skillName: part.skillName }),
                });
              } else if (part.type === "tool_call") {
                await stream.writeSSE({
                  event: "tool_call",
                  data: JSON.stringify({ tool: part.tool, status: part.status }),
                });
              } else if (part.type === "agent_active") {
                await stream.writeSSE({
                  event: "agent_active",
                  data: JSON.stringify({ agentId: part.agentId, agentName: part.agentName }),
                });
              } else if (part.type === "handoff") {
                handoffsSeen.push(part.to);
                await stream.writeSSE({
                  event: "handoff",
                  data: JSON.stringify({ from: part.from, to: part.to, label: part.label }),
                });
              } else if (part.type === "stream_error") {
                // Handled by helper's `specialist_ended.failure`; we don't
                // emit a top-level error here because other specialists or
                // the synthesizer might still produce a usable answer.
              }
            } else if (ev.kind === "specialist_trace") {
              await forwardRuntimeTrace(ev.event);
            } else if (ev.kind === "specialist_ended") {
              // Trace already emitted by helper; nothing UI-visible here.
            } else if (ev.kind === "synthesis_started") {
              // Signal the UI that the synthesis phase is starting. We
              // reuse `agent_active` with `agentId: "orchestrator"` so
              // existing UI handlers know to start a new live block.
              await stream.writeSSE({
                event: "agent_active",
                data: JSON.stringify({
                  agentId: "orchestrator",
                  agentName: requestedAgent.name,
                }),
              });
            } else if (ev.kind === "synthesis_stream") {
              const part = ev.part;
              if (part.type === "token") {
                if (collector && !firstClientTokenSent) {
                  firstClientTokenSent = true;
                  collector.event("latency.checkpoint", {
                    name: "api.client.first_token",
                    elapsedMs: Date.now() - collector.startTs,
                    agentId: "orchestrator",
                  });
                }
                await stream.writeSSE({
                  event: "token",
                  data: JSON.stringify({
                    text: part.text,
                    ...(part.phase ? { phase: part.phase } : {}),
                  }),
                });
              }
            } else if (ev.kind === "synthesis_ended") {
              // Trace already emitted by helper; nothing UI-visible here.
            } else if (ev.kind === "needs_clarification") {
              // Vague / low-signal message: the classifier abstained. The
              // orchestrator asks the customer to clarify instead of
              // force-routing to a specialist. This is a normal (non-error)
              // turn — the orchestrator's reply IS the persisted answer.
              clarificationEmitted = true;
              finalAgentId = "orchestrator";
              await stream.writeSSE({
                event: "agent_active",
                data: JSON.stringify({
                  agentId: "orchestrator",
                  agentName: requestedAgent.name,
                }),
              });
              for await (const part of runOrchestratorClarification({
                userMessage: body.message,
                priorTurns,
                memoryContext,
              })) {
                if (part.type === "token") {
                  fullReply += part.text;
                  if (collector && !firstClientTokenSent) {
                    firstClientTokenSent = true;
                    collector.event("latency.checkpoint", {
                      name: "api.client.first_token",
                      elapsedMs: Date.now() - collector.startTs,
                      agentId: "orchestrator",
                    });
                  }
                  await stream.writeSSE({
                    event: "token",
                    data: JSON.stringify({ text: part.text }),
                  });
                }
              }
            } else if (ev.kind === "stream_error") {
              streamFailed = { code: ev.code, message: ev.message };
              await stream.writeSSE({
                event: "error",
                data: JSON.stringify({ code: ev.code, message: ev.message, requestId }),
              });
            }
          }
        } else {
          // Single-runtime path (specialist direct or USE_ORCHESTRATOR_RUNTIME=1).
          for await (const ev of invokeAgentRuntime({
            message: body.message,
            agentId: routeAgentId,
            sessionId: body.sessionId,
            priorTurns,
            memoryContext,
            userJwt: bearerToken,
            runtimeArn,
            invokeMode,
          })) {
            if (ev.kind === "stream") {
              const part = ev.part;
              if (part.type === "token") {
                fullReply += part.text;
                if (collector && !firstClientTokenSent) {
                  firstClientTokenSent = true;
                  collector.event("latency.checkpoint", {
                    name: "api.client.first_token",
                    elapsedMs: Date.now() - collector.startTs,
                    agentId: routeAgentId,
                  });
                  reqLog.debug("[chat] first token to client", { agentId: routeAgentId });
                }
                await stream.writeSSE({
                  event: "token",
                  data: JSON.stringify({ text: part.text }),
                });
              } else if (part.type === "handoff") {
                handoffsSeen.push(part.to);
                await stream.writeSSE({
                  event: "handoff",
                  data: JSON.stringify({ from: part.from, to: part.to, label: part.label }),
                });
              } else if (part.type === "agent_active") {
                await stream.writeSSE({
                  event: "agent_active",
                  data: JSON.stringify({ agentId: part.agentId, agentName: part.agentName }),
                });
              } else if (part.type === "skill_loaded") {
                await stream.writeSSE({
                  event: "skill_loaded",
                  data: JSON.stringify({ skillName: part.skillName }),
                });
              } else if (part.type === "tool_call") {
                await stream.writeSSE({
                  event: "tool_call",
                  data: JSON.stringify({ tool: part.tool, status: part.status }),
                });
              } else if (part.type === "stream_error") {
                streamFailed = { code: part.code, message: part.message };
                await stream.writeSSE({
                  event: "error",
                  data: JSON.stringify({ code: part.code, message: part.message, requestId }),
                });
              }
            } else if (ev.kind === "trace") {
              await forwardRuntimeTrace(ev.event);
            } else if (ev.kind === "done") {
              nestedTraceId = ev.payload.nestedTraceId;
              nestedEventsDropped = ev.payload.nestedEventsDropped ?? 0;
              if (ev.payload.error && !streamFailed) {
                streamFailed = ev.payload.error;
                await stream.writeSSE({
                  event: "error",
                  data: JSON.stringify({
                    code: ev.payload.error.code,
                    message: ev.payload.error.message,
                    requestId,
                  }),
                });
              }
            }
          }
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        const klass = err instanceof Error ? err.name : "Error";
        const stack = err instanceof Error ? err.stack : undefined;
        reqLog.error("[chat] AgentCore Runtime error", { requestId, agentId: routeAgentId, error: message });
        streamFailed = { code: "AGENTCORE_RUNTIME_ERROR", message };
        collector?.event("error", {
          class: klass,
          message,
          stack,
          source: "agentcore.invoke",
        });
        await stream.writeSSE({
          event: "error",
          data: JSON.stringify({ code: "AGENTCORE_RUNTIME_ERROR", message, requestId }),
        });
      } finally {
        if (keepaliveTimer) clearInterval(keepaliveTimer);
      }

      // Persistence and trace splice run AFTER the stream is fully relayed
      // so they never sit on the user's TTFB clock. The `done` SSE frame
      // fires next; long-term memory + persistTrace are dispatched as
      // dangling promises so they don't hold the response open either.
      //
      // Multi-orchestrator path: per-specialist nested events are already
      // attached under each specialist's wrapper span by the helper. We
      // only fall through to the legacy single-wrapper attachment for the
      // single-runtime branch.
      if (
        collector &&
        !useMultiSpecialistOrchestrator &&
        nestedTraceEvents.length > 0
      ) {
        const wrapperId = findOutermostAgentcoreInvokeId(collector);
        if (wrapperId) {
          collector.attachEventsNested(nestedTraceEvents, wrapperId, {
            nestedEventsDropped,
            logger: { warn: (msg, ctx) => reqLog.warn(msg, ctx as Record<string, unknown> | undefined) },
          });
          collector.event("agentcore.nested_trace", {
            nestedTraceId,
            nestedRuntimeArn: runtimeArn,
            eventCount: nestedTraceEvents.length,
            nestedEventsDropped,
          });
        }
      }

      // Persist the assistant message synchronously (small Mongo write; we
      // need the messageId before emitting `done` so the client can deep-link).
      // The persisted agent id is `finalAgentId`:
      //   - synthesis path → `"orchestrator"` (the user-visible final agent)
      //   - single-specialist fast path → the routed specialist
      //   - explicit specialist or USE_ORCHESTRATOR_RUNTIME=1 → `routeAgentId`
      if (!streamFailed) {
        await appendAssistantMessage(body.sessionId, fullReply, finalAgentId, userId);
        if (useAgentcoreShortTerm && fullReply.trim()) {
          await tryWriteShortTermAssistantMessage(body.sessionId, userId, fullReply, finalAgentId);
        }
        reqLog.info("[chat] assistant persisted", {
          messageId,
          replyBytes: Buffer.byteLength(fullReply, "utf8"),
          finalAgentId,
        });
      }

      reqLog.info("[chat] runtime stream relay complete", {
        streamFailed: Boolean(streamFailed),
        nestedTraceEvents: nestedTraceEvents.length,
        useMultiSpecialistOrchestrator,
      });
      if (collector) {
        collector.recordBytesIn(Buffer.byteLength(body.message, "utf8"));
        collector.recordBytesOut(Buffer.byteLength(fullReply, "utf8"));
        collector.setFinalAgentId(finalAgentId);
        const durationMs = Date.now() - collector.startTs;
        collector.event("chat.turn.end", {
          durationMs,
          summary: collector.summary(),
        });
        try {
          recordChatTurn({
            agentId: finalAgentId,
            latencyMs: durationMs,
            error: Boolean(streamFailed),
            errorClass: typeof streamFailed === "string" ? streamFailed : undefined,
          });
        } catch {
          // metric emission must never destabilize the chat turn
        }
      }

      // Persist BEFORE `done` so any client that immediately reads
      // `/sessions/:id` or `/traces/:traceId` sees a consistent state:
      //   - setLastTraceId tags the assistant message → /sessions visible.
      //   - persistTrace populates the in-memory ring buffer synchronously
      //     and the Mongo `traces` doc (fast: ~10-30ms warm replaceOne).
      // Long-tail Bedrock Haiku fact extraction stays dangling — that's
      // the only call slow enough to be worth deferring past `done`.
      if (collector) {
        const traceJson = collector.toJSON();
        try {
          await setLastTraceId(body.sessionId, messageId, collector.traceId);
        } catch (e) {
          reqLog.warn("[chat] setLastTraceId failed", {
            error: e instanceof Error ? e.message : String(e),
          });
        }
        try {
          await persistTrace(traceJson);
        } catch (e) {
          reqLog.warn("[chat] trace persistence failed", {
            traceId: collector.traceId,
            error: e instanceof Error ? e.message : String(e),
          });
        }
        reqLog.info("[chat] trace store finished", { traceId: collector.traceId });
      }
      await stream.writeSSE({
        event: "done",
        data: JSON.stringify({
          sessionId: body.sessionId,
          messageId,
          traceId: collector?.traceId,
          ...(streamFailed ? { error: streamFailed } : {}),
        }),
      });

      // Dangling fact extraction: Bedrock Haiku call + Mongo write. Stays
      // off the user's clock — errors are logged but never block.
      //
      // The collector outlives this request via AsyncLocalStorage closure, so
      // any `memory.long_term_write` / `memory.long_term_skip` events emitted
      // by writeLongTermMemory still land on it. The trace was already
      // persisted above (before `done`), so without a second persistTrace
      // those events would never make it into the stored doc. Re-persist
      // after the write settles. `persistTrace` is an upsert, so this is
      // idempotent and safe to retry even if the first call also succeeded.
      if (!streamFailed && fullReply.trim()) {
        const userMessage = body.message;
        const reply = fullReply;
        const liveCollector = collector;
        // LTM is keyed by (userId, agentId). We write under `finalAgentId`
        // so future turns recall the cohesive answer (orchestrator on the
        // synthesis path; the single specialist on the fast path).
        const ltmAgentId = finalAgentId;
        queueMicrotask(() => {
          void writeLongTermMemory(userId, ltmAgentId, userMessage, reply)
            .catch((e) => {
              reqLog.warn("[chat] writeLongTermMemory failed", {
                error: e instanceof Error ? e.message : String(e),
              });
            })
            .finally(() => {
              if (!liveCollector) return;
              const updated = liveCollector.toJSON();
              persistTrace(updated).catch((e) => {
                reqLog.warn("[chat] post-write trace re-persist failed", {
                  traceId: liveCollector.traceId,
                  error: e instanceof Error ? e.message : String(e),
                });
              });
            });
        });
      }
    });

    unsubTrace?.();
  });
});

/** Inbound headers safe to embed in the trace doc for the Developer details
 *  "copy curl to reproduce" block. Auth-bearing headers are *not* listed;
 *  they're redacted to `***` on the off chance the allow list grows. */
const HEADER_ALLOW_LIST = new Set([
  "x-request-id",
  "user-agent",
  "x-forwarded-for",
  "accept",
  "content-length",
]);

function previewRequestHeaders(headers: Headers): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of headers.entries()) {
    const lower = k.toLowerCase();
    if (HEADER_ALLOW_LIST.has(lower)) {
      out[lower] = v;
    } else if (lower === "authorization" || lower === "cookie") {
      out[lower] = "***";
    }
  }
  return out;
}

/** Locate the most recent `agentcore.invoke` SPAN id on the collector so we
 *  can splice nested runtime trace events under it. The adapter creates
 *  exactly one wrapper per `invokeAgentRuntime` call within a turn.
 *
 *  Implementation notes:
 *
 *  - `start("agentcore.invoke", …)` emits an event whose `id` IS the span id
 *    (with `durationMs === undefined`). That event stays in the collector's
 *    list permanently — `end()` does NOT remove it; it appends a SECOND
 *    event with a fresh uuid + `parentId: spanId` + `durationMs` set. So
 *    the open-vs-closed distinction is NOT what determines whether the
 *    span id is recoverable; the start event is always there.
 *
 *  - We must return the start event's id (the span id), not the end event's
 *    fresh uuid. `attachEventsNested` calls `events.find(e => e.id === wrapperId)`
 *    and uses the start event's ts as the wrapper-start clock for the
 *    nested-trace tsOffset calculation. Returning the end event's uuid
 *    would point at the wrong event and shift the entire nested trace by
 *    `(endTs - startTs)` ms.
 *
 *  Pinned by api/tests/unit/chat-find-outermost-agentcore-invoke.test.ts. */
export function findOutermostAgentcoreInvokeId(collector: TraceCollector): string | undefined {
  const events = collector.getEvents();
  for (let i = events.length - 1; i >= 0; i--) {
    const ev = events[i];
    // `durationMs === undefined` distinguishes the START event (which carries
    // the span id) from the synthetic END event (fresh uuid). Both share
    // `type: "agentcore.invoke"`.
    if (ev.type === "agentcore.invoke" && ev.durationMs === undefined) {
      return ev.id;
    }
  }
  return undefined;
}
