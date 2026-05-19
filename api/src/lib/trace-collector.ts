/**
 * Per-turn trace collector. One instance per chat turn.
 *
 * Responsibilities:
 *  - Mint `traceId` (uuid) once.
 *  - Track an open-span stack so `currentTrace()?.span(...)` adapters auto-parent.
 *  - Emit events live (`onEvent` listeners) so the SSE writer can push them.
 *  - Enforce per-event + per-turn byte caps. When the per-turn cap is exceeded,
 *    drop large/low-priority events but keep `chat.turn.start/end`, `handoff.decision`,
 *    `model.usage`, `error`, and span start/ends. Record drop count on
 *    `chat.turn.end.summary.eventsDropped`.
 *  - Summarize `model.usage` events via `model-pricing.ts` for the inline cost tile.
 *  - Maintain `pendingAssistantText` (4 KB FIFO) — populated by `run-chat-stream.ts`
 *    on each text delta, snapshotted on every `BeforeToolCallEvent` so a
 *    `handoff.decision` payload carries the *orchestrator reasoning* preceding it.
 *  - `attachEventsNested(...)` — splice nested AgentCore trace events into the
 *    parent collector with id rewiring + clock normalization. (§6.3.1 of plan.)
 */

import { type Span, SpanStatusCode, trace as otelTrace } from "@opentelemetry/api";
import { costOfUsage } from "./model-pricing.ts";
import { recordMongoQuery } from "./cw-metrics.ts";
import type {
  ChatTurnSummary,
  Trace,
  TraceEvent,
  TraceEventType,
  ModelUsagePayload,
} from "./trace-types.ts";

// ---------------------------------------------------------------------------
// Env knobs (kept here so callers don't have to remember the names)
//
// Note: these read `process.env` per-call rather than capturing it at module
// load. Capturing it at load time made test isolation fragile — any test
// file that did `process.env = { ...saved }` in afterEach replaced the env
// object, and a captured reference would no longer see live mutations.
// ---------------------------------------------------------------------------

function envInt(name: string, fallback: number, env: NodeJS.ProcessEnv = process.env): number {
  const v = env[name];
  if (!v) return fallback;
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function envBool(name: string, fallback: boolean, env: NodeJS.ProcessEnv = process.env): boolean {
  const v = env[name]?.trim().toLowerCase();
  if (v === undefined || v === "") return fallback;
  if (v === "0" || v === "false") return false;
  if (v === "1" || v === "true") return true;
  return fallback;
}

export function tracingEnabled(): boolean {
  return envBool("TRACING_ENABLED", true);
}

const DEFAULT_MAX_EVENT_BYTES = 16_384;
const DEFAULT_MAX_TURN_BYTES = 2_097_152;
const DEFAULT_PENDING_TEXT_BYTES = 4096;

/** Events that should never be dropped by the byte-cap logic. */
const PROTECTED_TYPES: ReadonlySet<TraceEventType> = new Set<TraceEventType>([
  "chat.turn.start",
  "chat.turn.end",
  "handoff.decision",
  "model.usage",
  "model.stop",
  "agentcore.invoke",
  "agentcore.classification",
  "agentcore.nested_trace",
  "latency.checkpoint",
  "error",
  "tool.call", // start/end stubs kept; large payloads stripped first
  "mongo.intent",
  "mongo.query",
  "mongo.result",
  "mongo.vector_search",
]);

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

function uuid(): string {
  // Bun + Node 22 both expose crypto.randomUUID.
  return (globalThis.crypto as Crypto).randomUUID();
}

function nowMs(): number {
  return Date.now();
}

function safeStringify(v: unknown): string {
  try {
    return JSON.stringify(v);
  } catch {
    return "";
  }
}

function approxBytes(ev: TraceEvent): number {
  return safeStringify(ev).length;
}

// PII redaction keys (lower-case match).
const PII_KEYS = new Set(["email", "phone", "address", "name", "dob", "ssn"]);

function redactDeep(value: unknown, depth = 0): unknown {
  if (depth > 6) return value;
  if (value == null) return value;
  if (typeof value === "string") {
    return value.length > 512 ? value.slice(0, 512) + "…[truncated]" : value;
  }
  if (Array.isArray(value)) return value.map((v) => redactDeep(v, depth + 1));
  if (typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      if (PII_KEYS.has(k.toLowerCase())) out[k] = "[redacted]";
      else out[k] = redactDeep(v, depth + 1);
    }
    return out;
  }
  return value;
}

