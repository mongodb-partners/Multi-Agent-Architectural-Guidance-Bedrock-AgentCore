# Observability runbook

> **Audience:** on-call engineers, SREs, security reviewers. Companion to [`docs/logging-architecture.md`](logging-architecture.md), which is the design doc — this file is the day-2 ops doc.
>
> **TL;DR.** Every chat turn is observable end-to-end via three surfaces: **CloudWatch GenAI Observability** (managed AgentCore + Model Invocations dashboards), **Transaction Search** (`aws/spans` — searchable OTLP spans), and the custom fleet dashboards under the `<project>-{fleet,mongo,cost}-<env>` names. Use this file to find traces, read the right log group for the symptom you have, manage PII, tune sampling, add alarms, and recover from common failure modes.
>
> **Dashboard reference (with screenshots):** [`docs/dashboards/README.md`](dashboards/README.md)

---

## 1. Finding a trace

You almost always start from one of:

- **A failed UI chat session.** Open the Streamlit chat page footer — `last_x_trace_id` is the W3C trace id of the most recent turn. Copy it.
- **A user complaint with a `requestId`.** That `req_*` id is in every JSON log line of the turn, so:
  ```text
  fields @timestamp, trace_id, msg
  | filter requestId = "req_abc123def-456"
  | sort @timestamp asc
  | limit 1
  ```
  The first hit's `trace_id` is your trace.
- **An alarm SNS notification.** The dashboard widget the alarm fires on includes a "View related traces" link.

With a trace id in hand:

| Surface | URL pattern |
|---|---|
| CloudWatch X-Ray trace map | `https://<region>.console.aws.amazon.com/cloudwatch/home?region=<region>#xray:traces/<trace_id>` |
| Logs Insights — API | run the query below against `/<SHARED_RESOURCE_PREFIX>/<env>/api` (where `SHARED_RESOURCE_PREFIX` defaults to `multiagent`) |
| Logs Insights — `aws/spans` | run the query below against `aws/spans` |
| GenAI Observability Agents tab | `https://<region>.console.aws.amazon.com/cloudwatch/home?region=<region>#gen-ai-observability:agent-core` then filter by `trace_id` |
| Streamlit Trace Viewer (in-product) | `https://<ui-host>/Trace_Viewer?traceId=<UUID>` — click **"Show developer details"** to lazy-load the `?include=dev` projection. The Identifiers sub-section there has one-click ServiceLens / X-Ray deep links built from `trace.otel.{traceId, rootSpanId}` so you can skip the URL pattern above. |

The Trace Viewer's two-tier fetch (`?include=core` default → `?include=dev` on toggle) is logged in the audit channel — filter `channel = "audit" and msg = "[trace] fetch" and userId = "<sub>"` to see exactly when a developer expanded dev-grade detail for a given trace.

Standard "everything on this trace" query:

```text
fields @timestamp, msg, level, agent_id, span_id, requestId
| filter trace_id = "<TRACE_ID>"
| sort @timestamp asc
| limit 200
```

---

## 1b. Day-2: debug a single turn from the Trace Viewer

Once you have a `traceId` (see §1) and a URL like `https://<ui-host>/Trace_Viewer?traceId=<UUID>`, the **Streamlit Trace Viewer** is the single console where you can answer almost every "what happened on this turn?" question without leaving the browser.

The page loads `?include=core` by default — a summary-safe view (no system-prompt bodies, no raw tool args, no per-vector-leg internals). Click **"Show developer details"** to lazy-load the `?include=dev` projection (cached in `st.session_state[f"dev_trace_{traceId}"]` for the lifetime of the page; the cache survives every sidebar/control rerun, but **not** navigation to a different `traceId` — see `ui/tests/test_trace_view.py::test_render_developer_details_caches_dev_fetch_across_reruns`). Each access is recorded in the audit channel as `[trace] fetch include=dev userId=<sub>` so you can later grep who looked at what.

The bordered "Developer details" container then shows thirteen sub-sections in a fixed order. Read them top-down — each answers one specific debug question:

### 1.b.1 Identifiers — "Which trace, which user, which request?"

Surfaces `traceId`, `messageId`, `sessionId`, `userId`, `agentId`, `release.gitSha`, `correlation.requestId`, and a pair of one-click links built from `trace.otel`:

- **Open in CloudWatch ServiceLens** → `https://<region>.console.aws.amazon.com/cloudwatch/home?region=<region>#servicelens:service-map/?trace=<traceId>`
- **Open in X-Ray Trace Map** → `…#xray:traces/<traceId>`

