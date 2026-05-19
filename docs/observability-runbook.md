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
| Logs Insights — API | run the query below against `/<project>/<env>/api` |
| Logs Insights — `aws/spans` | run the query below against `aws/spans` |
| GenAI Observability Agents tab | `https://<region>.console.aws.amazon.com/cloudwatch/home?region=<region>#gen-ai-observability:agent-core` then filter by `trace_id` |

Standard "everything on this trace" query:

```text
fields @timestamp, msg, level, agent_id, span_id, requestId
| filter trace_id = "<TRACE_ID>"
| sort @timestamp asc
| limit 200
```

---

## 2. Log group cheat-sheet

| Symptom | Read this group first |
|---|---|
| Chat turn errored before any tool call | `/<project>/<env>/api` |
| Chat turn looked fine in API but the model said "I cannot…" | `/aws/bedrock/invocations` (errors + stop reason) |
| AgentCore Runtime invocation failed | `/<project>/<env>/api` (look for `[agentcore-runtime] InvokeAgentRuntime failed`), then `/aws/bedrock-agentcore/runtimes/<id>/...` for runtime-side stack |
| Memory write / read seems wrong | `/aws/vendedlogs/bedrock-agentcore/memory/APPLICATION_LOGS/<id>` |
| Gateway tool call returned 401 / 403 | `/aws/vendedlogs/bedrock-agentcore/gateway/APPLICATION_LOGS/<id>` |
| Span shows up in X-Ray but no JSON log lines | `/<project>/<env>/otel` — the OTLP-logs path may have emitted them |
| PII detection alarm fired | `/aws/bedrock/invocations` filtered by `{ $.eventType = "DataMaskingFinding" }` |
| Streamlit UI itself crashed | `/<project>/<env>/ui` |
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

1. **Connection leak in the app** — a recently-deployed change creates `MongoClient` without `await client.close()`. Spot it by counting active streams in `/<project>/<env>/api` against connection counts on the dashboard; if app load is flat but connections climb, it's a leak.
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
3. Set **Indexed spans percentage** to the value matching `var.span_sampling_percent` (default `5`).
4. Confirm. CloudWatch auto-creates the `aws/spans` log group (you cannot create it yourself — the `aws/` prefix is reserved).

**Or, if you have the perms, single-shot CLI (same effect):**
```bash
aws xray update-trace-segment-destination --destination CloudWatchLogs
aws xray update-indexing-rule --name Default \
  --rule "Probabilistic={DesiredSamplingPercentage=5}"
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
SOURCE '/<project>/<env>/api'
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
SOURCE '/<project>/<env>/api' | fields @timestamp, level, msg, error_class, error_message, trace_id
| filter level = "error"
| sort @timestamp desc
| limit 50
```

### "Show me chat turns over 5s"
```text
SOURCE '/<project>/<env>/api' | fields @timestamp, agent_id, session_id, latency_ms, trace_id
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
SOURCE '/<project>/<env>/api' | fields @timestamp, user_id
| filter msg = "chat.turn.end"
| stats count() as turns by user_id
| sort turns desc
| limit 25
```
