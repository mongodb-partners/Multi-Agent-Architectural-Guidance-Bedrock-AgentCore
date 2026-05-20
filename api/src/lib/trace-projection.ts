/**
 * Server-side trace projection for the Trace Viewer's two-tier fetch model.
 *
 * The Trace Viewer (Streamlit, `ui/pages/2_Trace_Viewer.py`) loads in two
 * tiers:
 *
 *   1. **Initial load (default)** — fetches `?include=core`, a lite projection
 *      that strips heavy debug-only payload fields and dev-only event types.
 *      Client-facing sections (`render_summary_header`, `render_memory`,
 *      `render_mongo_dashboard`, etc.) render from this; the page stays fast
 *      for client demos.
 *
 *   2. **On-demand (when the user clicks "Show developer details")** — fetches
 *      `?include=dev`, the full trace doc. The Developer details panel renders
 *      from this; the payload is cached in `st.session_state` so toggling the
 *      panel doesn't re-fetch.
 *
 *   3. **`?include=full`** — identity projection. Used by smoke tests
 *      (`e2e-smoke/verify-trace-ui-shape.py`) and any external caller pinned
 *      to today's wire shape. This is also the server-side **default** in
 *      PR 1 — the UI explicitly opts into `core`/`dev` in PR 2.
 *
 * Sentinels: a stripped field is replaced with
 *   `{ _omittedForCoreMode: true, bytesAvailable: <N>, wasRedacted?: boolean }`
 *
 * so the client UI can render a muted "click to load N bytes" caption where
 * the field would have been. When the source field was already `<redacted>`
 * (e.g. when `MEMORY_TRACE_VALUES=0` redacts memory facts), we set
 * `wasRedacted: true` and `bytesAvailable: 0` so the UI renders
 * "redacted by MEMORY_TRACE_VALUES" instead of "11 bytes available".
 *
 * The projection runs in the route handler at read time, **after** the
 * collector's `redactDeep` pass at emit time. PII keys (`email|phone|…`)
 * are always redacted regardless of `include`.
 */

import type { Trace, TraceEvent, TraceEventType } from "./trace-types.ts";

export type TraceIncludeMode = "core" | "dev" | "full";

export const TRACE_INCLUDE_MODES: ReadonlyArray<TraceIncludeMode> = [
  "core",
  "dev",
  "full",
];

/**
 * Coerce a raw query-string value to a valid `include` mode. Falls back to
 * `full` (the server default) for unknown / missing values.
 */
export function parseIncludeMode(raw: string | undefined | null): TraceIncludeMode {
  const v = raw?.trim().toLowerCase();
  if (v === "core" || v === "dev" || v === "full") return v;
  return "full";
}

/** Heavy fields stripped in `core` mode, keyed by event type. Sub-paths use
 *  `.` to express nested key lookup (1-level deep is sufficient today). */
const STRIP_FIELDS_BY_TYPE: Partial<Record<TraceEventType, ReadonlyArray<string>>> = {
  "prompt.assembled": ["body"],
  "model.request": ["userMessage", "messagesSeed", "priorTurnsPreview"],
  "model.thinking_block": ["text"],
  "mongo.query": ["pipeline", "filter", "normalizedFilter", "projection", "sort"],
  "mongo.result": ["sampleDocs"],
  "mongo.vector_search": ["documentPreviews.fields", "queryVectorPreview", "filter"],
  "memory.long_term_write": [
    "factCandidates",
    "extractorRawText",
    "extractorRequestPrompt",
    "extractorErrorClass",
    "extractorErrorMessage",
  ],
  "memory.scoped_read": [
    "retrievalErrorClass",
    "retrievalErrorMessage",
    "retrieval.perCollection.error",
  ],
  "memory.shared_read": [
    "retrievalErrorClass",
    "retrievalErrorMessage",
    "retrieval.perCollection.error",
  ],
  "tool.call": ["input", "result"],
  "tool.http": ["body", "responseSnippet"],
  "tool.mcp": ["args", "result"],
  "agentcore.invoke": ["payload", "responseBody", "requestHeadersPreview", "responseHeadersPreview"],
  "skill.activated": ["bodyPreview", "resourceReads"],
};

/** Event types dropped entirely from `core` mode. The Developer details
 *  panel is the only consumer of these. */
const DEV_ONLY_EVENT_TYPES: ReadonlySet<TraceEventType> = new Set<TraceEventType>([
  "dev.environment",
  "dev.byte_cap_hit",
  "model.retry",
  "agentcore.retry",
  "model.text_delta_batch",
  "latency.checkpoint",
]);

/** Top-level trace fields dropped from `core` mode. */
const DEV_ONLY_TOP_LEVEL: ReadonlyArray<keyof Trace> = [
  "release",
  "correlation",
  "otel",
  "spanTree",
];