If `trace.otel` is missing (older traces, traces emitted while the OTel SDK was disabled), the deep-link section shows `no data recorded` — not a bug, just a pre-OTel-bridge turn.

**Common failure modes:**

- `userId` is blank → JWT was anonymous or auth was bypassed; check `/<SHARED_RESOURCE_PREFIX>/<env>/api` for `auth.bypass.unauthenticated` lines on that requestId.
- `release.gitSha` doesn't match `git rev-parse HEAD` on the EC2 host → API has not been redeployed since the last code change; rerun `./deploy/deploy-api.sh`.

### 1.b.2 Span tree — "What happened, in what order?"

Indented tree built from `trace.spanTree` (precomputed server-side by `TraceCollector.buildSpanTree()`). Falls back to a parent-id recompute when older traces have no `spanTree` field. Each node shows `type` (or `name` for legacy nodes), duration, and `agentId`.

Look here first when the question is "why was this turn slow?" — the longest-duration child is your culprit. Drill into the matching sub-section below for the payload (Mongo / Model / AgentCore / etc.).

### 1.b.3 Prompt & model I/O — "What did the model actually see / say?"

The full assembled system prompt body (the same one that hit Bedrock), the seeded prior turns (`model.request.messagesSeed`), the assistant response, and (when present) the raw `model.response.body` preview. Honors the `?include=dev` `_omittedForCoreMode` sentinel — if you see `[omitted in core mode]`, the projection accidentally over-stripped; file a bug against `api/src/lib/trace-projection.ts`.

**Use this when:** the model produced an unexpected refusal, hallucinated a tool call, or ignored a memory hint. Cross-reference with `model.request.systemPromptHash` — two turns with the same hash always saw the same system prompt.

### 1.b.4 Mongo internals — "Which collection, which index, which docs?"

Per `mongo.query` and `mongo.vector_search` event: `collection`, `operation`, the actual `pipeline` (JSON), `documentCount`, `documentPreviews[]` (the field surfaced as hover-tooltip in the summary view), `scoping` (`user_scoped` vs `missing_user_filter`), and crucially **`indexName`** — the actual `$vectorSearch.index` / `$search.index` operand the MongoDB MCP client expanded. `missing_user_filter` rows render with the `.trace-chip.danger` red chip; an `index` of `default` on a vector search is almost always the bug ("you forgot to set `index:` in the pipeline and Atlas silently lexical-scanned").

**Use this when:** memory recall surfaced wrong / no documents, the new index you just added isn't being hit, or the cost dashboard shows unexpected vector-search ops.

### 1.b.5 Long-term memory internals — "Why did / didn't recall fire?"

Mirrors the `memory.scoped_read` event in full: candidates with per-leg RRF / weighted / recency / MMR scores, per-collection breakdown, the LLM extractor's accepted / rejected facts on the write side, and `memory.long_term_skip` reasons (e.g. `userId_missing`, `agent_flag_off`, `mongo_unavailable`). The `e2e-smoke/memory-recall-diagnostic.py` harness maps each observation to one of the seven labeled hypotheses (`H1`–`H7`); if you see scenario C / D failing here, the harness is the next thing to run on the same EC2 host.

### 1.b.6 AgentCore internals — "What did the runtime actually return?"

The full `AgentcoreInvokePayload` per invocation: `arn`, `mode` (`ec2_to_orchestrator` etc.), request/response body previews (capped via the tiered truncation system — see §1.b.13), response headers, and the always-emitted `observability_link` so you can pivot straight to the GenAI Observability "Agents" tab. The `agentcore.retry` event is rendered in the Retries sub-section, not here.

### 1.b.7 Tool calls (verbose) — "What args, what result, what error?"

Full `tool.call` / `tool.result` pairs with raw `arguments` and `result` JSON (after PII redaction, which exempts structural identifiers like `skill.activated.name` — see `PII_EXEMPT_FIELDS` in `api/src/lib/trace-collector.ts`). The summary view shows just the tool name + duration; this is where you copy-paste the actual argument blob into your reproducer.

### 1.b.8 Skill resource reads — "Which `references/`, `scripts/`, or `http-tools.json` did each skill pull?"

Per-skill table rolled up from `read_skill_resource` tool calls and folded into `skill.activated.resourceReads` by `TraceCollector.recordSkillResourceRead`. If a skill is activated but its `resourceReads` is empty, the skill body itself answered the turn without needing progressive disclosure — that's the design, not a bug. If it's full of repeats of the same path, the agent looped on a single reference; check the model output for "let me re-read…" patterns.

