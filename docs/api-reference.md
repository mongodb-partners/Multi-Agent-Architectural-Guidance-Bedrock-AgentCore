# API Reference

> **Audience:** developers integrating with the API directly, writing tests, or debugging from the command line.

The API is a Hono server (TypeScript on Bun) listening on port `3000`. It exposes JSON endpoints for session management and a Server-Sent Events stream for chat.

**Authentication is mandatory.** The API refuses to boot without `AUTH_JWKS_URI` + `AUTH_ISSUER` (`assertJwksAuthConfigured()` in `api/src/lib/jwt-verify.ts`). Every endpoint except `/health` requires a valid Bearer JWT signed by the configured JWKS pool. There is no `ALLOW_UNAUTHENTICATED` / `REQUIRE_AUTH=false` bypass.

---

## 1. Endpoints summary

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Liveness + dependency status |
| GET | `/health/deep` | Authenticated end-to-end MCP tool-path probe |
| POST | `/chat` | Stream a chat reply (SSE) |
| GET | `/sessions` | List sessions for the calling user |
| GET | `/sessions/:id` | Fetch one session |
| DELETE | `/sessions/:id` | Delete a session |
| GET | `/agents` | List all loaded agents |
| GET | `/agents/:id` | Get one agent's full config |
| POST | `/internal/agents/refresh` | Deploy-only agent config/cache refresh |
| GET | `/skills` | List all loaded skills |
| GET | `/http-tools` | List configured HTTP tools and their environment-bound URLs |
| GET | `/demo-prompts` | Suggested chat prompts from `config/demo-prompts.yaml` |
| GET | `/traces` | List recent traces (sidebar metrics) |
| GET | `/traces/:id` | Fetch one trace document by id |
| GET | `/trace` | Fetch a trace by `sessionId`+`messageId` |
| GET | `/trace/mongo` | Trace projection with only `mongo.*` events |

---

## 2. `GET /health`

Returns liveness + dependency state. Always public (auth bypass).

**Response (production EC2, healthy):**

```json
{
  "status": "ok",
  "version": "0.1.0",
  "timestamp": "2026-05-21T12:00:00.000Z",
  "dependencies": {
    "mongodb": "connected",
    "longTermMemory": "connected",
    "agentcore": "connected",
    "bedrockKnowledgeBase": "connected"
  }
}
```

Each `dependencies.*` value is the result of a **live probe** (or `not_configured` when the env var for that integration is unset). The response does not include config-only fields such as short-term memory backend choice (`SHORT_TERM_MEMORY_BACKEND`) or MCP hosting topology — use env / `deploy-manifest.json` for that.

| Field | Possible values | Meaning |
|---|---|---|
| `mongodb` | `connected` / `unreachable` / `not_configured` | Atlas ping via `MONGODB_URI` |
| `longTermMemory` | `connected` / `unreachable` / `not_configured` / `no_agents` | Mongo reachable and ≥1 agent has `memory.longTerm: true` |
| `agentcore` | `connected` / `inactive` / `unreachable` / `not_configured` | AgentCore Memory probe (`ListSessions` on a synthetic actor). `connected` includes the expected `ResourceNotFoundException` for the fake actor (API round-trip succeeded). `inactive` = `AGENTCORE_MEMORY_STORE_ID` is set but the store is not `ACTIVE` (provisioning or deleting). |
| `mcpServer` | `connected` / `unreachable` (optional) | Only present when the request includes a valid `Authorization: Bearer` JWT. Probes Gateway MCP via `listTools` (`AGENTCORE_GATEWAY_URL`). Omitted on unauthenticated `/health` because the Gateway requires JWT — use chat smoke or call `/health` with a Cognito token to probe MCP. |
| `bedrockKnowledgeBase` | `connected` / `not_configured` / `unreachable` | `BEDROCK_KB_ID` set and a minimal Bedrock Agent Runtime `Retrieve` probe returns `{ status: "ok" }`. `unreachable` usually means IAM (`bedrock-agent-runtime:Retrieve` on the KB ARN) or KB not `ACTIVE` — check API logs for `[health] bedrock KB probe`. |

