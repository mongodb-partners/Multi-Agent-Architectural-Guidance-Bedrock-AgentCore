# Trace UI — system overview

> **Audience:** anyone trying to understand the whole tracing UI surface area, not just the Trace Viewer page. Read this first, then drill into one of:
>
> - [`trace-viewer-client-guide.md`](trace-viewer-client-guide.md) — the section-by-section field guide to the client-facing view
> - [`trace-viewer-developer-guide.md`](trace-viewer-developer-guide.md) — the field guide to the Developer details panel
> - [`observability-runbook.md`](observability-runbook.md) §1.b — the Day-2 workflow that uses both

The Trace UI is not one page. It is **four surfaces** rendering the same trace data, plus **two off-stack tools** for developers. This doc maps all six and tells you which one to look at when.

---

## The six surfaces at a glance

| # | Surface | Where | Audience | What loads |
|---|---|---|---|---|
| 1 | **Inline summary card** | Chat panel, under every assistant reply | End user / demo viewer | Streamed in-band (no extra fetch) |
| 2 | **Trace Viewer page — client view** | `/Trace_Viewer?traceId=…` | PM / AE / customer / support | `GET /traces/<id>?include=core` (15 KB typical) |
| 3 | **Trace Viewer page — Developer details panel** | Same page, behind a button | Engineer debugging a turn | `GET /traces/<id>?include=dev` (40 KB typical), cached in `st.session_state` |
| 4 | **Sessions page** | `/Sessions` | Anyone with access | `GET /sessions` + on click `GET /traces?sessionId=` |
| 5 | **Developer fixture harness** | `streamlit run ui/scripts/render_dev_fixture.py` | Engineer iterating on the dev panel | No API at all — loads `ui/tests/fixtures/dev_trace_*.json` |
| 6 | **Print / PDF** | Any of the above + `Cmd/Ctrl + P` | Anyone needing a deliverable | CSS print media stripping in `trace_css.py` |

Sub-surfaces 1 + 2 are **always-on** for every chat turn. Sub-surface 3 is **opt-in per trace** (one click). 4 + 5 are **distinct entry points**. 6 is **CSS-only** (no separate render path).

---

## 1. Inline summary card (chat panel)

Lives in `ui/lib/inline_summary.py`. Renders immediately under each assistant reply in `ui/lib/chat_panel.py`. The card is composed of three independently-conditional panels:

### 1a. Vector sources panel

Driven by `mongo.vector_search` events on the turn. For each search (deduped on `collection`):

- **Header**: `Hybrid sources from vector + lexical fusion — N hits on \`<collection>\`` (or `Sources from vector search — N hits`)
- **Per-document bullet** (top 5):
  - `#rank Title — score` (Markdown bullet)
  - `URL: …` (caption) if the document carries one
  - First 160 chars of the snippet
  - `Fields: key=value, key=value, …` (top 5 fields, 80-char-truncated values)
- **Footer captions** for edge cases — `No vector-search documents were returned`, `No source document preview was recorded`, `No source URL recorded`.

This is the closest thing in the chat panel to "show me the receipts" — a customer reading the assistant's reply can scan the actual MongoDB documents the model grounded on.

### 1b. Memory panel

Driven by `memory.long_term_write` + `memory.long_term_skip`. When the agent has long-term memory enabled and either event fired:

- **Write branch**: an expander labelled "Learned N new fact(s) this turn" listing each fact's first 120 chars + an `inserted` / `duplicate` chip
- **Skip branch**: a one-liner with a human-readable reason (mapped from the technical reason via `_MEMORY_SKIP_LABELS`):
  - `no_user_id` → "no signed-in user — memory write skipped"
  - `empty_assistant_reply` → "assistant reply was empty — nothing to learn from"
  - `no_fact_candidates` → "the extractor found no personal facts in this turn"
  - `duplicates_only` → "nothing new — every candidate was a duplicate of a saved fact"
  - `llm_extractor_failed` → "the fact extractor model errored — no facts were added"
  - `no_fact_acceptance` → "extractor returned candidates but none matched curation rules"
- A `st.toast` at the top of the page mirrors the write/skip event for users who scrolled past the card

When the agent's `.agent.md` doesn't have `memory.longTerm: true`, this panel is entirely hidden — no memory story for that agent on that turn.

### 1c. View full trace button

`View full trace →` — opens `/Trace_Viewer?traceId=<id>` in the same tab. Only renders when a `traceId` is available (i.e. the streamed `done` event carried one).

### What the inline card does **not** show

The card is intentionally narrow:

- No latency / token / cost tiles → those are in the Trace Viewer summary header
- No tool call list → too noisy in a chat panel; Trace Viewer renders it
- No raw event JSON → that's the dev panel's job

The discipline is "anything that makes the chat panel feel busy goes to the Trace Viewer." Test contract: `ui/tests/test_inline_summary.py::test_has_signal` covers when each panel renders.

---

## 2. Trace Viewer page — client view (default)

