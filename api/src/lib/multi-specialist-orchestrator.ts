/**
 * Multi-specialist orchestration flow.
 *
 * Replaces the old single-specialist hand-off with:
 *   1. Multi-select classification (`classifyAgents(...)`).
 *   2. Sequential specialist runtime invocations (in classifier-ranked order).
 *   3. If 1 specialist: stream its tokens directly as the final answer
 *      (FAST PATH — no synthesis call, no extra latency or cost).
 *   4. If 2+ specialists: stream each specialist's draft attributed,
 *      then run the synthesizer agent to produce one cohesive final answer.
 *
 * The helper encapsulates:
 *   - `orchestrator.multi_route_decision` — emitted exactly once.
 *   - `orchestrator.specialist_draft` — one per specialist.
 *   - `orchestrator.synthesis` — emitted only on the synthesis path.
 *   - Wrapper-span attachment of nested specialist runtime trace events
 *     (each specialist owns its own `agentcore.invoke` wrapper span).
 *   - `phase: "specialist" | "synthesis"` token metadata.
 *
 * The caller (chat.ts route or agent-runtime-code.ts) provides:
 *   - A `SpecialistInvoker` callback that yields `RuntimeStreamEvent`s for
 *     a given specialist id and reports the wrapper span id on creation.
 *   - The active `TraceCollector` (from `currentTrace()` or explicit pass).
 *
 * Output:
 *   - An async generator of `MultiSpecialistFlowEvent`s the caller forwards
 *     to its SSE channel + uses for live UI rendering.
 *   - On completion, a `MultiSpecialistFlowResult` summarizing the final
 *     persisted answer + path taken.
 */

import { listAgents, getAgent } from "./config-scan.ts";
import { logger } from "./logger.ts";
import {
  classifyAgents,
  type MultiClassificationResult,
} from "./agent-classifier.ts";
import type { ChatMessage } from "./session-store.ts";
import type { ChatStreamPart } from "./chat-stream-types.ts";
import type { RuntimeStreamEvent } from "./runtime-sse.ts";
import type { TraceCollector } from "./trace-collector.ts";
import type { TraceEvent } from "./trace-types.ts";
import {
  runSynthesizerAgent,
  SYNTHESIZER_AGENT_ID,
  SYNTHESIZER_AGENT_NAME,
  type SpecialistAnswer,
} from "./specialist-answer-synthesizer.ts";

/**
 * Pluggable specialist invoker. Returns runtime stream events for one
 * specialist call.
 *
 * The invoker MUST report the wrapper span id (returned by
 * `trace.start("agentcore.invoke", ...)`) via `onWrapperSpan` so the
 * orchestrator can attach nested trace events under the matching wrapper.
 *
 * Used by both call sites:
 *   - `chat.ts` adapts `invokeAgentRuntime(...)` into this shape.
 *   - `agent-runtime-code.ts` adapts `invokeSpecialistStream(...)` into
 *     this shape.
 */
export type SpecialistInvoker = (params: {
  specialistId: string;
  message: string;
  priorTurns?: ChatMessage[];
  memoryContext?: string;
  onWrapperSpan: (spanId: string | undefined) => void;
}) => AsyncIterable<RuntimeStreamEvent>;

export type MultiSpecialistFlowOptions = {
  message: string;
  priorTurns?: ChatMessage[];
  memoryContext?: string;
  /** Trace collector for the outer turn. Required when tracing is on. */
  collector?: TraceCollector;
  /** Specialist runtime invoker. */
  invokeSpecialist: SpecialistInvoker;
  /**
   * Optional override for the classifier (mostly for tests). Defaults to
   * `classifyAgents` from `agent-classifier.ts`.
   */
  classifier?: typeof classifyAgents;
};

/**
 * Outer flow events. The caller forwards these to its SSE channel and
 * accumulates the final answer for persistence.
 *
 * Token-bearing events carry `phase` metadata so the caller can emit
 * SSE `token` frames with the correct attribution. All other events
 * are forwarded verbatim where they make sense (skill_loaded, tool_call,
 * agent_active, handoff, stream_error).
 */