Returns `503` with `status: degraded` when `mongodb` is `unreachable` only. Other dependencies may be `unreachable` or `inactive` while `status` stays `ok` (informational; does not fail liveness).

---

## 2b. `GET /health/deep`

Authenticated end-to-end probe of the **MCP tool path**. Issues a real `mongodb_query` (`products.findOne`) through the AgentCore Gateway — the same code path a chat-driven tool call takes, but without an LLM. Used by the deploy-time smoke (Phase 9a3) so a broken MCP runtime / Gateway target wiring fails the deploy with a precise diagnosis before the LLM-dependent chat smoke runs.

**Auth:** requires a Bearer JWT (same Cognito pool as the rest of the API). Unlike `/health`, this route is **not** public — without a token the Gateway authorizer rejects the call.

**Response (connected):**

```json
{
  "mcpProbe": "connected",
  "latencyMs": 142,
  "gatewayUrl": "https://...gateway.../mcp"
}
```

| Field | Possible values | Meaning |
|---|---|---|
| `mcpProbe` | `connected` / `unreachable` / `timeout` | Outcome of the live `mongodb_query` round-trip via Gateway MCP |
| `latencyMs` | number | Probe round-trip duration |
| `gatewayUrl` | string | Resolved MCP server / Gateway URL that was probed |
| `error` | string (optional) | Failure detail when `mcpProbe` is not `connected` |

Status codes:

- `200` when `mcpProbe === "connected"`.
- `503` when the probe is `unreachable` / `timeout`.
- `401` (with `mcpProbe: "unreachable"`) when no Bearer token is supplied.

---

## 3. `POST /chat` — the main endpoint

Streams an assistant reply as Server-Sent Events.

**Request:**

```http
POST /chat HTTP/1.1
Content-Type: application/json
Accept: text/event-stream

{
  "message": "Where is my order ORD-1234?",
  "sessionId": "session-abc-123",
  "agentId": "orchestrator"
}
```

| Field | Required | Notes |
|---|---|---|
| `message` | yes | The user's question |
| `sessionId` | yes | Any string ≥ 1 char. The API pads it to ≥ 33 chars internally before invoking AgentCore (runtime session-id requirement). |
| `agentId` | no | Default: in-API classifier picks the specialist (heuristic + Haiku fallback). Pass an explicit specialist id (e.g. `troubleshooting`) to bypass classification, or `orchestrator` to force the in-API classifier path even when an upstream caller pinned a different agent. When `USE_ORCHESTRATOR_RUNTIME=1`, every request goes through the orchestrator runtime regardless of this field. |

**Response:** `text/event-stream` with a sequence of named events.

### SSE event types