The full per-turn dashboard. Loads `?include=core` (no system prompts, no raw tool args, no internal flags). See [`trace-viewer-client-guide.md`](trace-viewer-client-guide.md) for the section-by-section walk.

**Sidebar features** (left rail of the page):

- `← Chat` — page link back to the chat
- `Sessions` — page link to the Sessions page
- `Recent traces` — top 10 `GET /traces` results. Each is a button `<traceId8>… · <agentId>` that calls `open_trace_viewer(traceId)` (which sets `st.session_state[SELECTED_TRACE_ID_KEY]` + reruns the page with the new id in the URL).

**Header navigation** (in the page body, above the summary tiles):

- `← previous turn` / `next turn →` arrows
- Jump-to-turn pills `[1] [2] [3] …` covering every assistant turn in the same session

Both surfaces are wired by `render_session_nav(settings, api_token, trace)` in `ui/lib/trace_navigation.py`, backed by `GET /traces?sessionId=<id>&excludeTraceId=<current>`. The nav only renders when the session has more than one turn.

---

## 3. Trace Viewer page — Developer details panel

The same page, but a single button — `Show developer details` — gates the entire panel. See [`trace-viewer-developer-guide.md`](trace-viewer-developer-guide.md) for the 14-sub-section catalog.

Key behavioral contract (pinned by `ui/tests/test_trace_view.py`):

- **Closed panel = zero work.** No fetch, no `_dev_*` evaluation.
- **First open = one `GET /traces/<id>?include=dev` fetch.** Cached in `st.session_state[f"dev_trace_{traceId}"]`.
- **Every subsequent rerun on the same trace = cache hit.** Sidebar tweaks, prev/next navigation, anything that triggers a Streamlit rerun re-reads from the cache.
- **Different traceId = fresh fetch.** Cache key includes the trace id.

Every fetch is logged in the audit channel:

```text
{ "channel": "audit", "msg": "[trace] fetch", "include": "dev",
  "userId": "<sub>", "traceId": "<UUID>", "requestId": "<req_…>" }
```

…filterable in CloudWatch Logs Insights via `filter channel = "audit" and msg = "[trace] fetch"`.

---

## 4. Sessions page

`ui/pages/1_Sessions.py`. Per-row layout (one row per chat session belonging to the signed-in user):

| Button | Behavior |
|---|---|
| `Open in chat` | Sets the session id as the active one and routes to `app.py` so you can resume chatting |
| `View traces` | Picks the most recent assistant message's `traceId` and opens `/Trace_Viewer?traceId=<id>` |
| `Delete` | `DELETE /sessions/<id>` (cascade-deletes `chat_sessions` + `chat_messages` rows for that session); only the session owner can call this |

This is the **only entry point for cross-session navigation**. The Trace Viewer itself is strictly per-turn — you cannot aggregate across sessions inside the Trace Viewer.

---

## 5. Developer fixture harness — `ui/scripts/render_dev_fixture.py`

The fastest way to iterate on a `_dev_*` sub-renderer without deploying or even running the API:

```bash
streamlit run ui/scripts/render_dev_fixture.py -- \
  --fixture ui/tests/fixtures/dev_trace_full_kitchen_sink.json
```

The harness:

1. Loads a fixture JSON from `ui/tests/fixtures/dev_trace_*.json`.
2. Pre-sets `st.session_state[f"dev_open_{traceId}"] = True` and `st.session_state[f"dev_trace_{traceId}"] = <fixture>`, so `render_developer_details` renders on first paint without the click.
3. Passes `settings=None` to `render_developer_details`, which short-circuits the on-demand fetch (the cached payload is used instead).
4. Adds a sidebar `selectbox` to swap fixtures in place — saves you `streamlit run` restarts when iterating.

### Available fixtures

| Fixture file | What it exercises |
|---|---|
| `dev_trace_byte_cap.json` | `dev.byte_cap_hit` events + `trace.truncated` + `eventsDropped` flag — the Byte cap drops sub-section |
| `dev_trace_environment_and_otel.json` | `dev.environment` event payload + `trace.otel.{traceId, rootSpanId}` + ServiceLens / X-Ray deep-link buttons |
| `dev_trace_retries.json` | Interleaved `model.retry` + `agentcore.retry` events — the Retries sub-section |
| `dev_trace_skill_resource_reads.json` | `skill.activated.resourceReads[]` rollup with multiple per-skill reads |
| `dev_trace_span_tree.json` | Hierarchical `trace.spanTree` with parent/child + duration merging |
| `dev_trace_vector_search_indexname.json` | `mongo.vector_search.indexName` plumbing + `documentPreviews[]` capping |
| `dev_trace_full_kitchen_sink.json` | All of the above in one fixture — the "render every sub-section once" smoke |

Pair the harness with `bun test tests/unit/trace-projection.test.ts` if you've changed the `core`/`dev` projection rules — the fixtures are dev-mode payloads, so any over-stripping bug would show up as missing fields in the rendered panel.

---

## 6. Print / PDF

