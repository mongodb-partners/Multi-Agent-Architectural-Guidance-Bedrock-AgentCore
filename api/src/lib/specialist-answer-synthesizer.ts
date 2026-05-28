/**
 * Synthesizer agent — collates 2+ specialist answers into one cohesive
 * customer-visible reply.
 *
 * The synthesizer is a transient, in-process Strands `Agent`. There is NO
 * `.agent.md` file and NO AgentCore Runtime. It exists only as a name in
 * traces and Bedrock invocation logs (`agentId: "synthesizer"`).
 *
 * Construction reuses the cached BedrockModel from the orchestrator persona
 * via `resolveModel(getAgent("orchestrator"))`, so this is a sub-millisecond
 * agent build (no skill loading, no MCP, no template cache).
 *
 * Trace contract:
 *   - The auto-emitted `model.request`, `model.text_delta_batch`,
 *     `model.usage`, `model.stop`, and `model.retry` events are tagged
 *     `agentId: "synthesizer"` thanks to `withSynthesizerAgentId(...)`.
 *   - The orchestrator separately emits an `orchestrator.synthesis` summary
 *     event with timing and IO counts.
 *
 * This file is invoked ONLY when ≥2 specialists ran. The single-specialist
 * fast path skips synthesis entirely (see `multi-specialist-orchestrator.ts`).
 */

import { Agent } from "@strands-agents/sdk";
import { resolveModel } from "../adapters/resolve-model.ts";
import { getAgent } from "./config-scan.ts";
import { logger } from "./logger.ts";
import { currentTrace } from "./trace-context.ts";
import type { TraceCollector } from "./trace-collector.ts";

/** Agent id reported in trace events / Bedrock requestMetadata for synthesis. */
export const SYNTHESIZER_AGENT_ID = "synthesizer";
export const SYNTHESIZER_AGENT_NAME = "Synthesizer";

/**
 * Synthesizer system prompt. Composed in this file (not loaded from a
 * `.agent.md`) because the synthesizer is a runtime-only construct.
 */
const SYSTEM_PROMPT = `You compose a single cohesive customer answer from one or more specialist answers.

You are NOT a router or a tool-using agent. You receive specialist answers as input and produce one final answer for the customer.

Rules:
- Merge overlapping facts; do not repeat the same information across sections.
- Preserve specialist caveats and warnings verbatim where they apply.
- Use second-person ("you", "your") to address the customer directly.
- Do NOT mention routing mechanics, classifier, orchestrator, specialists by id, or the synthesis step itself.
- Do NOT invent facts. If specialists disagree, prefer the more specific or more conservative answer and acknowledge the conflict in customer-safe language.
- If a specialist failed or returned nothing, mention the missing area only in customer-safe language (e.g. "I wasn't able to look up shipment details right now"). Never name the failed specialist.
- Keep the response concise and well-structured. Use short paragraphs or compact bullet lists when natural; avoid unnecessary headings.
- End with a single short next-step suggestion or question only when it adds value.`;

/** One specialist answer fed into the synthesizer. */
export type SpecialistAnswer = {
  /** Routing id (e.g. `order-management`). Used internally only. */
  agentId: string;
  /** Customer-facing display name (e.g. "Order Management"). */
  agentName: string;
  /** Status reported by the orchestrator. Failed/empty answers can be passed in. */
  status: "success" | "failed" | "empty";
  /** The specialist's full answer text. Empty for failed/empty status. */
  answerText: string;
  /** Reason text for failed/empty answers (customer-safe phrasing recommended). */
  failureMessage?: string;
};

export type SynthesizerInput = {
  /** Original customer question, verbatim. */
  userMessage: string;
  /** Specialist answers, in classifier-ranked order. */
  specialistAnswers: SpecialistAnswer[];
};

/**
 * Build the structured user-message block fed into the synthesizer.
 * Internal helper exported for tests.
 */
export function buildSynthesizerUserMessage(input: SynthesizerInput): string {
  const lines: string[] = [];
  lines.push(`# User question`);
  lines.push("");
  lines.push(input.userMessage.trim());
  lines.push("");
  lines.push(`# Specialist answers`);
  lines.push("");
  for (let i = 0; i < input.specialistAnswers.length; i++) {
    const a = input.specialistAnswers[i];
    lines.push(`## ${i + 1}. ${a.agentName}`);
    lines.push("");
    if (a.status === "success" && a.answerText.trim()) {
      lines.push(a.answerText.trim());
    } else if (a.status === "failed") {
      lines.push(`(this specialist could not answer; ${a.failureMessage ?? "unknown error"})`);
    } else {
      lines.push(`(this specialist returned no usable text)`);
    }
    lines.push("");
  }
  lines.push(`# Instructions`);
  lines.push("");
  lines.push(
    "Combine the specialist answers above into one cohesive customer reply. Follow the system prompt rules.",
  );
  return lines.join("\n");
}

/**
 * Run a callback with the trace collector's `agentId` temporarily scoped
 * to the synthesizer. Save/restore is exception-safe via try/finally.
 *
 * This affects:
 *   - `MetadataAwareBedrockModel` reads `currentTrace().agentId` and
 *     injects it as Bedrock `requestMetadata.agentId` so synthesis spend
 *     is attributed to `agentId: "synthesizer"` in the cost dashboard.
 *   - The auto-emitted `model.request` / `model.usage` / `model.stop` /
 *     `model.retry` events use the collector's current agentId, so they
 *     are tagged `agentId: "synthesizer"` for the duration of synthesis.
 *
 * The collector's agentId is restored on exit so subsequent code (assistant
 * message persistence, LTM write) operates under the original agentId
 * (`"orchestrator"`).
 */