### 1.b.9 Retries — "Did Bedrock or AgentCore have to retry?"

Interleaved `model.retry` (one row per AWS SDK v3 retry inside `BedrockRuntimeClient` — emitted by `TracingRetryStrategy` in `api/src/adapters/resolve-model.ts`) and `agentcore.retry` (one row per manual loop iteration in `agentcore-runtime.ts`). Columns: `attempt`, `previousErrorClass` (`ThrottlingException`, `InternalServerException`, …), `backoffMs`, and for AgentCore `mode` + `arn`. Empty == no retries.

If you see ≥3 `ThrottlingException` retries in a single turn, your account hit a Bedrock per-region per-model TPM limit — open the **Per-user cost dashboard** (§7) to see if a single user is responsible.

### 1.b.10 Performance — "Where did the seconds go?"

Bar chart of `cost.summary.byType` durations, plus the `chat.turn.end.firstTokenLatencyMs` chip. Don't read this in isolation — combine with §1.b.2 (span tree) for the call order and §1.b.4 (Mongo) / §1.b.9 (retries) for the underlying cause.

### 1.b.11 Cost breakdown — "Tokens in / tokens out / dollars."

Same data the `<project>-cost-<env>` CloudWatch dashboard groups by `requestMetadata.userId` (see §7). If the dashboard shows a user-level cost spike and a specific turn from that user is suspicious, this section confirms the per-turn token count without leaving the Trace Viewer.

### 1.b.12 Environment — "Which feature flags were active when this turn ran?"

The `dev.environment` event captured at chat-start by `emitEnvironment()`: `chatMode` (`live` / `stub`), `DEV_MOCK_BACKENDS`, `MEMORY_*` knobs (`MEMORY_VECTOR_TOPK`, `MEMORY_WEIGHT_FACTS`, etc.), `BEDROCK_MAX_ATTEMPTS`, OTel exporter URL, and the AgentCore runtime/agent ARNs. **If a turn behaves differently from what you reproduced locally, diff this section against `env | grep -E "MEMORY_|BEDROCK_|CHAT_|DEV_"` on your laptop — 9 times out of 10 the answer is here.**

### 1.b.13 Byte-cap hits — "Did the collector drop any events on the floor?"

Lists every `dev.byte_cap_hit` event with `droppedType`, `bytes`, and `reason` (`per_event` vs `per_turn`). When this is non-empty, the trace document is incomplete — the full payloads were silently dropped to stay under `TRACE_MAX_EVENT_BYTES` (default 16 KB) / `TRACE_MAX_TURN_BYTES` (default 2 MB / `2_097_152`). Override per-environment via the matching env vars when investigating a turn with truncated payloads; remember to revert after.

### 1.b.14 Raw events — "Give me the JSON, I'll grep myself."

The full ordered event list as structured JSON, last so it never crowds the synthesized views above. Searchable via the multiselect / text-input filters at the top of the sub-section. Use this as the source of truth when filing bugs — paste the relevant event into the ticket.

### Pre-merge / pre-deploy sanity checks

- `e2e-smoke/verify-trace-ui-shape.py` is the live-stack analogue of the unit tests. After every API redeploy, run it to confirm `trace.otel`, `trace.spanTree`, `dev.environment`, `mongo.vector_search.indexName`, and the `?include=core|dev|full` round-trip projection all still match the contract.
- If a developer reports "the dev panel is missing X", first ask whether X is gated on a newer collector — check `release.gitSha` in §1.b.1 against the API container's commit; pre-debug-grade traces won't have the field.

---

## 2. Log group cheat-sheet

| Symptom | Read this group first |
|---|---|
| Chat turn errored before any tool call | `/<SHARED_RESOURCE_PREFIX>/<env>/api` |
| Chat turn looked fine in API but the model said "I cannot…" | `/aws/bedrock/invocations` (errors + stop reason) |
| AgentCore Runtime invocation failed | `/<SHARED_RESOURCE_PREFIX>/<env>/api` (look for `[agentcore-runtime] InvokeAgentRuntime failed`), then `/aws/vendedlogs/bedrock-agentcore/runtime/APPLICATION_LOGS/<runtime-id>` for runtime-side stack (matches API `trace_id`) |
| Memory write / read seems wrong | `/aws/vendedlogs/bedrock-agentcore/memory/APPLICATION_LOGS/<id>` |
| Gateway tool call returned 401 / 403 | `/aws/vendedlogs/bedrock-agentcore/gateway/APPLICATION_LOGS/<id>` |
| MongoDB MCP tool call timed out / errored | `/aws/vendedlogs/bedrock-agentcore/runtime/APPLICATION_LOGS/<mongodb_mcp_runtime_id>` |
| Span shows up in X-Ray but no JSON log lines | `/<SHARED_RESOURCE_PREFIX>/<env>/otel` — the OTLP-logs path may have emitted them |
| PII detection alarm fired | `/aws/bedrock/invocations` filtered by `{ $.eventType = "DataMaskingFinding" }` |
| Streamlit UI itself crashed | `/<SHARED_RESOURCE_PREFIX>/<env>/ui` |
| Atlas connection saturation alarm | dashboard `<project>-atlas-<env>` widgets |