| Event | Payload | When |
|---|---|---|
| `agent_info` | `{agentId, agentName}` | Once at start of the response |
| `stream` | `ChatStreamPart` JSON (`{type: "token" \| "tool_call" \| "skill_loaded" \| ...}`) | One per streamed part forwarded from the specialist runtime. The runtime container emits `event: stream` per SSE frame; the API forwards verbatim. **Multi-specialist orchestration:** `token` parts may include `phase: "specialist" \| "synthesis"` plus `specialistId`, `specialistName`, `rank`. `phase: "specialist"` tokens are draft fragments streamed live from each specialist (NOT persisted). `phase: "synthesis"` tokens are the final cohesive answer (the only tokens persisted to `chat_sessions.messages`). On the single-specialist fast path no `phase` field is set and the specialist's tokens are themselves persisted. |
| `token` | `{text}` | Legacy event — still emitted in local-dev / stub paths and by `swarm-chat-stream.ts`. AgentCore Runtime path emits `stream` instead. |
| `skill_loaded` | `{skillName}` | When the agent activates a skill |
| `tool_call` | `{tool, status}` | When a tool is invoked. `status` is `started` / `completed` / `failed` |
| `agent_active` | `{agentId, agentName}` | When orchestration switches active agent (Swarm mode only) |
| `handoff` | `{from, to, label}` | When the in-API classifier (or orchestrator) routes to a specialist |
| `trace` | `{id, ts, type, parentId?, agentId?, durationMs?, payload}` | Per emitted trace event (gated by `TRACING_ENABLED`, default `1`). `model.text_delta_batch` trace forwarding is throttled to `TRACE_SSE_THROTTLE_MS` (default 100 ms) to keep the trace channel from contending with token frames; the full batch still lands in the persisted trace. See [Trace event types](#trace-event-types). |
| `error` | `{code, message, requestId}` | Terminal failure. Followed by `done`. |
| `done` | `{sessionId, messageId, traceId?, error?}` | Always emitted last. `traceId` set when tracing is enabled. |

**Example: order tracking question (default path — in-API classifier → AgentCore Runtime, true SSE streaming)**

```
event: agent_info
data: {"agentId": "order-management", "agentName": "Order Management Agent"}

event: handoff
data: {"from": "orchestrator", "to": "order-management", "label": "classifier:heuristic"}

event: stream
data: {"type": "token", "text": "Your order "}

event: stream
data: {"type": "token", "text": "ORD-1234 is currently in transit"}

event: stream
data: {"type": "tool_call", "tool": "mongodb_query", "status": "started"}

event: stream
data: {"type": "tool_call", "tool": "mongodb_query", "status": "completed"}

event: stream
data: {"type": "token", "text": " and is expected to arrive on 2026-05-04."}

event: done
data: {"sessionId": "session-abc-123", "messageId": "msg_a1b2c3d4e5f6", "traceId": "..."}
```

**Example: troubleshooting question (Path B — Strands Swarm in local dev)**

```
event: agent_info
data: {"agentId": "orchestrator", "agentName": "Orchestrator Agent"}

event: agent_active
data: {"agentId": "orchestrator", "agentName": "Orchestrator Agent"}

event: token
data: {"text": "I see you have error PWR-001. "}

event: handoff
data: {"from": "orchestrator", "to": "troubleshooting", "label": "PWR-001"}

event: agent_active
data: {"agentId": "troubleshooting", "agentName": "Troubleshooting Agent"}

event: tool_call
data: {"tool": "bedrock_kb_retrieve", "status": "started"}

event: tool_call
data: {"tool": "bedrock_kb_retrieve", "status": "completed"}

event: token
data: {"text": "PWR-001 indicates a power supply issue. "}

event: token
data: {"text": "First, verify the wall outlet is working by..."}

event: done
data: {"sessionId": "session-abc-123", "messageId": "msg_..."}
```

### Error format (terminal stream failure)

```
event: error
data: {"code": "AGENTCORE_RUNTIME_ERROR", "message": "...", "requestId": "..."}

event: done
data: {"sessionId": "session-abc-123", "messageId": "msg_...", "error": {"code": "AGENTCORE_RUNTIME_ERROR", "message": "..."}}
```

Common error codes:

| Code | Cause |
|---|---|
| `INVALID_REQUEST` | Body parse / Zod validation failed (HTTP 400) |
| `AGENT_NOT_FOUND` | `agentId` doesn't match any loaded config (HTTP 404) |
| `AGENTCORE_RUNTIME_ERROR` | InvokeAgentRuntime failed (terminal SSE) |
| `STREAM_EXCEPTION` | Unexpected exception in Strands path (terminal SSE) |
| `TOOL_FAILED` | A tool call returned an error (non-terminal — sent as `tool_call` with status `failed`) |

### Curl example

```bash
curl -N -X POST http://localhost:3000/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "Where is my order ORD-1234?", "sessionId": "test-001"}'
```

### Python example

```python
import requests

with requests.post(
    "http://localhost:3000/chat",
    json={"message": "Where is my order ORD-1234?", "sessionId": "test-001"},
    stream=True,
    headers={"Accept": "text/event-stream"},
) as r:
    for line in r.iter_lines(decode_unicode=True):
        if line.startswith("event:"):
            event = line.split(":", 1)[1].strip()
        elif line.startswith("data:"):
            data = line.split(":", 1)[1].strip()
            print(event, data)
```

---

## 4. `GET /sessions`

Lists sessions for the calling user.

Filters by JWT `sub` claim — returns only sessions owned by the caller. Sessions persisted before user scoping was wired (no `userId` on the document) are treated as legacy and remain visible to any authenticated caller; new sessions always carry a `userId`. Persistence: in deployed AWS, short-term memory is AgentCore-backed; when `MONGODB_URI` is set, sessions are also mirrored to the `chat_sessions` collection for the Sessions page, audit/debug history, and cold-read fallback (opt out with `PERSIST_CHAT_SESSIONS=0`).

**Response:**

```json
{
  "sessions": [
    {
      "sessionId": "session-abc-123",
      "userId": "abc-123",
      "createdAt": "2026-05-01T13:42:11Z",
      "updatedAt": "2026-05-01T13:48:32Z",
      "messageCount": 6
    }
  ]
}
```

Sorted newest activity first.

---

## 5. `GET /sessions/:id`

Fetches a single session with all messages.

**Response:**

```json
{
  "sessionId": "session-abc-123",
  "userId": "abc-123",
  "createdAt": "2026-05-01T13:42:11Z",
  "messages": [
    {
      "id": "msg_a1b2c3d4",
      "role": "user",
      "content": "Where is my order ORD-1234?",
      "timestamp": "2026-05-01T13:42:11Z"
    },
    {
      "id": "msg_e5f6g7h8",
      "role": "assistant",
      "content": "Your order ORD-1234 is in transit...",
      "timestamp": "2026-05-01T13:42:14Z",
      "agentId": "order-management"
    }
  ]
}
```

`404` if not found. For cross-user access attempts in auth mode, API intentionally returns `404` (not `403`) to avoid resource enumeration.

---

## 6. `DELETE /sessions/:id`

Deletes a session. Idempotent (404 if already gone).

If auth is on and the session belongs to another user, API returns `404` for the same anti-enumeration reason.

---

## 7. `GET /agents`

Returns all loaded agent configs (parsed from `config/agents/*.agent.md`).

```json
{
  "agents": [
    {
      "id": "orchestrator",
      "name": "Orchestrator Agent",
      "model": "us.anthropic.claude-haiku-4-5-20251001-v1:0",
      "tools": ["..."],
      "skills": ["..."],
      "memory": {"shortTerm": true, "longTerm": false}
    }
  ]
}
```

`GET /agents/:id` returns one agent including the system prompt body.

---

## 8. `POST /internal/agents/refresh`

Deploy-only endpoint used by `deploy/deploy-agents.sh` after AgentCore runtime updates. It lets the API pick up agent add/update/delete changes without rebuilding the API image or restarting `multiagent-api`.

Auth requirements:
- Valid Bearer JWT, same as other protected endpoints.
- `X-Agent-Config-Refresh-Token` matching `AGENT_CONFIG_REFRESH_TOKEN` in `.env.live`.

Request body:

```json
{
  "files": {
    "agents/order-management.agent.md": "...",
    "skills/order-management/SKILL.md": "..."
  },
  "specialistArns": {
    "order-management": "arn:aws:bedrock-agentcore:..."
  }
}
```

The API writes the snapshot to an internal runtime config directory, switches `resolveConfigRoot()` to that snapshot, refreshes the specialist ARN override map, clears agent/config/classifier/template/skill caches, refreshes HTTP tools, and pre-warms agent templates.

This endpoint is not intended for UI use.

---

## 9. `GET /skills`

Returns all loaded skills with their tool counts:

```json
{
  "skills": [
    {
      "name": "order-management",
      "description": "...",
      "scriptCount": 1,
      "referenceCount": 2,
      "httpTools": [
        {"name": "calculate_shipping", "urlConfigured": true}
      ]
    }
  ]
}
```

---

## 10. `GET /http-tools`

Returns the HTTP tool registry — useful for debugging which tool URLs are wired vs unset.

This endpoint only reports **configured HTTP tools** (root `config/http-tools.json` and per-skill `config/skills/<skill>/http-tools.json`). It does not list MongoDB MCP tools, Bedrock tools, `read_skill_resource`, `run_skill_script`, or internal helpers. For the complete developer catalog, see [`reference/tools.md`](reference/tools.md).

```json
{
  "globalTools": [
    {"name": "...", "urlConfigured": false}
  ],
  "skillTools": [
    {
      "skill": "order-management",
      "tools": [
        {"name": "calculate_shipping", "urlConfigured": true}
      ]
    }
  ]
}
```

When `HTTP_TOOLS_MOCK=1`, all tools return mock payloads regardless of `urlConfigured`.

---

## 11. Authentication

JWKS auth is **always required** — the API refuses to start without `AUTH_JWKS_URI` + `AUTH_ISSUER`.

- Every protected request needs `Authorization: Bearer <jwt>`.
- JWT signature, `iss`, and `exp` are verified using `jose`. Optional `AUTH_APP_CLIENT_ID` validates `aud`/`client_id`. `AUTH_TOKEN_USE` controls whether `token_use` must equal `access` or `id`.
- The decoded JWT `sub` claim becomes the `userId` used for session ownership and long-term memory keying.

Public routes that bypass the gate: `GET /health`.

Errors: `401 UNAUTHORIZED` for missing or malformed Authorization header; `401 INVALID_TOKEN` for tokens that fail verification.

---

## 12. Rate limiting

| Variable | Default | Purpose |
|---|---|---|
| `RATE_LIMIT_PER_MIN` | `60` | Per-IP (or per-token) requests per minute |
| `RATE_LIMIT_DISABLED` | unset | Set to `1` to disable rate limiting entirely |

`429 RATE_LIMITED` when exceeded.

---

## 13. Headers and middleware

- `X-Request-Id` — generated per-request unless the caller sends a valid inbound `X-Request-Id` (alphanumeric, `_`, `-`, 1–64 chars). Echoed on every response; use with support tickets.
- `X-Trace-Id` — W3C trace id (32 hex chars) for the HTTP server span on routes that run OpenTelemetry middleware (skipped for lightweight `GET`s such as `/health`, `/agents`, `/traces`, etc.). **Distinct** from the persisted product `traceId` in SSE `done` / MongoDB `traces` — both are useful: `X-Trace-Id` joins API access logs and CloudWatch journald streams; product `traceId` joins the Trace Viewer.
- `traceparent` / `tracestate` — optional inbound W3C context; the API continues the trace when present. Outbound MCP and AgentCore calls inject `traceparent` when a span is active.
- `Access-Control-Allow-Origin` — set per `CORS_ORIGINS` env var or `config/environment.yaml`. Exposed headers include `X-Request-Id`, `X-Trace-Id`, `traceparent`, `tracestate`.
- Structured log lines (`api/src/lib/logger.ts`) include `trace_id` / `span_id` / `trace_flags` when inside an active span, plus `service` from `OTEL_SERVICE_NAME`.

---

## 14. Tracing endpoints

When `TRACING_ENABLED=1` (default), every `POST /chat` turn produces a `Trace`
document with one `TraceEvent` per discrete step (model request, tool call,
MongoDB op, handoff decision, etc.). Traces are persisted to MongoDB
(`traces` collection with a TTL index — see `TRACE_TTL_DAYS`, default 30)
plus an in-process ring buffer (`TRACE_RING_BUFFER_SIZE`, default 100).

### `GET /traces/:traceId[?include=core|dev|full]`

Fetch a trace. Returns 404 when not found or the calling user doesn't own it
(auth ownership: if `trace.userId` is set, the caller's JWT `sub` must match).

`?include=` controls server-side projection — see `api/src/lib/trace-projection.ts`:

| Mode | Behavior | Used by |
|---|---|---|
| `full` (default, back-compat) | Identity — full trace document. | `e2e-smoke/verify-trace-ui-shape.py`, external callers. |
| `core` | Strips heavy debug payload fields into `{ _omittedForCoreMode: true, bytesAvailable: N, wasRedacted? }` sentinels; drops dev-only event types (`dev.environment`, `dev.byte_cap_hit`, `model.retry`, `agentcore.retry`, `model.text_delta_batch`, `latency.checkpoint`); removes dev-only top-level fields (`release`, `correlation`, `otel`, `spanTree`). All `mongo.*` payload fields (query filter/pipeline/projection/sort, result sampleDocs, vector_search filter/queryVectorPreview/documentPreviews including nested fields) stay visible — the summary MongoDB dashboard renders them inline; `mongo.vector_search.documentPreviews` is independently capped to the top-3 entries. | Streamlit Trace Viewer initial load. |
| `dev` | Identity, including dev-only fields. | Streamlit Trace Viewer "Developer details" on-demand fetch. |

Every response sets `X-Trace-Include: core|dev|full` so the UI can
assert the projection round-tripped. The UI `api_client.get_trace` raises if
the header doesn't match the requested mode. The audit log channel records
`[trace] fetch` with the `include` field for SOC2 review.

### `GET /trace?sessionId=…&messageId=…[&include=core|dev|full]`

Same as above, looked up by `(sessionId, messageId)`. Useful when the UI
only has the message id from a session listing.

### `GET /trace/mongo?traceId=…` (or `?sessionId=…&messageId=…`)

Trace projection containing only the `mongo.*` events. Cheaper to render
than the full document when the dashboard only needs the MongoDB panel.

### `GET /traces?limit=25[&sessionId=…][&excludeTraceId=…]`

Recent traces visible to the caller. Used by the sidebar's "Live metrics"
block to compute aggregate cost / latency / token totals.

Optional filters:

* `?sessionId=…` — restrict to a single session. Powers the Trace Viewer's
  prev/next-turn-in-session arrows. Over-fetches `4 × limit` server-side
  then filters; capped at 500.
* `?excludeTraceId=…` — drop a specific trace from the list (the UI uses
  this to omit the currently displayed turn from "Other turns in this
  session").

#### Trace event types

The full discriminated union is defined in [`api/src/lib/trace-types.ts`](../api/src/lib/trace-types.ts).
Highlights:

| Type | Meaning |
|---|---|
| `chat.turn.start` / `chat.turn.end` | Boundary of a single user turn |
| `auth.context_build` | Authenticated user context resolution |
| `memory.scoped_read` / `memory.shared_read` | Long-term memory read into the system prompt. The `scoped_read` payload now carries hybrid-retrieval enrichments (`mode`, `embeddingSource`, `embeddingModel`, `retrieval.{topK, fetchK, vectorHits, lexicalHits, rrfMergedCount, perCollection[]}`) so the Trace Viewer can show what was fused. Event names preserved for UI compat. |
| `memory.long_term_write` / `memory.long_term_skip` | Long-term memory write outcome. `long_term_write` now reports `op: "bulkWrite"`, plus `duplicatesSkipped`, `embeddedCount`, and `embeddingModel` for vector-aware persistence. |
| `prompt.assembled` | Final system prompt (persona + memory + skills) |
| `model.request` / `model.usage` / `model.stop` | Bedrock model call boundary + token usage |
| `model.text_delta_batch` / `model.thinking_block` | Token stream and stripped XML thinking blocks |
| `skill.activated` | A skill was loaded into the agent's prompt |
| `tool.call` | A generic Strands tool invocation (`phase: "start"` / `"end"`) |
| `tool.http` / `tool.mcp` | Specialised tool events for HTTP- and MCP-flavoured tools |
| `handoff.decision` | Orchestrator → specialist routing decision (with attribution). Single-handoff legacy path. |
| `orchestrator.multi_route_decision` | Multi-specialist routing decision: selected specialists (ordered), rejected candidates with reasons, classifier thresholds, source (`heuristic` / `haiku` / `cache` / `mixed`), and `pathTaken: "single" \| "synthesis"`. Emitted exactly once per orchestrator turn. |
| `orchestrator.specialist_draft` | One per specialist invocation: `{ agentId, agentName, status: "final"\|"draft"\|"failed"\|"empty", answerByteCount, answerPreview?, latencyMs, runtimeSpanId?, failureMessage?, failureStack? }`. The `answerPreview`, `runtimeSpanId`, `failureStack` fields are stripped in the `core` projection (visible only in `?include=dev`). |
| `orchestrator.synthesis` | Synthesizer agent summary: `{ modelId, inputSpecialists, omittedSpecialists, outputByteCount, latencyMs, persistedAsFinal }`. Emitted only when 2+ specialists ran. The Bedrock call inside synthesis is tagged `agentId: "synthesizer"` for cost attribution (the persisted assistant message itself remains tagged `agentId: "orchestrator"`). |
| `agent.activate` | A node became active in the Swarm graph |
| `mongo.*` | MongoDB intent / query / plan / result / diagnostic / vector_search / schema. `mongo.vector_search` includes query-vector preview, score summary/histogram, and compact `documentPreviews[]` metadata for the retrieved source documents, including native Mongo `_id` when present; Streamlit uses those previews for chat-side source pills and the Trace Viewer vector panel. |
| `agentcore.invoke` / `agentcore.nested_trace` / `agentcore.classification` | AgentCore Runtime hops (with nested-trace splicing). `agentcore.invoke` carries `responseBody` + `requestHeadersPreview` / `responseHeadersPreview` for the Developer details panel. |
| `dev.environment` | One-shot snapshot of the runtime env knobs (`chatMode`, `devMockBackends`, `mongoConfigured`, `voyageConfigured`, `logLevel`, …). Emitted once per turn by `chat.ts`. Powers the Developer details Environment sub-section. |
| `dev.byte_cap_hit` | Emitted when a payload was trimmed by the per-event or per-turn byte cap. Carries `{ droppedType, bytes, reason: "per_event" \| "per_turn" }`. Capped at 50 emissions per turn to prevent spam. |
| `model.retry` / `agentcore.retry` | One event per retry attempt with `attempt`, `previousErrorClass`, `backoffMs`. Powers the Developer details Retries sub-section. |
| `error` | Surfaced as a child event with `parentId` pointing to the failing span |

Top-level trace document fields (alongside `events[]` + `summary`):

| Field | Meaning |
|---|---|
| `release` | `{ gitSha, imageTag?, env }` — release metadata for the Developer details Identifiers section. |
| `correlation` | `{ requestId, userAgent?, clientIp? }` — request correlation IDs. |
| `otel` | `{ traceId, rootSpanId }` — OTel trace + span IDs used to deep-link to CloudWatch ServiceLens / X-Ray. |
| `spanTree` | Hierarchical `{ id, type, ts, durationMs, agentId?, children[] }` array, pre-computed at finalize time so the UI doesn't have to reconstruct from `parentId`. |
| `truncated` / `eventsDropped` | Byte-cap status — set when the per-turn cap fired. |

Env knobs:

- `TRACING_ENABLED` (default `1`)
- `TRACE_TTL_DAYS` (default `30`)
- `TRACE_RING_BUFFER_SIZE` (default `100`)
- `TRACE_MAX_TURN_BYTES` (default `2 097 152`) — soft cap; protected events still emit
- `TRACE_MAX_EVENT_BYTES` (default `16 384`)
- `TRACE_REDACT` (default `0`) — scrub PII keys
- `MEMORY_TRACE_VALUES` (default `0`) — include actual fact strings in `memory.*` payloads
- `MONGO_TRACE_DIAGNOSTIC` / `MONGO_TRACE_EXPLAIN` — opt-in for empty-result analysis
- `AGENTCORE_NESTED_TRACE_MAX_BYTES` — cap nested events returned by runtime container

---

## 15. Critical files reference

| File | Purpose |
|---|---|
| [`api/src/routes/chat.ts`](../api/src/routes/chat.ts) | `POST /chat` (the main route) |
| [`api/src/routes/sessions.ts`](../api/src/routes/sessions.ts) | `/sessions` endpoints |
| [`api/src/routes/trace.ts`](../api/src/routes/trace.ts) | Trace fetch routes |
| [`api/src/routes/health.ts`](../api/src/routes/health.ts) | `/health` |
| [`api/src/routes/agents.ts`](../api/src/routes/agents.ts) | `/agents` introspection |
| [`api/src/routes/agent-config-refresh.ts`](../api/src/routes/agent-config-refresh.ts) | Deploy-only `/internal/agents/refresh` cache/config refresh |
| [`api/src/lib/trace-types.ts`](../api/src/lib/trace-types.ts) | `TraceEvent` discriminated union (source of truth) |
| [`api/src/lib/trace-collector.ts`](../api/src/lib/trace-collector.ts) | Per-turn collector, byte-cap, cost summary, nested splice |
| [`api/src/lib/trace-store.ts`](../api/src/lib/trace-store.ts) | Ring buffer + MongoDB persistence |
| [`api/src/lib/chat-stream-types.ts`](../api/src/lib/chat-stream-types.ts) | TypeScript types for SSE events |
| [`api/src/middleware/`](../api/src/middleware/) | Auth, rate limit, CORS, access log |
