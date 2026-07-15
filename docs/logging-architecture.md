# Logging architecture

> **Audience:** anyone reading or shipping logs from this repo — including incident-response engineers, security reviewers, and AI agents editing the codebase.
>
> **TL;DR.** Every API / agent-runtime / MCP / Streamlit process writes single-line **JSON** to stdout/stderr. Each line carries the W3C **`trace_id`** / **`span_id`** of the active OpenTelemetry span, so a single chat turn can be reconstructed across services in CloudWatch Logs Insights. On EC2, **`amazon-cloudwatch-agent`** tails the file-based service logs into project log groups, and an **ADOT Collector sidecar** on `127.0.0.1:4318` signs SigV4 outbound to the CloudWatch X-Ray OTLP endpoint so spans land in **`aws/spans`** for **CloudWatch GenAI Observability** + **Transaction Search**. The Strands TS SDK auto-instruments via the global tracer provider, emitting `gen_ai.*` spans, and Bedrock model invocation logging captures per-call metadata in **`/aws/bedrock/invocations`** (prompt + completion bodies are **OFF** by default for privacy; flip `log_prompt_bodies = true` per environment to enable them — a Data Protection Policy still masks PII even when bodies are on).

---

## 1. Why this design

| Requirement | How we meet it |
|---|---|
| Logs queryable in CloudWatch Insights | Single-line JSON, stable key names, structured timestamps. |
| One request reconstructable end-to-end (API → AgentCore → MongoDB MCP) | OpenTelemetry trace context propagated by HTTP `traceparent` / `tracestate` headers **and** by `_trace` JSON envelope on Bedrock `InvokeAgentRuntime` payloads. Every emitted log line includes `trace_id` / `span_id` when inside an active span. |
| Compliance filter ("audit" channel) | `logger.audit().info(...)` tags `channel: "audit"`; CloudWatch metric / subscription filters can pin on that channel. |
| Cost discipline | Per-component `LOG_LEVEL_*` (API / agent-runtime / MCP) overrides global `LOG_LEVEL`. SSE deltas live at `debug`; only `info` / `warn` / `error` ship by default. Log group retention is split (`api` 30d, `ui`/`mcp`/`agentcore` 7d). |
| Local-dev parity | The same JSON shape lands on `docker compose logs` and on `~/.../multiagent-setup.log`. No special tooling required to read it. |
| Defensive PII redaction | A default redactor recursively masks keys matching `token|secret|password|authorization|jwt|api[_-]?key|mongodb_uri`, hashes `email`/`phone`/`ssn`, truncates `query`/`message` to 256 chars, and rewrites Mongo URIs to strip credentials. |

The original design intentionally skipped OTLP/X-Ray; **Phase 2 of the CloudWatch GenAI Observability rollout** turned that on without changing the JSON log shape. The ADOT Collector sidecar (modules/adot-collector) is the single SigV4 boundary — apps still speak plain OTLP to localhost; the sidecar signs requests outbound. When `OTEL_EXPORTER_OTLP_ENDPOINT` is unset (local docker compose / `DEV_MOCK_BACKENDS=1`) the bootstrap falls back to in-process tracing only and everything else still works.

---

## 2. Field contract

Every log line is **one** UTF-8 JSON object terminated by `\n`. Keys are stable.

| Key | Type | Required | Notes |
|---|---|---|---|
| `level` | `"error" \| "warn" \| "info" \| "debug"` | always | error+warn → stderr; info+debug → stdout. |
| `ts` | ISO-8601 UTC | always | e.g. `2026-05-15T08:51:22.144Z`. |
| `msg` | string | always | Static-ish prefix (`"[chat] turn start"`, `"[auth] jwt verified"`) for grepping. |
| `service` | string | when `OTEL_SERVICE_NAME` is set | `mongodb-multiagent-api` / `mongodb-multiagent-agent-runtime` / `mongodb-multiagent-mcp`. |
| `channel` | `"app" \| "audit"` | always | `audit` is reserved for compliance-relevant events (auth outcomes, tool calls with PII, session DELETE, long-term memory writes). |
| `trace_id` | 32-hex W3C trace id | when inside an active span | Joinable with `X-Trace-Id` response header + the AgentCore-managed log group of the runtime invoked on this turn. |
| `span_id` | 16-hex W3C span id | when inside an active span | |
| `trace_flags` | 2-hex | when inside an active span | Currently always `"01"` (sampled). |
| `requestId` | `req_*` string | per-request | Mints `req_<uuid12>` unless a valid (`/^[a-zA-Z0-9_-]{1,64}$/`) inbound `X-Request-Id` was sent. |
| `userId` | string | per-protected route | JWT `sub` from Cognito (or any other JWKS). |
| `agentId`, `sessionId` | string | when known | Routing/handoff context. |
| `...rest` | redacted ctx | conditional | Whatever the caller passed. |

The full implementation lives in [`api/src/lib/logger.ts`](../api/src/lib/logger.ts).

### Example line

```json
{"level":"info","ts":"2026-05-15T08:51:22.396Z","msg":"[chat] routing to AgentCore Runtime","service":"mongodb-multiagent-api","channel":"app","trace_id":"706ad3686485be1c2fcb30cb9cf63e0a","span_id":"964d438f51291531","trace_flags":"01","requestId":"req_41f11217-198","userId":"user-stream","sessionId":"stream_sess","requestedAgent":"orchestrator","agentId":"order-management","mode":"ec2_to_specialist","hasRuntimeOverride":true,"traceCollectorId":"d1108cec-a305-414c-8d47-b60a7943bb8a"}
```