---

## 3. Flipping prompt-body logging on

**Default posture:** OFF (`log_prompt_bodies = false`, `log_embedding_bodies = false`). Bodies are not delivered to CloudWatch.

**Checklist before turning on:**

1. **Security sign-off.** Body logging captures user input + model output verbatim. Even with the Data Protection Policy masking PII, this raises the audit scope of `/aws/bedrock/invocations`.
2. **Confirm Data Protection Policy is in effect.** `aws logs get-data-protection-policy --log-group-name /aws/bedrock/invocations` must return a policy with `Audit` + `Deidentify` operations.
3. **Pick a scope.** Per-env (`TF_VAR_log_prompt_bodies=true` in dev only) is the typical first step.
4. **Apply.**
   ```bash
   cd deploy/terraform/envs/ec2
   TF_VAR_log_prompt_bodies=true terraform apply
   ```
5. **Verify masking.** Send a chat turn containing a fake email (`alex@example.com`) and a phone number. After 1–2 minutes, query `/aws/bedrock/invocations`:
   ```text
   fields @timestamp, modelId, input, output
   | sort @timestamp desc
   | limit 10
   ```
   `input.text` should show `{EmailAddress}` and `{PhoneNumber}` rather than the raw values.
6. **Schedule a re-disable date.** Body logging is meant for time-boxed incident investigation, not a permanent posture. Add a calendar entry to flip it off.

To disable: re-run with `TF_VAR_log_prompt_bodies=false` (or remove the override).

---

## 4. Tuning trace sampling

Two layers control how much data lands in CloudWatch:

| Layer | Controls | Default | Where |
|---|---|---|---|
| **OTel SDK sampler** | Whether the app *exports* a span at all. `parentbased_traceidratio` + `OTEL_TRACES_SAMPLER_ARG` (0..1). | 1.0 (export everything) | `OTEL_TRACES_SAMPLER` / `OTEL_TRACES_SAMPLER_ARG` env vars, set by `deploy-project.sh` via `OTEL_SAMPLE_RATIO`. |
| **X-Ray Transaction Search indexing** | What fraction of received spans get an *indexed trace summary*. Underlying spans always land in `aws/spans` regardless. | 100% | `var.span_sampling_percent` in `envs/ec2`, applied via `modules/cloudwatch-genai`. |

**Recommendations:**

- **Dev / staging:** keep both at defaults (everything indexed). Cheap and high signal.
- **Low-volume prod (<1 RPS):** keep both at defaults; cost is negligible.
- **Mid-volume prod (1–10 RPS):** set `span_sampling_percent = 50` and keep export at 1.0. You still keep every span body for ad-hoc Logs Insights, but only half become indexed.
- **High-volume prod (>10 RPS):** drop export sampling first (`OTEL_SAMPLE_RATIO=0.2`), keep `span_sampling_percent = 100` so the spans you DO export are all indexed. This makes the most cost-effective use of the indexing budget.

**Always-sample errors** (recommended override): set `OTEL_TRACES_SAMPLER=parentbased_jaeger_remote` or implement a custom rules-based sampler that always keeps error traces. Out of scope for the default install but the seam is there.

---

## 5. Authoring a new alarm

1. Identify the metric. CloudWatch metric (e.g. `AWS/Bedrock`), log-derived (add a metric filter via `aws_cloudwatch_log_metric_filter`), or math expression (combine others).
2. Pick a threshold + window. Default convention: 5-minute periods, "2 of 3" for noisy metrics, "1 of 1" for clear-signal metrics (data-protection findings, AgentCore errors).
3. Add it to [`modules/cloudwatch-fleet-dashboards/main.tf`](../deploy/terraform/modules/cloudwatch-fleet-dashboards/main.tf) under the existing `aws_cloudwatch_metric_alarm` block — keep alarms in that one module so the SNS routing wiring is consistent.
4. `alarm_actions = [aws_sns_topic.alarms.arn]` + `ok_actions` (so the topic sees recoveries, not just incidents).
5. Add a paragraph to **§7 of this runbook** describing what the alarm means and the first three things on-call should do.

