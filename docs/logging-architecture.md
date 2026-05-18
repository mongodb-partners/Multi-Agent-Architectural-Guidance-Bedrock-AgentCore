# Logging architecture

> **Audience:** anyone reading or shipping logs from this repo — including incident-response engineers, security reviewers, and AI agents editing the codebase.
>
> **TL;DR.** Every API / agent-runtime / MCP / Streamlit process writes single-line **JSON** to stdout/stderr. Each line carries the W3C **`trace_id`** / **`span_id`** of the active OpenTelemetry span, so a single chat turn can be reconstructed across services in CloudWatch Logs Insights. On EC2, **`amazon-cloudwatch-agent`** tails the file-based service logs into project log groups. There is **no OTLP exporter** and **no collector** — OpenTelemetry runs in-process purely for trace-id correlation.

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

We deliberately **did not** wire OTLP / X-Ray / metrics. Logs + in-process trace IDs are enough to answer 95% of operational questions, and the spans we already emit are hex/W3C-compatible — when ADOT is eventually provisioned, joining logs with traces is a one-line collector config.

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
  UI[Streamlit UI<br/>ui/lib/log.py]
  API[Hono API<br/>api/src/lib/logger.ts<br/>+ otel.ts]
  AR[AgentCore Runtime<br/>api/src/agent-runtime-code.ts<br/>(deployed as ECR image)]
  MCP[MongoDB MCP Runtime<br/>mcp-runtimes/mongodb-mcp/src/lib/logger.ts]
  CWA[amazon-cloudwatch-agent<br/>(EC2)]
  CWG[(CloudWatch Log Groups<br/>/&lt;project&gt;/&lt;env&gt;/{api,ui,mcp,agentcore})]
  AWS[(/aws/bedrock-agentcore/runtimes/*<br/>AWS-managed)]

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

- `X-Trace-Id` from a single `POST /chat` matches the `trace_id` field in **every** log line emitted by that turn — in `/<project>/<env>/api`, in the AgentCore runtime's log group, and in MCP's group.
- The Trace Viewer's `traceId` is a **different** identifier (the `TraceCollector` UUID, persisted in MongoDB `traces`). Both coexist; both are useful. The `TraceCollector` UUID is included on the OTel span as the `trace.collector_id` attribute so they can be joined.

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

Terraform module [`deploy/terraform/modules/cloudwatch/`](../deploy/terraform/modules/cloudwatch/) creates four groups under `/<project>/<env>/`:

| Group | Retention | Source |
|---|---|---|
| `/api` | `api_retention_days` (default **30**) | `multiagent-api.service` → `/var/log/multiagent-api.log` → CW agent |
| `/ui` | `aux_retention_days` (default **7**) | `multiagent-ui.service` → `/var/log/multiagent-ui.log` → CW agent |
| `/mcp` | `aux_retention_days` (default **7**) | Reserved (current MongoDB MCP host is the AgentCore Runtime; its logs live under `/aws/bedrock-agentcore/...`). Useful if you ever run an MCP sidecar on the EC2 host directly. |
| `/agentcore` | `aux_retention_days` (default **7**) | Reserved (AgentCore Runtime logs are AWS-managed at `/aws/bedrock-agentcore/runtimes/<id>/`). |

The 30-day retention on `/api` carries the audit channel — keep it long enough to investigate after-the-fact. The 7-day retention on the placeholders avoids paying for empty groups.

### 8.2 EC2 bootstrap (`deploy/terraform/modules/ec2/user_data.sh`)

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

### 8.3 Local development

`docker compose up --build` does **not** run the CloudWatch agent. Logs stay on stdout in the same JSON shape; tail with `docker compose logs -f api`. The CWA path is EC2-only.

---

## 9. Smoke verification

[`e2e-smoke/post-deploy-smoke.py`](../e2e-smoke/post-deploy-smoke.py) `check_cloudwatch_join`:

1. `POST /chat`, capture `X-Trace-Id` from response headers.
2. Poll `aws logs filter-log-events --log-group-name /<project>/<env>/api --filter-pattern '{ $.trace_id = "<id>" }'` for up to 90 s. Pass when ≥1 match.
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
| [`deploy/terraform/modules/cloudwatch/`](../deploy/terraform/modules/cloudwatch/) | 4 log groups + per-group retention. |
| [`deploy/terraform/modules/ec2/user_data.sh`](../deploy/terraform/modules/ec2/user_data.sh) | Installs CW agent + file-based collectors + logrotate. |
| [`deploy/scripts/deploy-project.sh`](../deploy/scripts/deploy-project.sh) | Post-bootstrap CW-agent + describe-log-streams probes. |
| [`e2e-smoke/post-deploy-smoke.py`](../e2e-smoke/post-deploy-smoke.py) | `check_cloudwatch_join` — verifies `trace_id` appears in `/api` and AgentCore log groups. |
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

## 12. Future work (out of scope today)

- **OTLP exporter** — when an ADOT collector is provisioned, swap `BasicTracerProvider`'s no-op SpanProcessor for `OTLPTraceExporter` in `api/src/lib/otel.ts`. Logs already carry the right IDs.
- **CloudWatch metric filters / alarms** — none defined yet. `channel="audit"` is the seam for future filters.
- **X-Ray correlation** — `trace_id` is already W3C hex, so X-Ray ADOT export joins automatically without further code changes.
- **Log archival to S3** — CloudWatch native retention only for now.