---

## 3. Components

```mermaid
flowchart LR
  UI[Streamlit UI<br/>ui/lib/log.py<br/>+ opentelemetry-instrument]
  API[Hono API<br/>api/src/lib/logger.ts<br/>+ otel.ts NodeTracerProvider]
  AR[AgentCore Runtime<br/>api/src/agent-runtime-code.ts<br/>(deployed as ECR image)]
  MCP[MongoDB MCP Runtime<br/>mcp-runtimes/mongodb-mcp/src/lib/logger.ts]
  ADOT[ADOT Collector sidecar<br/>127.0.0.1:4318 OTLP<br/>SigV4 outbound]
  CWA[amazon-cloudwatch-agent<br/>(EC2)]
  CWG[(CloudWatch Log Groups<br/>/&lt;SHARED_RESOURCE_PREFIX&gt;/&lt;env&gt;/{api,ui,mcp,agentcore,otel,otel-atlas})]
  AWS[(/aws/bedrock-agentcore/runtimes/*<br/>AWS-managed)]
  SPANS[(aws/spans<br/>Transaction Search)]
  INV[(/aws/bedrock/invocations<br/>+ Data Protection Policy)]

  UI -- X-Request-Id --> API
  API <-- X-Trace-Id --> UI
  API -- traceparent header + _trace payload --> AR
  AR -- traceparent header --> MCP
  API -- traceparent header --> MCP

  API -- stdout/stderr --> Journald[(/var/log/multiagent-api.log)]
  UI  -- stdout/stderr --> Journald2[(/var/log/multiagent-ui.log)]
  Journald --> CWA
  Journald2 --> CWA
  CWA --> CWG
  AR  -- stdout JSON --> AWS
  MCP -- stdout JSON --> AWS

  UI  -- OTLP HTTP --> ADOT
  API -- OTLP HTTP --> ADOT
  ADOT -- awsxray exporter --> SPANS
  ADOT -- awscloudwatchlogs exporter --> CWG
  AR -- service-vended --> SPANS
  API -- requestMetadata.userId/agentId --> INV
```

### 3.1 API (`api/`)

- **Bootstrap:** [`api/src/index.ts`](../api/src/index.ts) calls `initOtel({ serviceName: "mongodb-multiagent-api" })` and, when `STRANDS_LOG_REDIRECT=1`, `installStrandsConsoleRedirect()`.
- **Middleware order** (`api/src/app.ts`):
  1. `requestIdMiddleware` — sets `X-Request-Id` (prefer inbound).
  2. `otelServerSpanMiddleware` — extracts inbound `traceparent`, starts the HTTP server span, sets `X-Trace-Id` response header. Skips lightweight `GET` paths (`/health`, `/agents`, `/skills`, `/traces`, `/demo-prompts`).
  3. `accessLogMiddleware` — one `"request"` info line per non-probe path; probes go to `debug`.
  4. CORS (exposes `X-Request-Id`, `X-Trace-Id`, `traceparent`, `tracestate`).
  5. Auth (`audit` channel for every JWT outcome).

### 3.2 AgentCore agent-runtime (`api/src/agent-runtime-code.ts`)

The bundle that ships into Bedrock AgentCore Runtime containers. On boot it:

- calls `initOtel({ serviceName: "mongodb-multiagent-agent-runtime" })`,
- installs the Strands console redirect (`STRANDS_LOG_REDIRECT=1`),
- extracts `_trace` from the `InvokeAgentRuntime` JSON payload and wraps `handleInvocations` in `context.with(parentCtx, ...)` so every span / log line continues the API's trace.

Stdout/stderr from this container lands in the **AWS-managed** log group `/aws/bedrock-agentcore/runtimes/<id>/...` automatically — we don't ship it ourselves. Joining with the API log group is by **`trace_id`**.

### 3.3 MongoDB MCP runtime (`mcp-runtimes/mongodb-mcp/`)