export async function withSynthesizerAgentId<T>(
  collector: TraceCollector | undefined,
  fn: () => Promise<T>,
): Promise<T> {
  if (!collector) return fn();
  const previous = collector.agentId;
  collector.agentId = SYNTHESIZER_AGENT_ID;
  try {
    return await fn();
  } finally {
    collector.agentId = previous;
  }
}

export type SynthesizerEvent =
  | { kind: "token"; text: string }
  | { kind: "stop"; stopReason?: string }
  | { kind: "error"; message: string; class: string };

export type SynthesizerOptions = {
  /** Override Bedrock model id without editing the orchestrator persona. */
  modelIdOverride?: string;
};

/**
 * Run the synthesizer agent and stream its tokens.
 *
 * Yields `kind: "token"` for each text delta and `kind: "stop"` at end.
 * On failure, yields a single `kind: "error"` and returns; the caller is
 * responsible for propagating an SSE error frame.
 *
 * The function wraps the entire stream consumption in
 * `withSynthesizerAgentId(...)` so all trace events emitted under the active
 * collector are tagged `agentId: "synthesizer"`.
 */
export async function* runSynthesizerAgent(
  input: SynthesizerInput,
  options: SynthesizerOptions = {},
): AsyncGenerator<SynthesizerEvent, { modelId: string; outputBytes: number; latencyMs: number }> {
  const orchestrator = getAgent("orchestrator");
  if (!orchestrator) {
    yield {
      kind: "error",
      class: "ConfigurationError",
      message: "Synthesizer requires the orchestrator agent config to resolve a model.",
    };
    return { modelId: "unknown", outputBytes: 0, latencyMs: 0 };
  }

  // Optional model override: deep-clone the orchestrator config and swap
  // the model id so `resolveModel(...)` returns a separate cached instance.
  const modelOverride = options.modelIdOverride?.trim() || process.env.MULTI_SYNTHESIS_MODEL_ID?.trim();
  const agentConfig = modelOverride
    ? { ...orchestrator, id: SYNTHESIZER_AGENT_ID, model: modelOverride }
    : orchestrator;
  const model = resolveModel(agentConfig);
  const modelId = (modelOverride || orchestrator.model || "unknown").trim();

  const userMessage = buildSynthesizerUserMessage(input);

  const collector = currentTrace();
  const t0 = Date.now();
  let outputBytes = 0;

  // Build the synthesizer agent. tools: [], no priorTurns seed — the
  // synthesis turn is stateless on top of the buffered specialist answers.
  const strandsAgent = new Agent({
    model,
    systemPrompt: SYSTEM_PROMPT,
    name: SYNTHESIZER_AGENT_NAME,
    id: SYNTHESIZER_AGENT_ID,
    printer: false,
    tools: [],
  });

  // Run the entire stream consumption under `agentId: "synthesizer"` so
  // every trace event auto-emitted by the Strands SDK + every Bedrock
  // requestMetadata is tagged correctly.
  type StreamItem =
    | { kind: "token"; text: string }
    | { kind: "stop"; stopReason?: string }
    | { kind: "error"; class: string; message: string };

  // Cannot easily yield from inside withSynthesizerAgentId, so collect the
  // events into a list and yield from the outer scope. For streaming, we
  // push tokens onto a queue and yield as they arrive — but a simpler
  // implementation that buffers all events at synthesis end is acceptable
  // here because the synthesis text is short (a single cohesive answer)
  // and the user has already seen specialist drafts stream live.
  //
  // To preserve true streaming, we use a producer/consumer pattern with a
  // pending-token queue. The consumer (this generator) waits on a promise
  // that the producer resolves whenever a new event arrives.
  const queue: StreamItem[] = [];
  let producerDone = false;
  let producerError: Error | undefined;
  let waiter: { resolve: () => void } | undefined;
  function notify(): void {
    const w = waiter;
    waiter = undefined;
    w?.resolve();
  }
  function waitForEvent(): Promise<void> {
    if (queue.length > 0 || producerDone || producerError) return Promise.resolve();
    return new Promise<void>((resolve) => {
      waiter = { resolve };
    });
  }

  const producer = withSynthesizerAgentId(collector, async () => {
    try {
      for await (const ev of strandsAgent.stream(userMessage)) {
        if (ev.type === "modelStreamUpdateEvent") {
          const inner = ev.event;
          if (inner.type === "modelContentBlockDeltaEvent") {
            if (inner.delta.type === "textDelta") {
              const t = inner.delta.text;
              if (t) {
                outputBytes += Buffer.byteLength(t, "utf8");
                queue.push({ kind: "token", text: t });
                notify();
              }
            }
          }
        } else if (ev.type === "afterModelCallEvent") {
          const stopReason = ev.stopData?.stopReason;
          queue.push({ kind: "stop", stopReason });
          notify();
        }
      }
    } catch (err) {
      producerError = err instanceof Error ? err : new Error(String(err));
      logger.warn("[synthesizer] stream failed", {
        modelId,
        error: producerError.message,
      });
      queue.push({
        kind: "error",
        class: producerError.name || "Error",
        message: producerError.message,
      });
      notify();
    } finally {
      producerDone = true;
      notify();
    }
  });

  try {
    while (true) {
      await waitForEvent();
      while (queue.length > 0) {
        const ev = queue.shift()!;
        if (ev.kind === "token") {
          yield { kind: "token", text: ev.text };
        } else if (ev.kind === "stop") {
          yield { kind: "stop", stopReason: ev.stopReason };
        } else if (ev.kind === "error") {
          yield { kind: "error", class: ev.class, message: ev.message };
        }
      }
      if (producerDone) break;
    }
  } finally {
    // Make sure the producer promise settles even if the consumer aborts.
    await producer.catch(() => undefined);
  }

  return { modelId, outputBytes, latencyMs: Date.now() - t0 };
}
