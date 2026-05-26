# Trace Viewer — summary guide

> **Audience:** product managers, account executives, support engineers, and customers walking through a live demo. Every section below is what's on screen **by default** when you open the Trace Viewer — no toggles, no developer mode.
>
> **For the debug-grade developer surface** (loaded on demand when you click "Show developer details"), see [`trace-viewer-developer-guide.md`](trace-viewer-developer-guide.md).

The Trace Viewer is a per-turn dashboard. Every assistant reply produces exactly one trace. The Streamlit UI surfaces it in **four** places — see [`trace-ui-system-overview.md`](trace-ui-system-overview.md) for the full surface map. This guide walks **the full page only**, top to bottom. The other surfaces (inline summary card, Sessions page, developer fixture harness, print PDF) are covered in the system overview.

Section names below match the on-screen headings.

---

## How to open a trace

| From | Action |
|---|---|
| Chat panel | Click **"View full trace →"** under any assistant reply |
| Sessions page | Click **"View traces"** on any session row |
| Direct URL | `https://<ui-host>/Trace_Viewer?traceId=<UUID>` |
| Direct URL (by session + message) | `…/Trace_Viewer?sessionId=<id>&messageId=<msg>` |

The page fetches `?include=core` from the API (a lite, summary-safe projection — system prompt bodies, raw tool inputs, and internal flags are stripped). It loads in well under a second on a typical turn.

The "← previous turn" / "next turn →" arrows in the header (and `[1] [2] [3]…` jump-to-turn pills) let you walk every turn in the session without going back to the Sessions page.

---

## 1. Brand strip + trace metadata

At the top:

- **Brand pills** — "MongoDB Atlas", "AWS Bedrock", "multi-agent trace" — reinforce the stack on screen recordings and PDF exports.
- **Session navigator** — `← previous` / `next →` arrows and jump-to-turn pills (only renders when the session has more than one turn).
- **Trace meta line** — agent that produced this turn, message id, timestamp, and a "permalink" copy button so you can paste the trace URL into Slack/email.

When the API ran in **mock mode** (no AWS credentials, no Atlas, no AgentCore — used in `docker compose up` for offline demos), a yellow **`MOCK BACKENDS`** banner appears immediately above the tiles so nobody mistakes a fixture-driven reply for a live AWS one.

---

## 2. Summary tiles (the 5–9 tile row)

The single most-glanced surface in the whole UI. Each tile is one chip with a metric and an optional small caption underneath. Tiles are only shown when the underlying metric is non-zero, so a turn with no Mongo ops simply omits the Mongo tile.

