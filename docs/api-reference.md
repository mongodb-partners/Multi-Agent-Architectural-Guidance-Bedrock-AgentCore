# API Reference

> **Audience:** developers integrating with the API directly, writing tests, or debugging from the command line.

The API is a Hono server (TypeScript on Bun) listening on port `3000`. It exposes JSON endpoints for session management and a Server-Sent Events stream for chat.

By default, **no authentication is required**. Set `REQUIRE_AUTH=true` (with `AUTH_JWKS_URI` + `AUTH_ISSUER`) to require a valid JWT on every endpoint except `/health`.

---

## 1. Endpoints summary

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Liveness + dependency status |
| POST | `/chat` | Stream a chat reply (SSE) |
| GET | `/sessions` | List sessions for the calling user |
| GET | `/sessions/:id` | Fetch one session |
| DELETE | `/sessions/:id` | Delete a session |
| GET | `/agents` | List all loaded agents |
| GET | `/agents/:id` | Get one agent's full config |
| GET | `/skills` | List all loaded skills |
| GET | `/http-tools` | List configured HTTP tools and their environment-bound URLs |
| GET | `/demo-prompts` | Suggested chat prompts from `config/demo-prompts.yaml` (public) |
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
  "version": "...",
  "uptime": 12345,
  "dependencies": {
    "mongodb": "connected",
    "longTermMemory": "connected",
    "chatSessions": "memory",
    "toolHosting": "lambda",
    "agentcore": "connected",
    "mcpServer": "connected",
    "bedrockKnowledgeBase": "connected"
  }
}
```

| Field | Possible values | Meaning |
|---|---|---|
| `mongodb` | `connected` / `unavailable` | Real Mongo ping result |
| `longTermMemory` | `connected` / `unavailable` / `mongodb` / `agentcore` | Long-term memory backend status |
| `chatSessions` | `memory` / `mongodb` / `agentcore` / `unavailable` | Where short-term sessions live |
| `toolHosting` | `lambda` / `gateway` / `direct` | Tool execution mode (per `TOOL_HOSTING_MODE`) |
| `agentcore` | `connected` / `unreachable` / `not_configured` | AgentCore SDK probe (`ListSessions`) |
| `mcpServer` | `connected` / `unreachable` / `not_configured` | Lambda MCP probe |
| `bedrockKnowledgeBase` | `connected` / `not_configured` | KB ID present + reachable |

Returns `503` with `status: degraded` if `mongodb` is `unreachable` or `chatSessions` is `unavailable` while session persistence is enabled (default when `MONGODB_URI` is set; opt out with `PERSIST_CHAT_SESSIONS=0`).

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
| `sessionId` | yes | Any string. The API keys session state to this. |
| `agentId` | no | Default: `orchestrator`. Direct addressing of a specialist (e.g. `troubleshooting`) is allowed — bypasses orchestration. |

**Response:** `text/event-stream` with a sequence of named events.

### SSE event types

| Event | Payload | When |
|---|---|---|
| `agent_info` | `{agentId, agentName}` | Once at start of the response |
| `token` | `{text}` | Each token (in-process Strands) or one burst (AgentCore Runtime) |
| `skill_loaded` | `{skillName}` | When the agent activates a skill |
| `tool_call` | `{tool, status}` | When a tool is invoked. `status` is `started` / `completed` / `failed` |
| `agent_active` | `{agentId, agentName}` | When orchestration switches active agent (Swarm mode only) |
| `handoff` | `{from, to, label}` | When orchestrator routes to a specialist |
| `trace` | `{id, ts, type, parentId?, agentId?, durationMs?, payload}` | Per emitted trace event (gated by `TRACING_ENABLED`, default `1`). See [Trace event types](#trace-event-types). |
| `error` | `{code, message, requestId}` | Terminal failure. Followed by `done`. |
| `done` | `{sessionId, messageId, traceId?, error?}` | Always emitted last. `traceId` set when tracing is enabled. |

**Example: order tracking question (Path A — AgentCore Runtime)**

```
event: agent_info
data: {"agentId": "orchestrator", "agentName": "Orchestrator Agent"}

event: token
data: {"text": "Your order ORD-1234 is currently in transit and is expected to arrive on 2026-05-04. Tracking number: ..."}

event: handoff
data: {"from": "orchestrator", "to": "order-management", "label": ""}

event: done
data: {"sessionId": "session-abc-123", "messageId": "msg_a1b2c3d4e5f6"}
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

