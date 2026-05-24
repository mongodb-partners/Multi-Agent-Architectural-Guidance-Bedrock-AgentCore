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
import { enrichVectorSearchTraceEvents } from "../adapters/mongodb-mcp-client.ts";
import { costOfUsage } from "./model-pricing.ts";
import { recordMongoQuery } from "./cw-metrics.ts";
import type {
  ChatTurnSummary,
  Trace,
  TraceEvent,
  TraceEventType,
  TraceSpanNode,
  ModelUsagePayload,
  DevEnvironmentPayload,
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

/**
 * Per-event-type allow-list of field names that look like PII (`name`,
 * `address`, …) but are actually structural identifiers. Without this,
 * `skill.activated.name` (the skill id, e.g. `"order-management"`) gets
 * stomped to `"[redacted]"`, and the `toJSON()` rollup that folds
 * `read_skill_resource` calls back onto the matching `skill.activated`
 * event silently breaks because it can no longer look up the bucket.
 *
 * The right shape long-term is event-type-typed redaction; this table is
 * the narrowest fix that keeps PII redaction default-on while not
 * destroying schema-level identifiers.
 */
const PII_EXEMPT_FIELDS: Partial<Record<TraceEventType, ReadonlySet<string>>> = {
  "skill.activated": new Set(["name"]),
};

// ---------------------------------------------------------------------------
// Tiered per-event-type truncation caps.
//
// Debug-critical fields (full prompt body, model.request.userMessage, raw
// AgentCore I/O, etc.) get a generous 64 KB cap so a developer can actually
// debug the turn from the Trace Viewer's Developer details panel. Everything
// else stays at the historical 512-char cap. PII redaction (`PII_KEYS`) runs
// regardless and is orthogonal to length capping.
//
// Reviewer note: 64 KB per field is well under the per-event byte cap
// (`TRACE_MAX_EVENT_BYTES = 16_384`) — the per-event cap kicks in second,
// after these per-field caps, and now reports a `dev.byte_cap_hit` event
// instead of silently dropping. The pre-merge checklist measures real-world
// trace doc size and the cap is lowered to 16 KB if p50 > 1 MB.
// ---------------------------------------------------------------------------

const TRUNCATION_CAP_DEFAULT = 512;
const TRUNCATION_CAP_DEBUG = 65_536;

/**
 * Field-name allow-list per event type for the 64 KB debug cap. Fields not
 * listed (and fields on other event types) fall back to `TRUNCATION_CAP_DEFAULT`.
 * Top-level field names only — nested objects/arrays inherit the larger cap
 * when traversed through a debug field.
 */
const DEBUG_CAP_FIELDS: Partial<Record<TraceEventType, ReadonlySet<string>>> = {
  "prompt.assembled":         new Set(["body"]),
  "model.request":            new Set(["userMessage", "messagesSeed", "priorTurnsPreview"]),
  "model.text_delta_batch":   new Set(["text"]),
  "model.thinking_block":     new Set(["text"]),
  "tool.call":                new Set(["input", "result"]),
  "tool.http":                new Set(["body", "responseSnippet"]),
  "tool.mcp":                 new Set(["args", "result"]),
  "agentcore.invoke":         new Set(["payload", "responseBody"]),
  "skill.activated":          new Set(["bodyPreview"]),
};

function capString(s: string, cap: number): string {
  if (s.length <= cap) return s;
  return s.slice(0, cap) + "…[truncated]";
}

/**
 * Recursive redactor with per-field cap awareness. Once we descend into a
 * field that's been flagged as `debug` (via `DEBUG_CAP_FIELDS`), the larger
 * cap follows through nested objects/arrays so the entire `messagesSeed`
 * array (or `responseBody` object tree) gets the debug cap, not just the
 * top-level string.
 */
function redactValue(value: unknown, cap: number, depth = 0): unknown {
  if (depth > 6) return value;
  if (value == null) return value;
  if (typeof value === "string") return capString(value, cap);
  if (Array.isArray(value)) return value.map((v) => redactValue(v, cap, depth + 1));
  if (typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      if (PII_KEYS.has(k.toLowerCase())) out[k] = "[redacted]";
      else out[k] = redactValue(v, cap, depth + 1);
    }
    return out;
  }
  return value;
}