| Tile | Meaning | Caption example |
|---|---|---|
| **Latency** | Total wall-clock seconds for the turn (`chat.turn.end.durationMs`) | `18.28s` |
| **AgentCore** | How many hops orchestrator → specialists made this turn | `1 hop`, hint `17.9s runtime` |
| **Memory** | Long-term memory result for the turn | `14 entries` (hybrid read), hint `read · degraded` if a leg failed |
| **MongoDB** | Mongo ops fired this turn, with success ratio | `3/3 ok`, hint `12 doc(s), 1 vector · 8 hit(s)` |
| **Tools** | Tool / MCP calls (every `tool.call` plus `tool.mcp`) | `2 calls` |
| **Tokens** | Total tokens (sum of all `model.usage` events) | `9,539`, hint `9,343 in / 196 out` |
| **Cost** | Estimated USD for the turn (per-model Bedrock pricing) | `$0.0103` (or `≈$x.xxxx` when one leg's pricing is unknown) |
| **Errors** | Count of `error` events + failed Mongo ops + AgentCore errors | `1` with hint "See details below" |
| **Model** | Single model id (or "N models" when more than one) | `claude-sonnet-4-5` |

The tile row alone is usually enough for a sales / PM demo — it tells the "how fast, how much, what just happened" story in one glance.

---

## 3. MongoDB-first dashboard

A short row of MongoDB-Atlas-branded chips and tables that surface anything Atlas-touching:

- **Collections used** — `products`, `chat_messages`, `agent_memory_facts`, …
- **Vector searches** — count, top scores, and a tooltip on each result showing the first ~200 chars of the matched document (sourced from `mongo.vector_search.documentPreviews[]`). Hover any result to see what the model actually retrieved. Tooltips are rendered with the browser-native HTML `title=` attribute — no custom JS — so they work on every browser and survive PDF export as alt-text. The contract is documented in `AGENTS.md` under `mongo.vector_search.documentPreviews[]`; do not switch to a custom JS tooltip without updating that contract first.
- **BM25 (lexical) hits** — same shape as vector when hybrid search ran on the turn.
- **Per-query latency strip** — small bar for each `mongo.query` so you can see at a glance which collection dominated the turn's wall time.
- **Real filter / pipeline JSON + sample documents** — the actual query operand and the first sample docs returned by Atlas, rendered inline. No longer hidden behind Developer details.

This section is **always rendered first** after the tiles because customer demos are almost always centered on the Atlas story.

---

## 4. "What happened" — plain-English narrative

Three to ten bullet lines generated by `ui/lib/demo_narratives.py::narrate(events)` that translate the trace into something a non-engineer can read. Each line is conditional — it only renders when the underlying event fired.

| Order | Line | Driven by | Renders when |
|---|---|---|---|
| 1 | "We recognised the user via the JWT claim … and enriched their context with N customer + M order(s) from MongoDB." | `auth.context_build` | `customersResolved > 0` or `ordersResolved > 0` |
| 2 | "Recalled N prior context entry(s) via `hybrid` retrieval (V vector + L lexical hit(s); X ms), injecting K bytes into the system prompt." | `memory.scoped_read` / `memory.shared_read` | `entryCount > 0` (a warn-dot is appended when `primaryFailed`) |
| 2b | "Persisted N new fact(s) to long-term memory (`outcome`) (M duplicate(s) skipped)." | `memory.long_term_write` | A write happened (any branch) |
|  | "Skipped the long-term memory write — reason `<reason>`." | `memory.long_term_skip` | No write but a skip event |
| 3 | "The orchestrator routed to `<agent>` because of the phrase '<trigger>'." | `handoff.decision` | A handoff fired |
| 4 | "All N MongoDB lookup(s) returned 0 documents — see the diagnostic panel for why." / "Ran N MongoDB op(s) — X ok, Y empty." | `mongo.result` | Any Mongo op |
| 5 | "Crossed the AgentCore Runtime boundary N time(s) — M nested event(s) were spliced under the wrapper span(s)." | `agentcore.invoke` (+ optional `agentcore.nested_trace`) | At least one invoke |
| 6 | "Total model tokens consumed: N." | `model.usage` | Any usage event |
| 7 | "N error(s) recorded — see the trace events for details." | `error` | Any error |
| 8 | "Detected N MongoDB query(ies) without user scoping — see Developer details → MongoDB internals." | `mongo.query` with `scoping == "missing_user_filter"` | Tenant-leak guardrail tripped (security signal — investigate) |
| 9 | "Retried N time(s) before success — `<errClass>` · X ms backoff (M model + K agentcore)." | `model.retry` + `agentcore.retry` | Any retry — combined into one line so the viewer sees one summary, not two |
| 10 | "Some debug payloads were trimmed to fit the trace cap — N event(s) capped, K bytes dropped. See Developer details." | `dev.byte_cap_hit` | Trace was big enough to hit a payload cap |

Empty narrative = entirely uneventful turn. There's no padding for the sake of padding.

If you see lines 8 (missing-user-scoping) or 9 (retries) in a customer-facing demo, **stop and triage** — those are guardrails, not normal traffic.

---

## 5. Timeline

A lightweight Gantt-style strip with one row per major event (model request, tool call, Mongo query, AgentCore invoke, memory read/write). Each bar is positioned at its start time and scaled to its duration. Hover a bar to see the exact event type + duration in milliseconds.

This is the fastest way to answer "why was this turn slow?" — the longest bar wins.

---

## 6. Context (auth + JWT subject)

A small two-line block:

- **User** — the JWT `sub` claim that authenticated the request (when present), and any user-context bullets the API merged in.
- **Session** — the session id this turn belongs to, with a back-link to the Sessions page.

When the API ran with `REQUIRE_AUTH=true` (production posture), this section confirms the trace was bound to a real user; turns without a user are flagged so they don't quietly poison cross-session memory.

---

## 7. Prompt assembly + activated skills

What we put in front of the model **before** it answered:

- **Persona size** — bytes of the agent's `.agent.md` body that landed in the system prompt.
- **Discovery section** — bytes of the agent + tool catalogue the orchestrator advertises.
- **Memory context** — bytes prepended as `## Relevant prior context` (long-term memory hits + auth context).
- **Activated skills** — a chip per skill the loader matched into this turn (`name`, source: `pre_activate` vs `lazy`, `injectedVia`, bytes added).

The full system prompt body, the raw memory hits, and the system prompt hash live in the Developer details panel — they're heavy and only useful when debugging.

---

## 8. Memory (long-term)

A focused recap of what the long-term memory pipeline did on this turn:

- **Header tiles** — read outcome (e.g. "hybrid · 14 entries"), write outcome (`persisted` · `inserted: N` · `dup: M`), skip reason if applicable (e.g. `userId_missing`).
- **Facts injected into the prompt** — the prepended `## Relevant prior context` block (the canonical recall surface — every memory-enabled agent inherits the four LTM recall rules from `LONG_TERM_MEMORY_RECALL_RULES`).
- **Persisted facts (newly learned)** — the LLM-extracted facts the writer accepted and upserted. Rejected candidates and the extractor's raw output are in Developer details.
- **Related memory events** — small inline cards for `memory.long_term_skip` (with reason chip), shared-tenant `memory.shared_read`, and any memory errors.

When the agent has `memory.longTerm: false`, this whole section is hidden — the agent doesn't have a memory story on this turn.

---

## 9. Model activity

What Bedrock did:

- **Models used** — one chip per `model.usage` event (`anthropic.claude-sonnet-4-5`, etc.).
- **Token bars** — input vs output per call, side by side.
- **Stop reasons** — `endTurn` / `tool_use` / `max_tokens` chips per `model.stop` event.
- **First-token latency** — milliseconds from request start to first streamed token (when `chat.turn.end.firstTokenLatencyMs` is present) — the truest "feels fast" signal.

The actual request and response bodies live in Developer details — this section just shows the metabolic readout.

---

## 10. Routing decisions (when present)

For every orchestrator → specialist handoff:

- **From → To** — `orchestrator → order-management`.
- **Trigger** — the heuristic span that fired (e.g. `keyword: "order"` with `score=1.79`).
- **Runner-up** — second-best specialist + its score, so you can see how close the decision was.
- **Confidence** — the score gap that produced the pick.

Empty for single-agent turns. The full pre-rule rubric and the orchestrator's intermediate scratchpad are in Developer details.

---

## 11. Tool calls

One card per `tool.call`:

- Tool name (`mongodb_query`, `mongodb_vector_search`, `read_skill_resource`, MCP tool names, …)
- Duration in milliseconds
- Success / failure chip
- Hover hint: the high-level "what was asked" (tool input summary; the **full** raw args live in Developer details so we don't leak PII into a demo screen)

For HTTP tools we additionally show the method + response status code; for MCP tools we show the MCP server + tool surface.

---

## 12. AgentCore runtime

The cross-runtime hop story:

- **Orchestrator → specialist** — one card per `agentcore.invoke` showing the target ARN's short name, latency, status (success / error / timeout).
- **Nested trace splicing chip** — when the specialist ran inside an AgentCore Runtime, this badge confirms its internal events were spliced into the trace (and how many).
- **Observability link** — a click-through to the AWS Bedrock AgentCore "Agents" observability page, scoped to this specialist + this trace id. Useful for the X-Ray / CloudWatch GenAI observability dashboard, without leaving the Trace Viewer.

For local / `docker compose` runs that don't touch AgentCore, this section is hidden.

---

## 13. Errors (when present)

Any `error` event, plus any Mongo op with `status=error`, plus any AgentCore call with an `errorMessage`. Each surfaces with:

- Error class name + first 200 chars of the message
- Which span it fired in (so you know which collection / runtime to blame)
- A red chip in the summary tiles so you can spot a problem turn from the sessions list

When this section is empty, the turn completed cleanly.

---

## 14. Trace meta (footer)

A tiny footer with timestamps, the trace's W3C `traceId`, the `messageId`, and the truncation chip (`degraded` / `truncated` when the byte cap fired — the per-event cap is 16 KB, per-turn 2 MB by default; you can override via env vars but the demo defaults are conservative).

If the turn was truncated, the Developer details panel's "Byte-cap drops" sub-section lists exactly which event types were dropped and how many bytes were lost.

---

## 15. The "Show developer details" toggle

Below every section above, a single muted divider:

> **Developer details (loaded on demand)**

…with a `Show developer details` button. **Until you click it, nothing else is fetched.** This is the doorway to:

- Full system prompt + raw model I/O
- Full Mongo pipelines with the `indexName` operand and per-result scoring
- Long-term memory candidates with per-leg RRF / weighted / recency / MMR scores
- Per-skill `read_skill_resource` rollup
- Bedrock & AgentCore retry events
- The complete span tree + the OTel `traceId` / `rootSpanId` (with ServiceLens & X-Ray deep links)
- Environment knobs at the moment of the turn (`chatMode`, `MEMORY_*`, model ids, …)
- Byte-cap drop log
- Raw `TraceEvent[]` JSON with filter / search / download

Read [`trace-viewer-developer-guide.md`](trace-viewer-developer-guide.md) for a sub-section-by-sub-section tour of that panel.

The toggle is **ungated** — anyone with access to the Trace Viewer can open it — and every fetch is recorded in the audit channel (`channel = "audit" msg = "[trace] fetch" include = "dev"`), so support can later see who looked at debug-grade detail for a given trace.

---

## Print / PDF / share

The page is print-friendly without any toggles. `Cmd/Ctrl + P` produces a clean PDF that strips the brand strip, flattens tile shadows, and hides the **body** of every Developer details expander (but keeps the summary labels so the reader can see an outline of what's behind the toggle). See [`trace-ui-system-overview.md`](trace-ui-system-overview.md#6-print-pdf) for the exact CSS contract.

**Tip for the cleanest PDF:** open the page in the *summary* view only — don't click "Show developer details" first. Streamlit re-renders the expander state on print, so an open dev panel may keep its body visible despite the `@media print` rule.

For sharing with a customer, **prefer a PDF export over a live URL** — the URL is meaningless without API access (auth is enforced server-side), but a PDF is self-contained.

---

## Mobile

This page works on a phone for the **summary view only**. The Developer details panel is desktop-only — its tables and span tree are wide and overflow horizontally on a phone screen. See the system overview's [Mobile / responsive posture](trace-ui-system-overview.md#mobile--responsive-posture) section for the full posture matrix.

The inline summary card in the chat panel (the small card under each assistant reply) also works on a phone.

---

## Frequently-asked questions

**Q: Why are tiles I expect missing on this turn?**
Each tile is conditional on its underlying metric being non-zero. A turn with no Mongo ops simply omits the Mongo tile. The tile order itself doesn't change.

**Q: Why is "Memory" sometimes `degraded`?**
The hybrid retriever runs vector + BM25 legs in parallel and surfaces whichever returned first / better. `degraded` means one leg failed (timeout, index not yet queryable, embedding provider hiccup) but the other returned, so the answer still grounded — just on a partial pool. The Developer details `Long-term memory internals` sub-section shows which leg failed and why.

**Q: Why is the "Cost" tile prefixed with `≈`?**
At least one model in the turn didn't have a pricing entry in the cost calculator yet (typically because a brand-new Bedrock model id launched between releases). The tokens are real; the dollars are a lower bound.

**Q: My turn says `truncated`. Did the user see a partial reply?**
No — the truncation flag is **trace-only**. The streamed assistant reply was complete. What got dropped is the *trace document* (specific oversized events were trimmed to keep the doc under `TRACE_MAX_TURN_BYTES`). Open Developer details → "Byte cap drops" to see which event types were affected.

**Q: How long are traces kept?**
30 days by default (`TRACE_TTL_DAYS=30`). The MongoDB `traces` collection has a TTL index that the API auto-ensures on first write. After the TTL fires, the Trace Viewer URL returns a "Trace not found" page; the structured CloudWatch logs (which include the same `trace_id`) are kept for the log group's own retention.

**Q: Can I share a trace URL with a customer?**
Yes — the URL is by `traceId` (UUID) and is meaningless without API access. Auth is enforced server-side; without a valid Bearer token the API returns 401. For summary demos, share a screenshot or PDF export rather than a live URL.

---

## Related docs

- [`trace-ui-system-overview.md`](trace-ui-system-overview.md) — **start here** — all six trace surfaces in one place (inline card, viewer, sessions, fixture harness, print, mobile)
- [`trace-viewer-developer-guide.md`](trace-viewer-developer-guide.md) — the Developer details panel, sub-section by sub-section
- [`demo/demo-mode-guide.md`](demo/demo-mode-guide.md) — Trace UI walkthrough + env knobs for demos
- [`observability-runbook.md`](observability-runbook.md) §1.b — Day-2 "debug a single turn" pointers (CloudWatch / ServiceLens / X-Ray correlation)
- [`api-reference.md`](api-reference.md) `GET /traces/:traceId?include=` — the wire shape that backs both summary and developer views
