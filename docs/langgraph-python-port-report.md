# Porting to LangChain / LangGraph (Python) — Change Report

**Subject:** Re-creating the exact functionality of this project on LangGraph + Python
**Current stack:** Bun + Hono + Strands Agents TypeScript SDK, Streamlit UI, Bedrock AgentCore, MongoDB Atlas
**Date:** 2026-07-29

---

## 1. Verdict up front

The port is **large but bounded**. Roughly 19k lines of TypeScript under `api/src` plus a 2.9k-line seeding
suite move to Python. The Streamlit UI (~6.5k lines) and the MongoDB MCP runtime do **not** need to move.

Three facts shape the whole plan:

1. **The SSE wire contract is the API/UI boundary.** `ui/lib/api_client.py` parses named SSE events
   (`agent_info`, `agent_active`, `token`, `handoff`, `tool_call`, `skill_loaded`, `trace`, `done`,
   `error`) and the persisted trace JSON shape. Preserve those byte-for-byte and the entire UI is a
   zero-change deliverable. Break them and you inherit a second 6.5k-line port.
2. **LangGraph absorbs real work.** The ReAct loop, checkpointed short-term memory, and MCP tool
   binding are library features here but hand-written today. Expect a **net reduction** of ~4–6k lines.
3. **The trace subsystem has no equivalent** in LangGraph and must be ported near-verbatim. It is the
   single largest and least mechanical piece of the job (~2.1k lines across collector + types +
   projection + store).

---

## 2. What does NOT change

| Area | Why it survives untouched |
|---|---|
| `ui/` — Streamlit app, Trace Viewer, Sessions, chat panel | Already Python. Consumes the API over HTTP/SSE only. Zero code change if the contract holds. |
| `mcp-runtimes/mongodb-mcp/` — Node MCP server | Reached over the wire via AgentCore Gateway (`mcpServer` target, Streamable-HTTP). Language-agnostic. Rewriting it in Python buys nothing. |
| `config/agents/*.agent.md`, `config/skills/*/SKILL.md` | The whole point of the framework is that these are data, not code. Frontmatter schema is unchanged. |
| MongoDB collections, Atlas Search / vector index definitions | Aggregation pipelines are driver-agnostic. |
| Terraform modules (structure) | Only variable *values* change — see §7. |
| `e2e-smoke/` | Already Python (`post-deploy-smoke.py`, `multi-specialist-smoke.py`, etc.). |

---

## 3. Agent framework changes

### 3.1 Core mapping

| Strands Agents (TS) | LangChain / LangGraph (Python) |
|---|---|
| `new Agent({ model, systemPrompt, tools, messages })` | `langgraph.prebuilt.create_react_agent(model, tools, prompt=…, checkpointer=…)` |
| `agent.stream(msg)` | `graph.astream_events(input, version="v2")` |
| `BedrockModel` | `langchain_aws.ChatBedrockConverse` |
| `tool({ name, description, inputSchema: z.object(…), callback })` | `@tool` decorator + Pydantic `args_schema`, or `StructuredTool.from_function` |
| `McpClient` + `StreamableHTTPClientTransport` | `langchain_mcp_adapters.client.MultiServerMCPClient(transport="streamable_http")` |
| `Swarm` (`ORCHESTRATOR_MODE=swarm`) | `StateGraph` supervisor pattern (or `langgraph-supervisor`) |
| `strands_structured_output` routing tool | `model.with_structured_output(RouteDecision)` or a router node returning `Command(goto=…)` |
| `AsyncLocalStorage` (trace, gateway JWT, userId contexts) | `contextvars.ContextVar` — direct 1:1, asyncio-native |
| Zod schemas (`lib/schemas.ts`) | Pydantic v2 models |
| `gray-matter` frontmatter parsing | `python-frontmatter` (or `PyYAML` + a split) |

### 3.2 Streaming event translation — the highest-risk mechanical change

`api/src/lib/run-chat-stream.ts` (520 lines) is a giant `for await` over Strands' event union, emitting
both UI stream parts and trace events. Every branch needs a LangGraph equivalent:

