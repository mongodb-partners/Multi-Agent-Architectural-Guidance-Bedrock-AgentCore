import { Hono } from "hono";
import { streamSSE } from "hono/streaming";
import { z } from "zod";
import { getAgent } from "../lib/config-scan.ts";
import { runChatStream } from "../lib/run-chat-stream.ts";
import { runSwarmChatStream } from "../lib/swarm-chat-stream.ts";
import { useOrchestratorSwarm } from "../lib/orchestrator-mode.ts";
import {
  appendAssistantMessage,
  appendUserMessage,
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
import { useAgentcoreOrchestratorArn, invokeAgentRuntime } from "../adapters/agentcore-runtime.ts";
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

  // Extract userId from JWT sub claim (available when REQUIRE_AUTH + JWKS is configured).
  const userId = c.get("jwtPayload")?.sub;
  const useAgentcoreShortTerm = useAgentcoreShortTermMemory(userId);
  let priorTurns;
  if (useAgentcoreShortTerm && userId) {
    const acTurns = await tryReadShortTermMessages(body.sessionId, userId);
    if (acTurns.length > 0) {
      priorTurns = acTurns;
    } else {
      const fallbackSession = await getSession(body.sessionId);
      priorTurns = fallbackSession ? fallbackSession.messages : [];
    }
  } else {
    const session = await getSession(body.sessionId);
    priorTurns = session ? session.messages : [];
  }

  await appendUserMessage(body.sessionId, body.message, userId);
  if (useAgentcoreShortTerm && userId) {
    await tryWriteShortTermUserMessage(body.sessionId, userId, body.message);
  }

  // Build auth + memory context.
  let memoryContext: string | undefined;
  if (userId) {
    const blocks: string[] = [];
    const authCtx = await buildAuthenticatedUserContext(
      userId,
      c.get("jwtPayload"),
      c.get("bearerToken"),
    );
    if (authCtx) blocks.push(authCtx);

    // Shared user facts are useful even for orchestrator turns.
    const shared = await readSharedLongTermMemory(userId);
    if (shared) blocks.push(`## Shared User Facts\n\n${shared}`);

    // Agent-scoped memory is only loaded for agents that opt into long-term memory.
    if (agent.memory?.longTerm) {
      const scoped = await readLongTermMemory(userId, agentId);
      if (scoped) blocks.push(`## ${agentId} Memory\n\n${scoped}`);
      if (shared || scoped) {
        logger.debug("[chat] injecting long-term memory", { userId, agentId });
      }
    }

    if (blocks.length > 0) {
      memoryContext = blocks.join("\n\n");
    }
  }

  const messageId = `msg_${crypto.randomUUID().slice(0, 12)}`;
  const requestId = c.get("requestId");

  // Per-turn tracing — one TraceCollector per chat turn, replayed as SSE `trace`.
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

  return streamSSE(c, async (stream) => {
    // Live SSE bridge for trace events.
    let unsubTrace: (() => void) | undefined;
    if (collector) {
      unsubTrace = collector.onEvent(async (ev) => {
        try {
          await stream.writeSSE({ event: "trace", data: JSON.stringify(ev) });
        } catch {
          // Stream may have closed; swallow to avoid destabilizing the collector.
        }
      });
      collector.event("chat.turn.start", {
        sessionId: body.sessionId,
        messageId,
        agentId,
        userId,
        requestId,
        startTs: Date.now(),
      });
    }

    // Scope the caller's JWT for the entire turn so the MCP transport in
    // mongodb-mcp-client.ts can inject Authorization: Bearer <jwt> on every
    // outbound AgentCore Gateway call when TOOL_HOSTING_MODE=gateway. In
    // lambda/direct mode this is a no-op.
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

    // ── Path A: AgentCore Runtime (when AGENTCORE_ORCHESTRATOR_ARN is set) ─────
    if (useAgentcoreOrchestratorArn()) {
      try {
        logger.info("[chat] routing to AgentCore Runtime", { agentId, requestId });
        // Forward the caller's raw bearer token so the runtime can authenticate
        // to the AgentCore Gateway when TOOL_HOSTING_MODE=gateway. authMiddleware
        // stores the raw token on the Hono context as `bearerToken`.
        const result = await invokeAgentRuntime({
          message: body.message,
          agentId,
          sessionId: body.sessionId,
          priorTurns,
          memoryContext,
          userJwt: bearerToken,
        });
        fullReply = result.response;
        // Emit the full reply as a single token burst so SSE consumers still work
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
    } else {
      // ── Path B: Strands in-process (local dev or EC2 without runtime ARN) ────
      const streamGen = useOrchestratorSwarm(agentId)
        ? runSwarmChatStream({
            userMessage: body.message,
            priorTurns,
            memoryContext,
          })
        : runChatStream({
            agentId,
            userMessage: body.message,
            priorTurns,
            memoryContext,
          });

      try {
        for await (const part of streamGen) {
          if (part.type === "stream_error") {
            streamFailed = { code: part.code, message: part.message };
            collector?.event("error", {
              class: part.code,
              message: part.message,
              source: "chat.stream",
            });
            await stream.writeSSE({
              event: "error",
              data: JSON.stringify({
                code: part.code,
                message: part.message,
                requestId,
              }),
            });
            break;
          }
          if (part.type === "token") {
            fullReply += part.text;
            await stream.writeSSE({
              event: "token",
              data: JSON.stringify({ text: part.text }),
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
              data: JSON.stringify({
                agentId: part.agentId,
                agentName: part.agentName,
              }),
            });
          } else if (part.type === "handoff") {
            await stream.writeSSE({
              event: "handoff",
              data: JSON.stringify({
                from: part.from,
                to: part.to,
                label: part.label,
              }),
            });
          }
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        const klass = err instanceof Error ? err.name : "Error";
        const stack = err instanceof Error ? err.stack : undefined;
        logger.error("[chat] stream exception", { requestId, agentId, error: message });
        streamFailed = { code: "STREAM_EXCEPTION", message };
        collector?.event("error", {
          class: klass,
          message,
          stack,
          source: "chat.stream",
        });
        await stream.writeSSE({
          event: "error",
          data: JSON.stringify({
            code: "STREAM_EXCEPTION",
            message,
            requestId,
          }),
        });
      }
    }

    if (!streamFailed) {
      await appendAssistantMessage(body.sessionId, fullReply, agentId);
      if (useAgentcoreShortTerm && userId && fullReply.trim()) {
        await tryWriteShortTermAssistantMessage(body.sessionId, userId, fullReply, agentId);
      }
      // Persist user-level facts across sessions for authenticated users.
      // This includes orchestrator turns so generic preferences ("I like blue")
      // are retained even when no specialist is involved.
      if (userId && fullReply.trim()) {
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