/** Maximum number of `documentPreviews` retained per `mongo.vector_search`
 *  event in core mode. The client memory panel only needs top-3 source previews. */
const CORE_DOC_PREVIEWS_LIMIT = 3;

function approxJsonBytes(v: unknown): number {
  if (v == null) return 0;
  try {
    const s = JSON.stringify(v);
    return s ? s.length : 0;
  } catch {
    return 0;
  }
}

const REDACTED_SENTINEL = "<redacted>";

function isAlreadyRedacted(v: unknown): boolean {
  return typeof v === "string" && v === REDACTED_SENTINEL;
}

function stripSentinel(value: unknown): unknown {
  if (isAlreadyRedacted(value)) {
    return { _omittedForCoreMode: true, bytesAvailable: 0, wasRedacted: true };
  }
  return {
    _omittedForCoreMode: true,
    bytesAvailable: approxJsonBytes(value),
  };
}

/**
 * Strip a 1-level-nested key path like `documentPreviews.fields` from a
 * payload. The first segment selects the top-level field; the second segment
 * is removed from every entry in the array (or the single object if it's not
 * an array). Used for fields like `mongo.vector_search.documentPreviews[].fields`.
 */
function stripNestedPath(payload: Record<string, unknown>, path: string): void {
  const [topKey, subKey] = path.split(".");
  if (!topKey || !subKey) return;
  const top = payload[topKey];
  if (Array.isArray(top)) {
    payload[topKey] = top.map((item) => {
      if (item && typeof item === "object" && subKey in (item as Record<string, unknown>)) {
        const { [subKey]: _omitted, ...rest } = item as Record<string, unknown>;
        void _omitted;
        return rest;
      }
      return item;
    });
  } else if (top && typeof top === "object" && subKey in (top as Record<string, unknown>)) {
    const { [subKey]: _omitted, ...rest } = top as Record<string, unknown>;
    void _omitted;
    payload[topKey] = rest;
  }
}

/**
 * Apply core-mode stripping to a single event. Returns either the projected
 * event (cloned, original untouched) or `null` if the event type is dropped
 * entirely from core mode.
 */
function projectEventForCore(ev: TraceEvent): TraceEvent | null {
  if (DEV_ONLY_EVENT_TYPES.has(ev.type)) return null;

  const stripFields = STRIP_FIELDS_BY_TYPE[ev.type];
  if (!stripFields || stripFields.length === 0) return ev;

  const payload = { ...((ev.payload ?? {}) as Record<string, unknown>) };

  for (const field of stripFields) {
    if (field.includes(".")) {
      stripNestedPath(payload, field);
      continue;
    }
    if (!(field in payload)) continue;
    const value = payload[field];
    if (value === undefined || value === null) continue;
    payload[field] = stripSentinel(value);
  }

  // mongo.vector_search: keep only top-3 documentPreviews in core mode.
  if (ev.type === "mongo.vector_search") {
    const previews = payload.documentPreviews;
    if (Array.isArray(previews) && previews.length > CORE_DOC_PREVIEWS_LIMIT) {
      payload.documentPreviews = previews.slice(0, CORE_DOC_PREVIEWS_LIMIT);
    }
  }

  return { ...ev, payload: payload as never };
}

/**
 * Project a trace document for the requested `include` mode.
 *
 *   - `full` (default): identity. The doc is returned verbatim — same shape
 *     today's UI + `verify-trace-ui-shape.py` expect.
 *   - `dev`: identity (full doc, including dev-only top-level fields and
 *     event types). The Developer details panel calls this on-demand.
 *   - `core`: strips heavy payload fields (with sentinels), drops dev-only
 *     event types, and removes dev-only top-level fields (`release`,
 *     `correlation`, `otel`, `spanTree`). Used by the Trace Viewer's
 *     initial fast load.
 */
export function projectTraceForInclude(trace: Trace, include: TraceIncludeMode): Trace {
  if (include === "full" || include === "dev") return trace;
  // core mode
  const projectedEvents: TraceEvent[] = [];
  for (const ev of trace.events) {
    const out = projectEventForCore(ev);
    if (out) projectedEvents.push(out);
  }
  const projected: Trace = {
    traceId: trace.traceId,
    sessionId: trace.sessionId,
    messageId: trace.messageId,
    userId: trace.userId,
    agentId: trace.agentId,
    events: projectedEvents,
    summary: trace.summary,
    createdAt: trace.createdAt,
    truncated: trace.truncated,
    eventsDropped: trace.eventsDropped,
  };
  // Strip dev-only top-level fields (release / correlation / otel / spanTree).
  for (const key of DEV_ONLY_TOP_LEVEL) {
    delete (projected as Record<string, unknown>)[key as string];
  }
  return projected;
}