| Strands event | Emitted today | LangGraph `astream_events` equivalent |
|---|---|---|
| `modelStreamUpdateEvent` → `textDelta` | `token` part + `model.text_delta_batch` trace | `on_chat_model_stream` → `event["data"]["chunk"].content` |
| `modelStreamUpdateEvent` → `reasoningContentDelta` | `model.thinking_block` trace | `on_chat_model_stream`, chunk with `reasoning_content` block |
| `modelMetadataEvent.usage` | `model.usage` trace (incl. cache read/write tokens) | `on_chat_model_end` → `response.usage_metadata` |
| `afterModelCallEvent.stopData.stopReason` | `model.stop` trace | `on_chat_model_end` → `response.response_metadata["stopReason"]` |
| `beforeToolCallEvent` | `tool_call` (started) + `tool.call` span start | `on_tool_start` |
| `afterToolCallEvent` | `tool_call` (completed) + span end | `on_tool_end` / `on_tool_error` |
| `messageAddedEvent` | `conversation.message_added` trace | `on_chain_end` on the agent node |
| `contentBlockEvent` (assembled reasoning) | `model.thinking_block` | Assemble from streamed chunks |

**Gap to close:** LangGraph does not expose a pre-tool-call hook with the same guarantees Strands' event
loop gives, and `on_tool_start` fires per tool. The orchestrator's handoff detection currently
intercepts a `strands_structured_output` tool call mid-stream and `return`s early. In LangGraph this
becomes a **router node** in the graph that returns a typed decision — cleaner, but it is a structural
change, not a translation.

### 3.3 Agent construction and caching

`api/src/lib/create-strands-agent.ts` builds a per-agent *template* (model + tools + skill registry +
base system prompt) cached by `.agent.md` mtime, with a deliberate no-cache rule for MCP-degraded
templates. Port this pattern **and keep it** — compiling a LangGraph graph is more expensive than
constructing a Strands `Agent`, so the cache matters more, not less.

Cache the **compiled graph** keyed on `(agent_id, agent_md_mtime)`. Keep:
- The MCP-degraded detection and `tools.degraded` trace + `TOOLS_UNAVAILABLE` SSE error.
- The refusal to cache degraded templates (so a transient MCP outage self-heals next turn).
- `warm_agent_cache()` at boot.

### 3.4 Model layer — one genuine gap

`api/src/adapters/resolve-model.ts` wraps `BedrockModel` twice:

- **`MetadataAwareBedrockModel`** injects Bedrock `requestMetadata` with `agentId` so invocation logging
  and the Cost dashboard attribute spend per agent (including the synthetic `synthesizer` agent).
- **`TracingRetryStrategy`** wraps the AWS SDK retry strategy to emit `model.retry` trace events.

Neither has an out-of-the-box Python equivalent:

- `ChatBedrockConverse` accepts `additional_model_request_fields`, but `requestMetadata` is a top-level
  Converse parameter, not a model field. **You need a subclass** overriding `_stream`/`_agenerate` to
  add `requestMetadata={"agentId": …}` to the Converse call. ~40 lines.
- Retry observability: pass a botocore `Config(retries={"max_attempts": N, "mode": "standard"})` and
  register a `before-send` / `needs-retry` event hook on the boto3 client to emit `model.retry`. ~30
  lines. Simpler than the TS version.

Keep the per-`(agentId, modelId, maxTokens, temperature, region)` model cache — the boto3 client build
cost is the same problem.

### 3.5 Multi-specialist orchestration

`multi-specialist-orchestrator.ts` (611 lines) is an async generator yielding a typed event union
(`specialist_started`, `specialist_stream`, `specialist_trace`, `specialist_ended`, `synthesis_started`,
`synthesis_stream`, `synthesis_ended`, `stream_error`). It is consumed identically by the Hono API and
the AgentCore orchestrator runtime.

In Python this stays an `AsyncGenerator` yielding dataclasses — **do not** rebuild it as a LangGraph
subgraph. Reasons:
- The specialists are remote AgentCore Runtimes invoked over SSE, not local nodes.
- The two call sites (`routes/chat.ts` and `agent-runtime-code.ts`) must produce byte-identical SSE, and
  a plain generator makes that trivially verifiable.

The **synthesizer** (`specialist-answer-synthesizer.ts`) is a transient in-process agent with a
hard-coded system prompt and no `.agent.md`. In Python it is a bare `ChatBedrockConverse` + prompt —
no LangGraph graph needed. Keep the `agentId: "synthesizer"` tagging for cost attribution.

### 3.6 Classifier