// ---------------------------------------------------------------------------
// Collector
// ---------------------------------------------------------------------------

export type TraceCollectorInit = {
  sessionId: string;
  messageId: string;
  agentId: string;
  userId?: string;
  requestId?: string;
  /** Optional env overrides for tests. */
  env?: NodeJS.ProcessEnv;
};

type Listener = (ev: TraceEvent) => void;

export class TraceCollector {
  readonly traceId: string;
  readonly sessionId: string;
  readonly messageId: string;
  readonly userId?: string;
  agentId: string;
  readonly requestId?: string;
  readonly startTs: number;

  private events: TraceEvent[] = [];
  private listeners: Listener[] = [];
  private spanStack: string[] = [];
  private startedSpans = new Map<string, { type: TraceEventType; startTs: number; agentId?: string; parentId?: string }>();
  /**
   * Bridge from internal span id -> OTel Span. Populated by `start()` when
   * OTel is bootstrapped (api/src/lib/otel.ts has installed a tracer
   * provider). `end()` closes the matching OTel span; `event()` records the
   * one-off as an OTel span event on the current OTel span. Wrapped in
   * try/catch so OTel-side failures cannot destabilize the trace pipeline.
   *
   * `attachEventsNested()` deliberately bypasses this — AgentCore Runtime
   * already emits its own gen_ai.* spans, and re-emitting from spliced
   * events would produce a duplicate hierarchy in /aws/spans.
   */
  private otelSpans = new Map<string, Span>();

  // Byte accounting
  private totalBytes = 0;
  readonly maxEventBytes: number;
  readonly maxTurnBytes: number;
  private degraded = false;
  private eventsDropped = 0;
  private nestedEventsDropped = 0;

  // Redaction
  readonly redact: boolean;

  // Misc instrumentation
  private pendingAssistantText = "";
  private readonly pendingTextCap: number;
  /** Per-turn counters consumed by `summary()`. */
  private toolCallCount = 0;
  private mongoQueryCount = 0;
  private mongoDocsReturned = 0;
  private mcpCallCount = 0;
  private agentcoreHops = 0;
  private agentcoreRuntimeMs = 0;
  private bytesIn = 0;
  private bytesOut = 0;
  private finalAgentId?: string;

  constructor(init: TraceCollectorInit) {
    this.traceId = uuid();
    this.sessionId = init.sessionId;
    this.messageId = init.messageId;
    this.agentId = init.agentId;
    this.userId = init.userId;
    this.requestId = init.requestId;
    this.startTs = nowMs();
    const env = init.env ?? process.env;
    this.maxEventBytes = envInt("TRACE_MAX_EVENT_BYTES", DEFAULT_MAX_EVENT_BYTES, env);
    this.maxTurnBytes = envInt("TRACE_MAX_TURN_BYTES", DEFAULT_MAX_TURN_BYTES, env);
    this.pendingTextCap = envInt("TRACE_PENDING_TEXT_BYTES", DEFAULT_PENDING_TEXT_BYTES, env);
    const v = env.TRACE_REDACT?.trim().toLowerCase();
    this.redact = v === "1" || v === "true";
  }

  // -------- Listener pub/sub --------

  onEvent(l: Listener): () => void {
    this.listeners.push(l);
    return () => {
      const i = this.listeners.indexOf(l);
      if (i !== -1) this.listeners.splice(i, 1);
    };
  }

  // -------- Span helpers --------

  /** Begin a span. Returns the span id (use for `end()` / `child()`). */
  start(
    type: TraceEventType,
    payload: Record<string, unknown> = {},
    opts: { parentId?: string; agentId?: string } = {},
  ): string {
    const id = uuid();
    const parentId = opts.parentId ?? this.currentSpanId();
    const agentId = opts.agentId ?? this.agentId;
    this.startedSpans.set(id, { type, startTs: nowMs(), agentId, parentId });
    this.spanStack.push(id);
    this.emit({
      id,
      parentId,
      type,
      ts: nowMs(),
      agentId,
      payload: payload as never,
    } as TraceEvent);
    this.emitOtelStart(id, type, payload, agentId);
    return id;
  }

