import { createHash } from "node:crypto";
import { Agent, Message, TextBlock } from "@strands-agents/sdk";
import type { ChatStreamPart } from "./chat-stream-types.ts";
import { getAgent, loadAgentPersona } from "./config-scan.ts";
import { buildSystemPrompt } from "./prompt.ts";
import type { ChatMessage } from "./session-store.ts";
import { logger } from "./logger.ts";
import { currentTrace } from "./trace-context.ts";
import { attributeHandoff } from "./handoff-attribution.ts";
import { getAgentTemplate } from "./create-strands-agent.ts";

export type { ChatStreamPart };

/**
 * Agents whose skills are always pre-activated (they are specialists — they
 * always need their domain instructions). The orchestrator is NOT in this set;
 * it gets discovery-only and lets the model call `activate_skill` if needed.
 */
const ALWAYS_ACTIVATE_SKILLS = true; // flip to false to force lazy even for specialists

function tracePromptBodyEnabled(): boolean {
  const v = process.env.TRACE_PROMPT_BODY?.trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function strandsHistory(priorTurns: ChatMessage[] | undefined): Message[] | undefined {
  if (!priorTurns?.length) return undefined;
  return priorTurns.map(
    (m) =>
      new Message({
        role: m.role,
        content: [new TextBlock(m.content)],
      }),
  );
}

/**
 * Snapshot the `messages: seed` array passed into the Strands `Agent`
 * constructor for trace persistence. We do NOT capture the live `Message`
 * objects (they carry framework metadata); instead, we extract `role` plus
 * the concatenated text content with a per-item preview cap of 4 KB. The
 * collector's per-event-type truncation table additionally caps the whole
 * array via `model.request.messagesSeed` so a 100-turn session can't blow
 * the per-event byte cap.
 */
function seedPreview(seed: Message[] | undefined): Array<{
  role: string;
  contentBytes: number;
  contentPreview: string;
}> | undefined {
  if (!seed?.length) return undefined;
  const PER_ITEM_CAP = 4096;
  return seed.map((m) => {
    let text = "";
    const blocks = (m as unknown as { content?: Array<{ text?: string }> }).content ?? [];
    for (const b of blocks) {
      if (typeof b?.text === "string") text += b.text;
    }
    const role = (m as unknown as { role?: string }).role ?? "unknown";
    const contentBytes = Buffer.byteLength(text, "utf8");
    const contentPreview = text.length > PER_ITEM_CAP ? text.slice(0, PER_ITEM_CAP) + "…[truncated]" : text;
    return { role, contentBytes, contentPreview };
  });
}

// ---------------------------------------------------------------------------
// Main streaming function
// ---------------------------------------------------------------------------

export async function* runChatStream(params: {
  agentId: string;
  userMessage: string;
  /** Messages before the current user turn (excludes the latest user message). */
  priorTurns?: ChatMessage[];
  /** Long-term memory context injected into the system prompt (Phase 5). */
  memoryContext?: string;
}): AsyncGenerator<ChatStreamPart> {
  const agentConfig = getAgent(params.agentId);
  if (!agentConfig) {
    yield { type: "token", text: `Error: unknown agent '${params.agentId}'.` };
    return;
  }

  // -------------------------------------------------------------------------
  // Build (or reuse) the agent template.
  //
  // Orchestrator: skills: [] → nothing to activate; gets discovery section only
  //   if it ever has skills listed. Template still cacheable.
  // Specialists: activate all allowed skills up front so the model has full
  //   instructions immediately. Cached across chats.
  // The model can still call activate_skill for any skill it was not pre-loaded
  // when caching is bypassed for that mode.
  // -------------------------------------------------------------------------
  const isOrchestrator = params.agentId === "orchestrator";
  const preActivateSkills = !isOrchestrator && ALWAYS_ACTIVATE_SKILLS && agentConfig.skills.length > 0;

  const template = await getAgentTemplate(params.agentId, { preActivateSkills });
  if (!template) {
    yield { type: "token", text: `Error: unable to build agent template for '${params.agentId}'.` };
    return;
  }

  // When the agent declared MCP-served tools (mongodb_*) but the loader
  // returned [], surface this loudly so the smoke test, UI, and operator
  // logs see why the model can never answer questions that need a Mongo
  // round-trip. Without this, the model silently retries with no tools
  // and emits hallucinated "I cannot access the database" text that
  // looks like a normal answer to the smoke test's content checks.
  // Probable root causes:
  //   - AGENTCORE_GATEWAY_URL missing from runtime env vars
  //     (drifted by `terraform apply`; see docs/status/debugging.md pitfalls).
  //   - AgentCore Gateway / MongoDB MCP runtime down or unreachable.
  // The template is intentionally NOT cached when degraded (see
  // create-strands-agent.ts) so the next chat turn re-attempts MCP.
  if (template.mcpDegraded) {
    const collector = currentTrace();
    const missing = template.missingTools ?? [];
    const mcpEndpoint = process.env.AGENTCORE_GATEWAY_URL?.trim()
      || "(missing AGENTCORE_GATEWAY_URL — no localhost fallback)";
    collector?.event("tools.degraded", {
      agentId: params.agentId,
      missingTools: missing,
      reason: "mcp_tools_unavailable",
      mcpEndpoint,
      hint:
        "MongoDB MCP tools were declared by the agent but getMcpTools() returned an empty list. "
        + "Verify AGENTCORE_GATEWAY_URL on the runtime and "
        + "that the AgentCore Gateway target for MongoDB MCP is reachable.",
    });
    logger.warn("[chat] refusing to run turn against degraded template", {
      agentId: params.agentId,
      missingTools: missing,
      mcpEndpoint,
    });
    yield {
      type: "stream_error",
      code: "TOOLS_UNAVAILABLE",
      message:
        `Required MongoDB MCP tools are unavailable for agent '${params.agentId}': `
        + `${missing.join(", ") || "(none reported)"}. `
        + `MCP endpoint resolved to: ${mcpEndpoint}. `
        + `Check AGENTCORE_GATEWAY_URL on the AgentCore Runtime env.`,
    };
    return;
  }

  const registry = template.registry;

  if (preActivateSkills) {
    for (const block of registry.activatedBlocks) {
      yield { type: "skill_loaded", skillName: block.name };
    }
  }

  // -------------------------------------------------------------------------
  // Build the per-turn system prompt by splicing memoryContext into the
  // cached base. When no memoryContext is set we reuse the cached string.
  // -------------------------------------------------------------------------
  const persona = loadAgentPersona(params.agentId) ?? "";
  const systemPrompt = params.memoryContext?.trim()
    ? buildSystemPrompt(
        persona,
        registry.discoveries,
        registry.activatedBlocks,
        params.memoryContext,
      )
    : template.systemPromptBase;

  const trace = currentTrace();
  const systemPromptBytes = Buffer.byteLength(systemPrompt, "utf8");
  const systemPromptHashFull = createHash("sha256").update(systemPrompt).digest("hex");
  const systemPromptHashShort = systemPromptHashFull.slice(0, 16);
  if (trace) {
    trace.event("prompt.assembled", {
      personaBytes: Buffer.byteLength(persona, "utf8"),
      discoveryBytes: registry.discoveries.length,
      memoryContextBytes: params.memoryContext ? Buffer.byteLength(params.memoryContext, "utf8") : 0,
      activatedSkills: registry.activatedBlocks.map((b) => ({
        name: b.name,
        bytes: Buffer.byteLength(b.body, "utf8"),
        injectedVia: "system_prompt" as const,
      })),
      totalBytes: systemPromptBytes,
      bodyBytes: systemPromptBytes,
      bodyHash: systemPromptHashShort,
      ...(tracePromptBodyEnabled() ? { body: systemPrompt } : {}),
    });
    for (const b of registry.activatedBlocks) {
      trace.event("skill.activated", {
        name: b.name,
        source: "pre_activate",
        injectedVia: "system_prompt",
        bytes: Buffer.byteLength(b.body, "utf8"),
        allowed: true,
        // 4 KB preview lets the dev panel show *which* skill body got
        // injected without forcing them to diff the full prompt by hand.
        bodyPreview: b.body.length > 4096 ? b.body.slice(0, 4096) : b.body,
      });
    }
  }

  // -------------------------------------------------------------------------
  // Strands Agent with cached tools + seeded history
  // -------------------------------------------------------------------------
  try {
    const seed = strandsHistory(params.priorTurns);

    const strandsAgent = new Agent({
      model: template.model,
      systemPrompt,
      name: template.agentConfig.name,
      id: template.agentConfig.id,
      printer: false,
      tools: template.tools,
      messages: seed,
    });

    let hasYieldedText = false;
    let hasYieldedStructuredMessage = false;

    // ── Tracing scratch state ────────────────────────────────────────────────
    const turnStartTs = Date.now();
    const modelId = agentConfig.model?.trim() ?? "unknown";
    let modelSpanId: string | undefined;
    let firstModelDeltaRecorded = false;
    let firstToolCallRecorded = false;
    if (trace) {
      modelSpanId = trace.start("model.request", {
        modelId,
        region: process.env.AWS_REGION,
        systemPromptHash: systemPromptHashShort,
        systemPromptBytes,
        priorTurnsCount: params.priorTurns?.length ?? 0,
        userMessage: params.userMessage,
        // Lightweight preview of the prior turns (max 6, 200 chars each).
        priorTurnsPreview: (params.priorTurns ?? []).slice(-6).map((m) => ({
          role: m.role,
          bytes: Buffer.byteLength(m.content, "utf8"),
          preview: m.content.length > 200 ? m.content.slice(0, 200) + "…" : m.content,
        })),
        // Source-of-truth replay: the actual `messages: seed` array the
        // Strands Agent was constructed with. Per-item content is previewed
        // (≤ 4 KB) and the whole array is implicitly capped at 32 KB by the
        // per-event-type truncation table (`messagesSeed` is a debug-cap
        // field — see `DEBUG_CAP_FIELDS` in `trace-collector.ts`).
        messagesSeed: seedPreview(seed),
      });
    }
    logger.info("[run-chat-stream] model stream start", {
      agentId: params.agentId,
      modelId,
      toolCount: template.tools.length,
      priorTurns: params.priorTurns?.length ?? 0,
    });

    const toolSpans = new Map<string, string>(); // toolUseId -> spanId
    const completedToolCalls: Array<{ name: string; toolUseId?: string; durationMs?: number }> = [];
    let priorHandoffCount = 0;

    // Text-delta batching — flush a model.text_delta_batch every ~250 ms.
    let textBatch = "";
    let textBatchStart = 0;
    let cumulativeBytes = 0; // running total since model.request start
    const FLUSH_MS = 250;
    function flushTextBatch(): void {
      if (!trace || !textBatch) return;
      const bytes = Buffer.byteLength(textBatch, "utf8");
      cumulativeBytes += bytes;
      trace.event("model.text_delta_batch", {
        text: textBatch,
        bytes,
        windowMs: Date.now() - textBatchStart,
        cumulativeBytes,
      });
      textBatch = "";
      textBatchStart = 0;
    }
    function pushTextDelta(t: string): void {
      if (!trace) return;
      trace.appendPendingText(t);
      if (!textBatch) textBatchStart = Date.now();
      textBatch += t;
      if (Date.now() - textBatchStart > FLUSH_MS) flushTextBatch();
    }

    function cleanStructuredMessage(text: string): string {
      return text
        .replace(/<thinking>[\s\S]*?<\/thinking>/g, "")
        .replace(/<strands_structured_output>[\s\S]*?<\/strands_structured_output>/g, "")
        .replace(/<\/?response>/g, "")
        .trim();
    }

    for await (const ev of strandsAgent.stream(params.userMessage)) {
      if (ev.type === "modelStreamUpdateEvent") {
        const inner = ev.event;
        if (inner.type === "modelContentBlockDeltaEvent") {
          if (inner.delta.type === "textDelta") {
            const t = inner.delta.text;
            if (t) {
              hasYieldedText = true;
              if (trace && !firstModelDeltaRecorded) {
                firstModelDeltaRecorded = true;
                trace.event("latency.checkpoint", {
                  name: "model.first_delta",
                  elapsedMs: Date.now() - turnStartTs,
                  agentId: params.agentId,
                  eventKind: inner.type,
                });
              }
              pushTextDelta(t);
              yield { type: "token", text: t };
            }
          } else if (inner.delta.type === "reasoningContentDelta" && inner.delta.text) {
            // Stream-level thinking deltas; ContentBlockEvent emits the assembled block.
            if (trace) {
              trace.event("model.thinking_block", {
                text: inner.delta.text,
                bytes: Buffer.byteLength(inner.delta.text, "utf8"),
              });
            }
          }
        } else if (inner.type === "modelMetadataEvent" && inner.usage) {
          flushTextBatch();
          if (trace) {
            trace.event("model.usage", {
              modelId,
              inputTokens: inner.usage.inputTokens,
              outputTokens: inner.usage.outputTokens,
              totalTokens: inner.usage.totalTokens,
              cacheReadInputTokens: inner.usage.cacheReadInputTokens,
              cacheWriteInputTokens: inner.usage.cacheWriteInputTokens,
              latencyMs: inner.metrics?.latencyMs,
              timeToFirstByteMs: inner.metrics?.timeToFirstByteMs,
            });
          }
        }
      } else if (ev.type === "afterModelCallEvent") {
        flushTextBatch();
        const stopReason = ev.stopData?.stopReason;
        if (trace && stopReason) {
          trace.event("model.stop", { stopReason });
        }
      } else if (ev.type === "contentBlockEvent") {
        const block = ev.contentBlock as { type?: string; text?: string };
        // Assembled ReasoningBlock — full thinking text.
        if (block.type === "reasoning" && block.text && trace) {
          trace.event("model.thinking_block", {
            text: block.text,
            bytes: Buffer.byteLength(block.text, "utf8"),
          });
        }
      } else if (ev.type === "beforeToolsEvent") {
        const msg = ev.message as { content?: unknown[] };
        if (trace) {
          trace.event("tools.batch", { toolCount: msg.content?.length ?? 0 });
        }
      } else if (ev.type === "beforeToolCallEvent") {
        flushTextBatch();
        const toolName = ev.toolUse.name;
        const toolUseId = ev.toolUse.toolUseId;
        if (trace && !firstToolCallRecorded) {
          firstToolCallRecorded = true;
          trace.event("latency.checkpoint", {
            name: "model.first_tool_call",
            elapsedMs: Date.now() - turnStartTs,
            agentId: params.agentId,
            toolName,
          });
        }
        yield { type: "tool_call", tool: toolName, status: "started" };

        const reasoningSnapshot = trace?.snapshotPendingText() ?? "";
        if (trace) {
          const spanId = trace.start("tool.call", {
            toolName,
            toolUseId,
            input: ev.toolUse.input,
          });
          toolSpans.set(toolUseId, spanId);
        }
        // Reset pending text after we've snapshotted it for handoff attribution.
        trace?.resetPendingText();

        // Orchestrator routing in single-agent mode:
        // emit an explicit handoff when structured output selects a specialist.
        if (toolName === "strands_structured_output") {
          const input = ev.toolUse.input as { agentId?: string; message?: string };
          if (params.agentId === "orchestrator" && input.agentId) {
            if (trace) {
              const orchestratorAgent = getAgent("orchestrator");
              const handoffs = orchestratorAgent?.handoffs ?? [];
              const matched = handoffs.find((h) => h.agent === input.agentId);
              const targetMeta = getAgent(input.agentId);
              const attribution = attributeHandoff({
                userMessage: params.userMessage,
                orchestratorReasoning: reasoningSnapshot,
                chosenAgentId: input.agentId,
                orchestratorHandoffs: handoffs,
                agentMeta: (id) => {
                  const a = getAgent(id);
                  return a ? { description: a.description, skills: a.skills } : undefined;
                },
              });
              priorHandoffCount += 1;
              trace.event("handoff.decision", {
                fromAgentId: "orchestrator",
                toAgentId: input.agentId,
                toAgentName: targetMeta?.name,
                toAgentDescription: targetMeta?.description,
                userMessage: params.userMessage,
                orchestratorReasoning: reasoningSnapshot,
                structuredOutput: input,
                reason: input.message,
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
                tokensBeforeDecision: 0, // populated post-hoc by summary aggregation; UI can compute
              });
            }
            yield { type: "handoff", from: "orchestrator", to: input.agentId, label: "" };
            return;
          }
        }

        // Phase 2 activation event — emit skill_loaded when activate_skill is called
        if (toolName === "activate_skill") {
          const skillName = (ev.toolUse.input as { skillName?: string }).skillName;
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
      } else if (ev.type === "afterToolCallEvent") {
        const toolUseId = ev.toolUse.toolUseId;
        const spanId = toolSpans.get(toolUseId);
        if (trace && spanId) {
          const endPayload: Record<string, unknown> = {
            toolName: ev.toolUse.name,
            toolUseId,
            result: ev.result,
          };
          if (ev.error) {
            endPayload.error = { class: ev.error.name, message: ev.error.message };
            trace.event("error", {
              class: ev.error.name,
              message: ev.error.message,
              stack: ev.error.stack,
              source: "tool.call",
            });
          }
          trace.end(spanId, endPayload);
          toolSpans.delete(toolUseId);
          // Track for handoff payload `priorToolCalls`.
          completedToolCalls.push({ name: ev.toolUse.name, toolUseId });
        }
        yield { type: "tool_call", tool: ev.toolUse.name, status: "completed" };
        // Some models answer through strands_structured_output.message without
        // streaming normal text deltas. Emit that as fallback so specialist
        // responses are never blank.
        if (ev.toolUse.name === "strands_structured_output") {
          const input = ev.toolUse.input as { agentId?: string; message?: string };
          const terminalMessage = !input.agentId && input.message;
          if (terminalMessage && !hasYieldedText && !hasYieldedStructuredMessage) {
            const cleaned = cleanStructuredMessage(input.message!);
            if (cleaned) {
              hasYieldedStructuredMessage = true;
              yield { type: "token", text: cleaned };
            }
          }
        }
      } else if (ev.type === "messageAddedEvent") {
        const msg = ev.message as { role?: string; content?: unknown[] };
        if (trace) {
          trace.event("conversation.message_added", {
            role: (msg.role as "user" | "assistant" | "system" | "tool") ?? "assistant",
            blockCount: msg.content?.length ?? 0,
            bytes: Buffer.byteLength(JSON.stringify(msg.content ?? []), "utf8"),
          });
        }
      }
    }
    flushTextBatch();
    if (trace && modelSpanId) trace.end(modelSpanId);
    logger.info("[run-chat-stream] model stream done", {
      agentId: params.agentId,
      durationMs: Date.now() - turnStartTs,
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    logger.error("[chat-stream] agent stream failed", { agentId: params.agentId, error: msg });
    yield {
      type: "stream_error",
      code: "CHAT_STREAM_FAILED",
      message: `${msg}\n\nCheck AWS credentials, region, and Bedrock model access for ${agentConfig.id}.`,
    };
  }
}
