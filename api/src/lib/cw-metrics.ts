/**
 * CloudWatch custom metrics emitter — Embedded Metric Format (EMF).
 *
 * EMF lets us ship custom metrics as a JSON log line: CloudWatch detects the
 * `_aws.CloudWatchMetrics` envelope and extracts the metric values without
 * any SDK call, no extra IAM, no extra container. The metric also stays in
 * the log group as a raw record, so Logs Insights can still group by
 * dimensions that didn't make it into the metric.
 *
 * The Phase 3 fleet dashboards + alarms read the following namespaces:
 *   - Multiagent/Chat    -> TurnsTotal, TurnErrors, TurnLatencyMs,
 *                          AgentCoreInvokes, AgentCoreInvokeErrors
 *   - Multiagent/Mongo   -> QueryCount, QueryLatencyMs, VectorSearchLatencyMs
 *   - Multiagent/Memory  -> FactsExtracted, FactsWritten, EmbeddingFailures,
 *                          MemoryEmbeddingSkipped (per-code)
 *   - Multiagent/Chat    -> ChatMirrorEmbeddingSkipped (per-code, in addition
 *                          to the chat metrics above)
 *
 * Without this emitter, those widgets stay empty. Call sites:
 *   - `recordChatTurn(...)`   — at chat.turn.end in run-chat-stream
 *   - `recordAgentCoreInvoke` — at agentcore.invoke end in agentcore-runtime
 *   - `recordMongoQuery`      — by tool.mongo end / mongo.vector_search end
 *   - `recordMemoryWrite`     — by long-term-memory write/embedding paths
 *
 * Local dev: emission is a no-op write to stdout in the same JSON shape
 * everything else uses; CloudWatch agent on EC2 ships it. Set
 * METRICS_EMITTER_ENABLED=0 to silence entirely (CI / unit tests).
 */

import { trace } from "@opentelemetry/api";

type Unit =
  | "Count"
  | "Milliseconds"
  | "Microseconds"
  | "Seconds"
  | "Bytes"
  | "None";

export type MetricDef = {
  name: string;
  unit?: Unit;
};

export type EmitOptions = {
  namespace: string;
  /**
   * Dimensions to associate with the metrics. CloudWatch creates one metric
   * series per unique dimension-value combination, so keep cardinality low
   * (agentId, modelId, errorClass: OK. userId: NOT OK as a dimension).
   */
  dimensions: Record<string, string>;
  metrics: Array<{ def: MetricDef; value: number }>;
  /** Extra fields included on the raw log record (NOT extracted as metrics). */
  context?: Record<string, unknown>;
};

function emitterEnabled(): boolean {
  const v = process.env.METRICS_EMITTER_ENABLED?.trim().toLowerCase();
  if (v === "0" || v === "false") return false;
  return true;
}

/**
 * Write a single EMF record. Routes to stdout in the same JSON shape as our
 * structured logger so the existing CloudWatch agent file-collector picks
 * it up. We deliberately do NOT write through `logger.ts` because EMF needs
 * the `_aws` envelope at the top level, not nested under our usual fields.
 */
export function emitMetric(opts: EmitOptions): void {
  if (!emitterEnabled()) return;
  try {
    const dims = Object.keys(opts.dimensions).filter((k) => opts.dimensions[k] != null && opts.dimensions[k] !== "");
    const span = trace.getActiveSpan();
    const sc = span?.spanContext();

    const record: Record<string, unknown> = {
      _aws: {
        Timestamp: Date.now(),
        CloudWatchMetrics: [
          {
            Namespace: opts.namespace,
            Dimensions: dims.length > 0 ? [dims] : [[]],
            Metrics: opts.metrics.map(({ def }) => ({
              Name: def.name,
              Unit: def.unit ?? "Count",
            })),
          },
        ],
      },
      // Dimensions live at the top level so the EMF parser can resolve them.
      ...opts.dimensions,
      // Each metric value lives at the top level keyed by metric name.
      ...Object.fromEntries(opts.metrics.map(({ def, value }) => [def.name, value])),
      // Correlation (NOT a metric / dimension).
      ...(sc ? { trace_id: sc.traceId, span_id: sc.spanId } : {}),
      ...(opts.context ?? {}),
      service: process.env.OTEL_SERVICE_NAME,
      channel: "metric",
    };
    // CloudWatch EMF records must be single-line JSON terminated with \n.
    process.stdout.write(`${JSON.stringify(record)}\n`);
  } catch {
    // Emission must never crash a chat turn.
  }
}

// =============================================================================
// Convenience helpers — call these from the chat / agentcore / mongo paths.
// Keep the signatures small; widen `context` for free-form correlation fields.
// =============================================================================