  /** Close an open span by id. */
  end(id: string, payload: Record<string, unknown> = {}): void {
    const span = this.startedSpans.get(id);
    const ts = nowMs();
    const durationMs = span ? Math.max(0, ts - span.startTs) : undefined;
    this.startedSpans.delete(id);
    // pop matching id from the stack (defensive — may not be on top under concurrency)
    const idx = this.spanStack.lastIndexOf(id);
    if (idx !== -1) this.spanStack.splice(idx, 1);
    // Tally tool / mongo / mcp / agentcore counters.
    if (span?.type === "tool.call") this.toolCallCount += 1;
    if (span?.type === "mongo.query") this.mongoQueryCount += 1;
    if (span?.type === "tool.mcp") this.mcpCallCount += 1;
    if (span?.type === "agentcore.invoke") {
      this.agentcoreHops += 1;
      if (durationMs) this.agentcoreRuntimeMs += durationMs;
    }
    this.emit({
      id: uuid(),
      parentId: id,
      type: (span?.type ?? "tool.call") as TraceEventType,
      ts,
      durationMs,
      agentId: span?.agentId,
      payload: payload as never,
    } as TraceEvent);
    this.emitOtelEnd(id, payload);
  }

  /** Emit a one-off (non-span) event. */
  event(
    type: TraceEventType,
    payload: Record<string, unknown> = {},
    opts: { parentId?: string; agentId?: string } = {},
  ): string {
    const id = uuid();
    const parentId = opts.parentId ?? this.currentSpanId();
    const agentId = opts.agentId ?? this.agentId;
    this.emit({
      id,
      parentId,
      type,
      ts: nowMs(),
      agentId,
      payload: payload as never,
    } as TraceEvent);
    this.emitOtelEvent(type, payload, parentId);
    // maybeEmitMetric is invoked centrally from `emit()` so spliced nested
    // events (specialist runtimes → orchestrator via attachEventsNested) also
    // bridge to CloudWatch EMF metrics. Don't double-emit from here.
    return id;
  }

  /**
   * Bridge known trace event types to CloudWatch custom metrics (EMF). Keeps
   * the metric emission centralized so individual mongo/tool call sites stay
   * focused on their main logic and don't have to import cw-metrics. Wrapped
   * in try/catch because metric emission must never destabilize a chat turn.
   */
  private maybeEmitMetric(type: TraceEventType, payload: Record<string, unknown>, agentId?: string): void {
    try {
      // mongo.result is the completion event; mongo.query is the start event.
      // Only the result carries latencyMs / status / errorClass. We bridge
      // from mongo.result so the Mongo dashboard widgets reflect actual
      // round-trip latency, not the synchronous payload-build time of the
      // start event (which is ~0ms and meaningless).
      if (type === "mongo.result") {
        const latencyMs = typeof payload?.latencyMs === "number" ? payload.latencyMs : undefined;
        if (latencyMs === undefined) return;
        const status = typeof payload?.status === "string" ? payload.status : undefined;
        // mongo.result doesn't carry collection/op — those live on the matching
        // mongo.query start event. To keep dimensions stable we encode kind as
        // "result" and let widgets group by `status` (ok/empty/error) plus
        // agent. Collection-level breakdowns stay in Logs Insights for now.
        const kind = status === "error" ? "other" : "find";
        recordMongoQuery({ kind, latencyMs });
        return;
      }
      // mongo.vector_search is emitted by the mongodb_vector_search tool wrapper
      // after the underlying MCP call returns. latencyMs covers the full MCP
      // round-trip (embed excluded — that is billed to the embedding provider).
      if (type === "mongo.vector_search") {
        const latencyMs = typeof payload?.latencyMs === "number" ? payload.latencyMs : undefined;
        if (latencyMs === undefined) return;
        const collection = typeof payload?.collection === "string" ? payload.collection : "unknown";
        recordMongoQuery({ kind: "vector_search", collection, latencyMs });
        return;
      }
      void agentId; // reserved for future per-agent dimensions
    } catch {
      // metric emission must never destabilize the chat turn
    }
  }

  // -------- OTel bridge --------
  //
  // Wrapped in try/catch at every call site so a tracer-side failure (e.g.
  // exporter back-pressure / sidecar restart) never bubbles into the chat
  // path. Spans land in /aws/spans via the ADOT sidecar in EXPORT mode and
  // stay in-process otherwise.