`agent-classifier.ts` (721 lines) is pure logic — tokenization, bigram overlap scoring against agent
descriptions/handoff labels, thresholds, LRU cache, plus a Bedrock Haiku tool-forced fallback via
`ConverseCommand`. Straight port:

- Scoring/tokenization → plain Python, no dependency.
- Haiku fallback → `boto3.client("bedrock-runtime").converse(...)` with `toolConfig`, or
  `ChatBedrockConverse(...).with_structured_output(ClassifierDecision)`.
- LRU cache → `functools.lru_cache` on a hash of the normalized message (the current cache is a
  256-entry Map with the same semantics).

All env knobs stay identical: `CLASSIFIER_BACKEND`, `CLASSIFIER_HEURISTIC_MIN_SCORE`,
`CLASSIFIER_HEURISTIC_MARGIN`, `CLASSIFIER_HEURISTIC_DOMINANT_MARGIN`, `CLASSIFIER_MULTI_MIN_SCORE`,
`CLASSIFIER_MULTI_RELATIVE_MARGIN`, `CLASSIFIER_MULTI_MAX_AGENTS`.

### 3.7 Skills subsystem

`skill-loader.ts` + `prompt.ts` + the `activate_skill` / `read_skill_resource` / `run_skill_script`
tools port with **no framework involvement** — they are filesystem + string assembly. Two notes:

- `run_skill_script` dynamically imports `.mjs` from `config/skills/<name>/scripts/`. Python equivalent
  is `importlib.util.spec_from_file_location` on `.py` files. **This changes the skill authoring
  contract** — any existing `.mjs` skill scripts must be rewritten. Today no shipped skill has a
  `scripts/` directory (only `references/`), so the blast radius is zero *now*, but
  `docs/skills-authoring-guide.md` must be updated.
- Keep the path-traversal guards in `resolve_skill_resource_path` verbatim. They are a trust boundary.

---

## 4. API layer changes

### 4.1 Web framework

| Hono (TS) | FastAPI (Python) |
|---|---|
| `new Hono()`, `app.route("/", …)` | `FastAPI()` + `APIRouter` |
| `streamSSE(c, async (stream) => …)` | `sse_starlette.EventSourceResponse(agen)` |
| `stream.writeSSE({ event, data })` | `yield {"event": …, "data": json.dumps(…)}` |
| `stream.write(": keepalive …")` | `EventSourceResponse(ping=15)` — built-in, replaces the manual keepalive timer |
| `hono/cors` | `fastapi.middleware.cors.CORSMiddleware` |
| `app.onError` | `@app.exception_handler(Exception)` |
| `c.get("requestId")` context vars | `contextvars` + a middleware, or `request.state` |
| Zod body parse → 400 | Pydantic request model → FastAPI 422 (**must be remapped to the existing 400 `INVALID_REQUEST` envelope**) |

**Server:** `uvicorn` with `--http h11`. Do **not** use `--workers > 1` without moving the in-process
caches (trace ring buffer, session Map fallback, classifier LRU, template cache) — they are per-process
today and the current Bun deployment is single-process.

### 4.2 Route-by-route

| Route | Change |
|---|---|
| `POST /chat` | Largest single file (888 lines). Structure survives; SSE plumbing swaps as above. `queueMicrotask` for the dangling LTM write → `asyncio.create_task(...)` held in a module-level set so it isn't GC'd. |
| `GET /agents`, `/agents/:id` | Trivial. Reads `config-scan`. |
| `GET /skills` | Trivial. |
| `GET/DELETE /sessions`, `/sessions/:id` | Trivial once the session store is ported (§5.1). |
| `GET /traces/:id`, `/trace`, `/trace/mongo`, `/traces` | Trivial + `trace-projection.ts` port. **Keep the `X-Trace-Include` response header** — `ui/lib/api_client.py::get_trace` asserts on it. |
| `GET /health`, `/health/deep` | Port `health-status.ts` dependency probes. |
| `GET /http-tools`, `POST /http-tools/:name/invoke` | Port `http-tools-runtime.ts` (421 lines) incl. SSRF guards. |
| `GET /demo-prompts` | Trivial. |
| `POST /internal/agents/refresh` | Port; must clear the Python-side config/skill/template caches. |

### 4.3 Middleware

