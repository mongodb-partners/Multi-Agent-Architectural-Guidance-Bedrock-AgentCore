# Trace Viewer — developer (debug-grade) guide

> **Audience:** engineers debugging a real turn — your own bug, a customer report, a flaky CI smoke. This is the catalog of every sub-section inside the **"Developer details"** panel of the Trace Viewer, what data each surfaces, where the data comes from in the code, and what failure mode it's designed to surface.
>
> **For the default summary view** (tiles, narrative, Mongo dashboard, etc.), see [`trace-viewer-guide.md`](trace-viewer-guide.md).

---

## How to open the developer panel

1. Load any trace at `https://<ui-host>/Trace_Viewer?traceId=<UUID>`. The page fetches `?include=core` by default (no system prompts, no raw tool args, no internal flags — see §"Projection contract" below).
2. Scroll past every summary section to the divider:

   > **Developer details (loaded on demand)**

3. Click **`Show developer details`**.

That click sets `st.session_state[f"dev_open_{traceId}"] = True`, fires `GET /traces/<id>?include=dev` inside an `st.spinner`, and caches the result in `st.session_state[f"dev_trace_{traceId}"]` for the lifetime of the page. Every subsequent Streamlit rerun (sidebar tweak, prev/next navigation, etc.) reads from the cache. Navigating to a **different** `traceId` triggers a fresh fetch (the cache key includes the trace id).

The fetch is recorded in the API's audit channel:

```text
{ "channel": "audit", "msg": "[trace] fetch", "include": "dev",
  "userId": "<sub>", "traceId": "<UUID>", ... }
```

so support can later see who looked at debug-grade detail for a given trace. No special role is required — the toggle is **ungated** by design; the audit log is the accountability mechanism.

The panel renders inside an `st.container(border=True)` with one expander per sub-section below. Sub-sections that have no data (e.g. `dev.byte_cap_hit` on a turn with no drops) degrade to a `no data recorded` caption rather than rendering an empty panel.

---

## Projection contract — what's actually in `?include=dev`

Three modes, served by `api/src/lib/trace-projection.ts`:

| `?include=` | `X-Trace-Include` header | What it returns |
|---|---|---|
| `core` (default) | `core` | Strips dev-only event types + heavy payload fields, drops dev-only top-level fields. Sentinels (`{ _omittedForCoreMode: true, bytesAvailable: N }`) mark where fields were removed so the UI can render a "click to load" caption. All `mongo.*` payload fields (query filter/pipeline/projection/sort, result sampleDocs, vector_search filter/queryVectorPreview/documentPreviews-with-fields) are kept visible — the summary MongoDB dashboard renders them inline. The trace collector's `shrinkPayload` already enforces a per-event byte cap on `sampleDocs`, and `mongo.vector_search.documentPreviews` is independently capped to the top-3 entries. |
| `dev` | `dev` | Identity. Full trace doc, including dev-only event types (`dev.environment`, `dev.byte_cap_hit`, `model.retry`, `agentcore.retry`, `model.text_delta_batch`, `latency.checkpoint`) and dev-only top-level fields (`release`, `correlation`, `otel`, `spanTree`). |
| `full` | `full` | Identity. Same as `dev` — kept as a stable wire shape for external callers + the `verify-trace-ui-shape.py` smoke. |

The Developer details panel always uses `?include=dev`. Stripped fields in `core` mode are replaced with:

```json
{ "_omittedForCoreMode": true, "bytesAvailable": 9580 }
```

…or when the source field was already `<redacted>` (e.g. `MEMORY_TRACE_VALUES=0` redacts fact text at emit time):

```json
{ "_omittedForCoreMode": true, "bytesAvailable": 0, "wasRedacted": true }
```

Every `_dev_*` renderer tolerates these sentinels via `is_omitted_sentinel()` / `render_omitted_sentinel()` so loading `?include=dev` against an older API that doesn't strip yet, or the fallback path where the dev fetch fails entirely, still renders without crashing.

### Hitting the projection contract from `curl`

You don't need to open Streamlit to inspect what the panel will render — every trace fetch is a plain authenticated `GET`:

```bash
# Core projection (what the page loads on first paint)
curl -sS -H "Authorization: Bearer $TOKEN" \
  "$API_BASE/traces/$TRACE_ID?include=core" -D - | head -20

# Full dev payload (what the panel fetches on click)
curl -sS -H "Authorization: Bearer $TOKEN" \
  "$API_BASE/traces/$TRACE_ID?include=dev" -D - | head -20

# Identity (back-compat alias for dev)
curl -sS -H "Authorization: Bearer $TOKEN" \
  "$API_BASE/traces/$TRACE_ID?include=full"
```