export type MultiSpecialistFlowEvent =
  /** A specialist call has started. UI can render an attributed draft block. */
  | {
      kind: "specialist_started";
      rank: number;
      specialistId: string;
      specialistName: string;
    }
  /** Specialist runtime stream-part. The caller writes SSE according to part type. */
  | {
      kind: "specialist_stream";
      rank: number;
      specialistId: string;
      specialistName: string;
      part: ChatStreamPart;
    }
  /** Specialist runtime trace event — caller forwards live to UI. */
  | {
      kind: "specialist_trace";
      rank: number;
      specialistId: string;
      event: TraceEvent;
    }
  /** Specialist call has finished (success / failure / fast-path-final). */
  | {
      kind: "specialist_ended";
      rank: number;
      specialistId: string;
      specialistName: string;
      status: "final" | "success" | "failed";
      answerBytes: number;
      latencyMs: number;
      failure?: { class: string; message: string };
    }
  /** Synthesis pass has started (only emitted on the 2+ specialist path). */
  | {
      kind: "synthesis_started";
      modelId: string;
    }
  /** Synthesis token. The caller writes SSE with `phase: "synthesis"`. */
  | {
      kind: "synthesis_stream";
      part: ChatStreamPart;
    }
  /** Synthesis pass has finished. */
  | {
      kind: "synthesis_ended";
      outputBytes: number;
      latencyMs: number;
    }
  /** Terminal failure. Caller emits SSE error + done with error. */
  | {
      kind: "stream_error";
      code: string;
      message: string;
    };

/** Final result of the orchestration. */
export type MultiSpecialistFlowResult = {
  pathTaken: "single" | "synthesis";
  /** The persisted assistant message (specialist answer on fast path, synthesis on multi). */
  finalAnswer: string;
  /** Specialists that returned successful answers. */
  successfulSpecialists: Array<{ agentId: string; agentName: string; answerBytes: number }>;
  /** Specialists that failed mid-stream. */
  failedSpecialists: Array<{ agentId: string; agentName: string; failureMessage: string }>;
  /** Per-specialist wrapper span ids for nested trace attachment. */
  wrapperSpansBySpecialist: Map<string, string>;
};

function nameFor(agentId: string): string {
  return getAgent(agentId)?.name ?? agentId;
}

/**
 * Run the multi-specialist orchestration.
 *
 * The caller iterates the returned generator. Trace events are emitted on
 * the collector as side effects of the iteration. The generator's `return`
 * value carries the final answer + per-specialist wrapper span ids.
 *
 * Note on wrapper-span attachment: the orchestrator collects nested trace
 * events per specialist into a buffer indexed by `rank` and emits the
 * corresponding `agentcore.nested_trace` event under each wrapper after
 * the specialist finishes. The caller is NOT responsible for
 * `attachEventsNested(...)` — this helper handles it because it knows
 * which wrapper span belongs to which specialist.
 */