| File | Python |
|---|---|
| `middleware/auth.ts` (jose JWKS verify) | `PyJWT` + `jwt.PyJWKClient(AUTH_JWKS_URI)` with its built-in key cache. Keep `assertJwksAuthConfigured()` — **refuse to boot without `AUTH_JWKS_URI` + `AUTH_ISSUER`**. There is no auth bypass today; do not introduce one. |
| `middleware/rate-limit.ts` | Keep the hand-rolled in-memory limiter (~50 lines). Do not add `slowapi` for this. |
| `middleware/request-id.ts` | ~15 lines of middleware. Keep `X-Request-Id` on the response. |
| `middleware/otel.ts` | `opentelemetry-instrumentation-fastapi` covers server spans; keep the manual `X-Trace-Id` response header. |
| `middleware/access-log.ts` | Port to the JSON logger. |

### 4.4 Tracing / observability

| File | Lines | Effort |
|---|---|---|
| `lib/trace-collector.ts` | 1237 | **High.** Spans, parent/child IDs, per-event-type byte caps, redaction, ring buffer, nested-trace splicing with clock normalization. No library equivalent. Port near-verbatim to dataclasses/Pydantic + `contextvars`. |
| `lib/trace-types.ts` | 877 | **Medium.** ~45 event types, each with a payload shape the UI renders. Becomes a Pydantic discriminated union. Mechanical but must be exact. |
| `lib/trace-projection.ts` | 266 | Mechanical (`core`/`dev`/`full` projections). |
| `lib/trace-store.ts` | 263 | Mechanical (Mongo upsert + TTL + ring buffer). |
| `lib/otel.ts` | 128 | **Easier in Python.** `opentelemetry-sdk` + `OTLPSpanExporter` to the same ADOT sidecar at `127.0.0.1:4318`. The UI already does exactly this. |
| `lib/logger.ts` | 172 | Python `logging` + a JSON formatter that pulls `trace_id`/`span_id` from the active span. |
| `lib/strands-console-redirect.ts` | 96 | **Delete.** Not needed — LangChain logs through `logging` already. |
| `lib/cw-metrics.ts` | 253 | Mechanical (EMF JSON to stdout). |

> The trace subsystem is the schedule driver. Budget it as its own phase and gate it with contract tests
> that replay `ui/tests/fixtures/` against the Python collector output.

---

## 5. Data and memory layer changes

### 5.1 Sessions / short-term memory — biggest available simplification

Today: `session-store.ts` (471) + `short-term-memory.ts` (211) + `chat-sessions-collection.ts` +
`chat-messages-collection.ts`, with a three-way backend matrix (AgentCore Memory authority, in-process
Map cache, MongoDB `chat_sessions` mirror).

LangGraph offers `langgraph.checkpoint.mongodb.AsyncMongoDBSaver`, which gives thread-scoped message
persistence for free. **Recommendation: adopt it as the process cache + Mongo mirror, keep AgentCore
Memory as the deployed-AWS authority.**

Constraint: the Sessions page reads the `chat_sessions` document shape (`messages[]`, `lastTraceId`,
title, timestamps). Checkpointer documents look nothing like that. Two options:

- **(a) Keep `chat_sessions` as an explicit mirror** written alongside the checkpointer. Preserves the
  UI and audit trail. ~150 lines. **Recommended.**
- (b) Rewrite the Sessions page against checkpoint documents. Cheaper in the API, breaks the "UI is
  zero-change" property. Not recommended.

Preserve exactly: `SHORT_TERM_MEMORY_BACKEND` selection matrix, `FORBIDDEN_SESSION` user-scoping
(pinned by `user-isolation.integration.test.ts`), and `setLastTraceId`.

### 5.2 Long-term memory — port, don't outsource

`long-term-memory.ts` (1302) + `vector-retrieval.ts` (606) + `llm-fact-extractor.ts` (357) implement
hybrid `$vectorSearch` + Atlas Search BM25 → RRF fusion → collection weights → recency decay → MMR
diversification across `agent_memory_facts` and `chat_messages`.

`langchain-mongodb` provides `MongoDBAtlasVectorSearch` and `MongoDBAtlasHybridSearchRetriever` (which
does RRF). **Do not swap them in.** The library's fusion does not implement collection weights or
recency decay, and its MMR is single-collection. Replacing the retriever changes recall behaviour and
invalidates `e2e-smoke/ltm/` and `memory-recall-diagnostic.py`.