---

## 6. SNS subscription management

The fleet alarms SNS topic is `${project}-fleet-alarms-${environment}`. Subscribers added via:

- `var.alarm_email = "oncall@example.com"` — single email subscriber, defaults off.
- `var.sns_extra_subscriptions = [{ protocol = "https", endpoint = "https://hooks.slack.com/..." }, ...]` — webhooks, lambdas, additional emails.

To add Slack:

```hcl
sns_extra_subscriptions = [
  { protocol = "https", endpoint = "https://hooks.slack.com/services/T.../B.../...." },
]
```

To add PagerDuty: use PagerDuty's CloudWatch integration, which gives you an `https://events.pagerduty.com/integration/...` endpoint that goes into the same list.

Always subscribe a human inbox first and watch for a week before adding bot endpoints.

---

## 7. Per-user cost dashboard

The `<project>-cost-<env>` dashboard's top widget groups `InputTokenCount` + `OutputTokenCount` by `requestMetadata.userId`. Requirements:

1. `var.enable_bedrock_invocation_logging = true` (Phase 1) so `/aws/bedrock/invocations` exists.
2. `MetadataAwareBedrockModel` wrapper instantiating on every model resolution (Phase 3 — default-on).
3. The user's request reached the API with a JWT (so `currentTrace().userId` is populated).

If the widget is empty for a known-active user, run the corresponding query directly:

```text
fields @timestamp, modelId, requestMetadata.userId as userId, requestMetadata.agentId as agentId, input.inputTokenCount, output.outputTokenCount
| filter userId = "<sub-from-JWT>"
| stats sum(input.inputTokenCount) as inputTokens, sum(output.outputTokenCount) as outputTokens by modelId
| sort inputTokens desc
```

If `userId` is empty in the results, the wrapper isn't injecting `requestMetadata`. Most common cause: a code path bypasses `resolveModel(...)` and instantiates `BedrockModel` directly. Fix by routing through `resolveModel`.

---

## 8. Atlas anomalies (Phase 4)

The Atlas dashboard (`<project>-atlas-<env>`) renders five widgets fed by the ADOT collector's Prometheus scrape into the `MongoDB/Atlas` CloudWatch namespace. The two associated alarms (`atlas-connection-saturation`, `atlas-replication-lag`) route through the same SNS topic as the fleet alarms.

**Enable the scrape:** set `enable_atlas_metrics = true` plus `atlas_prom_username` / `atlas_prom_password` / `atlas_prom_host` in `envs/ec2/terraform.tfvars` (credentials come from the Atlas UI: **Project → Integrations → Prometheus** → generate API key with *Project Read Only*). `terraform apply` creates the Secrets Manager entry, re-renders the collector config, and the sidecar restarts via the `adot_config_etag` user-data hash.

**If a widget is permanently empty,** check (in order):