export async function* runMultiSpecialistFlow(
  options: MultiSpecialistFlowOptions,
): AsyncGenerator<MultiSpecialistFlowEvent, MultiSpecialistFlowResult> {
  const collector = options.collector;
  const classifier = options.classifier ?? classifyAgents;

  // -------------------------------------------------------------------------
  // 1. Classify
  // -------------------------------------------------------------------------
  const decisionStartTs = Date.now();
  const classification: MultiClassificationResult | undefined = await classifier({
    message: options.message,
    priorTurns: options.priorTurns,
  });

  // No specialist confidently selected — emit a clear stream_error so the
  // caller surfaces it in SSE. The orchestrator persona is a router, not
  // an answerer; we never fall back to it.
  if (!classification || classification.selections.length === 0) {
    yield {
      kind: "stream_error",
      code: "NO_SPECIALIST_ROUTE",
      message: "Could not classify your message to a specialist; please rephrase.",
    };
    return {
      pathTaken: "single",
      finalAnswer: "",
      successfulSpecialists: [],
      failedSpecialists: [],
      wrapperSpansBySpecialist: new Map(),
    };
  }

  // Filter out any specialist whose runtime ARN is not configured. We do
  // NOT call into the invoker abstraction here — instead the caller is
  // expected to throw inside its invoker if the ARN is missing. We rely on
  // the invoker erroring out and convert that to a `failed` specialist
  // status below.

  const pathTaken: "single" | "synthesis" =
    classification.selections.length >= 2 ? "synthesis" : "single";

  // -------------------------------------------------------------------------
  // 2. Emit `orchestrator.multi_route_decision` exactly once.
  // -------------------------------------------------------------------------
  collector?.event("orchestrator.multi_route_decision", {
    selected: classification.selections.map((s) => ({
      agentId: s.agentId,
      agentName: nameFor(s.agentId),
      score: s.score,
      source: s.source,
      reasoning: s.reasoning,
    })),
    rejected: classification.rejectedCandidates,
    thresholds: classification.thresholds,
    pathTaken,
    inputMessage: options.message.slice(0, 500),
    latencyMs: Date.now() - decisionStartTs,
  });

  // -------------------------------------------------------------------------
  // 3. Run specialists sequentially. Buffer answer text per specialist.
  // -------------------------------------------------------------------------
  const specialistAnswers: SpecialistAnswer[] = [];
  const wrapperSpansBySpecialist = new Map<string, string>();
  // Collected nested trace events per specialist (rank -> events). We
  // attach each batch under that specialist's wrapper after it finishes.
  const nestedEventsByRank = new Map<number, TraceEvent[]>();

  for (let rank = 0; rank < classification.selections.length; rank++) {
    const sel = classification.selections[rank];
    const specialistId = sel.agentId;
    const specialistName = nameFor(specialistId);

    yield { kind: "specialist_started", rank, specialistId, specialistName };

    const startTs = Date.now();
    let answerText = "";
    let answerBytes = 0;
    let failure: { class: string; message: string } | undefined;
    let wrapperSpanId: string | undefined;
    const nestedEvents: TraceEvent[] = [];
    nestedEventsByRank.set(rank, nestedEvents);

    try {
      const stream = options.invokeSpecialist({
        specialistId,
        message: options.message,
        priorTurns: options.priorTurns,
        memoryContext: options.memoryContext,
        onWrapperSpan: (spanId) => {
          if (spanId) {
            wrapperSpanId = spanId;
            wrapperSpansBySpecialist.set(specialistId, spanId);
          }
        },
      });

      for await (const ev of stream) {
        if (ev.kind === "stream") {
          const part = ev.part;
          if (part.type === "token") {
            answerText += part.text;
            answerBytes += Buffer.byteLength(part.text, "utf8");
            // On the single-specialist fast path, tokens flow through with
            // no `phase` so they're persisted as the final answer.
            // On the synthesis path, tokens are tagged `phase: "specialist"`
            // so the UI renders them as a draft block but does NOT persist.
            const taggedPart: ChatStreamPart =
              pathTaken === "single"
                ? part
                : {
                    type: "token",
                    text: part.text,
                    phase: "specialist",
                    specialistId,
                    specialistName,
                    rank,
                  };
            yield {
              kind: "specialist_stream",
              rank,
              specialistId,
              specialistName,
              part: taggedPart,
            };
          } else if (part.type === "stream_error") {
            failure = { class: part.code, message: part.message };
            // Continue iterating to drain the runtime stream; do not break.
            // The runtime may still emit a `done` with the same error.
          } else {
            // Forward skill_loaded / tool_call / agent_active / handoff verbatim.
            yield {
              kind: "specialist_stream",
              rank,
              specialistId,
              specialistName,
              part,
            };
          }
        } else if (ev.kind === "trace") {
          nestedEvents.push(ev.event);
          yield { kind: "specialist_trace", rank, specialistId, event: ev.event };
        } else if (ev.kind === "done") {
          if (ev.payload.error && !failure) {
            failure = {
              class: ev.payload.error.code,
              message: ev.payload.error.message,
            };
          }
        }
      }
    } catch (err) {
      const klass = err instanceof Error ? err.constructor.name : "Error";
      const message = err instanceof Error ? err.message : String(err);
      logger.warn("[multi-orchestrator] specialist invocation threw", {
        specialistId,
        rank,
        error: message,
      });
      failure = { class: klass, message };
    }

    const latencyMs = Date.now() - startTs;
    const status: "final" | "success" | "failed" = failure
      ? "failed"
      : pathTaken === "single"
        ? "final"
        : "success";

    // Attach nested events under this specialist's wrapper span (if any).
    if (collector && wrapperSpanId && nestedEvents.length > 0) {
      try {
        collector.attachEventsNested(nestedEvents, wrapperSpanId, {
          logger: { warn: (msg, ctx) => logger.warn(msg, ctx as Record<string, unknown> | undefined) },
        });
      } catch (err) {
        logger.warn("[multi-orchestrator] attachEventsNested failed", {
          specialistId,
          rank,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }

    // Emit the per-specialist draft trace event.
    collector?.event("orchestrator.specialist_draft", {
      rank,
      agentId: specialistId,
      agentName: specialistName,
      status,
      answerBytes,
      // Cap the preview at 4 KB; per-event-type DEBUG_CAP_FIELDS allows up
      // to 64 KB but most answers fit comfortably under 4 KB.
      answerPreview: answerText.length > 4096 ? answerText.slice(0, 4096) : answerText,
      latencyMs,
      runtimeSpanId: wrapperSpanId,
      failureClass: failure?.class,
      failureMessage: failure?.message,
    });

    yield {
      kind: "specialist_ended",
      rank,
      specialistId,
      specialistName,
      status,
      answerBytes,
      latencyMs,
      failure,
    };

    // Track for synthesis (multi-path) or final return (single-path).
    if (failure) {
      specialistAnswers.push({
        agentId: specialistId,
        agentName: specialistName,
        status: "failed",
        answerText: "",
        failureMessage: failure.message,
      });
    } else if (!answerText.trim()) {
      specialistAnswers.push({
        agentId: specialistId,
        agentName: specialistName,
        status: "empty",
        answerText: "",
      });
    } else {
      specialistAnswers.push({
        agentId: specialistId,
        agentName: specialistName,
        status: "success",
        answerText,
      });
    }
  }

  // -------------------------------------------------------------------------
  // 4. Path branch: single → return specialist's text; multi → synthesize.
  // -------------------------------------------------------------------------
  const successful = specialistAnswers.filter((a) => a.status === "success");
  const failed = specialistAnswers.filter((a) => a.status === "failed");

  if (pathTaken === "single") {
    const only = specialistAnswers[0];
    return {
      pathTaken: "single",
      finalAnswer: only?.status === "success" ? only.answerText : "",
      successfulSpecialists: successful.map((a) => ({
        agentId: a.agentId,
        agentName: a.agentName,
        answerBytes: Buffer.byteLength(a.answerText, "utf8"),
      })),
      failedSpecialists: failed.map((a) => ({
        agentId: a.agentId,
        agentName: a.agentName,
        failureMessage: a.failureMessage ?? "unknown error",
      })),
      wrapperSpansBySpecialist,
    };
  }

  // -------------------------------------------------------------------------
  // 5. Synthesis path: ≥ 2 specialists. Run synthesizer over their answers.
  //    If ALL specialists failed, surface a stream_error.
  // -------------------------------------------------------------------------
  if (successful.length === 0) {
    const lastFailure = failed[failed.length - 1];
    yield {
      kind: "stream_error",
      code: "ALL_SPECIALISTS_FAILED",
      message:
        lastFailure?.failureMessage ??
        "All selected specialists failed to answer this turn.",
    };
    return {
      pathTaken: "synthesis",
      finalAnswer: "",
      successfulSpecialists: [],
      failedSpecialists: failed.map((a) => ({
        agentId: a.agentId,
        agentName: a.agentName,
        failureMessage: a.failureMessage ?? "unknown error",
      })),
      wrapperSpansBySpecialist,
    };
  }

  const synthesisStartTs = Date.now();
  let synthesisOutputBytes = 0;
  let finalAnswer = "";
  let synthesisModelId = "unknown";
  let synthesisFailed: { code: string; message: string } | undefined;

  // Stream the synthesizer agent. It emits trace events tagged
  // `agentId: "synthesizer"` thanks to `withSynthesizerAgentId(...)` inside
  // `runSynthesizerAgent`.
  const synthGen = runSynthesizerAgent({
    userMessage: options.message,
    specialistAnswers,
  });

  // Pull one event first to peek at the model id (the generator does not
  // expose it before the first token), then continue. We can also surface
  // the model id via a separate `start` event from runSynthesizerAgent —
  // but simpler: emit `synthesis_started` with the orchestrator's model id
  // (or the override env var) before consuming.
  synthesisModelId =
    process.env.MULTI_SYNTHESIS_MODEL_ID?.trim() ||
    getAgent("orchestrator")?.model?.trim() ||
    "unknown";
  yield { kind: "synthesis_started", modelId: synthesisModelId };

  while (true) {
    const next = await synthGen.next();
    if (next.done) {
      // The generator returns `{ modelId, outputBytes, latencyMs }`.
      synthesisModelId = next.value.modelId || synthesisModelId;
      break;
    }
    const ev = next.value;
    if (ev.kind === "token") {
      finalAnswer += ev.text;
      synthesisOutputBytes += Buffer.byteLength(ev.text, "utf8");
      const part: ChatStreamPart = {
        type: "token",
        text: ev.text,
        phase: "synthesis",
      };
      yield { kind: "synthesis_stream", part };
    } else if (ev.kind === "error") {
      synthesisFailed = { code: ev.class, message: ev.message };
    }
    // `kind: "stop"` is currently informational; we let model.usage carry
    // token counts in trace.
  }

  const synthesisLatencyMs = Date.now() - synthesisStartTs;

  if (synthesisFailed) {
    collector?.event("orchestrator.synthesis", {
      modelId: synthesisModelId,
      inputSpecialists: successful.map((a) => ({
        agentId: a.agentId,
        agentName: a.agentName,
        answerBytes: Buffer.byteLength(a.answerText, "utf8"),
      })),
      omittedSpecialists: failed.map((a) => ({ agentId: a.agentId, reason: "failed" as const })),
      outputBytes: synthesisOutputBytes,
      latencyMs: synthesisLatencyMs,
      finalAnswerPersisted: false,
    });
    yield {
      kind: "stream_error",
      code: "SYNTHESIS_FAILED",
      message: synthesisFailed.message,
    };
    return {
      pathTaken: "synthesis",
      finalAnswer: "",
      successfulSpecialists: successful.map((a) => ({
        agentId: a.agentId,
        agentName: a.agentName,
        answerBytes: Buffer.byteLength(a.answerText, "utf8"),
      })),
      failedSpecialists: failed.map((a) => ({
        agentId: a.agentId,
        agentName: a.agentName,
        failureMessage: a.failureMessage ?? "unknown error",
      })),
      wrapperSpansBySpecialist,
    };
  }

  collector?.event("orchestrator.synthesis", {
    modelId: synthesisModelId,
    inputSpecialists: successful.map((a) => ({
      agentId: a.agentId,
      agentName: a.agentName,
      answerBytes: Buffer.byteLength(a.answerText, "utf8"),
    })),
    omittedSpecialists: [
      ...failed.map((a) => ({ agentId: a.agentId, reason: "failed" as const })),
      ...specialistAnswers
        .filter((a) => a.status === "empty")
        .map((a) => ({ agentId: a.agentId, reason: "empty" as const })),
    ],
    outputBytes: synthesisOutputBytes,
    latencyMs: synthesisLatencyMs,
    finalAnswerPersisted: Boolean(finalAnswer.trim()),
  });

  yield {
    kind: "synthesis_ended",
    outputBytes: synthesisOutputBytes,
    latencyMs: synthesisLatencyMs,
  };

  return {
    pathTaken: "synthesis",
    finalAnswer,
    successfulSpecialists: successful.map((a) => ({
      agentId: a.agentId,
      agentName: a.agentName,
      answerBytes: Buffer.byteLength(a.answerText, "utf8"),
    })),
    failedSpecialists: failed.map((a) => ({
      agentId: a.agentId,
      agentName: a.agentName,
      failureMessage: a.failureMessage ?? "unknown error",
    })),
    wrapperSpansBySpecialist,
  };
}

// -- helpers exported for tests --------------------------------------------

/** Names of all currently-routable specialists. Used by tests / docs. */
export function listKnownSpecialists(): string[] {
  return listAgents()
    .map((a) => a.id)
    .filter((id) => id !== "orchestrator" && id !== SYNTHESIZER_AGENT_ID);
}

export const _internal = {
  SYNTHESIZER_AGENT_ID,
  SYNTHESIZER_AGENT_NAME,
};
