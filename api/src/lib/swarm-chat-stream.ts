import { Swarm } from "@strands-agents/sdk";
import {
  BeforeNodeCallEvent,
  MultiAgentHandoffEvent,
  NodeStreamUpdateEvent,
} from "@strands-agents/sdk/multiagent";
import { createConfiguredStrandsAgent } from "./create-strands-agent.ts";
import { getAgent, listAgents } from "./config-scan.ts";
import type { ChatStreamPart } from "./chat-stream-types.ts";
import type { ChatMessage } from "./session-store.ts";
import { logger } from "./logger.ts";
import { currentTrace } from "./trace-context.ts";
import { attributeHandoff } from "./handoff-attribution.ts";
import { isDevMockBackends } from "../adapters/dev-mock-env.ts";

/**
 * Build the ordered agent ID list for the Swarm from config/agents/ at call time.
 * Orchestrator always leads; remaining agents follow in alphabetical order.
 * Falls back to ["orchestrator"] if no agents are found in config.
 */
function buildSwarmAgentIds(): string[] {
  const all = listAgents().map((a) => a.id);
  if (all.length === 0) return ["orchestrator"];
  const specialists = all.filter((id) => id !== "orchestrator").sort();
  const hasOrch = all.includes("orchestrator");
  return hasOrch ? ["orchestrator", ...specialists] : all.sort();
}

function packConversationForSwarm(priorTurns: ChatMessage[] | undefined, latestUserMessage: string): string {
  if (!priorTurns?.length) return latestUserMessage;
  const history = priorTurns.map((m) => {
    // Tag assistant messages with which specialist responded so the orchestrator
    // doesn't misread prior specialist replies as its own output.
    const label = m.role === "assistant" && m.agentId && m.agentId !== "orchestrator"
      ? `ASSISTANT (${m.agentId})`
      : m.role.toUpperCase();
    return `${label}: ${m.content}`;
  }).join("\n");
  return `Conversation so far:\n${history}\n\nCurrent user message:\n${latestUserMessage}`;
}

function isNodeStreamUpdate(ev: unknown): ev is NodeStreamUpdateEvent {
  return (
    typeof ev === "object" &&
    ev !== null &&
    "type" in ev &&
    (ev as { type: string }).type === "nodeStreamUpdateEvent"
  );
}

function isHandoff(ev: unknown): ev is MultiAgentHandoffEvent {
  return (
    typeof ev === "object" &&
    ev !== null &&
    "type" in ev &&
    (ev as { type: string }).type === "multiAgentHandoffEvent"
  );
}

function isBeforeNode(ev: unknown): ev is BeforeNodeCallEvent {
  return (
    typeof ev === "object" &&
    ev !== null &&
    "type" in ev &&
    (ev as { type: string }).type === "beforeNodeCallEvent"
  );
}

