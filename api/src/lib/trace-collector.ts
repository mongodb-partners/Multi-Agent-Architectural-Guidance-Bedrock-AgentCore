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

import { costOfUsage } from "./model-pricing.ts";
import type {
  ChatTurnSummary,
  Trace,
  TraceEvent,
  TraceEventType,
  ModelUsagePayload,
} from "./trace-types.ts";

// ---------------------------------------------------------------------------
// Env knobs (kept here so callers don't have to remember the names)
// ---------------------------------------------------------------------------

const ENV = process.env;

function envInt(name: string, fallback: number): number {
  const v = ENV[name];
  if (!v) return fallback;
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function envBool(name: string, fallback: boolean): boolean {
  const v = ENV[name]?.trim().toLowerCase();
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
  "error",
  "tool.call", // start/end stubs kept; large payloads stripped first
  "mongo.intent",
  "mongo.query",
  "mongo.result",
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
    const env = init.env ?? ENV;
    this.maxEventBytes = envInt("TRACE_MAX_EVENT_BYTES", DEFAULT_MAX_EVENT_BYTES);
    this.maxTurnBytes = envInt("TRACE_MAX_TURN_BYTES", DEFAULT_MAX_TURN_BYTES);
    this.pendingTextCap = envInt("TRACE_PENDING_TEXT_BYTES", DEFAULT_PENDING_TEXT_BYTES);
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
    return id;
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

    for (const ev of this.events) {
      if (ev.type !== "model.usage") continue;
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
    }

    return {
      inputTokens,
      outputTokens,
      totalTokens: inputTokens + outputTokens,
      cacheReadInputTokens: cacheReadInputTokens || undefined,
      cacheWriteInputTokens: cacheWriteInputTokens || undefined,
      toolCalls: this.toolCallCount,
      mongoQueries: this.mongoQueryCount,
      mongoDocsReturned: this.mongoDocsReturned,
      mcpCalls: this.mcpCallCount,
      agentcoreHops: this.agentcoreHops || undefined,
      agentcoreRuntimeMs: this.agentcoreRuntimeMs || undefined,
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