  private otelTracer() {
    return otelTrace.getTracer("multiagent-api");
  }

  private flattenAttrs(prefix: string, value: unknown, out: Record<string, string | number | boolean>, depth = 0): void {
    if (depth > 3 || value == null) return;
    if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
      out[prefix] = value;
      return;
    }
    if (Array.isArray(value)) {
      if (value.every((v) => typeof v === "string" || typeof v === "number" || typeof v === "boolean")) {
        // primitive array — flatten as JSON for OTel compat
        out[prefix] = safeStringify(value);
      } else {
        out[prefix] = safeStringify(value);
      }
      return;
    }
    if (typeof value === "object") {
      for (const [k, v] of Object.entries(value)) {
        this.flattenAttrs(`${prefix}.${k}`, v, out, depth + 1);
      }
    }
  }

  private emitOtelStart(id: string, type: TraceEventType, payload: Record<string, unknown>, agentId?: string): void {
    try {
      const tracer = this.otelTracer();
      const attrs: Record<string, string | number | boolean> = {
        "multiagent.span.type": type,
        "multiagent.trace_id": this.traceId,
        "multiagent.session_id": this.sessionId,
        "multiagent.message_id": this.messageId,
      };
      if (agentId) attrs["multiagent.agent_id"] = agentId;
      if (this.userId) attrs["enduser.id"] = this.userId;
      this.flattenAttrs("multiagent.payload", payload, attrs);
      const span = tracer.startSpan(type, { attributes: attrs });
      this.otelSpans.set(id, span);
    } catch {
      // OTel-side failure must not destabilize trace collection
    }
  }

  private emitOtelEnd(id: string, payload: Record<string, unknown>): void {
    try {
      const span = this.otelSpans.get(id);
      if (!span) return;
      this.otelSpans.delete(id);
      const extra: Record<string, string | number | boolean> = {};
      this.flattenAttrs("multiagent.end", payload, extra);
      span.setAttributes(extra);
      const err = (payload as { error?: { class?: string; message?: string } }).error;
      if (err) {
        span.setStatus({ code: SpanStatusCode.ERROR, message: err.message ?? err.class ?? "error" });
      } else {
        span.setStatus({ code: SpanStatusCode.OK });
      }
      span.end();
    } catch {
      // OTel-side failure must not destabilize trace collection
    }
  }

  private emitOtelEvent(type: TraceEventType, payload: Record<string, unknown>, parentId?: string): void {
    try {
      const parentSpan = parentId ? this.otelSpans.get(parentId) : undefined;
      const attrs: Record<string, string | number | boolean> = {};
      this.flattenAttrs("multiagent.payload", payload, attrs);
      if (parentSpan) {
        parentSpan.addEvent(type, attrs);
      } else {
        // No parent span → emit as a zero-duration span so the event still
        // appears in /aws/spans Transaction Search. Useful for top-level
        // events emitted before any wrapper span exists.
        const tracer = this.otelTracer();
        const span = tracer.startSpan(type, { attributes: attrs });
        span.end();
      }
    } catch {
      // OTel-side failure must not destabilize trace collection
    }
  }

  /** Convenience: run an async function inside a span, auto-closing on resolve/reject. */
  async span<T>(
    type: TraceEventType,
    payload: Record<string, unknown>,
    fn: (spanId: string) => Promise<T> | T,
  ): Promise<T> {
    const id = this.start(type, payload);
    try {
      const result = await fn(id);
      this.end(id);
      return result;
    } catch (err) {
      const e = err instanceof Error ? err : new Error(String(err));
      this.event(
        "error",
        { class: e.name, message: e.message, stack: e.stack, source: type },
        { parentId: id },
      );
      this.end(id, { error: { class: e.name, message: e.message } });
      throw err;
    }
  }

  currentSpanId(): string | undefined {
    return this.spanStack.length ? this.spanStack[this.spanStack.length - 1] : undefined;
  }

  // -------- Pending assistant text scratch (handoff attribution) --------

  appendPendingText(text: string): void {
    if (!text) return;
    this.pendingAssistantText += text;
    if (this.pendingAssistantText.length > this.pendingTextCap) {
      this.pendingAssistantText = this.pendingAssistantText.slice(-this.pendingTextCap);
    }
  }

  snapshotPendingText(): string {
    return this.pendingAssistantText;
  }

  resetPendingText(): void {
    this.pendingAssistantText = "";
  }

  // -------- Counters consumed by summary() --------

  recordMongoDocs(count: number): void {
    this.mongoDocsReturned += Math.max(0, count);
  }

  setFinalAgentId(id: string): void {
    this.finalAgentId = id;
  }

  recordBytesIn(n: number): void {
    this.bytesIn += Math.max(0, n);
  }

  recordBytesOut(n: number): void {
    this.bytesOut += Math.max(0, n);
  }

  // -------- Emit pipeline --------

  private emit(raw: TraceEvent): void {
    const ev = this.applyRedaction(raw);
    const size = approxBytes(ev);

    // Per-event cap: if a single event exceeds the per-event byte cap, strip
    // large fields (payload body) before deciding whether to drop.
    if (size > this.maxEventBytes) {
      this.shrinkPayload(ev);
    }
    const size2 = approxBytes(ev);

    // Per-turn cap: when total exceeds limit, drop non-protected events.
    if (!PROTECTED_TYPES.has(ev.type) && this.totalBytes + size2 > this.maxTurnBytes) {
      this.degraded = true;
      this.eventsDropped += 1;
      return;
    }

    this.totalBytes += size2;
    this.events.push(ev);

    // Bridge to EMF metrics here (not in event()) so spliced nested events
    // from specialist runtimes also emit. agentId on the event takes priority
    // — falls back to this collector's agentId for direct events.
    this.maybeEmitMetric(
      ev.type,
      (ev.payload ?? {}) as Record<string, unknown>,
      ev.agentId ?? this.agentId,
    );

    for (const l of this.listeners) {
      try {
        l(ev);
      } catch {
        // listeners must not destabilize the collector
      }
    }
  }

  private applyRedaction(ev: TraceEvent): TraceEvent {
    if (!this.redact) return ev;
    return { ...ev, payload: redactDeep(ev.payload) as never };
  }

  /**
   * Strip the biggest payload fields when a single event is over budget.
   * Preserves a marker so the UI can render a "[trimmed]" badge.
   */
  private shrinkPayload(ev: TraceEvent): void {
    const p = ev.payload as Record<string, unknown> | undefined;
    if (!p) return;
    for (const key of ["body", "result", "response", "responseBody", "payload", "sampleDocs", "input"]) {
      if (key in p) {
        const original = p[key];
        const originalStr = safeStringify(original);
        if (originalStr.length > 1024) {
          p[key] = `[trimmed ${originalStr.length}B]`;
        }
      }
    }
  }

  // -------- Cost & summary --------

  /** Sum every model.usage event into a single ChatTurnSummary. */
  summary(): ChatTurnSummary {
    let inputTokens = 0;
    let outputTokens = 0;
    let cacheReadInputTokens = 0;
    let cacheWriteInputTokens = 0;
    let cost = 0;
    const breakdown: Record<string, number> = {};
    let allKnown = true;
    let anyUsage = false;
    let derivedToolCalls = 0;
    let derivedMongoQueries = 0;
    let derivedMongoDocsReturned = 0;
    let derivedMcpCalls = 0;
    let derivedAgentcoreHops = 0;
    let derivedAgentcoreRuntimeMs = 0;

    for (const ev of this.events) {
      const payload = (ev.payload ?? {}) as Record<string, unknown>;
      if (ev.type === "model.usage") {
        anyUsage = true;
        const u = ev.payload as ModelUsagePayload;
        inputTokens += u.inputTokens ?? 0;
        outputTokens += u.outputTokens ?? 0;
        cacheReadInputTokens += u.cacheReadInputTokens ?? 0;
        cacheWriteInputTokens += u.cacheWriteInputTokens ?? 0;
        const c = costOfUsage({
          modelId: u.modelId,
          inputTokens: u.inputTokens ?? 0,
          outputTokens: u.outputTokens ?? 0,
          cacheReadInputTokens: u.cacheReadInputTokens,
          cacheWriteInputTokens: u.cacheWriteInputTokens,
        });
        if (c === undefined) {
          allKnown = false;
        } else {
          cost += c;
          breakdown[u.modelId] = (breakdown[u.modelId] ?? 0) + c;
        }
      } else if (ev.type === "tool.call" && ev.durationMs !== undefined) {
        derivedToolCalls += 1;
      } else if (ev.type === "mongo.query") {
        derivedMongoQueries += 1;
      } else if (ev.type === "mongo.result") {
        derivedMongoDocsReturned += Number(payload.docCount ?? 0) || 0;
      } else if (ev.type === "mongo.vector_search") {
        derivedMongoQueries += 1;
        derivedMongoDocsReturned += Array.isArray(payload.scores) ? payload.scores.length : 0;
      } else if (ev.type === "tool.mcp") {
        derivedMcpCalls += 1;
      } else if (ev.type === "agentcore.invoke" && ev.durationMs !== undefined) {
        derivedAgentcoreHops += 1;
        derivedAgentcoreRuntimeMs += Number(payload.latencyMs ?? ev.durationMs ?? 0) || 0;
      }
    }

    return {
      inputTokens,
      outputTokens,
      totalTokens: inputTokens + outputTokens,
      cacheReadInputTokens: cacheReadInputTokens || undefined,
      cacheWriteInputTokens: cacheWriteInputTokens || undefined,
      toolCalls: Math.max(this.toolCallCount, derivedToolCalls),
      mongoQueries: Math.max(this.mongoQueryCount, derivedMongoQueries),
      mongoDocsReturned: Math.max(this.mongoDocsReturned, derivedMongoDocsReturned),
      mcpCalls: Math.max(this.mcpCallCount, derivedMcpCalls),
      agentcoreHops: Math.max(this.agentcoreHops, derivedAgentcoreHops) || undefined,
      agentcoreRuntimeMs: Math.max(this.agentcoreRuntimeMs, derivedAgentcoreRuntimeMs) || undefined,
      bytesIn: this.bytesIn,
      bytesOut: this.bytesOut,
      finalAgentId: this.finalAgentId,
      eventsDropped: this.eventsDropped,
      nestedEventsDropped: this.nestedEventsDropped || undefined,
      estimatedCostUsd: anyUsage ? cost : null,
      costBreakdown: breakdown,
      costEstimateComplete: anyUsage ? allKnown : false,
    };
  }

  // -------- Nested-trace splice (AgentCore deep tracing) --------

  /**
   * Splice nested events into this collector under a single wrapper span.
   * Implements §6.3.1 of the plan:
   *   - Parent rewiring: roots / nested chat.turn ids / orphans → wrapperId.
   *   - Clock normalization: shift nested ts so nested.first → wrapper.startTs.
   *   - Bound-check: clamp + warn when nested ts overshoots wrapper end by > 100ms.
   *
   * Idempotent — passing the same nestedEvents twice produces identical output
   * (the first call may mutate, but identical input gives identical output).
   */
  attachEventsNested(
    nestedEvents: TraceEvent[],
    wrapperId: string,
    opts: { nestedEventsDropped?: number; logger?: { warn: (msg: string, ctx?: unknown) => void } } = {},
  ): void {
    if (!nestedEvents.length) return;
    const wrapper = this.events.find((e) => e.id === wrapperId);
    if (!wrapper) return;
    const wrapperStartTs = wrapper.ts;
    const wrapperDuration = wrapper.durationMs ?? 0;
    const wrapperEnd = wrapperStartTs + wrapperDuration;

    const nestedIds = new Set(nestedEvents.map((e) => e.id));
    const nestedRoot =
      nestedEvents.find((e) => e.type === "chat.turn.start") ??
      nestedEvents.find((e) => !e.parentId);
    const nestedOrigin = nestedRoot?.ts ?? Math.min(...nestedEvents.map((e) => e.ts));
    const tsOffset = wrapperStartTs - nestedOrigin;

    for (const raw of nestedEvents) {
      // Defensive copy so we don't mutate caller's array.
      const ev: TraceEvent = { ...raw } as TraceEvent;
      let payload = (ev.payload ?? {}) as Record<string, unknown>;
      const originalTs = ev.ts;
      ev.ts = ev.ts + tsOffset;
      if (ev.ts > wrapperEnd + 100 && wrapperDuration > 0) {
        opts.logger?.warn?.("[trace-collector] nested event ts exceeds wrapper end; clamping", {
          eventId: ev.id,
          originalTs,
          wrapperEnd,
        });
        ev.ts = wrapperEnd;
      }
      // Rewire parents.
      if (ev.parentId == null) {
        ev.parentId = wrapperId;
      } else if (ev.parentId === nestedRoot?.id) {
        ev.parentId = wrapperId;
      } else if (!nestedIds.has(ev.parentId)) {
        payload = { ...payload, _orphanFrom: ev.parentId };
        ev.parentId = wrapperId;
      }
      payload = { ...payload, _originalTs: originalTs };
      ev.payload = payload as never;
      // Account for size and emit through the same byte-cap pipeline.
      this.emit(ev);
      // Roll up tool / mongo / mcp counters from the nested collector.
      //
      // The runtime collector mixes two emission shapes:
      //
      // 1. Spans: Strands' in-process tool calls go through start(...)/end(...),
      //    producing two events of the same type — start with no `durationMs`,
      //    end with `durationMs` set. Counting only `durationMs != null` avoids
      //    double-counting (matches what end(...) does on the parent collector).
      //
      // 2. One-off events: emitted via event(...). Used by:
      //      * extractAndReplayMcpTraces (mongodb-mcp-client.ts) for every
      //        mongo.* event the MongoDB MCP runtime ships back through the
      //        MCP envelope.
      //      * the McpClient.callTool wrapper for `tool.mcp` (one event per
      //        gateway round-trip — see mongodb-mcp-client.ts).
      //    These have no `durationMs` and need to be counted as one each.
      //
      // We count `mongo.query` and `tool.mcp` regardless of `durationMs`
      // (they only ever come from one-off `event(...)`); `tool.call` only
      // when `durationMs != null` (it always comes from a span pair).
      //
      // Without this, the trace summary always shows `toolCalls: 0` /
      // `mongoQueries: 0` for AgentCore Runtime turns even though every
      // mongo.* / tool.* event is present in the events list — exactly the
      // observability gap that motivated the runtime trace splice.
      if (ev.type === "tool.call") {
        if (ev.durationMs != null) this.toolCallCount += 1;
      } else if (ev.type === "mongo.query") {
        this.mongoQueryCount += 1;
      } else if (ev.type === "tool.mcp") {
        this.mcpCallCount += 1;
      } else if (ev.type === "agentcore.invoke") {
        // Roll up the orchestrator → specialist hop (and any deeper hops in
        // future) so `summary.agentcoreHops` reflects the real runtime
        // topology, not just the Hono → orchestrator outer hop. Counters are
        // ALWAYS span pairs from `start(...)/end(...)` for this type so we
        // gate on `durationMs != null` to count completions only.
        //
        // We deliberately do NOT roll up `agentcoreRuntimeMs` from spliced
        // events: the parent's own outer-hop duration is wall-clock and
        // already includes the time the inner specialist hop spent
        // executing. Summing nested durations on top would double-count and
        // make `agentcoreRuntimeMs` exceed the actual turn latency.
        if (ev.durationMs != null) this.agentcoreHops += 1;
      }

      // Roll up mongo docs returned. Each `mongo.result` event payload
      // carries `docCount: <n>` (see lambda/mongodb-mcp/index.mjs →
      // `tracing.mjs` and the `traceMongoResult` helper). Earlier in-process
      // emitters used `count`, so accept both fields for backward compat.
      if (ev.type === "mongo.result") {
        const p = payload as { docCount?: unknown; count?: unknown };
        const c = typeof p.docCount === "number" ? p.docCount
                : typeof p.count === "number" ? p.count
                : 0;
        if (c > 0) this.mongoDocsReturned += c;
      }
    }
    if (opts.nestedEventsDropped) {
      this.nestedEventsDropped += opts.nestedEventsDropped;
    }
  }

  // -------- Serialization --------

  getEvents(): TraceEvent[] {
    return this.events.slice();
  }

  getEvent(id: string): TraceEvent | undefined {
    return this.events.find((e) => e.id === id);
  }

  /** True once any non-protected event was dropped under the byte cap. */
  isDegraded(): boolean {
    return this.degraded;
  }

  totalEventCount(): number {
    return this.events.length;
  }

  toJSON(): Trace {
    return {
      traceId: this.traceId,
      sessionId: this.sessionId,
      messageId: this.messageId,
      userId: this.userId,
      agentId: this.agentId,
      events: this.events.slice(),
      summary: this.summary(),
      createdAt: new Date(this.startTs).toISOString(),
      truncated: this.degraded || this.eventsDropped > 0 || undefined,
      eventsDropped: this.eventsDropped || undefined,
    };
  }
}