/** Emitted at chat.turn.end. `error` bumps TurnErrors; latencyMs always present. */
export function recordChatTurn(opts: {
  agentId?: string;
  latencyMs: number;
  error?: boolean;
  errorClass?: string;
  context?: Record<string, unknown>;
}): void {
  const metrics: EmitOptions["metrics"] = [
    { def: { name: "TurnsTotal", unit: "Count" }, value: 1 },
    { def: { name: "TurnLatencyMs", unit: "Milliseconds" }, value: opts.latencyMs },
    // Always emit TurnErrors (0 on success) so the dashboard line stays visible
    // and the SLO-burn alarm can compute error_rate even in quiet periods.
    { def: { name: "TurnErrors", unit: "Count" }, value: opts.error ? 1 : 0 },
  ];
  emitMetric({
    namespace: "Multiagent/Chat",
    dimensions: {
      agentId: opts.agentId ?? "unknown",
    },
    metrics,
    context: {
      ...(opts.errorClass ? { errorClass: opts.errorClass } : {}),
      ...(opts.context ?? {}),
    },
  });
}

/** Emitted at agentcore.invoke end. */
export function recordAgentCoreInvoke(opts: {
  agentId?: string;
  mode?: string;
  latencyMs: number;
  error?: boolean;
  errorClass?: string;
}): void {
  const metrics: EmitOptions["metrics"] = [
    { def: { name: "AgentCoreInvokes", unit: "Count" }, value: 1 },
    { def: { name: "AgentCoreInvokeLatencyMs", unit: "Milliseconds" }, value: opts.latencyMs },
    // Always emit AgentCoreInvokeErrors (0 on success) so the dashboard line
    // stays visible and the runtime-failure alarm has continuous data.
    { def: { name: "AgentCoreInvokeErrors", unit: "Count" }, value: opts.error ? 1 : 0 },
  ];
  emitMetric({
    namespace: "Multiagent/Chat",
    dimensions: {
      agentId: opts.agentId ?? "unknown",
      mode: opts.mode ?? "unknown",
    },
    metrics,
    context: opts.errorClass ? { errorClass: opts.errorClass } : undefined,
  });
}

/** Emitted at mongo.query / mongo.vector_search end. */
export function recordMongoQuery(opts: {
  collection?: string;
  kind: "find" | "aggregate" | "vector_search" | "other";
  latencyMs: number;
}): void {
  const metrics: EmitOptions["metrics"] = [
    { def: { name: "QueryCount", unit: "Count" }, value: 1 },
    { def: { name: "QueryLatencyMs", unit: "Milliseconds" }, value: opts.latencyMs },
  ];
  if (opts.kind === "vector_search") {
    metrics.push({ def: { name: "VectorSearchLatencyMs", unit: "Milliseconds" }, value: opts.latencyMs });
  }
  emitMetric({
    namespace: "Multiagent/Mongo",
    dimensions: {
      collection: opts.collection ?? "unknown",
      kind: opts.kind,
    },
    metrics,
  });
}

/** Emitted at long-term memory write end. */
export function recordMemoryWrite(opts: {
  agentId?: string;
  factsExtracted: number;
  factsWritten: number;
  embeddingFailures: number;
}): void {
  emitMetric({
    namespace: "Multiagent/Memory",
    dimensions: {
      agentId: opts.agentId ?? "unknown",
    },
    metrics: [
      { def: { name: "FactsExtracted", unit: "Count" }, value: opts.factsExtracted },
      { def: { name: "FactsWritten", unit: "Count" }, value: opts.factsWritten },
      { def: { name: "EmbeddingFailures", unit: "Count" }, value: opts.embeddingFailures },
    ],
  });
}

/**
 * Strict-mode-only: emitted when one or more LTM facts could not be embedded
 * because the declared `EMBEDDINGS_PROVIDER` failed. Carries the
 * `EmbedErrorCode` as a low-cardinality dimension so dashboards can group
 * `voyage_strict_failed` separately from `titan_strict_failed`.
 */
export function recordMemoryEmbeddingSkipped(opts: {
  agentId?: string;
  code: string;
  count: number;
}): void {
  emitMetric({
    namespace: "Multiagent/Memory",
    dimensions: {
      agentId: opts.agentId ?? "unknown",
      code: opts.code,
    },
    metrics: [
      { def: { name: "MemoryEmbeddingSkipped", unit: "Count" }, value: opts.count },
    ],
  });
}

/**
 * Strict-mode-only: emitted from `mirrorMessageToMongo` when chat-message
 * embedding failed. The chat row is still written to `chat_messages` (without
 * `embedding`/`embeddingModel` fields and with an `embeddingError` marker), so
 * this metric tracks the rate at which mirrored rows are missing vectors.
 */
export function recordChatMirrorEmbeddingSkipped(opts: {
  agentId?: string;
  code: string;
}): void {
  emitMetric({
    namespace: "Multiagent/Chat",
    dimensions: {
      agentId: opts.agentId ?? "unknown",
      code: opts.code,
    },
    metrics: [
      { def: { name: "ChatMirrorEmbeddingSkipped", unit: "Count" }, value: 1 },
    ],
  });
}