**Port the pipelines as-is** with `pymongo`. The aggregation stages are identical strings. The pure
functions (`rrfMerge`, `applyRecencyDecay`, `applyCollectionWeights`, `mmrDiversify`,
`cosineSimilarity`) are ~200 lines of arithmetic — use `numpy` for `cosineSimilarity` and MMR and they
get shorter and faster.

Keep: LLM-only fact extraction with **no regex fallback** (deliberate — a regex fallback stores false
"facts" on every Bedrock blip), the `{userId, factHash}` upsert key, the TTL index, and the
`memory.long_term_skip` reason codes.

### 5.3 Driver and embeddings

| File | Change |
|---|---|
| `lib/mongo-client.ts` | `mongodb` Node driver → **`pymongo` 4.9+ `AsyncMongoClient`** (native async; prefer over `motor`, which is now in maintenance). Keep the singleton + lazy connect + pool config. |
| `adapters/voyage-embedding.ts` (424) | `@aws-sdk/client-sagemaker-runtime` → `boto3.client("sagemaker-runtime").invoke_endpoint`. The multimodal envelope (`{inputs: [{content: […]}]}`), `VOYAGE_EMBEDDING_DIMS`, and base64 redaction are custom — port verbatim. **Do not** substitute `langchain_aws.BedrockEmbeddings`. |
| `lib/embed-query.ts` (287) | Straight port incl. Titan/Cohere fallback and structured `status: "error"` degradation. |
| `adapters/bedrock-retrieval.ts` (119) | `boto3.client("bedrock-agent-runtime").retrieve`. Or `langchain_aws.AmazonKnowledgeBasesRetriever` — but the custom version returns a specific shape the trace renders. Port it. |
| `adapters/mongodb-mcp-client.ts` (1637) | **Shrinks substantially.** `langchain-mcp-adapters` handles the transport, `tools/list`, and LangChain tool conversion. What must be kept: the `mongodb-mcp___` gateway prefix aliasing, per-call JWT header injection from a `ContextVar`, the 401-reset-and-retry, query-vector pre-embedding before the MCP envelope, and `enrichVectorSearchTraceEvents`. Estimate ~600 lines. |
| `db-seeding/*.ts` (2945) | Optional. These are standalone scripts run once. Port to `pymongo` for a single-language repo, or leave as Bun scripts. Recommend porting `seed-embeddings.ts` + `seed-indexes.ts` only. |

---

## 6. UI changes

**Required: none.** Contingent on preserving:

1. Named SSE events and their JSON payload keys — including the multi-specialist `phase`
   (`"specialist"` / `"synthesis"`), `specialistId`, `specialistName`, `rank` fields on `token` frames.
2. The persisted trace document shape (`events[]` with `type`, `id`, `ts`, `payload`, `parentId`,
   `agentId`, `durationMs`) and every `type` string in the ~45-member event union.
3. Response headers `X-Request-Id`, `X-Trace-Id`, `X-Trace-Include`.
4. Error envelope `{ error: { code, message, requestId } }` and status codes (`INVALID_REQUEST` 400,
   `AGENT_NOT_FOUND` 404, `SESSION_NOT_FOUND` 404, `UNAUTHORIZED` 401).

**Optional consolidation:** with the API in Python, the UI and API can share one venv and one container
image, dropping one ECR repo and one systemd unit. This is a deploy simplification, not a requirement.

**Add:** contract tests. `ui/tests/` already has fixtures; add a test that asserts the Python API's SSE
frames and trace JSON parse cleanly through `ui/lib/api_client.py`. This is what stops the UI from
silently becoming part of the port.

---

## 7. Deployment and infrastructure changes

### 7.1 AgentCore Runtime — recommend switching to container mode

Today the four agent runtimes deploy in **code mode**: `esbuild` bundles `agent-runtime-code.ts` to a
single CJS file, zipped with `config/`, uploaded to S3, run on the AgentCore `NODE_22` runtime.

For Python, code mode is technically available (`var.code_runtime` is already a Terraform variable — see
`deploy/terraform/modules/agentcore-agent-runtime/variables.tf:19`, which already documents
`NODE_22/Python`). But the Python dependency tree (`langgraph`, `langchain-aws`, `pymongo`,
`opentelemetry-*`, `boto3`) vendored into a zip runs 50–80 MB versus today's single bundled JS file.