The response header `X-Trace-Include: <mode>` confirms what the server actually returned (useful when a CDN or proxy is rewriting query params). The audit-log line described above also fires for `curl` access, so off-UI debugging is still tracked.

The Streamlit app (`ui/lib/api_client.py::get_trace`) also reads `X-Trace-Include` from the response and **logs a warning** when it doesn't match the requested mode — a signal that the API is older than the UI and is silently returning a different projection. If you see `api get_trace include mismatch` in the UI process logs, redeploy the API first.

---

## Sub-sections (top to bottom inside the panel)

Order matches what's on screen. Each entry below answers four questions: **what's shown**, **where it comes from in code**, **what bug it surfaces**, **what to read next when it's empty / wrong**.

### 1. Identifiers + OTel correlation

**What's shown.** A short Markdown table of `traceId`, `sessionId`, `messageId`, `userId`, `agentId`, `finalAgentId`, `createdAt`. Below it: the `trace.correlation` object (`requestId`, `userAgent`), the JWT claims captured by `auth.context_build`, and an OTel block:

> **OTel** — traceId `abcdef…` · rootSpanId `1234abcd…`
> [ServiceLens](https://…) · [X-Ray](https://…)

The ServiceLens and X-Ray links are deep links into AWS that scope to this exact `traceId`, so you can pivot to the cross-service map without copy-pasting an id. Region is taken from `trace.release.region` or `AWS_REGION`.

At the bottom: a **"Reproduce this turn"** code block — a `curl` command pre-baked from the captured request (URL, headers, body) so you can replay the turn outside the UI.

**Where in code.** `_dev_identifiers` in `ui/lib/developer_trace_view.py`. `trace.otel` is populated by `TraceCollector.captureOtelIds()` (only when an active OTel span is in scope); `trace.correlation` by `chat.ts` route handler.

**What it surfaces.**
- `userId = anonymous` → JWT was missing / bypassed. Check `/<SHARED_RESOURCE_PREFIX>/<env>/api` for `auth.bypass.unauthenticated` on the requestId.
- OTel block reads `no traceId on this trace` → the trace pre-dates the OTel bridge, or the OTel SDK was disabled. The deep links won't render.
- `release.gitSha` (visible in §12) differs from `git rev-parse HEAD` → API needs a redeploy.

---

### 2. Span tree (call hierarchy)

**What's shown.** Indented tree of every span on the turn. Each row: `<code>span.type</code> — Nms · agentId`. Nodes are precomputed server-side via `TraceCollector.buildSpanTree()` (cheaper than recomputing in the browser on every rerun) and shipped in `trace.spanTree`. Falls back to a parent-id recompute when older traces have no `spanTree` field.

**Where in code.** `_dev_span_tree` + `_compute_span_tree_from_parent_id` (fallback). API-side builder is `buildSpanTree()` in `trace-collector.ts`.

**What it surfaces.** The longest-duration child is your "why was this turn slow" culprit. Drill into the matching sub-section below (Mongo / Model / AgentCore / etc.) for the payload.

---

### 3. Prompt & model I/O

**What's shown.** Everything the model actually saw and replied:

- **Full assembled system prompt body** (`prompt.assembled.body`, in `core` mode this is a sentinel saying "9580 bytes available").
- **Seeded prior turns** (`model.request.messagesSeed`) — the conversation history that was replayed into the agent on this turn.
- **User message** (`model.request.userMessage`).
- **Per-step assistant deltas** (`model.text_delta_batch` events when present — `core` mode strips these entirely; only `dev` mode ships them).
- **Final assistant response** (concatenated from `conversation.message_added` events).
- **`model.response.body` preview** when captured.

Each block respects redaction sentinels: if you see `[omitted in core mode]` despite being in the dev panel, the projection over-stripped — file a bug against `api/src/lib/trace-projection.ts`.

**Where in code.** `_dev_prompt_and_model_io`. Captured at write time by `run-chat-stream.ts` + `create-strands-agent.ts`.

**What it surfaces.** Unexpected refusal, hallucinated tool call, ignored memory hint, prompt drift between deploys. Cross-reference `model.request.systemPromptHash` across two turns — same hash always means same system prompt.

---

### 4. Mongo internals

**What's shown.** Per `mongo.query` and `mongo.vector_search` event:

- `collection`, `operation`, `documentCount`
- The actual `pipeline` (full JSON, often the most useful payload in the whole dev panel)
- `documentPreviews[]` (same field surfaced as hover-tooltips in the summary view)
- `scoping`: `user_scoped` vs `missing_user_filter` — the latter renders as a red `.trace-chip.danger` chip ("you forgot to scope this aggregate to the current user")
- **`indexName`** — the actual `$vectorSearch.index` / `$search.index` operand the MongoDB MCP client expanded. Plumbed via `vectorIndexFromTransformArgs()` in `mongodb-mcp-client.ts`. An `indexName` of `default` on a vector search is almost always the bug ("you forgot to set `index:` in the pipeline and Atlas silently lexical-scanned").

> The basic per-query view (filter / pipeline / projection / sort + sample docs) is also rendered in the **summary MongoDB dashboard** above — these fields are kept visible in `?include=core`. The dev panel still adds the scoping chip, raw plan/diagnostic JSON, `indexName`, and the per-candidate hybrid score breakdown.

**Where in code.** `_dev_mongo_internals`. Source events from `MongoQueryPayload` / `MongoVectorSearchPayload` in `trace-types.ts`.

**What it surfaces.** Memory recall surfaced wrong / no documents, the new index you just added isn't being hit, the cost dashboard shows unexpected vector-search ops, an aggregate is leaking cross-tenant data.

---

### 5. Long-term memory internals

**What's shown.** The full `memory.scoped_read` and `memory.shared_read` events with everything the hybrid retriever computed:

- Per-candidate per-leg scores (vector RRF, lexical RRF, weighted, recency-decayed, MMR-diversified)
- `perCollection` breakdown — how many hits came from `agent_memory_facts` vs `chat_messages`, and which leg won each
- Retrieval timing (per-leg ms + total)
- The LLM extractor's accepted / rejected facts on the write side (full `factCandidates[]` including the rejected ones and their `rejectReason`)
- `memory.long_term_skip` reasons (`userId_missing`, `agent_flag_off`, `mongo_unavailable`)
- Env knobs in effect at retrieval time (`MEMORY_VECTOR_TOPK`, `MEMORY_WEIGHT_FACTS`, `MEMORY_WEIGHT_CHAT_MESSAGES`, `MEMORY_MMR_LAMBDA`, etc.)
- Raw payload JSON (so you can copy-paste into a reproducer)

**Where in code.** `_dev_memory_internals`. Source: `readLongTermMemoryContext` + `writeLongTermMemory` in `long-term-memory.ts`.

**What it surfaces.** "Why did the model not remember the user's favorite color even though I told it last turn?" — this is where the answer lives. Empty candidates → embedding service down or vector index not yet queryable. Strong candidates that lost to recency → tune `MEMORY_RECENCY_HALFLIFE_DAYS`. Same fact upserted thrice → write path is missing the `factHash` dedup key.

If the harness `e2e-smoke/memory-recall-diagnostic.py` is failing scenario C/D/E/G, this sub-section is the first place to look.

---

### 6. AgentCore internals

**What's shown.** Per `agentcore.invoke` event:

- `arn` (full ARN of the runtime that was called)
- `mode` — `ec2_to_orchestrator` (typical) / `orchestrator_to_specialist` (intra-AgentCore hop) / `mcp_runtime`
- `requestBody` / `responseBody` previews (capped via the tiered truncation system — see §13)
- Request + response headers previews (`requestHeadersPreview` / `responseHeadersPreview`)
- The always-emitted `observability_link` — a click-through to the GenAI Observability "Agents" tab scoped to this specialist + this trace id

`agentcore.retry` events render in the Retries sub-section (§9), not here.

**Where in code.** `_dev_agentcore_internals`. Source: `AgentcoreInvokePayload` in `trace-types.ts`; emitted by `agentcore-runtime.ts`.

**What it surfaces.** Specialist returned an error (the full `responseBody` is here when present), the wrong runtime was invoked (mode chip + ARN), nested-trace splicing didn't fire (a `nested_events_dropped > 0` warning would render here).

---

### 6b. Multi-specialist orchestration internals

**What's shown.** Raw orchestration payloads for any orchestrator turn that ran through `runMultiSpecialistFlow(...)`. One block per event type:

- **`orchestrator.multi_route_decision`** — full classifier output: `selected[]` (with per-agent `score`, `reasoning`, `source`), `rejected[]` (with per-agent rejection reason — `"below multi-min-score"`, `"outside multi-relative-margin"`, or `"max-agents-cap"`), the live `thresholds` snapshot (`multiMinScore`, `multiRelativeMargin`, `multiMaxAgents`, `heuristicMinScore`, `heuristicMargin`), and `pathTaken: "single" | "synthesis"`. This is the source of truth for "why did the orchestrator pick these agents on this turn?"
- **`orchestrator.specialist_draft`** — one entry per specialist with `agentId`, `agentName`, `status` (`final` for fast path, `success` for synthesis path, `failed` on error, `empty` when the specialist returned no usable text), `answerByteCount`, `answerPreview` (first 512 chars, dev-mode only — stripped in `core` projection), `latencyMs`, `runtimeSpanId` (links back to the `agentcore.invoke` span), `failureMessage` and `failureStack` when present.
- **`orchestrator.synthesis`** — synthesizer agent metadata: `modelId` (effective Bedrock model id, including any `MULTI_SYNTHESIS_MODEL_ID` override), `inputSpecialists[]` (which drafts were combined), `omittedSpecialists[]` (failed/empty drafts the synthesizer mentioned only in customer-safe language), `outputByteCount`, `latencyMs`, `persistedAsFinal: true` confirming the synthesis text became the durable assistant message.

**Cross-references.** Each `orchestrator.specialist_draft.runtimeSpanId` matches an `agentcore.invoke` in §6 — click through to the corresponding card to see the full request/response body for that specialist. The synthesizer's Bedrock call appears in §5 (Model calls) tagged `agentId: "synthesizer"`, and in §1 (Identifiers) the Bedrock invocation log shows `requestMetadata.agentId = "synthesizer"` so the cost dashboard can attribute the synthesis spend separately from orchestrator routing.

**Where in code.** `_dev_orchestrator_internals` in `developer_trace_view.py`. Sources: `OrchestratorMultiRouteDecisionPayload`, `OrchestratorSpecialistDraftPayload`, `OrchestratorSynthesisPayload` in `trace-types.ts`; emitted by `multi-specialist-orchestrator.ts` and `specialist-answer-synthesizer.ts`.

**What it surfaces.** "Why did `classifyAgents` fan out to two specialists when I only asked one question?" → look at `selected[].score` vs the `thresholds.multiRelativeMargin` — if the runner-up was just inside the margin, tighten the knob. "Why did synthesis omit the second specialist?" → `omittedSpecialists[]` lists the reason. "Did the customer see the failed specialist's name?" → cross-check the `failureMessage` against the rendered final answer (the synthesizer is instructed to never expose specialist ids).

---

### 7. Tool calls (verbose)

**What's shown.** Full `tool.call` / `tool.result` pairs with raw `arguments` and `result` JSON. PII redaction is applied at emit time by `redactDeep` in the collector, with the **exempt list** (`PII_EXEMPT_FIELDS`) ensuring structural identifiers like `skill.activated.name` survive redaction.

For HTTP tools (`tool.http`): method, URL, status code, request body preview, response snippet, request headers preview (with `Authorization` redacted).

For MCP tools (`tool.mcp`): MCP server URL, tool name, raw `args`, raw `result`.

**Where in code.** `_dev_tool_calls_verbose`. The summary view (§11 in [`trace-viewer-guide.md`](trace-viewer-guide.md)) shows just tool name + duration; this is where you copy-paste the actual argument blob into your reproducer.

**What it surfaces.** Tool call failed with an unhelpful summary; the model hallucinated tool args; an HTTP tool got 401/403 (Auth header redaction does NOT hide the call itself); an MCP tool is being invoked with the wrong server URL.

---

### 8. Skill resource reads

**What's shown.** A per-skill table rolled up from `read_skill_resource` tool calls and folded into `skill.activated.resourceReads[]` by `TraceCollector.recordSkillResourceRead`. One row per file the skill pulled from `references/`, `scripts/`, or `http-tools.json`. Columns: `path`, `bytes`, `ts`, `ok`.

When a skill is activated but its `resourceReads` array is empty, the skill body alone answered the turn without needing progressive disclosure — that's the design, not a bug.

**Where in code.** `_dev_skill_resource_reads`. The buffer + rollup live in `trace-collector.ts`; the call site is `base-tools.readSkillResourceWithRegistry`.

**What it surfaces.** A skill that's looping ("let me re-read…" patterns) — you'll see the same path repeated multiple times. A skill that's pulling a file it shouldn't have access to — every read is logged with its `ok` flag.

---

### 9. Retries

**What's shown.** Interleaved `model.retry` (one row per AWS SDK v3 retry inside `BedrockRuntimeClient` — emitted by `TracingRetryStrategy` in `api/src/adapters/resolve-model.ts`) and `agentcore.retry` (one row per manual loop iteration in `agentcore-runtime.ts`). Columns:

| Column | Source |
|---|---|
| `attempt` | retry counter (1, 2, 3, …) |
| `previousErrorClass` | `ThrottlingException`, `InternalServerException`, `ModelStreamErrorException`, … |
| `backoffMs` | what the strategy chose to wait |
| `mode` (AgentCore only) | `ec2_to_orchestrator` etc. |
| `arn` (AgentCore only) | which runtime was being retried |

Empty == no retries. Three or more `ThrottlingException` retries in a single turn means your account hit a Bedrock per-region per-model TPM limit — pivot to the per-user cost dashboard (§7 of `observability-runbook.md`) to see if one user is responsible.

**Where in code.** `_dev_retries`. Strands SDK 0.7 has no native hook for AWS SDK retries (`AfterModelCallEvent.retry` is for *application*-level retries) — see `api/scripts/validate-strands-retries.ts`. We ship the SDK v3 middleware fallback (`TracingRetryStrategy`) and pin its behavior with `api/tests/unit/strands-retry-contract.test.ts` so a Strands upgrade can't silently break this column.

---

### 10. Performance

**What's shown.** A small bar chart of `cost.summary.byType` durations (which span types dominated the turn), plus the `chat.turn.end.firstTokenLatencyMs` chip, plus a `latency.checkpoint` table (one row per intermediate checkpoint emitted along the chat path: auth, prompt assembly, memory read, first model call, first delta, …).

`latency.checkpoint` events are dev-only — they're stripped from `core` mode.

**Where in code.** `_dev_performance`. Checkpoints are emitted by `chat.ts`, `run-chat-stream.ts`, and `agentcore-runtime.ts`.

**What it surfaces.** Don't read this in isolation — combine with §2 (span tree) for the call order and §4 (Mongo) / §9 (retries) for the underlying cause.

---

### 11. Cost breakdown

**What's shown.** `summary.estimatedCostUsd` plus a per-model breakdown — the same data the `<project>-cost-<env>` CloudWatch dashboard groups by `requestMetadata.userId` (see §7 of `observability-runbook.md`). If the dashboard shows a user-level cost spike and a specific turn from that user is suspicious, this sub-section confirms the per-turn token + dollar split without leaving the Trace Viewer.

**Where in code.** `_dev_cost_breakdown`. Computed by the trace collector's `costSummary()`; per-user attribution is injected by `MetadataAwareBedrockModel` in `resolve-model.ts`.

---

### 12. Environment

**What's shown.** The `dev.environment` event captured at chat-start by `TraceCollector.emitEnvironment()`:

| Field | What it is |
|---|---|
| `runtime` | `bun X.Y.Z` or `node X.Y.Z` |
| `modelBackend` | `bedrock` or `mock` (`DEV_MOCK_BACKENDS=1`) |
| `chatMode` | `live` / `stub` |
| `devMockBackends` | bool, the env knob above |
| `mongoUri` | `configured` / `missing` (presence-only — we never log the URI itself) |
| `voyageConfigured` | bool, `VOYAGE_API_KEY` presence |
| `bedrockRegion` | `AWS_REGION` / `BEDROCK_REGION` at the moment of the turn |
| `flags` | `{ TRACE_REDACT, TRACE_PROMPT_BODY, MEMORY_TRACE_VALUES, METRICS_EMITTER_ENABLED, PERSIST_CHAT_SESSIONS }` each as `"0"` / `"1"` |

Above the event payload, the `trace.release` block is rendered: `gitSha`, `bunVersion`, `nodeVersion`, `env` — populated by `chat.ts` at turn start from build metadata.

Mock-mode "chips" (`MOCK MODE`, `STUB CHAT`, …) render at the bottom when `_mock_markers(events)` finds any indicator events.

**Where in code.** `_dev_environment`. Source: `emitEnvironment` in `trace-collector.ts`.

**What it surfaces.** **The single most useful sub-section for "works on my laptop, fails in prod" bugs.** Diff this against `env | grep -E "MEMORY_|BEDROCK_|CHAT_|DEV_"` on your machine — 9 times out of 10 the answer is here.

---

### 13. Byte-cap drops

**What's shown.** Every `dev.byte_cap_hit` event with `droppedType`, `bytes`, and `reason` (`per_event` vs `per_turn`). Plus the top-level `trace.truncated` flag + `eventsDropped` count.

**Where in code.** `_dev_byte_cap`. The caps themselves live in `trace-collector.ts`:

| Env var | Default | What it caps |
|---|---|---|
| `TRACE_MAX_EVENT_BYTES` | 16 KB | A single event's payload size before it's dropped + a `dev.byte_cap_hit` (`reason: per_event`) fires |
| `TRACE_MAX_TURN_BYTES` | 2 MB (`2_097_152`) | The whole trace doc; oversized events are evicted in emission order |
| `TRUNCATION_CAP_DEBUG` | 64 KB | Field-level cap for fields tagged debug (system prompt body, raw response body) |
| `TRUNCATION_CAP_DEFAULT` | 512 chars | Field-level cap for all other text fields |

Three or more `dev.byte_cap_hit` of the same `droppedType` on a turn means a real event class is over-emitting (typically tool results with huge JSON blobs). Bumping the per-env cap is the right knob; remember to revert after the investigation.

**What it surfaces.** Trace doc is incomplete; payloads you expected to see are missing.

---

### 14. Raw events

**What's shown.** The full ordered `TraceEvent[]` JSON list with:

- **Filter** by event type (multiselect)
- **Search** by free text (substring match against `JSON.stringify(event)`)
- **Pagination** + a per-page row count input
- **Download** as JSON

Use this as the source of truth when filing bugs — paste the relevant event(s) into the ticket.

**Where in code.** `_dev_raw_events`. The list is `dev_trace.events` post-projection — same array every other `_dev_*` renderer above iterates, but here you see every field unfiltered.

---

## Lazy-loading contract — what you can rely on

Three guarantees that govern everything in the panel:

1. **Closed panel = zero work.** If you never click the toggle, the Streamlit page emits exactly one widget (the button). No fetch, no `_dev_*` evaluation, no extra payload over the wire. Pinned by `ui/tests/test_trace_view.py::test_render_developer_details_caches_dev_fetch_across_reruns`.
2. **Open panel = one fetch per `(traceId, session)`.** Subsequent Streamlit reruns (sidebar tweaks, navigation, anything that triggers a script rerun) read from `st.session_state[f"dev_trace_{traceId}"]`. Pinned by the same test.
3. **Navigating to a different trace = fresh fetch.** Cache key includes the trace id; revisiting trace A after viewing trace B serves A from the cache, but visiting C fires a new fetch. Pinned by `ui/tests/test_trace_view.py::test_render_developer_details_refetches_for_distinct_trace_ids`.

If you ever see the bordered container flicker on an unrelated sidebar change, one of those tests has regressed.

---

## Failure modes + how the panel degrades

| Symptom | Likely cause | What renders |
|---|---|---|
| The dev fetch fails entirely | Network blip / API restart mid-page | `st.warning("Developer details fetch failed: …")` + the panel falls back to rendering everything against the `core` trace already in hand. Every sentinel field renders as a "click to load N bytes" caption. |
| A sub-section says `no data recorded` | Event type wasn't emitted on this turn (no retries, no skill activations, etc.) | Empty expander body with a muted caption. **Not a bug.** |
| `OTel: no traceId on this trace` | Trace pre-dates the OTel bridge, or the OTel SDK was disabled at the moment of the turn | The deep-link buttons (ServiceLens / X-Ray) don't render; the identifier table still shows everything else. |
| A field renders as `_omittedForCoreMode` even inside the dev panel | Projection bug — `?include=dev` is identity, this should never happen | File a bug against `api/src/lib/trace-projection.ts`. |
| All sub-sections show "no data recorded" but `trace.events` is non-empty in §14 | The collector emitted events the `_dev_*` renderers don't know how to surface (typically because a new event type landed without a matching renderer) | Open `_dev_raw_events`, search for the unrendered type, then either add a sub-section or extend an existing one. |

---

## Backend contract — where each field comes from

| Field on screen | Backend producer | Test |
|---|---|---|
| `trace.otel.{traceId, rootSpanId}` | `TraceCollector.captureOtelIds()` | `api/tests/unit/trace-collector-otel.test.ts` |
| `trace.spanTree` | `TraceCollector.buildSpanTree()` | `api/tests/unit/trace-collector-spantree.test.ts` |
| `dev.environment` | `TraceCollector.emitEnvironment()` invoked at chat-start in `chat.ts` | `api/tests/unit/trace-collector-spantree.test.ts` + `verify-trace-ui-shape.py` |
| `dev.byte_cap_hit` | Per-event + per-turn caps in `trace-collector.ts` | `api/tests/unit/trace-collector-bytecap.test.ts` |
| `model.retry` | `TracingRetryStrategy` wired onto the BedrockRuntimeClient in `resolve-model.ts` | `api/tests/unit/model-retry.test.ts` + `strands-retry-contract.test.ts` |
| `agentcore.retry` | Manual retry loop in `agentcore-runtime.ts` (classified by `isRetryableAgentcoreError`) | `api/tests/unit/agentcore-retry.test.ts` |
| `mongo.vector_search.indexName` | `vectorIndexFromTransformArgs` in `mongodb-mcp-client.ts` | `api/tests/unit/vector-search-indexname.test.ts` |
| `skill.activated.resourceReads` | `TraceCollector.recordSkillResourceRead` + `toJSON()` rollup | `api/tests/unit/skill-resource-rollup.test.ts` |
| `?include=core` sentinels | `projectTraceForInclude` in `trace-projection.ts` | `api/tests/unit/trace-projection.test.ts` + integration `traces-route-include` |
| `X-Trace-Include` response header | `api/src/routes/trace.ts` | `api/tests/integration/trace-routes.integration.test.ts` |

If any of these tests start failing, the corresponding sub-section will silently miss data on a live deploy. The `e2e-smoke/verify-trace-ui-shape.py` runs against the deployed stack and asserts every one of these fields is present.

---

## Iterating on a sub-renderer — the fixture harness

The fastest dev loop for any `_dev_*` sub-renderer is **not** the live API. It's `ui/scripts/render_dev_fixture.py`, which lets you load a checked-in fixture JSON, pre-opens the dev panel, and bypasses the on-demand fetch entirely:

```bash
streamlit run ui/scripts/render_dev_fixture.py -- \
  --fixture ui/tests/fixtures/dev_trace_full_kitchen_sink.json
```

The sidebar `selectbox` lets you swap fixtures without restarting the process. Each fixture is a minimal-but-realistic trace doc that exercises one slice of the panel:

| Fixture | Sub-section under test |
|---|---|
| `dev_trace_byte_cap.json` | §13 Byte-cap drops (`dev.byte_cap_hit` + `trace.truncated`) |
| `dev_trace_environment_and_otel.json` | §1 Identifiers + OTel + §12 Environment (`dev.environment` + `trace.otel`) |
| `dev_trace_retries.json` | §9 Retries (mixed `model.retry` + `agentcore.retry`) |
| `dev_trace_skill_resource_reads.json` | §8 Skill resource reads (`skill.activated.resourceReads[]`) |
| `dev_trace_span_tree.json` | §2 Span tree (hierarchical `trace.spanTree` + duration merging) |
| `dev_trace_vector_search_indexname.json` | §4 Mongo internals (`mongo.vector_search.indexName` + `documentPreviews[]`) |
| `dev_trace_full_kitchen_sink.json` | All of the above in one trace — the "render every sub-section once" smoke |

Pair the harness with `bun test tests/unit/trace-projection.test.ts` whenever you've touched the projection rules — the fixtures are dev-mode payloads, so any over-stripping bug shows up immediately as a missing field in the rendered panel. See [`trace-ui-system-overview.md`](trace-ui-system-overview.md#5-developer-fixture-harness--uiscriptsrender_dev_fixturepy) for the harness's full internal contract.

---

## What's NOT in the Developer details panel

The panel is intentionally a **per-turn** view. Cross-turn / cross-session investigations need a different tool:

| Question | Where to look instead |
|---|---|
| "Show me every turn this user has had" | Sessions page (`/Sessions`) → click into a session |
| "How many turns timed out across all users today?" | CloudWatch Metrics → `Multiagent/Chat` namespace (EMF emitter); see `observability-runbook.md` §3 |
| "Which user is responsible for the cost spike at 2 PM?" | `<project>-cost-<env>` dashboard grouped by `requestMetadata.userId`; see `observability-runbook.md` §7 |
| "What does a healthy turn typically look like for this agent?" | No built-in surface — compare two Trace Viewer pages side-by-side, or pull both traces via `curl` and `jq` them |
| "Is the vector index being used at all?" | Cluster-wide answer is in the Atlas Search index page; per-turn answer is §4 here |
| "Was the model output safe / policy-compliant?" | Out of scope — there's no policy / safety scorer wired in; the panel only surfaces what the model returned |
| "Who looked at this trace?" | CloudWatch Logs → `filter channel = "audit" and msg = "[trace] fetch"`. The Trace Viewer doesn't show its own access log. |

If a customer asks for any of the above, do **not** try to bend the dev panel into answering it. Pivot to the right surface.

The panel also deliberately does **not**:

- Allow editing or replaying a trace (use the curl reproducer block in §1 instead — it's a copy-paste replay command).
- Render binary attachments (the API doesn't store them; redact-and-truncate happens at emit time).
- Pretty-print JSON over 64 KB inline (it stays in the raw events §14 with `st.json`'s built-in folding).

---

## Debugging the dev panel itself

When the panel renders wrong (missing field, blank expander, sentinel where there shouldn't be one), the *panel itself* is the thing under investigation. The triage order:

1. **Browser DevTools → Network tab.** Filter for `/traces/`. Confirm: status is 200, the URL ends in `?include=dev`, the response header `X-Trace-Include: dev` is set, and the JSON body has the field you expected. If `X-Trace-Include` echoes back `core`, the page sent the wrong query param (almost always means the click didn't fire — see step 3).
2. **Browser DevTools → Console tab.** The Streamlit app logs `api get_trace include mismatch` here when the response header doesn't match the request. That message means the API container is older than the UI.
3. **Streamlit's "View source" widget (`?embed=true&embedOptions=light_theme`)** plus `st.session_state` inspection. Add this line near the panel in `developer_trace_view.py` while reproducing:

   ```python
   st.write({k: v for k, v in st.session_state.items() if k.startswith("dev_")})
   ```

   Then check that `dev_open_<traceId>` is `True` and `dev_trace_<traceId>` is the parsed dict. If `dev_open` is True but `dev_trace` is missing, the on-demand fetch failed silently — check the API logs for the `requestId` of the failed `GET /traces/<id>?include=dev`.
4. **The fixture harness** (above) is the single fastest reproducer once you know which sub-section is wrong. Pick the fixture, edit `developer_trace_view.py`, save, Streamlit auto-reloads.
5. **The unit tests** at `ui/tests/test_trace_view.py` — every sub-section has a `test_dev_*` that asserts what it renders. If your fix passes locally but the test still fails, the test is your spec.

Common gotcha: `_StreamlitRecorder` (the test mock) needs an explicit method for any new Streamlit primitive you use. If you reach for `st.toast` or `st.bar_chart` and the test errors with `AttributeError: '_StreamlitRecorder' object has no attribute …`, add the mock first, then the renderer.

---

## Mobile / smaller screens

The Developer details panel is **desktop-only by design**. The Mongo pipeline tables, span-tree indented rows, `latency.checkpoint` table, and per-leg memory-retrieval breakdowns are wide and will overflow horizontally on a phone or narrow tablet. Pinch-to-zoom is your only escape, and `st.json` collapses to a tiny block on small viewports.

If you need to debug from a phone:

- Pull the JSON directly: `curl …?include=dev | jq` from a desktop shell over SSH.
- Open the raw events sub-section (§14) and use its built-in JSON folding — it's the most mobile-friendly part of the panel.
- For OTel cross-correlation, the ServiceLens / X-Ray AWS console deep-links in §1 do render usable on mobile.

See [`trace-ui-system-overview.md`](trace-ui-system-overview.md#mobile--responsive-posture) for the full mobile posture matrix across all six trace surfaces.

---

## Pre-merge / pre-deploy sanity checks

- **After every API redeploy:** run `e2e-smoke/verify-trace-ui-shape.py` to confirm `trace.otel`, `trace.spanTree`, `dev.environment`, `mongo.vector_search.indexName`, and the `?include=core|dev|full` round-trip projection all still match the contract.
- **After a Strands SDK upgrade:** run `bun run validate:strands-retries` (the upgrade alarm). The retry path is the one piece of the dev panel most likely to silently break on an SDK bump.
- **When a developer reports "the dev panel is missing X":** first check `release.gitSha` in §1 against the API container's commit. Pre-debug-grade traces won't have the field.

---

## Related docs

- [`trace-ui-system-overview.md`](trace-ui-system-overview.md) — **start here** — all six trace surfaces in one place (inline card, viewer, sessions, fixture harness, print, mobile)
- [`trace-viewer-guide.md`](trace-viewer-guide.md) — the default summary view (tiles, narrative, Mongo dashboard, etc.)
- [`observability-runbook.md`](observability-runbook.md) §1.b — Day-2 "debug a single turn" walkthrough including all 14 sub-sections (this guide is the catalog; the runbook is the workflow)
- [`api-reference.md`](api-reference.md) `GET /traces/:traceId?include=` — wire-level contract for the projection
- [`logging-architecture.md`](logging-architecture.md) — how `trace.otel` connects to CloudWatch / X-Ray
- [`memory-architecture.md`](memory-architecture.md) — full long-term memory design (§5 here is the per-turn view of what's globally documented there)
- `api/src/lib/trace-types.ts` — the source of truth for every event payload shape
- `api/src/lib/trace-collector.ts` — emit-time logic (redaction, byte caps, span tree, OTel bridge)
- `api/src/lib/trace-projection.ts` — read-time projection (`core` vs `dev` vs `full`)