- If `REQUIRE_AUTH=true`: filters by JWT `sub` claim. Returns only sessions owned by the caller plus sessions with no `userId`.
- If auth is off: returns all sessions in process memory (or MongoDB when session persistence is enabled — default when `MONGODB_URI` is set; opt out with `PERSIST_CHAT_SESSIONS=0`).

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
      "model": "us.anthropic.claude-sonnet-4-6",
      "tools": ["..."],
      "skills": ["..."],
      "memory": {"shortTerm": true, "longTerm": false}
    }
  ]
}
```

`GET /agents/:id` returns one agent including the system prompt body.

---

## 8. `GET /skills`

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

## 9. `GET /http-tools`

Returns the HTTP tool registry — useful for debugging which tool URLs are wired vs unset.

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

## 10. Authentication

When `REQUIRE_AUTH=true`:

- Every request needs `Authorization: Bearer <jwt>`.
- If `AUTH_JWKS_URI` + `AUTH_ISSUER` are set, JWT signature, `iss`, and `exp` are verified using `jose`. Optional `AUTH_APP_CLIENT_ID` validates `aud`/`client_id`. `AUTH_TOKEN_USE` controls whether `token_use` must equal `access` or `id`.
- In Cognito mode, API uses JWT `sub` as `userId` and resolves email/profile for auth-context-aware routing/personalization.
- If JWKS vars are unset, any non-empty Bearer token is accepted (development only — never use in production).
- The decoded JWT `sub` claim becomes the `userId` used for session ownership and long-term memory keying.

`401 INVALID_TOKEN` if verification fails.

---

## 11. Rate limiting

| Variable | Default | Purpose |
|---|---|---|
| `RATE_LIMIT_PER_MIN` | `60` | Per-IP (or per-token) requests per minute |
| `RATE_LIMIT_DISABLED` | unset | Set to `1` to disable rate limiting entirely |

`429 RATE_LIMITED` when exceeded.

---

## 12. Headers and middleware

- `X-Request-ID` — generated per-request, echoed in error payloads. Use this when reporting issues.
- `Access-Control-Allow-Origin` — set per `CORS_ORIGINS` env var or `config/environment.yaml`.
- All log lines include `requestId` for correlation.

---

## 13. Tracing endpoints

When `TRACING_ENABLED=1` (default), every `POST /chat` turn produces a `Trace`
document with one `TraceEvent` per discrete step (model request, tool call,
MongoDB op, handoff decision, etc.). Traces are persisted to MongoDB
(`traces` collection with a TTL index — see `TRACE_TTL_DAYS`, default 30)
plus an in-process ring buffer (`TRACE_RING_BUFFER_SIZE`, default 100).

### `GET /traces/:traceId`

Fetch a complete trace. Returns 404 when not found or the calling user
doesn't own it (auth ownership: if `trace.userId` is set, the caller's JWT
`sub` must match).

### `GET /trace?sessionId=…&messageId=…`

Same as above, looked up by `(sessionId, messageId)`. Useful when the UI
only has the message id from a session listing.

### `GET /trace/mongo?traceId=…` (or `?sessionId=…&messageId=…`)

Trace projection containing only the `mongo.*` events. Cheaper to render
than the full document when the dashboard only needs the MongoDB panel.

### `GET /traces?limit=25`

Recent traces visible to the caller. Used by the sidebar's "Live metrics"
block to compute aggregate cost / latency / token totals.

#### Trace event types

The full discriminated union is defined in [`api/src/lib/trace-types.ts`](../api/src/lib/trace-types.ts).
Highlights:

| Type | Meaning |
|---|---|
| `chat.turn.start` / `chat.turn.end` | Boundary of a single user turn |
| `auth.context_build` | Authenticated user context resolution |
| `memory.scoped_read` / `memory.shared_read` | Long-term memory read into the system prompt |
| `memory.long_term_write` / `memory.long_term_skip` | Long-term memory write outcome |
| `prompt.assembled` | Final system prompt (persona + memory + skills) |
| `model.request` / `model.usage` / `model.stop` | Bedrock model call boundary + token usage |
| `model.text_delta_batch` / `model.thinking_block` | Token stream and stripped XML thinking blocks |
| `skill.activated` | A skill was loaded into the agent's prompt |
| `tool.call` | A generic Strands tool invocation (`phase: "start"` / `"end"`) |
| `tool.http` / `tool.mcp` | Specialised tool events for HTTP- and MCP-flavoured tools |
| `handoff.decision` | Orchestrator → specialist routing decision (with attribution) |
| `agent.activate` | A node became active in the Swarm graph |
| `mongo.*` | MongoDB intent / query / plan / result / diagnostic / vector_search / schema |
| `agentcore.invoke` / `agentcore.nested_trace` / `agentcore.classification` | AgentCore Runtime hops (with nested-trace splicing) |
| `error` | Surfaced as a child event with `parentId` pointing to the failing span |

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

## 14. Critical files reference

| File | Purpose |
|---|---|
| [`api/src/routes/chat.ts`](../api/src/routes/chat.ts) | `POST /chat` (the main route) |
| [`api/src/routes/sessions.ts`](../api/src/routes/sessions.ts) | `/sessions` endpoints |
| [`api/src/routes/trace.ts`](../api/src/routes/trace.ts) | Trace fetch routes |
| [`api/src/routes/health.ts`](../api/src/routes/health.ts) | `/health` |
| [`api/src/routes/agents.ts`](../api/src/routes/agents.ts) | `/agents` introspection |
| [`api/src/lib/trace-types.ts`](../api/src/lib/trace-types.ts) | `TraceEvent` discriminated union (source of truth) |
| [`api/src/lib/trace-collector.ts`](../api/src/lib/trace-collector.ts) | Per-turn collector, byte-cap, cost summary, nested splice |
| [`api/src/lib/trace-store.ts`](../api/src/lib/trace-store.ts) | Ring buffer + MongoDB persistence |
| [`api/src/lib/chat-stream-types.ts`](../api/src/lib/chat-stream-types.ts) | TypeScript types for SSE events |
| [`api/src/middleware/`](../api/src/middleware/) | Auth, rate limit, CORS, access log |