**Recommendation: `TF_VAR_agentcore_runtime_deployment_mode=container`** for the agent runtimes. The
module already supports both paths (`main.tf:144-166`) — this is a variable flip plus an ARM64
Dockerfile, not a module rewrite. Update `docs/architecture.md` §7.2, which currently documents code
mode as the default and states the rationale.

### 7.2 Runtime entrypoint — a large deletion

`api/src/agent-runtime-code.ts` (563 lines) hand-rolls a `node:http` server implementing the AgentCore
contract (`GET /ping`, `POST /invocations` responding `text/event-stream`).

The **`bedrock-agentcore` Python SDK** provides `BedrockAgentCoreApp` with an `@app.entrypoint`
decorator that handles `/ping`, `/invocations`, and async-generator-to-SSE conversion. Expect ~563 → ~150
lines, keeping the orchestrator-vs-specialist dispatch on `AGENT_ID`, the trace collector wiring, the
W3C `traceparent` carrier extraction, and the `done` payload shape.

### 7.3 Build and deploy scripts

| File | Change |
|---|---|
| `api/package.json` | → `pyproject.toml` + `uv.lock` (or `requirements.txt`). All `bun run …` scripts become `uv run …` / `make` targets. |
| `deploy/deploy-api.sh` | Docker build for the API image: `oven/bun` base → `python:3.12-slim`. |
| `deploy/deploy-agents.sh` | Drop the esbuild bundle step; build/push an ARM64 agent-runtime image instead. |
| `deploy/scripts/deploy-project.sh` | Phase that zips `dist/agent-runtime-code.js` + `config/` is replaced by an ECR push. **Keep** the MCP image-digest → gateway-target-recreate logic (Phase 4d) unchanged — that invalidates the Gateway's cached tool schemas and is unrelated to language. |
| `api/scripts/validate-bun-compat.ts` | **Delete.** |
| `api/scripts/validate-agentcore-memory.ts`, `validate-strands-*.ts`, `bench-chat-ttfb.ts`, `voyage-print.ts`, `validate-multi-classifier.ts` | Port to Python. The `validate-strands-*` ones become `validate-langgraph-*` and should be rewritten against the new event names — they exist precisely to pin SDK behaviour across upgrades. |
| `compose.yaml`, `Makefile`, `.dockerignore` | Update service definitions and ignore patterns. |
| `deploy/terraform/**` | Only variable values: `code_runtime`, `code_entry_point`, `deployment_mode`, container URIs. **No module structure changes.** The `ignore_changes` rule on `environment_variables` stays. |
| `.env.sample` / `docs/reference/env-vars.md` | Every knob keeps its name. Add none, remove `STRANDS_LOG_REDIRECT` (no longer meaningful). |

### 7.4 IAM, networking, Atlas connectivity

**No change.** PrivateLink/peering modes, Route 53 private zones, KB NLB wiring, Cognito, Secrets
Manager, CloudWatch log groups and dashboards, ADOT sidecar — all language-agnostic.

---

## 8. Tests

| Suite | Count | Change |
|---|---|---|
| `api/tests/unit/` | 69 files | Port `bun test` → `pytest`. Mostly mechanical; the ones asserting Strands event handling need rewriting against `astream_events`. |
| `api/tests/integration/` | 8 files | Port. `chat-sse-trace`, `chat-sse-error`, `chat-streaming-e2e`, `trace-routes`, `user-isolation` are the **contract tests** — port these first and use them as the port's acceptance gate. |
| `ui/tests/` | 15 files | **No change.** Add SSE/trace contract tests here (§6). |
| `e2e/` (Playwright, TS) | 2 spec files | Small. Port to `pytest` + `httpx`, or leave as Node — it only exercises the live HTTP API. |
| `e2e-smoke/` | ~15 Python scripts | **No change.** Already Python. |

---

## 9. Net effect

| Area | TS today | Python estimate | Delta |
|---|---|---|---|
| Agent core (create-agent, run-stream, swarm, orchestrator, synthesizer, classifier) | ~2.9k | ~2.0k | −900 |
| MCP client adapter | 1.6k | ~0.6k | −1.0k |
| Sessions + short-term memory | ~0.9k | ~0.4k | −500 |
| Long-term memory + hybrid retrieval + extractor | ~2.3k | ~2.0k | −300 |
| Trace subsystem | ~2.6k | ~2.6k | 0 |
| Routes + middleware + app | ~1.7k | ~1.4k | −300 |
| AgentCore runtime entrypoint | 0.6k | ~0.15k | −450 |
| Tools, skills, prompt, config-scan, http-tools, embeddings, health, metrics | ~4.5k | ~4.3k | −200 |
| **Total `api/`** | **~19k** | **~13.5k** | **≈ −5.5k** |

