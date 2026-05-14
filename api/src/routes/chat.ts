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
  readLongTermMemory,
  readSharedLongTermMemory,
  writeLongTermMemory,
} from "../lib/long-term-memory.ts";
import { logger } from "../lib/logger.ts";
import { invokeAgentRuntime } from "../adapters/agentcore-runtime.ts";
import { buildAuthenticatedUserContext } from "../lib/auth-user-context.ts";
import { TraceCollector, tracingEnabled } from "../lib/trace-collector.ts";
import { withTrace } from "../lib/trace-context.ts";
import { withGatewayJwt } from "../lib/gateway-auth-context.ts";
import { persistTrace } from "../lib/trace-store.ts";

const bodySchema = z.object({
  message: z.string().min(1),
  sessionId: z.string().min(1),
  agentId: z.string().optional(),
});

export const chatRoutes = new Hono();

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

  const agentId = body.agentId ?? "orchestrator";
  const agent = getAgent(agentId);
  if (!agent) {
    return c.json(
      {
        error: {
          code: "AGENT_NOT_FOUND",
          message: `No agent with id '${agentId}' exists.`,
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

  const tracingOn = tracingEnabled();
  const collector = tracingOn
    ? new TraceCollector({
        sessionId: body.sessionId,
        messageId,
        agentId,
        userId,
        requestId,
      })
    : undefined;

  // Build auth + memory context.
  let memoryContext: string | undefined;
  if (userId) {
    const contextUserId = userId;
    const contextAgent = agent;
    await (collector ? withTrace(collector, buildContext) : buildContext());
    async function buildContext() {
      const blocks: string[] = [];
      const authCtx = await buildAuthenticatedUserContext(
        contextUserId,
        c.get("jwtPayload"),
        c.get("bearerToken"),
      );
      if (authCtx) blocks.push(authCtx);

      // Shared user facts are useful even for orchestrator turns.
      const shared = await readSharedLongTermMemory(contextUserId);
      if (shared) blocks.push(`## Shared User Facts\n\n${shared}`);

      // Agent-scoped memory is only loaded for agents that opt into long-term memory.
      if (contextAgent.memory?.longTerm) {
        const scoped = await readLongTermMemory(contextUserId, agentId);
        if (scoped) blocks.push(`## ${agentId} Memory\n\n${scoped}`);
        if (shared || scoped) {
          logger.debug("[chat] injecting long-term memory", { userId, agentId });
        }
      }

      if (blocks.length > 0) {
        memoryContext = blocks.join("\n\n");
      }
    }
  }

  return streamSSE(c, async (stream) => {
    let unsubTrace: (() => void) | undefined;
    if (collector) {
      unsubTrace = collector.onEvent(async (ev) => {
        try {
          await stream.writeSSE({ event: "trace", data: JSON.stringify(ev) });
        } catch {
          // Stream may have closed; swallow to avoid destabilizing the collector.
        }
      });
    }
    // Emit the turn-start event after the SSE subscriber is wired so the
    // client receives it on the wire (otherwise it's only recorded in the
    // collector's internal log and shows up in the persisted trace but not
    // in the live `trace` SSE channel).
    collector?.event("chat.turn.start", {
      sessionId: body.sessionId,
      messageId,
      agentId,
      userId,
      requestId,
      startTs: Date.now(),
    });

    // Scope the caller's JWT for the entire turn so the AgentCore Runtime
    // forwards it (as `userJwt`) and any in-process MCP transport can inject
    // it as `Authorization: Bearer <jwt>` on outbound Gateway calls.
    const bearerToken = c.get("bearerToken") as string | undefined;
    const runWithTrace = <T>(fn: () => Promise<T>): Promise<T> => {
      const traced = () => (collector ? withTrace(collector, fn) : fn());
      return Promise.resolve(withGatewayJwt(bearerToken, traced));
    };

    await runWithTrace(async () => {
      await stream.writeSSE({
        event: "agent_info",
        data: JSON.stringify({ agentId, agentName: agent.name }),
      });

      let fullReply = "";
      let streamFailed: { code: string; message: string } | undefined;

      try {
        logger.info("[chat] routing to AgentCore Runtime", { agentId, requestId });
        const result = await invokeAgentRuntime({
          message: body.message,
          agentId,
          sessionId: body.sessionId,
          priorTurns,
          memoryContext,
          userJwt: bearerToken,
        });
        fullReply = result.response;
        await stream.writeSSE({
          event: "token",
          data: JSON.stringify({ text: fullReply }),
        });
        if (result.handoffs?.length) {
          for (const to of result.handoffs) {
            await stream.writeSSE({
              event: "handoff",
              data: JSON.stringify({ from: agentId, to, label: "" }),
            });
          }
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        const klass = err instanceof Error ? err.name : "Error";
        const stack = err instanceof Error ? err.stack : undefined;
        logger.error("[chat] AgentCore Runtime error", { requestId, agentId, error: message });
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
      }

      if (!streamFailed) {
        await appendAssistantMessage(body.sessionId, fullReply, agentId, userId);
        if (useAgentcoreShortTerm && fullReply.trim()) {
          await tryWriteShortTermAssistantMessage(body.sessionId, userId, fullReply, agentId);
        }
        if (fullReply.trim()) {
          await writeLongTermMemory(userId, agentId, body.message, fullReply);
        }
      }

      if (collector) {
        collector.recordBytesIn(Buffer.byteLength(body.message, "utf8"));
        collector.recordBytesOut(Buffer.byteLength(fullReply, "utf8"));
        collector.setFinalAgentId(collector.agentId ?? agentId);
        collector.event("chat.turn.end", {
          durationMs: Date.now() - collector.startTs,
          summary: collector.summary(),
        });
        try {
          await setLastTraceId(body.sessionId, messageId, collector.traceId);
          await persistTrace(collector.toJSON());
        } catch (e) {
          logger.warn("[chat] trace persistence failed", {
            traceId: collector.traceId,
            error: e instanceof Error ? e.message : String(e),
          });
        }
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
    });

    unsubTrace?.();
  });
});