1. `systemctl status aws-otel-collector` on the EC2 host.
2. `aws secretsmanager get-secret-value --secret-id "${project}-atlas-prometheus-${env}"` returns JSON with `username` / `password` / `host`.
3. The collector log `/var/log/aws-otel-collector.log` for `prometheus` scrape errors (401 = wrong creds; connection refused = wrong host; empty = scrape working but the metric isn't published — confirm in the Atlas Prometheus UI).
4. The Atlas API key still has *Project Read Only* + Prometheus integration enabled.
5. CloudWatch namespace populated: `aws cloudwatch list-metrics --namespace MongoDB/Atlas | head` — empty means the awsemf exporter never received data.

---

## 9. Atlas anomalies — detailed playbook

### 9.1 Connection saturation (`atlas-connection-saturation`)

**Alarm fires when** `100 * mongodbatlas_connections_current / mongodbatlas_connections_available > 80` for 2 consecutive 5-minute windows.

**Most common root causes:**

1. **Connection leak in the app** — a recently-deployed change creates `MongoClient` without `await client.close()`. Spot it by counting active streams in `/<SHARED_RESOURCE_PREFIX>/<env>/api` against connection counts on the dashboard; if app load is flat but connections climb, it's a leak.
2. **Spiky workload outgrowing the pool** — `MongoClient` default `maxPoolSize` is 100; the API uses one client process-wide. Check the chat-turn rate on the fleet dashboard. If it's sustained > 50 RPS, raise `maxPoolSize` or shard load across multiple API instances.
3. **Atlas tier ceiling** — M10 caps at 1500 connections, M20 at 3000, M30 at 4000 (as of 2026-05). If `mongodbatlas_connections_available` itself is the limiting factor, upgrade the cluster tier.

**Immediate mitigation:** if it's mid-incident, rolling-restart the API container (`systemctl restart multiagent-api`) — Mongo connections close cleanly on TCP close and rebuild lazily. This buys ~30 minutes to debug.

### 9.2 Replication lag (`atlas-replication-lag`)

**Alarm fires when** `max(mongodbatlas_replset_oplog_master_lag_ms) > var.atlas_replication_lag_threshold_ms` (default 5 000 ms) for 2 of 3 5-minute windows.

**Most common root causes:**

1. **Write spike** — a backfill or seed job is writing faster than secondaries can apply. Check Mongo dashboard `QueryCount` / opcounters; if `insert` and `update` are 10× normal, the spike is in-app. Throttle the writer.
2. **Atlas maintenance / failover** — Atlas runs occasional secondary restarts. The lag spikes briefly then recovers within a few minutes. If the duration > 10 minutes, escalate to Atlas support.
3. **Slow secondary node** — one node is under-provisioned or networked-stressed (e.g. cross-AZ replication during a regional event). Atlas auto-recovers by promoting a healthy secondary, but the alarm catches it before that.

**Immediate mitigation:** if a backfill is causing it, pause the backfill. If it's Atlas-side, watch for auto-recovery and only escalate after 15 minutes of sustained breach.

### 9.3 Vector-search latency anomalies (no alarm; dashboard-only)

The `<project>-atlas-<env>` widget for `mongodbatlas_search_index_query_latency_ms` p95/p99 spikes warn of slow vector queries. Common causes:

1. **Cold cache after a deploy** — first 5 minutes after a `seed-indexes.ts` run repopulates the index. Wait it out; p99 should settle within 10 minutes.
2. **Index rebuild in flight** — Atlas Search rebuilds happen when the index spec changes. The `bun db-seeding/seed-indexes.ts` script logs every change; correlate with deploy timestamps.
3. **Hot collection without an index** — a new agent or skill is calling `mongo.vector_search` against a collection that doesn't have a vector index. Confirm by reading the Mongo Insights query for the offending `mongo.vector_search` event and cross-referencing `seed-indexes.ts`.

**Immediate mitigation:** there's no auto-recovery — the index has to finish rebuilding, or you need to add the missing index. The cost-dashboard impact is bounded because vector search timeouts hit at `MEMORY_SEARCH_MAX_TIME_MS` (default 8 s) and fall back to BM25.

---

## 9b. One-time CloudWatch Transaction Search enablement (admin)

**Why this is manual.** Transaction Search is an **account-wide singleton** and the API calls (`xray:UpdateTraceSegmentDestination`, `xray:UpdateIndexingRule`) typically belong to an account admin, not a deploy-user. Terraform exposes this as `enable_transaction_search_toggle = false` by default so least-privileged deploy users don't bounce on `AccessDeniedException`. Without this toggle the `aws/spans` log group is never created, the `aws_cloudwatch_log_group.spans` resource cannot work around it (AWS reserves the `aws/` namespace), and the GenAI Observability **Application Signals → Transaction Search** tab stays empty.

**Console steps (5 minutes, do once per AWS account+region):**

1. Open **CloudWatch → Application Signals → Transaction Search** in the target region.
2. Click **Enable Transaction Search** (or **Manage** if it shows "Disabled").
3. Set **Indexed spans percentage** to the value matching `var.span_sampling_percent` (default `100` — every span indexed; drop to `10` or lower for prod cost control, see §4).
4. Confirm. CloudWatch auto-creates the `aws/spans` log group (you cannot create it yourself — the `aws/` prefix is reserved).

**Or, if you have the perms, single-shot CLI (same effect):**
```bash
aws xray update-trace-segment-destination --destination CloudWatchLogs
aws xray update-indexing-rule --name Default \
  --rule "Probabilistic={DesiredSamplingPercentage=100}"   # match var.span_sampling_percent
```

**Re-enabling Terraform automation later:** when an admin grants the deploy user `xray:UpdateTraceSegmentDestination` + `xray:UpdateIndexingRule`, set `TF_VAR_enable_transaction_search_toggle=true` and re-apply. The module will idempotently re-assert the destination + sampling percentage on every apply, so re-tuning is just a tfvars change.

---

## 10. Custom metrics (EMF) — `Multiagent/Chat`, `Multiagent/Mongo`, `Multiagent/Memory`

Every fleet/Mongo dashboard widget and every Phase 3 alarm reads CloudWatch **custom metrics** in those three namespaces. They are emitted by [`api/src/lib/cw-metrics.ts`](../api/src/lib/cw-metrics.ts) as stdout EMF (Embedded Metric Format) lines that ride the same `/var/log/multiagent-api.log` path as everything else.

| Symptom | Likely cause | Fix |
|---|---|---|
| Fleet dashboard p50 / p99 / turns widgets show "No data" | API didn't restart on the last deploy, OR `METRICS_EMITTER_ENABLED=0` was set as an env override | `./deploy/deploy-api.sh`, then grep `/aws/multiagent-api` for `_aws.CloudWatchMetrics` records — they should appear within 30 s of the next chat turn. |
| Only `AgentCoreInvokes` is empty | EC2-to-orchestrator hop bypassed (e.g. dev-mock chat mode) | Confirm `CHAT_MODE=live` and that AgentCore Runtime is actually invoked. The metric is only emitted from `adapters/agentcore-runtime.ts`. |
| Only `VectorSearchLatencyMs` is empty | No agent with `memory.longTerm: true` has been queried | Run a turn against an agent that uses Mongo vector search (e.g. `troubleshooting` or any `memory.longTerm: true` agent). |
| P99-latency alarm is `INSUFFICIENT_DATA` for >15 min | Same as above, OR all three (Sum) data points are zero — CloudWatch needs ≥1 datapoint per evaluation window | Drive at least one chat turn per 5 min into the env (synthetic probe), OR lower `evaluation_periods` on the alarm. |
| A new metric isn't being plotted | Forgot to update the dashboard JSON template AND the alarm `metric_query` block | Edit `modules/cloudwatch-fleet-dashboards/{templates/*,main.tf}` together. The lock-down test `bun test tests/unit/cw-metrics.test.ts` only locks the **emitter**; it cannot detect downstream typos. |

To verify the emitter is healthy in 30 seconds:
```text
SOURCE '/<SHARED_RESOURCE_PREFIX>/<env>/api'
| filter ispresent(`_aws.CloudWatchMetrics.0.Namespace`)
| stats count() by `_aws.CloudWatchMetrics.0.Namespace`
| sort count desc
```
Expected output: three rows (`Multiagent/Chat`, `Multiagent/Mongo`, `Multiagent/Memory`) with non-zero counts. Zero rows ⇒ emitter disabled / wrong code on the box.

To disable in an emergency (e.g. CloudWatch log-cost spike during a stampede): set `METRICS_EMITTER_ENABLED=0` in `/opt/multiagent/.env.live` on the EC2 host and `sudo systemctl restart multiagent-api`. Dashboards lose data immediately; alarms move to `INSUFFICIENT_DATA` within the configured evaluation window. Re-enable by removing the line and restarting.

---

## 11. Emergency knobs

| Situation | Knob | Effect |
|---|---|---|
| Cost runaway / log volume spike | `var.span_sampling_percent = 1` | Drops indexed-span volume 100× without code change; underlying spans still land in `aws/spans`. |
| PII leaking despite Data Protection Policy | `var.log_prompt_bodies = false` | Stops body delivery to CloudWatch entirely. |
| ADOT sidecar crashing | `var.enable_adot_collector = false` | Removes the sidecar; app falls back to in-process tracing only. Logs unaffected. |
| Per-user cost wrong / leaks | comment-out `MetadataAwareBedrockModel.stream override` in `api/src/adapters/resolve-model.ts`, redeploy API. | Stops metadata injection. Dashboard widget loses per-user breakdown but Bedrock invocation logging keeps working. |
| Alarm flapping | Bump the threshold in `var.{p99_latency_threshold_ms,error_rate_threshold_pct,throttle_burst_threshold}` and re-apply, OR temporarily set `treat_missing_data = "ignore"` in the alarm. Open a ticket to fix the underlying noise. |
| Need to fully disable observability stack | `enable_genai_observability=false`, `enable_bedrock_invocation_logging=false`, `enable_adot_collector=false`, `enable_fleet_dashboards=false`, `enable_atlas_metrics=false` | Tears down the stack but keeps existing log groups (CloudWatch destroy-protected). |

---

## 12. Recurring quick references

### "Show me the last 50 errors across the fleet"
```text
SOURCE '/<SHARED_RESOURCE_PREFIX>/<env>/api' | fields @timestamp, level, msg, error_class, error_message, trace_id
| filter level = "error"
| sort @timestamp desc
| limit 50
```

### "Show me chat turns over 5s"
```text
SOURCE '/<SHARED_RESOURCE_PREFIX>/<env>/api' | fields @timestamp, agent_id, session_id, latency_ms, trace_id
| filter ispresent(latency_ms) and latency_ms > 5000
| sort latency_ms desc
| limit 25
```

### "Show me PII audit findings in the last hour"
```text
SOURCE '/aws/bedrock/invocations' | fields @timestamp, eventType, dataIdentifier
| filter eventType = "DataMaskingFinding"
| stats count() by dataIdentifier
```

### "Show me model throttles per model id"
```text
SOURCE '/aws/bedrock/invocations' | fields @timestamp, modelId, errorCode
| filter errorCode = "ThrottlingException"
| stats count() by modelId
```

### "Show me top users by turn count (last 24h)"
```text
SOURCE '/<SHARED_RESOURCE_PREFIX>/<env>/api' | fields @timestamp, user_id
| filter msg = "chat.turn.end"
| stats count() as turns by user_id
| sort turns desc
| limit 25
```

---

## 16. Bedrock KB peering: IP drift recovery (peering mode only)

Applies only when `NETWORK_MODE=peering` and `TF_VAR_enable_kb_peering=true` (the default for peering deploys). The `modules/bedrock-kb-peering` NLB targets are pinned at deploy time by running `dig +short` against the Atlas SRV from the EC2 host (via SSM `send-command`). Atlas maintenance, scaling, or failover can rotate mongod private peering IPs and silently break KB ingestion — the NLB will start health-checking dead IPs and Bedrock KB ingestion jobs will fail to connect.

**Symptom:** `bedrock-agent get-ingestion-job` returns `FAILED` with a connection / timeout reason; CloudWatch NLB target health for the peering target group shows targets in `unhealthy`.

**Quick check from EC2:**

```bash
# Get the current Atlas mongod private IPs from inside the peered VPC
aws ssm start-session --target $(terraform output -raw ec2_instance_id) \
  --region $AWS_REGION
# inside the session:
dig +short <cluster>-pri.mongodb.net | sort
# compare against the targets registered on the peering NLB target group
```

**Recovery:** re-run the orchestrator with `--skip-network --skip-shared` to keep network + shared stacks untouched but re-run `envs/ec2` (which re-`dig`s and re-pins NLB targets via the `null_resource.discover_ips` trigger keyed off `sha1(atlas_connection_string)`):

```bash
./deploy/deploy-full-with-vpc-peering.sh --auto-approve --skip-network --skip-shared
```

**Preventive monitoring:** add a CloudWatch alarm on `AWS/NetworkELB UnHealthyHostCount` for the peering target group (target group name printed by `terraform output bedrock_kb_endpoint_service_name` and discoverable via `aws elbv2 describe-target-groups --names <project>-kb-peering-<env>`). Alarm fires within ~2 minutes of Atlas rotating IPs — much faster than waiting for the next KB ingestion to fail.

**Not applicable in PrivateLink mode:** the PL VPCE handles Atlas-side IP rotation transparently — Bedrock dials the VPCE DNS name and AWS routes to whichever Atlas-side ENI is healthy.

---

## 17. Connectivity mode mismatch (mode-switch incident)

**Symptom:** `deploy-project.sh` or `terraform plan` fails with `NETWORK MODE MISMATCH` referencing the SSM canary at `/{SHARED_VPC_NAME}/{REGION}/network_mode`.

**Cause:** `envs/network` was applied in one mode but `envs/ec2` tfvars say the other. PrivateLink and VPC peering are mutually exclusive per account — there is no hybrid path.

**Resolution:** do not try to flip the SSM canary manually. Run the full destroy sequence (mode-specific wrappers under `deploy/destroy/`) then redeploy with the correct orchestrator:

```bash
# PrivateLink stack (use *-with-vpc-peering.sh variants for peering stacks)
./deploy/destroy/destroy-project-with-privatelink.sh --auto-approve
./deploy/destroy/destroy-shared-with-privatelink.sh --auto-approve

# Set NETWORK_MODE in .env to the desired value, then:
./deploy/deploy-full-with-privatelink.sh     # OR
./deploy/deploy-full-with-vpc-peering.sh
```

Low-level equivalent: `deploy/scripts/destroy.sh --mode ec2|shared|network` (see [`reference/deploy-scripts.md`](reference/deploy-scripts.md)).

`deploy-network.sh --allow-mode-switch` exists as an escape hatch but is **not** a substitute for destroying the old resources — Atlas-side state (peering connection / VPCE binding) from the prior mode will collide with the new mode's apply.