/**
 * Apply PII redaction + tiered truncation caps to a payload, using the
 * event type to look up the per-field cap allow-list.
 */
function redactPayload(type: TraceEventType, payload: unknown): unknown {
  if (payload == null || typeof payload !== "object" || Array.isArray(payload)) {
    return redactValue(payload, TRUNCATION_CAP_DEFAULT);
  }
  const debugFields = DEBUG_CAP_FIELDS[type];
  const piiExempt = PII_EXEMPT_FIELDS[type];
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(payload as Record<string, unknown>)) {
    if (PII_KEYS.has(k.toLowerCase()) && !piiExempt?.has(k)) {
      out[k] = "[redacted]";
      continue;
    }
    const cap = debugFields?.has(k) ? TRUNCATION_CAP_DEBUG : TRUNCATION_CAP_DEFAULT;
    out[k] = redactValue(v, cap);
  }
  return out;
}

/**
 * Legacy export. Same behavior as `redactValue(value, TRUNCATION_CAP_DEFAULT)`
 * but kept for any out-of-tree caller that imports `redactDeep` directly.
 */
function redactDeep(value: unknown, depth = 0): unknown {
  return redactValue(value, TRUNCATION_CAP_DEFAULT, depth);
}
void redactDeep;

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
  /** Count-limit `dev.byte_cap_hit` emission per turn to avoid runaway loops
   *  if a misbehaving event source keeps tripping the cap. */
  private byteCapHitEmissions = 0;
  private static readonly MAX_BYTE_CAP_HIT_EMISSIONS = 50;

  // Redaction
  readonly redact: boolean;

  // Misc instrumentation
  private pendingAssistantText = "";
  private readonly pendingTextCap: number;
  /** Per-skill buffer of `read_skill_resource` tool reads observed during the
   *  turn. Folded into matching `skill.activated.resourceReads` arrays by
   *  `toJSON()` at finalize time so the Skills dev sub-panel can render a
   *  per-skill roll-up without forcing the dev to grep flat `tool.call`
   *  events. */
  private skillResourceReads = new Map<string, Array<{
    resourcePath: string;
    bytes: number;
    toolUseId?: string;
    latencyMs?: number;
  }>>();
  /** Per-turn counters consumed by `summary()`.
   *
   * The mongo counters are split per-event-kind so the summary can take a
   * MAX across kinds instead of summing them. A single logical Mongo call
   * fans out into siblings (`tool.mcp` + `mongo.query` + `mongo.result`,
   * or only the surviving `tool.mcp` when the AgentCore Gateway strips
   * `meta.traces`), and summing those would 2–3× the real count. Taking
   * the max correctly returns 1 in every transit configuration. See
   * docs/status/debugging.md "AgentCore Gateway response strips meta.traces".
   */
  private toolCallCount = 0;
  private mongoDocsReturned = 0;
  private mcpCallCount = 0;
  private agentcoreHops = 0;
  private agentcoreRuntimeMs = 0;
  // Per-kind mongo counters. summary() returns max(...) across these.
  // Updated by `end(...)` (in-process spans), `attachEventsNested(...)`
  // (spliced runtime traces), and re-derived from events in summary().
  private mongoQueryEvents = 0;          // from `mongo.query` start events
  private mongoResultEvents = 0;         // from `mongo.result` events (1 per logical call)
  private mongoVectorSearchEvents = 0;   // from `mongo.vector_search` events
  private toolMcpMongoEvents = 0;        // from `tool.mcp` events whose toolName matches /mongo/i
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
    if (span?.type === "mongo.query") this.mongoQueryEvents += 1;
    if (span?.type === "mongo.vector_search") this.mongoVectorSearchEvents += 1;
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

  /**
   * Record a `read_skill_resource` invocation against the named skill so
   * `toJSON()` can fold it into the matching `skill.activated.resourceReads`
   * roll-up at finalize time. The corresponding flat `tool.call` event keeps
   * streaming live — this is purely metadata for the Skills dev sub-panel.
   */
  recordSkillResourceRead(read: {
    skillName: string;
    resourcePath: string;
    bytes: number;
    toolUseId?: string;
    latencyMs?: number;
  }): void {
    const bucket = this.skillResourceReads.get(read.skillName) ?? [];
    bucket.push({
      resourcePath: read.resourcePath,
      bytes: read.bytes,
      toolUseId: read.toolUseId,
      latencyMs: read.latencyMs,
    });
    this.skillResourceReads.set(read.skillName, bucket);
  }

  // -------- Emit pipeline --------

  private emit(raw: TraceEvent): void {
    const ev = this.applyRedaction(raw);
    const size = approxBytes(ev);

    // Per-event cap: if a single event exceeds the per-event byte cap, strip
    // large fields (payload body) before deciding whether to drop. Surface
    // the trim as a `dev.byte_cap_hit` event so the Developer details panel
    // can show which type was capped, instead of silently swallowing it.
    if (size > this.maxEventBytes) {
      this.shrinkPayload(ev);
      this.emitByteCapHit(ev.type, size, "per_event");
    }
    const size2 = approxBytes(ev);

    // Per-turn cap: when total exceeds limit, drop non-protected events.
    if (!PROTECTED_TYPES.has(ev.type) && this.totalBytes + size2 > this.maxTurnBytes) {
      this.degraded = true;
      this.eventsDropped += 1;
      this.emitByteCapHit(ev.type, size2, "per_turn");
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

  /**
   * Apply tiered per-event-type truncation caps. PII keys are always
   * redacted (independent of `TRACE_REDACT`); truncation caps run on every
   * event so debug payloads never silently exceed the per-event byte cap.
   * When `TRACE_REDACT=1`, the underlying value-level pass still strips PII
   * field by field. The `this.redact` flag is preserved for back-compat but
   * the tiered cap path now runs unconditionally — pre-PR1 behavior of
   * "no caps at all" was the silent-bloat bug we're fixing.
   */
  private applyRedaction(ev: TraceEvent): TraceEvent {
    return { ...ev, payload: redactPayload(ev.type, ev.payload) as never };
  }

  /**
   * Push a `dev.byte_cap_hit` event into the trace whenever the byte-cap
   * path trims or drops a payload. Count-limited to 50 emissions per turn
   * so a misbehaving event source can't spam the trace. The emission goes
   * through `events.push` directly (not `emit()`) to avoid recursion if
   * the synthetic event itself somehow ever exceeded a cap.
   */
  private emitByteCapHit(
    droppedType: TraceEventType,
    bytes: number,
    reason: "per_event" | "per_turn",
  ): void {
    if (droppedType === "dev.byte_cap_hit") return;
    if (this.byteCapHitEmissions >= TraceCollector.MAX_BYTE_CAP_HIT_EMISSIONS) return;
    this.byteCapHitEmissions += 1;
    const synthetic: TraceEvent = {
      id: uuid(),
      parentId: this.currentSpanId(),
      type: "dev.byte_cap_hit",
      ts: nowMs(),
      agentId: this.agentId,
      payload: { droppedType, bytes, reason } as never,
    } as TraceEvent;
    this.events.push(synthetic);
    this.totalBytes += approxBytes(synthetic);
    for (const l of this.listeners) {
      try {
        l(synthetic);
      } catch {
        // listeners must not destabilize the collector
      }
    }
  }

  /**
   * Emit a one-shot `dev.environment` event capturing the runtime knobs in
   * play for this turn. Cheap, fixed-size; surfaces "why is this turn
   * behaving like a mock" in one shot under Developer details → Environment.
   * Called once from `routes/chat.ts` right after `start()`.
   */
  emitEnvironment(env: NodeJS.ProcessEnv = process.env): string {
    const chatMode = env.CHAT_MODE?.trim() || "live";
    const devMockBackends = envBool("DEV_MOCK_BACKENDS", false, env);
    const mongoConfigured = !!env.MONGODB_URI?.trim();
    const voyageConfigured = !!env.VOYAGE_API_KEY?.trim();
    const flags: Record<string, "0" | "1"> = {
      TRACE_REDACT: envBool("TRACE_REDACT", false, env) ? "1" : "0",
      TRACE_PROMPT_BODY: envBool("TRACE_PROMPT_BODY", false, env) ? "1" : "0",
      MEMORY_TRACE_VALUES: envBool("MEMORY_TRACE_VALUES", true, env) ? "1" : "0",
      METRICS_EMITTER_ENABLED: envBool("METRICS_EMITTER_ENABLED", true, env) ? "1" : "0",
      PERSIST_CHAT_SESSIONS: envBool("PERSIST_CHAT_SESSIONS", true, env) ? "1" : "0",
    };
    const payload: DevEnvironmentPayload = {
      runtime: typeof Bun !== "undefined"
        ? `bun ${Bun.version}`
        : `node ${process.versions.node}`,
      modelBackend: devMockBackends ? "mock" : "bedrock",
      chatMode,
      devMockBackends,
      mongoUri: mongoConfigured ? "configured" : "missing",
      voyageConfigured,
      bedrockRegion: env.AWS_REGION || env.BEDROCK_REGION,
      flags,
    };
    return this.event("dev.environment", payload as unknown as Record<string, unknown>);
  }

  /**
   * Build the precomputed span tree from `events` using `parentId` chains.
   * Roots are events with `parentId === undefined` (or whose `parentId`
   * refers to an event not in the list — orphans get reparented to root so
   * the tree is always complete).
   *
   * Span events appear twice in the events list (start + end pair sharing
   * the same span id via `end()`'s `parentId: id` trick). We collapse them
   * into one node, preferring the start event for `ts`/`agentId` and the
   * end event for `durationMs`.
   */
  buildSpanTree(): TraceSpanNode[] {
    type Acc = TraceSpanNode & { _seen: boolean };
    const nodes = new Map<string, Acc>();
    for (const ev of this.events) {
      // Start half of a span (ours own `start()` always sets `durationMs`
      // on the end half). Track it.
      let node = nodes.get(ev.id);
      if (!node) {
        node = {
          id: ev.id,
          type: ev.type,
          ts: ev.ts,
          durationMs: ev.durationMs,
          agentId: ev.agentId,
          children: [],
          _seen: false,
        };
        nodes.set(ev.id, node);
      } else {
        // Duplicate id is a synthetic end-event (id === uuid() but parentId
        // === spanId of start). We don't track end events as nodes; their
        // info gets merged below.
      }
      // End event: `parentId` of an end event is the span start's id.
      // (Set in `end()` via `parentId: id`.) Merge `durationMs` back.
      if (ev.durationMs !== undefined && ev.parentId && nodes.has(ev.parentId)) {
        const parentNode = nodes.get(ev.parentId)!;
        if (parentNode.type === ev.type) {
          parentNode.durationMs = ev.durationMs;
        }
      }
    }
    const rootNodes: TraceSpanNode[] = [];
    const seenIds = new Set<string>();
    for (const ev of this.events) {
      const node = nodes.get(ev.id);
      if (!node || seenIds.has(ev.id)) continue;
      seenIds.add(ev.id);
      const parentNode = ev.parentId ? nodes.get(ev.parentId) : undefined;
      // If parentId points at a real span node, nest under it. Otherwise
      // (orphan / one-off event / root span) put it at the top level.
      if (parentNode && parentNode.id !== node.id) {
        parentNode.children.push(node);
      } else {
        rootNodes.push(node);
      }
    }
    // Strip the internal `_seen` flag from the returned tree.
    const strip = (n: Acc): TraceSpanNode => ({
      id: n.id,
      type: n.type,
      ts: n.ts,
      durationMs: n.durationMs,
      agentId: n.agentId,
      children: n.children.map((c) => strip(c as Acc)),
    });
    return rootNodes.map((n) => strip(n as Acc));
  }

  /**
   * Capture the active OTel span's trace + root span IDs. Called at
   * finalize time from `toJSON()` / `routes/chat.ts` so the Trace Viewer
   * can deep-link to CloudWatch ServiceLens / X-Ray. Wrapped in try/catch
   * because OTel may be uninitialized (DEV_MOCK_BACKENDS=1 without
   * OTEL_EXPORTER_OTLP_ENDPOINT) — returns `undefined` cleanly.
   */
  captureOtelIds(): { traceId: string; rootSpanId: string } | undefined {
    try {
      const span = otelTrace.getActiveSpan();
      if (!span) return undefined;
      const ctx = span.spanContext();
      if (!ctx?.traceId || !ctx?.spanId) return undefined;
      return { traceId: ctx.traceId, rootSpanId: ctx.spanId };
    } catch {
      return undefined;
    }
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
    let derivedMongoDocsReturned = 0;
    let derivedMcpCalls = 0;
    let derivedAgentcoreHops = 0;
    let derivedAgentcoreRuntimeMs = 0;
    // Per-kind mongo event counts re-derived from `this.events` so summary()
    // is correct even when in-process counters were not updated (e.g. when
    // events were spliced from a nested AgentCore runtime trace). Take max
    // across kinds (not sum) to dedupe sibling events from the same logical
    // call. See comment on the private mongo*Events fields.
    let evMongoQueryCount = 0;
    let evMongoResultCount = 0;
    let evMongoVectorSearchCount = 0;
    let evToolMcpMongoCount = 0;

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
        // Span start (no durationMs) AND one-off `event(...)` (also no
        // durationMs) both denote one logical call. The end half (with
        // durationMs) is the same span and must not be counted again.
        if (ev.durationMs === undefined) evMongoQueryCount += 1;
      } else if (ev.type === "mongo.result") {
        evMongoResultCount += 1;
        derivedMongoDocsReturned += Number(payload.docCount ?? 0) || 0;
      } else if (ev.type === "mongo.vector_search") {
        if (ev.durationMs === undefined) evMongoVectorSearchCount += 1;
        derivedMongoDocsReturned += Array.isArray(payload.scores) ? payload.scores.length : 0;
      } else if (ev.type === "tool.mcp") {
        if (ev.durationMs === undefined) derivedMcpCalls += 1;
        const toolName = (payload as { toolName?: unknown; name?: unknown }).toolName
          ?? (payload as { name?: unknown }).name;
        if (typeof toolName === "string" && /mongo/i.test(toolName)) {
          if (ev.durationMs === undefined) evToolMcpMongoCount += 1;
        }
      } else if (ev.type === "agentcore.invoke" && ev.durationMs !== undefined) {
        derivedAgentcoreHops += 1;
        derivedAgentcoreRuntimeMs += Number(payload.latencyMs ?? ev.durationMs ?? 0) || 0;
      }
    }

    // Dedupe: a single logical mongo call typically emits one of each of
    // `tool.mcp` (mongo-named) + `mongo.query` + `mongo.result`, depending
    // on whether the AgentCore Gateway path strips `meta.traces`. Summing
    // them double/triple-counts; the MAX is correct in every transit shape:
    //   * Gateway path: only tool.mcp survives → max = tool.mcp count
    //   * Direct MCP:  all three present, 1:1 ratio → max = any one
    //   * Legacy in-process: no MCP wrapper → max = mongo.query / .result
    const mongoQueriesFromEvents = Math.max(
      evMongoQueryCount,
      evMongoResultCount,
      evMongoVectorSearchCount,
      evToolMcpMongoCount,
    );
    // Also consider the in-process counters (updated by `end()` from
    // `mongo.query` / `mongo.vector_search` spans). Re-derive their max
    // too so they don't double-add to event-derived counts.
    const mongoQueriesFromSpans = Math.max(
      this.mongoQueryEvents,
      this.mongoVectorSearchEvents,
      this.mongoResultEvents,
      this.toolMcpMongoEvents,
    );
    const mongoQueries = Math.max(mongoQueriesFromEvents, mongoQueriesFromSpans);

    return {
      inputTokens,
      outputTokens,
      totalTokens: inputTokens + outputTokens,
      cacheReadInputTokens: cacheReadInputTokens || undefined,
      cacheWriteInputTokens: cacheWriteInputTokens || undefined,
      toolCalls: Math.max(this.toolCallCount, derivedToolCalls),
      mongoQueries,
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
    // Backfill mongo.vector_search scoreSummary from sibling mongo.result.sampleDocs
    // when nested AgentCore traces omit scores on the wrapper event.
    nestedEvents = enrichVectorSearchTraceEvents(nestedEvents) as TraceEvent[];
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
      //
      // Per-kind mongo counters: increment the matching kind on every
      // spliced event and let `summary()` take the MAX across kinds at
      // rollup time. Summing kinds would 2–3× the real query count
      // because a single logical Mongo call fans out into siblings
      // (`tool.mcp` + `mongo.query` + `mongo.result`, or only the surviving
      // `tool.mcp` when the AgentCore Gateway strips `meta.traces`).
      //
      // For span pairs (start: no durationMs, end: durationMs set), count
      // only the start half to avoid double-counting within a single kind.
      if (ev.type === "tool.call") {
        if (ev.durationMs != null) this.toolCallCount += 1;
      } else if (ev.type === "mongo.query") {
        if (ev.durationMs === undefined) this.mongoQueryEvents += 1;
      } else if (ev.type === "mongo.vector_search") {
        if (ev.durationMs === undefined) this.mongoVectorSearchEvents += 1;
      } else if (ev.type === "tool.mcp") {
        if (ev.durationMs === undefined) this.mcpCallCount += 1;
        // MongoDB-targeted gateway tool: the AgentCore Gateway path strips
        // `meta.traces` from MCP envelopes so `mongo.query` events from the
        // MongoDB MCP runtime never reach the rollup; only this `tool.mcp`
        // survives. Without bumping the dedicated counter, the gateway-path
        // turn summary would show `mongoQueries: 0` even though every
        // gateway hop ran a real Mongo query.
        const toolName = (payload as { toolName?: unknown; name?: unknown }).toolName
          ?? (payload as { name?: unknown }).name;
        if (typeof toolName === "string" && /mongo/i.test(toolName)) {
          if (ev.durationMs === undefined) this.toolMcpMongoEvents += 1;
        }
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

      // mongo.result: bump the dedicated counter (mutually exclusive with
      // the kinds above — summary takes max), and accumulate doc counts.
      // Each `mongo.result` event payload carries `docCount: <n>` from
      // mcp-runtimes/mongodb-mcp/src/vendor/handlers.mjs (the MongoDB MCP
      // runtime). Legacy in-process emitters used `count` — accept both
      // for backward compat.
      if (ev.type === "mongo.result") {
        this.mongoResultEvents += 1;
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

  /**
   * Top-level metadata callers want to overwrite on the finalized trace
   * (release, correlation, otel). Stored here so `toJSON()` can fold them
   * in without forcing every call site to mutate the returned object.
   */
  private releaseMeta?: Trace["release"];
  private correlationMeta?: Trace["correlation"];

  setRelease(meta: Trace["release"]): void {
    this.releaseMeta = meta;
  }

  setCorrelation(meta: Trace["correlation"]): void {
    this.correlationMeta = meta;
  }

  toJSON(): Trace {
    const otel = this.captureOtelIds();
    const spanTree = this.buildSpanTree();
    // Fold per-skill `read_skill_resource` rollups into each matching
    // `skill.activated` event payload. We mutate a shallow clone of each
    // event so the live `events` array (still referenced by listeners) stays
    // unchanged.
    const events = this.events.map((ev) => {
      if (ev.type !== "skill.activated") return ev;
      const payload = ev.payload as { name?: string; resourceReads?: unknown[] };
      const reads = payload.name ? this.skillResourceReads.get(payload.name) : undefined;
      if (!reads || reads.length === 0) return ev;
      return {
        ...ev,
        payload: { ...payload, resourceReads: reads } as never,
      };
    });
    return {
      traceId: this.traceId,
      sessionId: this.sessionId,
      messageId: this.messageId,
      userId: this.userId,
      agentId: this.agentId,
      events,
      summary: this.summary(),
      createdAt: new Date(this.startTs).toISOString(),
      truncated: this.degraded || this.eventsDropped > 0 || undefined,
      eventsDropped: this.eventsDropped || undefined,
      release: this.releaseMeta,
      correlation: this.correlationMeta,
      otel,
      spanTree: spanTree.length ? spanTree : undefined,
    };
  }

  /** Test helper: snapshot the per-skill resource-read buffer without
   *  forcing a full `toJSON()` (which fires OTel capture + span-tree build). */
  getSkillResourceReadsForTests(): Map<string, Array<{
    resourcePath: string;
    bytes: number;
    toolUseId?: string;
    latencyMs?: number;
  }>> {
    return new Map(this.skillResourceReads);
  }
}