export async function* runSwarmChatStream(params: {
  userMessage: string;
  priorTurns?: ChatMessage[];
  memoryContext?: string;
}): AsyncGenerator<ChatStreamPart> {
  const agentIds = buildSwarmAgentIds();
  logger.debug("[swarm] building swarm", { agentIds });

  /** Track which agent node is currently active. */
  let currentNodeId = "";
  /**
   * True once a non-whitespace token has been yielded for the current node.
   * Used to decide whether strands_structured_output.message should be yielded
   * (only when the agent expressed itself via structured output, not token stream).
   */
  let hasYieldedContent = false;
  /**
   * True once we have yielded a response from strands_structured_output for this node.
   * Prevents the repeated message when Nova Pro calls the tool in a loop.
   */
  let hasYieldedFromStructuredOutput = false;
  /**
   * Set to true after a terminal strands_structured_output fires, to suppress
   * the duplicate token stream Nova models emit after the tool call.
   */
  let suppressTokens = false;

  /**
   * Strip internal XML blocks and wrapper tags from a complete string.
   * - <thinking>...</thinking> and <strands_structured_output>...</strands_structured_output>:
   *   discard content entirely (internal reasoning / tool echo)
   * - <response>...</response>: strip wrapper tags only, keep the inner content
   */
  function stripInternalBlocks(text: string): string {
    return text
      .replace(/<thinking>[\s\S]*?<\/thinking>/g, "")
      .replace(/<strands_structured_output>[\s\S]*?<\/strands_structured_output>/g, "")
      .replace(/<\/?response>/g, "")   // strip wrapper tags, keep content
      .replace(/\s+/g, " ")
      .trim();
  }

  /**
   * Nova models emit internal XML blocks in the token stream:
   *   <thinking>...</thinking>                       — internal reasoning
   *   <strands_structured_output>...</strands_structured_output> — tool call echo
   *
   * Both must be buffered and discarded. Tags can be split across chunk boundaries
   * (e.g. "<thinking" then ">"), so we maintain a prefixBuffer to hold potential
   * partial open tags until the next chunk confirms or refutes them.
   */
  const FILTERED_BLOCKS = [
    { open: "<thinking>",                   close: "</thinking>" },
    { open: "<strands_structured_output>",  close: "</strands_structured_output>" },
  ];

  // Tags whose content should be KEPT but the wrapper tags stripped.
  // These are added to the FILTERED_BLOCKS prefix-buffer detection so split-chunk
  // tags are caught, but when the "block" closes the inner content is re-emitted.
  // Handled via post-processing after filterTokens for whole-token matches.
  const STRIP_TAGS = ["<response>", "</response>"];

  let currentBlockClose = ""; // close tag for the block currently being filtered
  let blockBuffer      = ""; // accumulates tokens inside a filtered block
  let prefixBuffer     = ""; // holds a partial open-tag prefix at end of last chunk

  function filterTokens(raw: string): string | null {
    if (!raw) return null;

    const input = prefixBuffer + raw;
    prefixBuffer = "";

    // ── Inside a filtered block ──────────────────────────────────────────────
    if (currentBlockClose) {
      blockBuffer += input;
      const closeIdx = blockBuffer.indexOf(currentBlockClose);
      if (closeIdx === -1) return null; // still accumulating
      const after = blockBuffer.slice(closeIdx + currentBlockClose.length);
      blockBuffer      = "";
      currentBlockClose = "";
      return filterTokens(after);   // recurse — more blocks may follow
    }

    // ── Find the earliest opening tag ────────────────────────────────────────
    let earliestIdx = -1;
    let matchedBlock = FILTERED_BLOCKS[0]!;
    for (const block of FILTERED_BLOCKS) {
      const idx = input.indexOf(block.open);
      if (idx !== -1 && (earliestIdx === -1 || idx < earliestIdx)) {
        earliestIdx  = idx;
        matchedBlock = block;
      }
    }

    if (earliestIdx !== -1) {
      const before = input.slice(0, earliestIdx);
      currentBlockClose = matchedBlock.close;
      blockBuffer       = input.slice(earliestIdx);
      const closeIdx    = blockBuffer.indexOf(matchedBlock.close);
      if (closeIdx !== -1) {
        const after      = blockBuffer.slice(closeIdx + matchedBlock.close.length);
        blockBuffer       = "";
        currentBlockClose = "";
        const rest = filterTokens(after);
        return (before + (rest ?? "")) || null;
      }
      return before || null;
    }

    // ── Strip <response> / </response> wrapper tags (content is kept) ────────
    // These are simple inline replacements — no buffering needed for whole tokens.
    // Split-chunk partial tags are handled by the prefix-buffer check below.
    let stripped = input;
    for (const tag of STRIP_TAGS) {
      if (stripped.includes(tag)) stripped = stripped.split(tag).join("");
    }
    if (stripped !== input) return stripped || null;

    // ── Check for partial open-tag prefix at end of chunk ────────────────────
    // e.g. chunk ends with "<", "<th", "<thinking", "<strands_", "<res", etc.
    const ALL_TRACKED_OPENS = [
      ...FILTERED_BLOCKS.map((b) => b.open),
      ...STRIP_TAGS,
    ];
    for (const openTag of ALL_TRACKED_OPENS) {
      for (let len = openTag.length - 1; len >= 1; len--) {
        if (input.endsWith(openTag.slice(0, len))) {
          prefixBuffer = input.slice(-len);
          const visible = input.slice(0, input.length - len);
          return visible || null;
        }
      }
    }

    return input || null;
  }

  const agents = (
    await Promise.all(
      agentIds.map((id) =>
        createConfiguredStrandsAgent(id, {
          priorTurns: undefined,
          preActivateSkills: id !== "orchestrator",
          memoryContext: params.memoryContext,
        }),
      ),
    )
  ).filter((a): a is NonNullable<typeof a> => a != null);

  // Specialist agents (non-orchestrator) must NOT receive the Swarm's
  // structuredOutputSchema when their stream() is called by AgentNode.handle().
  // With the schema injected, Nova Pro loops on strands_structured_output indefinitely.
  // Without it, the SDK uses NullStructuredOutputContext:
  //   - No strands_structured_output tool is registered for the model
  //   - hasResult() always returns true → agent loop exits after one model turn
  //   - Model outputs text naturally, Swarm sees no agentId → terminates cleanly
  //
  // Patch: wrap stream() on each specialist agent instance to strip the schema option.
  const nodes = agents
    .filter((a): a is NonNullable<typeof a> => Boolean(a))
    .map((agent) => {
      if (agent.id !== "orchestrator") {
        const orig = agent.stream.bind(agent);
        // @ts-ignore — patching instance method to strip structuredOutputSchema
        agent.stream = (args: unknown, options?: Record<string, unknown>) => {
          const { structuredOutputSchema: _stripped, ...safe } = options ?? {};
          // @ts-ignore — args is unknown but orig accepts InvokeArgs; safe at runtime
          return orig(args, safe);
        };
      }
      return agent;
    });

  if (nodes.length === 0) {
    yield {
      type: "stream_error",
      code: "SWARM_NO_AGENTS",
      message: "No agents could be loaded for Swarm.",
    };
    return;
  }

  const input = packConversationForSwarm(params.priorTurns, params.userMessage);

  try {
    const startId = nodes.some((n) => n.id === "orchestrator") ? "orchestrator" : nodes[0]!.id;
    const swarm = new Swarm({
      nodes,
      start: startId,
      maxSteps: Math.min(12, Number(process.env.SWARM_MAX_STEPS ?? 8)),
    });

    const trace = currentTrace();
    const turnStartTs = Date.now();
    // Per-node accumulated assistant text — snapshot on the *from-node* when a
    // multiAgentHandoffEvent fires so the handoff payload carries the from-node's
    // reasoning (not the orchestrator's, for chained A→B→C handoffs).
    const perNodeReasoning = new Map<string, string>();
    const toolSpans = new Map<string, string>(); // toolUseId → spanId
    const completedToolCalls: Array<{ name: string; toolUseId?: string }> = [];
    let priorHandoffCount = 0;

    // Suppress UI events for orchestrator self-loops (orchestrator routing to itself).
    // The orchestrator eventually routes correctly; we only show the final meaningful handoff.
    let orchestratorInvocations = 0;
    let suppressOrchestratorEvents = false;

    // Once a specialist agent has run, cancel any re-entry into the orchestrator.
    // Without this, the swarm re-enters the orchestrator after the specialist responds,
    // triggering a second routing cycle (orchestrator → specialist → orchestrator → ...).
    let specialistHasRun = false;
    const { BeforeNodeCallEvent: BNCEvent } = await import("@strands-agents/sdk/multiagent");
    swarm.addHook(BNCEvent, (event: { nodeId: string; cancel?: boolean | string }) => {
      if (event.nodeId !== "orchestrator") {
        specialistHasRun = true;
      } else if (specialistHasRun) {
        // Cancel orchestrator re-entry after specialist has responded
        event.cancel = "specialist already handled the request";
      }
    });

    for await (const ev of swarm.stream(input)) {
      if (isBeforeNode(ev)) {
        currentNodeId = ev.nodeId;
        hasYieldedContent = false;
        hasYieldedFromStructuredOutput = false;
        suppressTokens = false;
        if (ev.nodeId === "orchestrator") {
          orchestratorInvocations++;
          // Suppress events for all but the first orchestrator invocation (self-loops are noise)
          suppressOrchestratorEvents = orchestratorInvocations > 1;
        } else {
          suppressOrchestratorEvents = false;
        }
        if (trace) {
          const meta = getAgent(ev.nodeId);
          trace.agentId = ev.nodeId;
          trace.event("agent.activate", {
            agentId: ev.nodeId,
            agentName: meta?.name,
            specialist: ev.nodeId !== "orchestrator",
            suppressed: suppressOrchestratorEvents,
          });
          // Reset pending text for the new node so we snapshot its own reasoning later.
          trace.resetPendingText();
          perNodeReasoning.set(ev.nodeId, "");
        }
        if (!suppressOrchestratorEvents) {
          const meta = getAgent(ev.nodeId);
          yield {
            type: "agent_active",
            agentId: ev.nodeId,
            agentName: meta?.name ?? ev.nodeId,
          };
        }
      } else if (isHandoff(ev)) {
        const to = ev.targets[0] ?? "";
        if (trace && to) {
          const fromNode = ev.source ?? currentNodeId;
          const fromAgent = getAgent(fromNode);
          const toMeta = getAgent(to);
          const reasoning = perNodeReasoning.get(fromNode) ?? trace.snapshotPendingText();
          const handoffs = fromAgent?.handoffs ?? [];
          const matched = handoffs.find((h) => h.agent === to);
          const attribution = attributeHandoff({
            userMessage: params.userMessage,
            orchestratorReasoning: reasoning,
            chosenAgentId: to,
            orchestratorHandoffs: handoffs,
            agentMeta: (id) => {
              const a = getAgent(id);
              return a ? { description: a.description, skills: a.skills } : undefined;
            },
          });
          priorHandoffCount += 1;
          trace.event("handoff.decision", {
            fromAgentId: fromNode,
            toAgentId: to,
            toAgentName: toMeta?.name,
            toAgentDescription: toMeta?.description,
            userMessage: params.userMessage,
            orchestratorReasoning: reasoning,
            structuredOutput: { agentId: to, source: ev.source, targets: ev.targets },
            reason: undefined,
            matchedHandoffEntry: matched,
            triggerSpans: attribution.triggerSpans,
            alternativesConsidered: attribution.alternativesConsidered,
            chosenScore: attribution.chosenScore,
            confidence: attribution.confidence,
            priorToolCalls: completedToolCalls.slice(),
            priorHandoffCount: priorHandoffCount - 1,
            conversationContextTurns:
              (params.priorTurns ?? []).slice(-4).map((m) => ({
                role: m.role,
                preview: m.content.length > 200 ? `${m.content.slice(0, 200)}…` : m.content,
              })),
            latencyToDecisionMs: Date.now() - turnStartTs,
            tokensBeforeDecision: 0,
            routingSource: isDevMockBackends() ? "devmock_regex" : "llm",
          });
        }
        // Always yield the handoff once a specialist is reached; suppress orch→orch self-loops
        if (to !== "orchestrator" || !suppressOrchestratorEvents) {
          yield {
            type: "handoff",
            from: ev.source,
            to,
            label: "",
          };
        }
      } else if (isNodeStreamUpdate(ev)) {
        const inner = ev.inner;
        if (inner.source === "agent") {
          const aev = inner.event;
          if (aev.type === "modelStreamUpdateEvent") {
            const me = aev.event;
            if (me.type === "modelContentBlockDeltaEvent") {
              if (me.delta.type === "textDelta") {
                const raw = me.delta.text;
                if (raw) {
                  // Track per-node reasoning for handoff attribution (even when
                  // tokens are suppressed for UI; the model still reasoned).
                  if (trace) {
                    trace.appendPendingText(raw);
                    const prev = perNodeReasoning.get(currentNodeId) ?? "";
                    const next = (prev + raw).slice(-4096);
                    perNodeReasoning.set(currentNodeId, next);
                  }
                  if (!suppressTokens) {
                    const filtered = filterTokens(raw);
                    if (filtered) {
                      if (filtered.trim().length > 0) hasYieldedContent = true;
                      if (trace) {
                        trace.event("model.text_delta_batch", {
                          text: filtered,
                          bytes: Buffer.byteLength(filtered, "utf8"),
                          windowMs: 0,
                        });
                      }
                      yield { type: "token", text: filtered };
                    }
                  }
                }
              } else if (me.delta.type === "reasoningContentDelta" && me.delta.text) {
                if (trace) {
                  trace.event("model.thinking_block", {
                    text: me.delta.text,
                    bytes: Buffer.byteLength(me.delta.text, "utf8"),
                  });
                }
              }
            } else if (me.type === "modelMetadataEvent" && me.usage) {
              if (trace) {
                const meta = getAgent(currentNodeId);
                trace.event("model.usage", {
                  modelId: meta?.model ?? "unknown",
                  inputTokens: me.usage.inputTokens,
                  outputTokens: me.usage.outputTokens,
                  totalTokens: me.usage.totalTokens,
                  cacheReadInputTokens: me.usage.cacheReadInputTokens,
                  cacheWriteInputTokens: me.usage.cacheWriteInputTokens,
                  latencyMs: me.metrics?.latencyMs,
                  timeToFirstByteMs: me.metrics?.timeToFirstByteMs,
                });
              }
            }
          } else if (aev.type === "afterModelCallEvent") {
            if (trace && aev.stopData?.stopReason) {
              trace.event("model.stop", { stopReason: aev.stopData.stopReason });
            }
          } else if (aev.type === "beforeToolCallEvent") {
            const toolName = aev.toolUse.name;
            const toolUseId = aev.toolUse.toolUseId;
            if (trace) {
              const spanId = trace.start("tool.call", {
                toolName,
                toolUseId,
                input: aev.toolUse.input,
              });
              toolSpans.set(toolUseId, spanId);
            }
            if (!suppressOrchestratorEvents) {
              yield { type: "tool_call", tool: toolName, status: "started" };
            }
            if (toolName === "activate_skill") {
              const skillName = (aev.toolUse.input as { skillName?: string }).skillName;
              if (skillName) {
                if (trace) {
                  trace.event("skill.activated", {
                    name: skillName,
                    source: "model_tool_call",
                    injectedVia: "tool_result",
                    bytes: 0,
                    allowed: true,
                  });
                }
                yield { type: "skill_loaded", skillName };
              }
            }
          } else if (aev.type === "afterToolCallEvent") {
            const toolUseId = aev.toolUse.toolUseId;
            const spanId = toolSpans.get(toolUseId);
            if (trace && spanId) {
              const endPayload: Record<string, unknown> = {
                toolName: aev.toolUse.name,
                toolUseId,
                result: aev.result,
              };
              if (aev.error) {
                endPayload.error = { class: aev.error.name, message: aev.error.message };
                trace.event("error", {
                  class: aev.error.name,
                  message: aev.error.message,
                  stack: aev.error.stack,
                  source: "tool.call",
                });
              }
              trace.end(spanId, endPayload);
              toolSpans.delete(toolUseId);
              completedToolCalls.push({ name: aev.toolUse.name, toolUseId });
            }
            if (!suppressOrchestratorEvents) {
              yield { type: "tool_call", tool: aev.toolUse.name, status: "completed" };
            }
            // When a specialist agent (non-orchestrator) emits a terminal strands_structured_output
            // (no agentId = no further handoff), its `message` field IS the final answer.
            // The orchestrator already streams its answers as text tokens, so skip it there.
            if (aev.toolUse.name === "strands_structured_output") {
              const input = aev.toolUse.input as { agentId?: string; message?: string };
              const isTerminal = !input.agentId && input.message;
              // Yield the structured output message only when no streaming tokens were emitted
              // for this node yet (i.e. the model expressed itself via structured output, not tokens).
              // Also suppress subsequent streaming tokens to avoid the duplicate that Nova models
              // emit after calling strands_structured_output.
              if (isTerminal) {
                // Always suppress any tokens the model streams after this tool call.
                suppressTokens = true;
                // Yield the structured-output message only when:
                //   1. No meaningful streaming tokens were emitted yet (model used structured
                //      output as its primary channel, not the token stream), AND
                //   2. We haven't already yielded from a previous strands_structured_output
                //      call for this node (Nova Pro sometimes calls this tool in a loop).
                if (!hasYieldedContent && !hasYieldedFromStructuredOutput) {
                  const cleaned = stripInternalBlocks(input.message!);
                  if (cleaned) {
                    hasYieldedFromStructuredOutput = true;
                    yield { type: "token", text: cleaned };
                  }
                }
              }
            }
          }
        }
      }
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    logger.error("[swarm] stream failed", { error: msg });
    yield {
      type: "stream_error",
      code: "SWARM_STREAM_FAILED",
      message: msg,
    };
  }
}
