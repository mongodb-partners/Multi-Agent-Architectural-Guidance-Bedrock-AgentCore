# Demo / trace UI guide

This stack is always demo-mode. There is no toggle. Every chat turn produces
a trace that the Streamlit UI renders inline and on a dedicated Trace
Viewer page.

> **For section-by-section guides to the Trace Viewer itself**, see:
>
> - [`trace-ui-system-overview.md`](../trace-ui-system-overview.md) — **start here** — every Trace UI surface in one place (inline summary card under chat replies, Trace Viewer page, Sessions integration, developer fixture harness, print/PDF, mobile posture).
> - [`trace-viewer-guide.md`](../trace-viewer-guide.md) — the **default** Trace Viewer page (tiles, narrative, Mongo dashboard, memory, tool calls, AgentCore hops). Audience: PMs / AEs / support / customers on a demo.
> - [`trace-viewer-developer-guide.md`](../trace-viewer-developer-guide.md) — the **"Show developer details"** panel (full prompt + model I/O, Mongo pipelines, LTM internals, retries, span tree, byte caps, fixture harness, debug-the-panel workflow). Audience: engineers debugging a real turn.
>
> This file (`demo-mode-guide.md`) covers env knobs + how the demo *itself* is wired (sidebar, mock-mode banner, prompt buttons). The two guides above cover **what's on screen** in the Trace Viewer.

## What the user sees

### Chat panel (inline summary card)

Every assistant reply is followed by a one-glance summary card showing the
high-priority signals for that turn:

- Latency · Tokens · Cost · Tool count · Mongo ops (5-tile row)
- Badges for memory reads/writes, skills activated, AgentCore hops,
  handoffs, errors.
- A compact "MongoDB ops" expander listing every query in order
  with status + latency.
- **View full trace →** link (opens `/Trace_Viewer?traceId=…`).
- A **Developer details** expander with the raw `TraceEvent` JSON.

### Trace Viewer page

Same trace, expanded:

- **What happened** — short, plain-English narrative lines.
- **Timeline** — lightweight Gantt-style bars per event.
- **Routing decisions** — handoff attribution with trigger spans, confidence,
  alternatives considered.
- **MongoDB** — per-query expander with normalized filter, sample docs,
  plan, diagnostic (offending clause / value-type warnings), DB Data info,
  vector-search histogram.
- **Tool calls** — generic tool spans, HTTP tools (with method/status/
  redacted headers), MCP tools.
- **AgentCore runtime** — orchestrator → specialist hops, nested trace
  splicing badge, observability links (X-Ray / CloudWatch when emitted).
- **Long-term memory** — facts read, facts written (with `factCandidates`
  showing matched + rejected), backend, latency.
- **Developer details** — raw `TraceEvent[]` JSON for copy-paste.

### Sidebar

- **Try a prompt** — buttons from `config/demo-prompts.yaml`. Click → the
  next rerun submits the prompt automatically.
- **Live metrics** — cached aggregate of cost / tokens / latency / Mongo
  ops over the last 25 turns visible to the caller (`GET /traces`).
- **Sessions** + **agent picker** — unchanged, just slimmer.

The **Sessions** page has a per-row **View traces** button that opens the
Trace Viewer at the latest assistant message's trace.

## Env knobs the demo cares about

| Variable | Default | Effect |
|---|---|---|
| `TRACING_ENABLED` | `1` | Set `0` to disable trace emission entirely. |
| `TRACE_TTL_DAYS` | `30` | TTL for the MongoDB `traces` collection. |
| `TRACE_RING_BUFFER_SIZE` | `100` | In-process fallback / sidebar source. |
| `TRACE_MAX_TURN_BYTES` | `2 097 152` | Per-turn byte cap (`degraded` flag fires when crossed). |
| `TRACE_MAX_EVENT_BYTES` | `16 384` | Per-event payload cap (large fields trimmed). |
| `TRACE_REDACT` | `0` | Scrub PII keys (email, token, …) from trace payloads. |
| `MEMORY_TRACE_VALUES` | `0` | Include actual fact strings in `memory.*` payloads. |
| `MONGO_TRACE_DIAGNOSTIC` | `0` | Run the empty-result diagnostic (clause walker, schema sampler, value-type heuristics). |
| `MONGO_TRACE_EXPLAIN` | `0` | Capture `explain("executionStats")` for queries. |
| `MONGO_TRACE_VECTOR_DEBUG` | `0` | Recall-without-filter comparison for vector search. |
| `AGENTCORE_NESTED_TRACE_MAX_BYTES` | `200 000` | Cap nested events the runtime container ships back. |

## Adding a new demo prompt

Edit `config/demo-prompts.yaml`. The file is served to the UI by the API at
`GET /demo-prompts` with the signed-in user's API token — this is why the file
lives in `config/` (mounted into the API container) and not in `ui/` (the
Streamlit container doesn't see the repo's `config/` tree).

Each prompt is `{ label, text }` and groups are free-form:

```yaml
- title: My demo
  prompts:
    - label: New scenario
      text: <the message body the UI submits when the button is clicked>
```

No code change required.

## Authoring trace events

Anywhere on the request path that has access to `currentTrace()` (from
`api/src/lib/trace-context.ts`) can emit events. The collector is
hooked into `POST /chat` for both EC2-resident and AgentCore Runtime
containers — `withTrace(collector, fn)` propagates via `AsyncLocalStorage`.

New event types must be added to the discriminated union in
`api/src/lib/trace-types.ts` first; otherwise TypeScript will reject the
`trace.event(...)` call.