Plus optional: `db-seeding` 2.9k TS → ~2.4k Python.

---

## 10. What gets harder

1. **Bedrock `requestMetadata` cost attribution** — needs a `ChatBedrockConverse` subclass (§3.4). If
   skipped, the Cost dashboard loses per-agent breakdown.
2. **Cold start.** Python + LangGraph import time on an AgentCore container is materially worse than a
   single bundled JS file on `NODE_22`. `lib/prewarm.ts` becomes more important, not less: pre-import,
   pre-build compiled graphs, pre-open the Mongo pool, pre-run `tools/list`.
3. **Two entry points, one core.** The FastAPI route and the AgentCore entrypoint must produce identical
   SSE. Keep `run_chat_stream` and `run_multi_specialist_flow` in a shared package imported by both —
   the same discipline the TS code uses today.
4. **Nested trace splicing.** `attachEventsNested` rewires event IDs and normalizes clocks across the
   EC2 → AgentCore boundary. It is subtle (see the `findOutermostAgentcoreInvokeId` comment block) and
   has a dedicated unit test. Port the test first.
5. **Graph compilation cost.** Cheap in Strands, not in LangGraph. Cache compiled graphs, invalidate on
   `.agent.md` mtime (§3.3).

---

## 11. Suggested phasing

| Phase | Scope | Gate |
|---|---|---|
| 0 | Contract capture: freeze SSE + trace JSON as golden fixtures from the current TS API | Fixtures replay through `ui/lib/api_client.py` |
| 1 | FastAPI skeleton: auth, health, request-id, CORS, logger, `config-scan`, `skill-loader`, `/agents`, `/skills` | Existing unit tests ported and green |
| 2 | Trace subsystem: collector, types, projection, store, OTel, routes | Golden fixtures from Phase 0 replay identically |
| 3 | Agent core: `ChatBedrockConverse` + `create_react_agent` + tools + MCP adapters + `run_chat_stream` | Single-specialist `/chat` streams correctly to the real UI |
| 4 | Memory: sessions + checkpointer + `chat_sessions` mirror + LTM hybrid retrieval + fact extractor | `e2e-smoke/ltm/` and `memory-recall-diagnostic.py` pass |
| 5 | Classifier + multi-specialist orchestrator + synthesizer | `multi-specialist-smoke.py` passes |
| 6 | AgentCore runtime entrypoint + container-mode Terraform + deploy scripts | `post-deploy-smoke.py` passes against a live deploy |
| 7 | Docs (`architecture.md` §7.2, `agent-authoring-guide.md`, `skills-authoring-guide.md`, `env-vars.md`, `AGENTS.md`), optional `db-seeding` port | `docs/` describes the shipped system |

Phases 2 and 4 are the long poles. Phase 0 is the cheapest insurance in the plan — without it, drift in
the SSE contract turns the zero-change UI into a second port.

---

## 12. Recommended dependency set

```toml
# pyproject.toml — core
langgraph                          # graph runtime, checkpointing
langchain-aws                      # ChatBedrockConverse
langchain-mcp-adapters             # MCP tools → LangChain tools
langgraph-checkpoint-mongodb       # AsyncMongoDBSaver
fastapi
uvicorn[standard]
sse-starlette                      # EventSourceResponse
pymongo>=4.9                       # AsyncMongoClient
pydantic>=2
pyjwt[crypto]                      # PyJWKClient
python-frontmatter                 # .agent.md / SKILL.md
boto3                              # SageMaker, Bedrock KB, AgentCore Memory
bedrock-agentcore                  # BedrockAgentCoreApp entrypoint
numpy                              # cosine similarity / MMR
opentelemetry-sdk
opentelemetry-exporter-otlp-proto-http
opentelemetry-instrumentation-fastapi
```

Deliberately **not** included: `langchain-mongodb` (§5.2), `slowapi` (§4.3), `motor` (§5.3),
`langgraph-supervisor` (§3.5).