The Trace Viewer is print-friendly by default. `Cmd/Ctrl + P` from any browser produces a clean PDF suitable for client deliverables. The `@media print` rule in `ui/lib/trace_css.py` does the heavy lifting:

- **Removes** the brand strip (`MongoDB Atlas` / `AWS Bedrock` pills) — it's a screen ornament, not a deliverable.
- **Flattens** tile shadows and just-loaded animations.
- **Hides the Developer details body** but keeps the expander summaries — so the printed PDF carries an outline of what's in the dev panel without dumping every JSON block. (CSS can't toggle `<details open>` so this is the best-effort approximation.)
- **Keeps `details` blocks `page-break-inside: avoid`** so an expander doesn't get split across pages.

Practical tip: open the **client view only** before printing — opening the dev panel first will keep its body visible in print despite the CSS, because Streamlit re-renders the expander state.

---

## Mobile / responsive posture

- **Inline summary card**: works on a phone. Vector-source bullets and memory expanders are single-column and don't overflow.
- **Trace Viewer client view**: works on a phone. Tiles wrap to multiple rows; tables fit because they're rendered as Markdown.
- **Trace Viewer Developer details panel**: **does not** work on a phone. The Mongo internals tables, span tree tree, and `latency.checkpoint` tables are wide and will overflow horizontally; pinch-to-zoom is your only escape. The dev panel is designed for desktop debugging.
- **Sessions page**: works on a phone (single-column rows).

If you need to share dev-grade data from a phone, screenshot the relevant sub-section or pull the trace via `GET /traces/<id>?include=dev` and view the JSON in a code editor.

---

## Wire-level contract (cheat sheet)

| Operation | Endpoint | Auth | Returns |
|---|---|---|---|
| Get a trace, client-fast view | `GET /traces/<id>?include=core` | Bearer JWT | Trace JSON minus sentinels + dev-only events + dev-only top-level fields; `X-Trace-Include: core` header |
| Get a trace, full dev view | `GET /traces/<id>?include=dev` | Bearer JWT | Identity (full trace); `X-Trace-Include: dev` header |
| Get a trace, identity (back-compat) | `GET /traces/<id>?include=full` | Bearer JWT | Identity; `X-Trace-Include: full` header |
| List recent traces | `GET /traces?limit=10` | Bearer JWT | Array of `{ traceId, agentId, createdAt, summary }` |
| List a session's traces | `GET /traces?sessionId=<id>` | Bearer JWT | Same shape, filtered |
| Exclude one trace | `GET /traces?sessionId=<id>&excludeTraceId=<curr>` | Bearer JWT | Same shape, minus the current one (used by prev/next nav) |

All trace fetches are logged to the audit channel with `include` so you can later see who looked at what level of detail. See `api/src/routes/trace.ts` for the exact log line.

---

## Where to look when something is wrong

| Symptom | First place to look |
|---|---|
| The chat reply has no inline summary card | Streamed `done` event was missing — check the API SSE stream + `chat.ts` |
| The "View full trace" button doesn't appear | `trace_id` wasn't on the `done` event payload; check `streaming.py` |
| The Trace Viewer page says "Trace not found" | TTL fired (30 days default) or trace was deleted; check `/<SHARED_RESOURCE_PREFIX>/<env>/api` for `[trace] not_found` |
| Developer details button is missing | The page failed to import `render_developer_details`; check the Streamlit container's stderr |
| Developer details button is there but click does nothing | `?include=dev` fetch failed; check the API access log + `_fetch_dev_trace` warning in the page body |
| Sessions page is empty for a user who has chatted | JWT subject mismatch — `GET /sessions` filters by JWT `sub`; confirm the user logged in with the same Cognito identity |
| Recent traces sidebar is empty | `GET /traces` returned an error — check the caption under the sidebar header |
| Print/PDF still shows the brand strip | Browser is rendering the on-screen CSS; check that `@media print` rule didn't get pruned during a build |

---

## Related docs

- [`trace-viewer-client-guide.md`](trace-viewer-client-guide.md) — section-by-section field guide to the client view (sections 1–15)
- [`trace-viewer-developer-guide.md`](trace-viewer-developer-guide.md) — section-by-section field guide to the dev panel (sub-sections 1–14)
- [`observability-runbook.md`](observability-runbook.md) §1.b — Day-2 workflow ("I have a trace id, now what?")
- [`api-reference.md`](api-reference.md) — `GET /traces` + `?include=` contract
- [`demo-mode-guide.md`](demo-mode-guide.md) — env knobs + how the demo's sidebar / mock-mode banner is wired
- `ui/lib/inline_summary.py` — the chat-panel inline card source
- `ui/pages/2_Trace_Viewer.py` — the main page
- `ui/pages/1_Sessions.py` — Sessions integration
- `ui/scripts/render_dev_fixture.py` — fixture harness
- `ui/lib/trace_css.py` — themes + print media
- `ui/lib/trace_navigation.py` — prev/next + recent-traces wiring