Same Logger class, copied to `mcp-runtimes/mongodb-mcp/src/lib/logger.ts` (kept in sync manually; the two trees deliberately don't share node_modules). On boot it calls `initOtel({ serviceName: "mongodb-multiagent-mcp" })`. The `/mcp` Express handler runs every JSON-RPC dispatch inside `context.with(extractContextFromHeaders(req.headers), …)` so the MCP server span is a child of the API/runtime span.

`redactArgsForLog` is the default redactor for MCP tool args — protects `filter`, `query`, `document`, `update`, `queryVector`, `pipeline`, `projection`, `sort` before any log emission.

### 3.4 Streamlit UI (`ui/lib/log.py`)

A minimal `logging`-based JSON formatter exposed as `ui_log.info/warn/error/debug`. Each user interaction mints a `req_*` id via `ui_log.new_request_id()` and forwards it as `X-Request-Id` to the API; the response `X-Trace-Id` header is captured into `st.session_state["last_x_trace_id"]` and surfaced in the chat-page footer.

---

## 4. Trace propagation in detail

OpenTelemetry context lives in `@opentelemetry/context-async-hooks.AsyncLocalStorageContextManager`. The carrier across boundaries is **W3C `traceparent` / `tracestate`** — never raw IDs in URLs or headers we invent.

| Boundary | Carrier |
|---|---|
| UI → API | `X-Request-Id` (correlation only) — UI does not synthesize `traceparent`. |
| API → API (downstream HTTP) | Standard `traceparent` header via `appendTraceContextHeaders(headers)`. |
| API → AgentCore Runtime (Bedrock SDK) | Bedrock `InvokeAgentRuntimeCommand` accepts no custom HTTP headers, so context is injected into the JSON body under a reserved key: `payload._trace = { traceparent, tracestate? }`. The runtime container's `handleInvocations` extracts and strips it before forwarding to the model. |
| API → MCP server (StreamableHTTP) | `traceparent` / `tracestate` headers on the fetch via `appendTraceContextHeaders(headers)`. AgentCore Runtime → MCP follows the same path because both share `api/src/adapters/mongodb-mcp-client.ts`. |

### Why this matters operationally

- `X-Trace-Id` from a single `POST /chat` matches the `trace_id` field in **every** log line emitted by that turn — in `/<SHARED_RESOURCE_PREFIX>/<env>/api`, in the AgentCore runtime's log group (`/aws/bedrock-agentcore/runtimes/<runtime-id>/...`), and in any MCP runtime group.
- The Trace Viewer's `traceId` is a **different** identifier (the `TraceCollector` UUID, persisted in MongoDB `traces`). Both coexist; both are useful. The `TraceCollector` UUID is included on the OTel span as the `trace.collector_id` attribute so they can be joined.
- The persisted trace doc now also carries `trace.otel = { traceId, rootSpanId }` (32-hex / 16-hex) at the top level — captured at finalize time by `TraceCollector.captureOtelIds()`. The Trace Viewer's **Developer details → Identifiers** sub-section builds ServiceLens / X-Ray / Logs Insights deep links from this directly, so on-call doesn't have to copy the W3C trace id by hand. Only present on `?include=dev|full` projections (stripped from `?include=core` for operator-demo size).

See [`tests/integration/chat-sse-trace.integration.test.ts`](../api/tests/integration/chat-sse-trace.integration.test.ts) for the wire-level contract.

---

## 5. Audit channel

`logger.audit().info(...)` / `.warn(...)` adds `channel: "audit"` to every line. **Use it** for:

- JWT verification outcomes (success + failure) — `api/src/middleware/auth.ts`.
- Every MCP `callTool` invocation — `api/src/adapters/mongodb-mcp-client.ts`.
- Session deletion — `api/src/routes/sessions.ts`.
- Long-term memory writes — `api/src/lib/long-term-memory.ts`.

**Do not use** it for noisy operational events (model start/stop, token deltas, cache hits). Audit must remain a low-volume, signal-rich channel so a CloudWatch metric filter like:

```text
{ $.channel = "audit" }
```

returns a small enough stream that a human can read it.

---

## 6. Default redactor

`api/src/lib/logger.ts` ships a `defaultRedact` that runs on every emitted context object up to depth 3:

| Pattern | Behavior | Example |
|---|---|---|
| Keys matching `/token\|secret\|password\|authorization\|jwt\|api[_-]?key\|mongodb_uri/i` | Value replaced with `"***"` | `{ password: "hunter2" }` → `{ password: "***" }` |
| String values matching `JWT_LIKE` (`a.b.c` base64-segments) under a non-sensitive key | Replaced with `"jwt:***"` | `{ evidence: "eyJ...J9.eyJ...Q.sig" }` → `{ evidence: "jwt:***" }` |
| Strings starting with `mongodb://` or `mongodb+srv://` | Credentials masked, embedded `@` in password handled correctly (regex matches to last `@` before path) | `mongodb+srv://user:p@ss@host/db` → `mongodb+srv://***@host/db` |
| Keys `email` / `phone` / `ssn` | Value hashed with sha1 prefix-8 | `{ email: "alex@example.com" }` → `{ email: "sha1:abcd1234" }` |
| Keys `query` / `message` (string values) | Truncated to 256 chars + `…` | A 500-char value becomes 257 chars. |

Coverage is locked in by [`api/tests/unit/logger-redactor.test.ts`](../api/tests/unit/logger-redactor.test.ts) (8-case matrix) and [`api/tests/unit/logger.test.ts`](../api/tests/unit/logger.test.ts).

### Adding a new sensitive key

1. Pick a name that matches the existing regex (`api_key`, `customer_secret`, `mongodb_uri_replica`, etc.). Don't try to evade the regex (`tok`, `pwd`) — call sites will eventually leak.
2. If the new redaction is structurally different (e.g. masking only the last 4 digits of a card number), pass a custom `redactor: …` when constructing a child `Logger`. **Do not** modify `defaultRedact` for one-off cases — every regression in the default touches the whole codebase.

---

## 7. Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `LOG_LEVEL` | `info` | Global level. `error` / `warn` / `info` / `debug`. Unknown values fall back to `info`. |
| `LOG_LEVEL_API` | unset | Override under `OTEL_SERVICE_NAME` containing `-api`. |
| `LOG_LEVEL_AGENT_RUNTIME` | unset | Override under `OTEL_SERVICE_NAME` containing `agent-runtime`. |
| `LOG_LEVEL_MCP` | unset | Override under `OTEL_SERVICE_NAME` containing `mcp`. |
| `OTEL_SERVICE_NAME` | set by `initOtel(...)` | Resource attribute + per-component log-level resolution key. |
| `STRANDS_LOG_REDIRECT` | unset | Set to `1` to install `installStrandsConsoleRedirect()` — copies every `console.error` into a `warn` line tagged `strands.console_error`. |
| `LOGS_RAW_CONSOLE` | unset | (Not implemented; reserved.) |

Test coverage:

- [`api/tests/unit/logger-log-level.test.ts`](../api/tests/unit/logger-log-level.test.ts) — per-component override + fallback.
- [`api/tests/unit/strands-console-redirect.test.ts`](../api/tests/unit/strands-console-redirect.test.ts) — env gate + capture + still-forwards behavior.

---

## 8. CloudWatch shipping (EC2)

### 8.1 Log groups

| Group | Retention | Source | Owning module |
|---|---|---|---|
| `/api` | `api_retention_days` (default **30**) | `multiagent-api.service` → `/var/log/multiagent-api.log` → CW agent | `modules/cloudwatch` |
| `/ui` | `aux_retention_days` (default **7**) | `multiagent-ui.service` → `/var/log/multiagent-ui.log` → CW agent | `modules/cloudwatch` |
| `/mcp` | `aux_retention_days` (default **7**) | Reserved (MongoDB MCP runs as an AgentCore Runtime; its logs land under `/aws/bedrock-agentcore/...`). | `modules/cloudwatch` |
| `/agentcore` | `aux_retention_days` (default **7**) | Reserved — AgentCore Runtime logs are AWS-managed at `/aws/bedrock-agentcore/runtimes/<id>/`. | `modules/cloudwatch` |
| `/<SHARED_RESOURCE_PREFIX>/<env>/otel` | `log_retention_days` (default **30**) | ADOT Collector sidecar's `awscloudwatchlogs` exporter — receives OTLP application logs from API + Streamlit. | `modules/adot-collector` |
| `aws/spans` | `span_retention_days` (default **14**) | X-Ray Transaction Search ingest. Receives OTLP spans signed by the ADOT sidecar + the AgentCore Runtime's own service-vended spans. | `modules/cloudwatch-genai` |
| `/aws/vendedlogs/bedrock-agentcore/memory/APPLICATION_LOGS/<id>` | `agentcore_log_retention_days` (default **7**) | AgentCore Memory service-vended `APPLICATION_LOGS`. | `modules/cloudwatch-genai` |
| `/aws/vendedlogs/bedrock-agentcore/gateway/APPLICATION_LOGS/<id>` | `agentcore_log_retention_days` (default **7**) | AgentCore Gateway service-vended `APPLICATION_LOGS`. | `modules/cloudwatch-genai` |
| `/aws/bedrock/invocations` | `invocation_retention_days` (default **7**) | Bedrock model invocation logging — per-call metadata (modelId, token counts, latency, requestMetadata, error). | `modules/bedrock-invocation-logging` |

The 30-day retention on `/api` carries the audit channel — keep it long enough to investigate after-the-fact. Spans default to 14 days because they're high-volume and the per-span value drops sharply after a week.

### 8.2 CloudWatch GenAI Observability (Phase 1)

Two modules light up the **AgentCore Agents** + **Model Invocations** tabs in the CloudWatch console:

- [`modules/cloudwatch-genai`](../deploy/terraform/modules/cloudwatch-genai/) — provisions the `aws/spans` log group, the X-Ray → Logs resource policy, the `awscc_xray_transaction_search_config` toggle (`var.span_sampling_percent`; account-scoped), and the service-vended log delivery triples for every AgentCore Memory and Gateway id.
- [`modules/bedrock-invocation-logging`](../deploy/terraform/modules/bedrock-invocation-logging/) — provisions `/aws/bedrock/invocations`, a customer-managed KMS key (alias `alias/<project>-<env>-bedrock-invocations`), the IAM role Bedrock assumes to write logs, and the singleton `aws_bedrock_model_invocation_logging_configuration`.

**Per-user / per-agent attribution.** Phase 3's `api/src/adapters/resolve-model.ts` injects `requestMetadata: { userId, agentId }` into every Converse / ConverseStream call via the `MetadataAwareBedrockModel` wrapper (reads from `currentTrace()` at call time). The cost dashboard groups `InputTokenCount` / `OutputTokenCount` by `requestMetadata.userId` to render per-user breakdown.

### 8.3 Data Protection Policy

[`modules/bedrock-invocation-logging`](../deploy/terraform/modules/bedrock-invocation-logging/) attaches an `aws_cloudwatch_log_data_protection_policy` to `/aws/bedrock/invocations`. The policy:

- **Audits** every detected PII identifier (`EmailAddress`, `PhoneNumber`, `CreditCardNumber`, `AwsSecretKey`, `BankAccountNumber`, `UsSocialSecurityNumber` by default — extend per environment via `var.data_protection_identifiers`).
- **Deidentifies** the same identifiers via `MaskConfig{}` so consumers reading the log see e.g. `{EmailAddress}` instead of the raw value.
- **Publishes audit findings** back into `/aws/bedrock/invocations` with `eventType="DataMaskingFinding"`. Phase 3's `modules/cloudwatch-fleet-dashboards` `audit_findings` metric filter increments `Multiagent/Audit:AuditFindings` on every finding, and the matching `audit_findings` alarm pages on > 10 findings / 5 minutes.

**Defense in depth.** Body logging is **OFF** by default (`var.log_prompt_bodies = false`, `var.log_embedding_bodies = false`). The Data Protection Policy still runs on the metadata records that DO get written (errors, requestMetadata, dimensions). When you flip `log_prompt_bodies = true` for a specific environment, the policy automatically scrubs PII in the new body field — but the body is still written before scrubbing, so treat that flag as opt-in and audit-reviewed.

### 8.4 ADOT Collector sidecar (Phase 2)

[`modules/adot-collector`](../deploy/terraform/modules/adot-collector/) uploads a rendered YAML config to S3 and `modules/ec2/user_data.sh` materializes it into a systemd unit running `aws-otel-collector` on the host network. The collector:

- Listens on `127.0.0.1:4318` (OTLP HTTP `/v1/traces` + `/v1/logs`) and `127.0.0.1:4317` (gRPC).
- Signs SigV4 outbound to `https://xray.<region>.amazonaws.com/v1/traces` via the `awsxray` exporter and to `https://logs.<region>.amazonaws.com/v1/logs` via `awscloudwatchlogs` — the EC2 instance profile holds `xray:PutTraceSegments / PutTelemetryRecords / GetSampling*` and `logs:PutLogEvents` for that.
- Phase 4: scrapes the MongoDB Atlas Prometheus endpoint and publishes to the `MongoDB/Atlas` CloudWatch namespace via the `awsemf` exporter.
- Exposes a `/13133` health endpoint so `multiagent-api.service` and `multiagent-ui.service` can declare `After=aws-otel-collector.service` and assume the receiver is up.

### 8.5 EC2 bootstrap (`deploy/terraform/modules/ec2/user_data.sh`)

We use **file-based collection**, not journald collection. The official AWS CloudWatch agent configuration reference (as of 2026-05) documents only `logs.logs_collected.files` and `logs.logs_collected.windows_events`. Journald support exists in the agent's source code but isn't part of the stable documented schema — pinning on it would mean undocumented JSON keys that can break on an agent RPM upgrade.

The flow is:

1. systemd unit `multiagent-api.service` uses `StandardOutput=append:/var/log/multiagent-api.log` and `StandardError=append:/var/log/multiagent-api.log`.
2. Same for `multiagent-ui.service` → `/var/log/multiagent-ui.log`.
3. `logrotate.d/multiagent` rotates daily / 100 MB max / 7 backups with `copytruncate` (so systemd's append handle stays valid).
4. `amazon-cloudwatch-agent.json` declares two file collectors pointing at those paths and ships into the two log groups templated from Terraform variables (`cw_log_group_api`, `cw_log_group_ui`).
5. `amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:…` validates + starts the agent.

`deploy-project.sh` runs **two** non-fatal validation probes after `.bootstrap-done` appears:

- `systemctl is-active amazon-cloudwatch-agent` over SSM (warn if not `active`).
- `aws logs describe-log-streams --log-group-name $CW_API_LOG_GROUP --max-items 1` polled for 60 s after API restart (warn if 0 streams).

### 8.6 EMF custom metrics — `Multiagent/Chat`, `Multiagent/Mongo`, `Multiagent/Memory` (Phase 3)

[`api/src/lib/cw-metrics.ts`](../api/src/lib/cw-metrics.ts) emits **CloudWatch Embedded Metric Format (EMF)** records as plain stdout JSON lines, riding the same `/var/log/multiagent-api.log` → `multiagent-api` log group path the structured logger uses. CloudWatch detects the `_aws.CloudWatchMetrics` envelope and extracts metrics automatically — **no extra SDK calls, no extra IAM, no extra container.**

Wired call sites:

| Source | Namespace · metrics |
|---|---|
| `routes/chat.ts` @ `chat.turn.end` | `Multiagent/Chat` · `TurnsTotal`, `TurnErrors`, `TurnLatencyMs` (dim: `agentId`) |
| `adapters/agentcore-runtime.ts` end/error | `Multiagent/Chat` · `AgentCoreInvokes`, `AgentCoreInvokeErrors`, `AgentCoreInvokeLatencyMs` (dims: `agentId`, `mode`) |
| `lib/trace-collector.ts` event bridge for `mongo.query` / `mongo.vector_search` | `Multiagent/Mongo` · `QueryCount`, `QueryLatencyMs`, `VectorSearchLatencyMs` (dims: `collection`, `kind`) |
| `lib/long-term-memory.ts` write end | `Multiagent/Memory` · `FactsExtracted`, `FactsWritten`, `EmbeddingFailures` (dim: `agentId`) |

These are the exact metric names the [`cloudwatch-fleet-dashboards`](../deploy/terraform/modules/cloudwatch-fleet-dashboards/) widgets and alarms read. **Without this emitter the fleet/Mongo dashboards stay empty and the P99 latency / error-rate / vector-search alarms go `INSUFFICIENT_DATA`.** Lock-down test: [`api/tests/unit/cw-metrics.test.ts`](../api/tests/unit/cw-metrics.test.ts) — fails CI the moment anyone renames a metric or moves the value off the top level of the EMF record.

Disable in CI / unit tests with `METRICS_EMITTER_ENABLED=0`. Dimension cardinality is intentionally low (no `userId` as a dimension — per-user attribution lives in Bedrock invocation logs via `requestMetadata.userId`).

### 8.7 Local development

`docker compose up --build` does **not** run the CloudWatch agent or the ADOT sidecar. Logs stay on stdout in the same JSON shape; tail with `docker compose logs -f api`. EMF lines are still emitted (they're harmless JSON to anything that's not CloudWatch). With `OTEL_EXPORTER_OTLP_ENDPOINT` unset, the API's `initOtel(...)` skips the OTLPTraceExporter installation and spans live in-process only — Trace Viewer still works, but nothing is exported.

---

## 9. Smoke verification

[`e2e-smoke/post-deploy-smoke.py`](../e2e-smoke/post-deploy-smoke.py) `check_cloudwatch_join`:

1. `POST /chat`, capture `X-Trace-Id` from response headers.
2. Poll `aws logs filter-log-events --log-group-name /<SHARED_RESOURCE_PREFIX>/<env>/api --filter-pattern '{ $.trace_id = "<id>" }'` for up to 90 s. Pass when ≥1 match.
3. Discover `/aws/bedrock-agentcore/runtimes/*` log groups and run the same filter against up to 8 of them. Pass when ≥1 match (proves cross-boundary `_trace` propagation).

Both probes are **warn-on-miss** rather than hard-fail because journald lag and AgentCore log-group provisioning are best-effort. Operators are expected to read the smoke output and notice WARN lines on first deploy.

---

## 10. Troubleshooting

### `X-Trace-Id` missing from a `/chat` response

- Check `otelServerSpanMiddleware` is wired in `api/src/app.ts` after `requestIdMiddleware`.
- Confirm the route isn't in the **probe-exclusion** list (`/health`, `/agents`, `/skills`, `/traces`, `/demo-prompts`, `OPTIONS *`). `POST /chat` should never be excluded.
- If the response goes through CORS, confirm `X-Trace-Id` is in `exposeHeaders` of `cors(...)`.

### Log lines lack `trace_id` even inside a request

- Verify `initOtel(...)` is called **before** `createApp()` (in `api/src/index.ts`) — middleware can't start a span without a registered tracer provider.
- Verify `process.env.OTEL_SERVICE_NAME` is set (it's set by `initOtel`). The per-component level resolution uses it.
- Run [`api/tests/unit/bun-als-context.test.ts`](../api/tests/unit/bun-als-context.test.ts) to confirm async context survives the Bun runtime under your version.

### `/api` log group has zero streams after deploy

- SSH (or SSM) to EC2 and run `systemctl status amazon-cloudwatch-agent`. If it's not running: `journalctl -u amazon-cloudwatch-agent -n 200`.
- Verify `/var/log/multiagent-api.log` exists and is non-empty: `tail -n 5 /var/log/multiagent-api.log`.
- Verify the IAM role on EC2 has `logs:CreateLogGroup` / `logs:CreateLogStream` / `logs:PutLogEvents` / `logs:DescribeLogStreams` (it should — see `modules/ec2/main.tf` `CloudWatchLogs` SID).

### Audit channel polluted by ops noise

Audit is supposed to be low-volume. If your CloudWatch filter `{ $.channel = "audit" }` is producing hundreds of lines per minute, you added a call site you shouldn't have. Move the noisy one back to `logger.info(...)` and add a regression test against the new audit volume.

### `mongodb+srv://` URI appears in plaintext logs

That's a regression — open `api/src/lib/logger.ts` and verify `maskMongoUri` and `defaultRedact` are still wired into `new Logger(undefined, { redactor: … })`. The `logger-redactor.test.ts` suite is your safety net; if it's passing but production still leaks, the call site is bypassing `logger` (likely a stray `console.log`). Grep:

```bash
rg "console\.(log|error|warn)" api/src/
```

That command must always return empty (CI enforces this via the test that JSON-parses every emitted line — see `api/tests/unit/logger.test.ts`).

### `aws/spans` is empty after a chat turn

- Confirm the ADOT sidecar is running on EC2: `systemctl is-active aws-otel-collector`. If not, `journalctl -u aws-otel-collector -n 200` will surface SigV4 / endpoint errors.
- Verify the API exported with the right endpoint: `grep OTEL_EXPORTER_OTLP_ENDPOINT /opt/multiagent/.env.live` — should be `http://127.0.0.1:4318`.
- Re-run `bun run validate:strands-otel` inside the API container — exit code 0 means the global tracer provider is bound (not Noop) and Strands `gen_ai.*` spans will flow.
- Check the `awscc_xray_transaction_search_config` indexing percentage — if you set it to a small number (e.g. 1), only 1% of spans are indexed; lower-volume traffic will look empty.

### Bedrock invocation log lines have no prompt body

That's the default. `var.log_prompt_bodies = false` (and `var.log_embedding_bodies = false`) is intentional — see §8.3. Flipping to true requires re-applying Terraform with the override and is gated on security review.

### CloudWatch GenAI Observability "Agents" tab is empty for memory / gateway columns

The runtime column populates automatically (AWS-managed). Memory + Gateway require the **service-vended log delivery triples** from `modules/cloudwatch-genai`. Apply Phase 1 (`enable_genai_observability = true`) and pass the actual memory / gateway IDs.

### Per-user cost widget on the cost dashboard is empty

Per-user attribution requires both: (1) `var.enable_bedrock_invocation_logging = true` (so `/aws/bedrock/invocations` exists at all), and (2) the API running with the Phase 3 `MetadataAwareBedrockModel` wrapper — confirm by running a chat turn and grepping the invocation log for `requestMetadata.userId`. If absent, the wrapper isn't being instantiated; check `api/src/adapters/resolve-model.ts` and run `bun test tests/unit/agentcore-runtime-traceparent.test.ts`.

### Fleet / Mongo dashboard widgets are empty, alarms are `INSUFFICIENT_DATA`

The Phase 3 dashboards + alarms read **custom metrics** in `Multiagent/Chat`, `Multiagent/Mongo`, and `Multiagent/Memory`. Those metrics are emitted by the EMF emitter in [`api/src/lib/cw-metrics.ts`](../api/src/lib/cw-metrics.ts) (see §8.6). Three things can break it: (1) someone set `METRICS_EMITTER_ENABLED=0` in the API env, (2) the API process didn't get the latest code (run `./deploy/deploy-api.sh`), (3) the call sites that import `recordChatTurn` / `recordAgentCoreInvoke` / `recordMongoQuery` / `recordMemoryWrite` were edited and dropped the call. Lock-down test: `bun test tests/unit/cw-metrics.test.ts`. To confirm metric extraction at runtime, search the API log group for `_aws.CloudWatchMetrics` in CloudWatch Logs Insights — if records appear, the emitter is healthy and the metric extractor will pick them up within ~1 min.

### A fleet alarm is firing constantly

Alarms route through the SNS topic `${project}-fleet-alarms-${env}`. Subscribe a human first (`var.alarm_email`) to triage signal vs. noise before adding webhook subscribers. Threshold defaults are in `envs/ec2/variables.tf` — bump `p99_latency_threshold_ms` / `error_rate_threshold_pct` / `throttle_burst_threshold` rather than disabling alarms.

---

## 11. File index

| Path | Role |
|---|---|
| [`api/src/lib/logger.ts`](../api/src/lib/logger.ts) | `Logger` class + default redactor + per-component level resolver. |
| [`api/src/lib/otel.ts`](../api/src/lib/otel.ts) | OTel bootstrap, W3C propagator, header inject/extract helpers. |
| [`api/src/lib/strands-console-redirect.ts`](../api/src/lib/strands-console-redirect.ts) | Optional Strands SDK `console.error` capture. |
| [`api/src/middleware/request-id.ts`](../api/src/middleware/request-id.ts) | Inbound `X-Request-Id` preference + sanitization. |
| [`api/src/middleware/otel.ts`](../api/src/middleware/otel.ts) | HTTP server span, `X-Trace-Id` response header, probe-route exclusion. |
| [`api/src/middleware/access-log.ts`](../api/src/middleware/access-log.ts) | One-line-per-request log; probes at `debug`. |
| [`api/src/middleware/auth.ts`](../api/src/middleware/auth.ts) | JWT verify with audit-channel outcome. |
| [`api/src/adapters/agentcore-runtime.ts`](../api/src/adapters/agentcore-runtime.ts) | Injects `_trace` payload into Bedrock `InvokeAgentRuntime`. |
| [`api/src/adapters/mongodb-mcp-client.ts`](../api/src/adapters/mongodb-mcp-client.ts) | Adds `traceparent` to MCP fetch, audit-channels every `callTool`. |
| [`api/src/agent-runtime-code.ts`](../api/src/agent-runtime-code.ts) | Container bundle — OTel bootstrap + Strands redirect + `_trace` extraction. |
| [`mcp-runtimes/mongodb-mcp/src/lib/logger.ts`](../mcp-runtimes/mongodb-mcp/src/lib/logger.ts) | Mirror of the API Logger class. |
| [`mcp-runtimes/mongodb-mcp/src/lib/otel.ts`](../mcp-runtimes/mongodb-mcp/src/lib/otel.ts) | Mirror of the API OTel bootstrap. |
| [`mcp-runtimes/mongodb-mcp/src/index.ts`](../mcp-runtimes/mongodb-mcp/src/index.ts) | Wraps Express `/mcp` in `context.with(extractContextFromHeaders(req.headers), …)`. |
| [`ui/lib/log.py`](../ui/lib/log.py) | Streamlit JSON logger + `new_request_id()`. |
| [`ui/lib/api_client.py`](../ui/lib/api_client.py) | Sends `X-Request-Id`, captures `X-Trace-Id` from response. |
| [`deploy/terraform/modules/cloudwatch/`](../deploy/terraform/modules/cloudwatch/) | 4 base log groups + per-group retention. |
| [`deploy/terraform/modules/cloudwatch-genai/`](../deploy/terraform/modules/cloudwatch-genai/) | Phase 1 — `aws/spans` + X-Ray Transaction Search + AgentCore vended log delivery. |
| [`deploy/terraform/modules/bedrock-invocation-logging/`](../deploy/terraform/modules/bedrock-invocation-logging/) | Phase 1 — `/aws/bedrock/invocations` + KMS + Data Protection Policy + invocation logging singleton. |
| [`deploy/terraform/modules/adot-collector/`](../deploy/terraform/modules/adot-collector/) | Phase 2 — ADOT collector sidecar config + OTLP log group. |
| [`deploy/terraform/modules/cloudwatch-fleet-dashboards/`](../deploy/terraform/modules/cloudwatch-fleet-dashboards/) | Phase 3 — SNS topic, 3 dashboards, 7 alarms, audit metric filter, query library. |
| [`deploy/terraform/modules/cloudwatch-atlas-dashboard/`](../deploy/terraform/modules/cloudwatch-atlas-dashboard/) | Phase 4 — Atlas dashboard + connection saturation + replication-lag alarms. |
| [`deploy/terraform/modules/ec2/user_data.sh`](../deploy/terraform/modules/ec2/user_data.sh) | Installs CW agent + ADOT collector sidecar + file-based collectors + logrotate. |
| [`deploy/scripts/deploy-project.sh`](../deploy/scripts/deploy-project.sh) | Post-bootstrap CW-agent + describe-log-streams probes; writes OTEL_* env vars into `.env.live`. |
| [`e2e-smoke/post-deploy-smoke.py`](../e2e-smoke/post-deploy-smoke.py) | `check_cloudwatch_join` — verifies `trace_id` appears in `/api` and AgentCore log groups. |
| [`api/scripts/validate-strands-otel.ts`](../api/scripts/validate-strands-otel.ts) | Smoke: global tracer provider is real (not Noop), so Strands `gen_ai.*` spans flow. |
| [`api/tests/unit/agentcore-runtime-traceparent.test.ts`](../api/tests/unit/agentcore-runtime-traceparent.test.ts) | Regression guard — every `InvokeAgentRuntime` payload carries W3C `_trace.traceparent`. |
| [`api/src/lib/cw-metrics.ts`](../api/src/lib/cw-metrics.ts) | EMF emitter — turns `Multiagent/Chat`, `Multiagent/Mongo`, `Multiagent/Memory` custom metrics into stdout JSON. |
| [`api/tests/unit/cw-metrics.test.ts`](../api/tests/unit/cw-metrics.test.ts) | Locks down EMF record shape so a metric rename never silently empties the fleet dashboards. |
| [`api/tests/unit/logger.test.ts`](../api/tests/unit/logger.test.ts) | JSON shape, level filtering, `trace_id` correlation, `child()`. |
| [`api/tests/unit/logger-redactor.test.ts`](../api/tests/unit/logger-redactor.test.ts) | 8-case redactor matrix. |
| [`api/tests/unit/logger-log-level.test.ts`](../api/tests/unit/logger-log-level.test.ts) | Per-component `LOG_LEVEL_*` overrides. |
| [`api/tests/unit/otel-middleware.test.ts`](../api/tests/unit/otel-middleware.test.ts) | Span lifecycle + `X-Trace-Id` header. |
| [`api/tests/unit/sse-span-lifecycle.test.ts`](../api/tests/unit/sse-span-lifecycle.test.ts) | `X-Trace-Id` set before first chunk; stable through stream. |
| [`api/tests/unit/bun-als-context.test.ts`](../api/tests/unit/bun-als-context.test.ts) | Bun async-hooks coverage for OTel context. |
| [`api/tests/unit/request-id-inbound.test.ts`](../api/tests/unit/request-id-inbound.test.ts) | Inbound `X-Request-Id` accept/reject matrix. |
| [`api/tests/unit/strands-console-redirect.test.ts`](../api/tests/unit/strands-console-redirect.test.ts) | Env gate + capture + forward. |
| [`api/tests/integration/chat-sse-trace.integration.test.ts`](../api/tests/integration/chat-sse-trace.integration.test.ts) | End-to-end `X-Trace-Id` + persisted product trace. |

---

## 12. CloudWatch GenAI Observability rollout — what landed, what's next

### Landed

- **Phase 1 — managed observability surfaces.** `modules/cloudwatch-genai` enables Transaction Search on `aws/spans` and wires AgentCore Memory + Gateway vended log delivery; `modules/bedrock-invocation-logging` provisions `/aws/bedrock/invocations` with KMS encryption and a Data Protection Policy (PII auditing + masking). Body logging defaults to OFF.
- **Phase 2 — OTLP export.** `api/src/lib/otel.ts` swapped `BasicTracerProvider` for `NodeTracerProvider` + `BatchSpanProcessor` + `OTLPTraceExporter` pointing at `127.0.0.1:4318`. `api/src/lib/trace-collector.ts` bridges every internal span / event into the global tracer provider, so Strands `gen_ai.*` spans and our domain events land in the same trace. The ADOT Collector sidecar (`modules/adot-collector`) signs SigV4 outbound — no SDK changes needed in any app. Streamlit launches via `opentelemetry-instrument` so its HTTP server spans + outbound `requests` calls join the same trace tree.
- **Phase 3 — fleet ops console.** `modules/cloudwatch-fleet-dashboards` creates an SNS topic + three dashboards (fleet / mongo / cost) + seven alarms (P99 latency, error rate, model throttles, AgentCore failures, Bedrock invocation errors, PII audit findings, SLO burn) + a Logs Insights query library. Per-user cost attribution comes from the `MetadataAwareBedrockModel` wrapper injecting `requestMetadata.userId / agentId` into every Converse call.
- **Phase 4 — MongoDB Atlas metrics.** The ADOT collector grew a Prometheus receiver that scrapes Atlas's metrics endpoint and an `awsemf` exporter publishing to the `MongoDB/Atlas` namespace. `modules/cloudwatch-atlas-dashboard` adds a 5-widget dashboard plus connection-saturation and replication-lag alarms wired into the Phase 3 SNS topic.

### Still open

- **Span-level sampling tuning** — `var.span_sampling_percent` controls the X-Ray indexed slice; the OTel SDK's own sampler (`OTEL_TRACES_SAMPLER=parentbased_traceidratio` + `OTEL_TRACES_SAMPLER_ARG`) controls export volume. A real workload profile is needed before recommending non-default ratios per env.
- **Application Inference Profile cost separation** — `requestMetadata` is good for dashboard attribution but not for IAM-isolated cost ledgers. If a customer wants per-business-unit billing with separate Bedrock quotas, switch to Application Inference Profiles per business unit and pivot the cost dashboard to AIP dimensions.
- **CI-side automation** — the deploy scripts run smoke tests post-apply, but a dedicated CI job that asserts every dashboard renders + every alarm fires once on a synthetic failure injection would harden against regressions.
- **Log archival to S3 / Athena** — CloudWatch native retention only for now.
