# Guidance for AI coding agents

This file is for **human and AI contributors** who edit the repository in Cursor, Copilot, or similar tools. It is **not** a Strands/Bedrock agent definition.

**Runtime agent personas** live under [`config/agents/`](config/agents/) as `.agent.md` files. **Domain knowledge** lives under [`config/skills/`](config/skills/) as `SKILL.md` trees.

---

## What this project is

A **configuration-driven multi-agent reference** on **AWS Bedrock** (via [Strands Agents SDK](https://github.com/strands-agents/sdk-typescript)) and **MongoDB Atlas**. The product goal: add specialists by editing markdown config, not by forking business logic for every customer.

Authoritative plan: [`ACTION_PLAN.md`](ACTION_PLAN.md). Day-to-day checklist: [`TASKS.md`](TASKS.md).

**Runbook and “what works today”:** [`DEV_STATUS.md`](DEV_STATUS.md) — **update it whenever you change how to run the stack, default env behavior, or major implemented vs not-implemented boundaries** (same PR as the code change).

**Rare, persistent pitfalls:** [`memory.md`](memory.md) is **not** a changelog. Add an entry only when the same class of failure has **recurred more than twice** or you are documenting a **severe one-off** guardrail (e.g. hung CI / infinite Strands loop). Ordinary bugs belong in PRs, commits, and [`docs/`](docs/).

---

## Repository layout

| Path | Role |
|------|------|
| `api/` | Bun + TypeScript + Hono HTTP API (SSE chat, sessions, agents/skills metadata, optional JWT/JWKS); [`Dockerfile`](api/Dockerfile) (build context = **repo root**) |
| `ui/` | Streamlit chat client (`app.py` + `pages/` e.g. **Sessions**); [`Dockerfile`](ui/Dockerfile) (context = **`ui/`**) |
| `deploy/terraform/` | AWS (and related) infrastructure; start here for IaC |
| `deploy/scripts/` | `docker-build.sh`, `docker-push-ecr.sh` |
| `compose.yaml` | Local **API + Streamlit** (`docker compose up --build`; default mock loop env) |
| `Makefile` | Optional **`make docker-up`**, **`docker-build`**, **`docker-down`**, **`docker-logs`** |
| `.dockerignore` | Root ignore rules for **`api/Dockerfile`** builds (context = repo root) |
| `config/agents/` | `.agent.md` — persona YAML frontmatter + markdown body |
| `config/skills/` | `SKILL.md` + optional `references/`, `scripts/`, `http-tools.json` |
| `config/http-tools.json` | Optional global HTTP tools + `security` host allowlist for skill-scoped HTTP tools |
| `config/environment.yaml` | Environment defaults (expand as needed) |
| `config/demo-prompts.yaml` | Sidebar "Try a prompt" entries surfaced by the Streamlit UI |
| `docs/` | Architecture, API, deployment, authoring guides |
| `e2e-smoke/` | Post-deploy live AWS smoke tests; run `python3 e2e-smoke/post-deploy-smoke.py` after `./deploy/deploy-full-with-privatelink.sh` to verify health, KB PrivateLink, Voyage/SageMaker alignment, and all agents |

[`ACTION_PLAN.md`](ACTION_PLAN.md) still describes an `apps/` / `packages/` layout; the **implemented** layout is **`api/` + `ui/` + `deploy/`** until a workspace refactor. Prefer editing what exists; update `TASKS.md` when you add new top-level dirs.

---

## Commands

See **[`DEV_STATUS.md`](DEV_STATUS.md)** for the full matrix (stub vs live, Swarm, MongoDB, rate limits).

**Minimal copy-paste**

```bash
# API
export PATH="$HOME/.bun/bin:$PATH"   # if `bun` is not on PATH
cd api && bun install && bun run typecheck && bun run validate:bun && bun run validate:agentcore && bun run dev

# Playwright API E2E (stub server on :3456; install browsers once)
# cd e2e && bun install && bunx playwright install chromium && bun run test

# UI (separate terminal)
cd ui && pip install -r requirements.txt && streamlit run app.py

# Terraform (optional)
cd deploy/terraform && terraform init && terraform validate

# Post-deploy live smoke tests (after ./deploy/deploy-full-with-privatelink.sh)
source .env && python3 e2e-smoke/post-deploy-smoke.py

# Agent-only redeploy (when only config/agents/*.agent.md or config/skills/ changed)
# Rebuilds + uploads the code artifact, targeted terraform apply on runtime modules,
# re-injects dynamic env vars, refreshes the API agent cache, runs a minimal agent smoke.
# Skips API/UI images and EC2 restart.
./deploy/deploy-agents.sh [--auto-approve] [--skip-smoke]

# API-only redeploy (when api/ code or API-bundled config changed)
# Rebuilds/pushes only the API image, refreshes .env.live, restarts multiagent-api, runs backend smoke.
./deploy/deploy-api.sh [--skip-docker] [--skip-smoke]

# UI-only redeploy (when only ui/ code changed)
# Rebuilds/pushes only the UI image, restarts multiagent-ui, runs Streamlit health check.
# Does NOT regenerate .env.live — run deploy-api.sh first if Cognito/Atlas/OTel env vars changed.
./deploy/deploy-ui.sh [--skip-docker] [--skip-smoke]

# Docker — full stack (mock model + fixtures; no AWS required)
docker compose up --build
# or: make docker-up
# or: ./deploy/scripts/docker-build.sh && docker compose up
```

---

## Conventions for code changes

1. **Match existing style** in each area: TypeScript in `api/src` (explicit `.ts` imports, Hono route modules), Python in `ui/`, HCL in `deploy/terraform/`.
2. **Prefer extending** `api/src/lib/` (loaders, prompt assembly, chat pipeline) and `api/src/routes/` over growing a single huge file.
3. **Domain behavior** belongs in **`config/skills/`** and **`config/agents/`**, not in ad-hoc strings inside route handlers — unless it is clearly temporary scaffolding marked as such.
4. **API surface** should stay aligned with [`docs/api-reference.md`](docs/api-reference.md) (paths, SSE event names, error shape, auth error codes such as **`INVALID_TOKEN`**). If you change the contract, update that doc in the same change. **New cloud or data integrations** should go behind **`api/src/adapters/`** (extend **`resolveModel`**, **`mongo-data`**, fixtures, and **[`DEV_STATUS.md`](DEV_STATUS.md)**) so **`DEV_MOCK_BACKENDS=1`** stays a complete local loop.
5. **Do not commit** `.env`, keys, or Terraform state. Follow [`.gitignore`](.gitignore).
6. **After meaningful increments**, update [`TASKS.md`](TASKS.md) checkboxes so the implementation tracker stays honest.
7. **When run behavior or implementation status changes**, update [`DEV_STATUS.md`](DEV_STATUS.md) in the same change. **Docker / Compose / ECR scripts / CI image jobs:** also align [`docs/deployment-guide.md`](docs/deployment-guide.md) (Step 5 + top status box) and this file’s layout/commands if paths or build context change.
8. **When a pitfall has recurred more than twice** (or is a critical regression worth a permanent rule), add a concise entry to [`memory.md`](memory.md). See that file’s Purpose section — do not append every fix there.
9. **Use `logger` (not `console.log`) for new diagnostic output** in `api/src/`. Import from `./logger.ts` (or `../lib/logger.ts`). `console.log` / `console.error` in tests and Streamlit (`ui/`) are fine. For **new Streamlit-side diagnostics**, prefer `ui/lib/log.py` (`log.info` / `warn` / `error` / `debug`) so support can grep JSON in process logs the same way as the API.

---

## Memory — config and setup

### Short-term memory

Conversation history is stored in `api/src/lib/session-store.ts` (in-memory `Map`) and — when `MONGODB_URI` is set — mirrored to the `chat_sessions` collection (default-on; set `PERSIST_CHAT_SESSIONS=0` to opt out). It is replayed into the Strands `Agent` as `messages: seed` on each turn under the live chat path (default; set `CHAT_MODE=stub` to disable). AgentCore-backed durable sessions are planned.

The `memory.shortTerm` frontmatter flag is parsed but has no additional runtime effect today beyond the default replay behavior. Set to `false` only for fully stateless agents (e.g. a one-shot lookup) where replaying prior turns would be wasteful.

### Long-term memory

Keyed by **`userId`** (JWT `sub` claim) and **`agentId`**. Activated only when both are present. Implementation: `api/src/lib/long-term-memory.ts`. Retrieval is **hybrid vector + lexical** across `agent_memory_facts` (LLM-curated facts) and `chat_messages` (vector-searchable mirror of every chat message) fused with Reciprocal Rank Fusion; see `api/src/lib/vector-retrieval.ts` for the shared primitives. Writes embed each accepted fact with `embedDocumentText` and upsert on a `factHash` dedup key so re-stating a fact is idempotent.

**Enable on an agent:**

```yaml
# config/agents/<name>.agent.md frontmatter
memory:
  longTerm: true
```

**Required env vars for production:**

| Variable | Purpose |
|----------|---------|
| `MONGODB_URI` | MongoDB Atlas connection string |
| `MONGODB_DB` | Database name. Project+env-derived (underscored) by `.env`, e.g. `mongodb_multiagent_dev` |
| `AUTH_JWKS_URI` | JWKS endpoint (e.g. Cognito pool). **Required** — `assertJwksAuthConfigured()` refuses to boot the API without it. |
| `AUTH_ISSUER` | Token issuer URL (e.g. Cognito pool URL). **Required** for the same reason. |
| `MEMORY_INJECT_TURNS` | Past turns to inject (legacy reader fallback; default `5`) |
| `MEMORY_VECTOR_TOPK` | Top-K hits after RRF + MMR (default `6`) |
| `MEMORY_VECTOR_FETCHK` | Per-leg over-fetch before merge (default `24`) |
| `MEMORY_VECTOR_NUM_CANDIDATES` | `$vectorSearch.numCandidates` width (default `200`) |
| `MEMORY_SEARCH_MAX_TIME_MS` | Server/client timeout for each Atlas vector/BM25 aggregation leg (default `8000`) |
| `MEMORY_EMBED_TIMEOUT_MS` | Query embedding timeout before lexical fallback (default `5000`) |
| `MEMORY_RECENCY_HALFLIFE_DAYS` | Exponential recency decay half-life; `0` disables (default `30`) |
| `MEMORY_MMR_LAMBDA` | 1 = pure relevance, 0 = pure diversity (default `0.7`) |
| `MEMORY_WEIGHT_FACTS` | Multiplier on `agent_memory_facts` RRF score (default `1.5`) |
| `MEMORY_WEIGHT_CHAT_MESSAGES` | Multiplier on `chat_messages` RRF score (default `1`) |
| `CHAT_MESSAGES_COLLECTION` | Override the vector-searchable chat-message mirror name (default `chat_messages`) |

**One-time MongoDB setup:** run `bun db-seeding/seed-indexes.ts` once per environment. It creates the TTL index on `agent_memory_facts`, the unique `{ userId, factHash }` dedup index, vector indexes for `agent_memory_facts` / `chat_messages` / `products` / `troubleshooting_docs`, and the matching Atlas Search (BM25) indexes used by the hybrid retriever. The API also auto-ensures the TTL + base indexes lazily on first write — manual `createIndex` is only needed for clusters where the seeder cannot run.

**Dev / local mode (`DEV_MOCK_BACKENDS=1`):** uses an in-process `Map` — no MongoDB or auth needed. Memory persists within one server run only. To exercise the full read/write flow locally, supply any non-empty Bearer token (JWKS not required when unset):

```bash
export DEV_MOCK_BACKENDS=1
# CHAT_MODE defaults to live; set CHAT_MODE=stub to disable the Strands loop
# REQUIRE_AUTH=true and a stub token gives the API a userId
export REQUIRE_AUTH=true
cd api && bun run dev
# then send requests with -H "Authorization: Bearer local-user-1"
```

**Data flow per turn:**

1. `POST /chat` arrives → `userId = c.get("jwtPayload")?.sub`
2. If `agent.memory.longTerm && userId`: call `readLongTermMemoryContext(userId, message, { agentId })` → hybrid vector + BM25 retrieval across `agent_memory_facts` and `chat_messages`, fused with RRF (k=60), weighted, recency-decayed, MMR-diversified.
3. Result is prepended to the system prompt as `## Relevant prior context` (alongside the auth-context block from `buildAuthenticatedUserContext`).
4. Every chat message is mirrored to `chat_messages` with an embedding via a microtask, so persistence never sits on the TTFB clock. `DELETE /sessions/:id` cascade-deletes the mirror.
5. Stream completes successfully → `writeLongTermMemory(userId, agentId, userMessage, assistantReply)` extracts facts with the LLM, embeds each fact, and `bulkWrite` upserts on `{ userId, factHash }` so duplicates collapse.

**Collection schemas:**

- `agent_memory_facts`: `{ userId, agentId, fact, source, ts, factHash, embedding?, embeddingModel? }`
- `chat_messages`: `{ messageId, sessionId, userId?, agentId?, role, content, timestamp, ts, embedding?, embeddingModel? }`

**Limits:** `userMessage` capped at 2 000 chars, `assistantReply` at 4 000 chars before storage. Embedding failures are non-fatal — the row lands without `embedding` and the lexical (BM25) leg still surfaces it; vector recall returns when the embedding provider is healthy and a future write touches the same `factHash`.

---

## Strands / Bedrock touchpoints

- Chat streaming pipeline: `api/src/lib/run-chat-stream.ts` (gated via `chatMode()` from `runtime-defaults.ts`, default `live`), optional Swarm in `api/src/lib/swarm-chat-stream.ts` (roster built dynamically from `listAgents()` — no hardcoded list).
- Agent construction: `api/src/lib/create-strands-agent.ts` and `resolveModel` in `api/src/adapters/resolve-model.ts` (`BedrockModel` vs `DevMockModel` when **`DEV_MOCK_BACKENDS=1`**; tools, prompts, optional `memoryContext`).
- Skill loading: `api/src/lib/skill-loader.ts` (activated skill bodies + `read_skill_resource`).
- Agent metadata + persona: `api/src/lib/config-scan.ts`, `api/src/lib/prompt.ts`, `api/src/lib/schemas.ts`. `AgentDetail` exposes the `memory` object (shortTerm / longTerm flags).
- System prompt assembly: `api/src/lib/prompt.ts` — `buildSystemPrompt(persona, discoveries, activated, memoryContext?)`. Long-term memory injected before skill sections.
- Long-term memory: `api/src/lib/long-term-memory.ts` — `readLongTermMemoryContext` (hybrid vector + BM25 retrieval across `agent_memory_facts` + `chat_messages`, fused with RRF / weights / recency / MMR) and `writeLongTermMemory` (LLM fact extraction → embed → `bulkWrite` upsert on `{ userId, factHash }`). Shared retrieval primitives live in `api/src/lib/vector-retrieval.ts`. Activated in `POST /chat` when agent has `memory.longTerm: true` and `userId` is known. AgentCore Memory Store remains the fallback when MongoDB writes fail. When `MONGODB_URI` is unset (e.g. **`DEV_MOCK_BACKENDS=1`**), `getMongoDb()` returns `null` and the retriever short-circuits to `null` memory context.
- Base tools: `api/src/lib/base-tools.ts` (includes per-skill `http-tools.json` under `config/skills/<skill>/`).
- HTTP tools metadata: `api/src/routes/http-tools-meta.ts` (`GET /http-tools`).
- Auth: `api/src/middleware/auth.ts` + `api/src/lib/jwt-verify.ts` — JWKS auth is mandatory. `assertJwksAuthConfigured()` runs at boot in `api/src/index.ts` and refuses to start without **`AUTH_JWKS_URI`** + **`AUTH_ISSUER`**. Every protected request is required to carry a valid Bearer JWT verified with **`jose`**; JWT `sub` is stored in `c.get("jwtPayload")?.sub` and used for session userId scoping. There is no `ALLOW_UNAUTHENTICATED` / `REQUIRE_AUTH=false` bypass.
- Session userId scoping: `api/src/lib/session-store.ts` carries `userId?`; `api/src/routes/sessions.ts` filters `GET /sessions` by user and enforces `DELETE` ownership.
- Structured logging: `api/src/lib/logger.ts` — JSON lines, level controlled by **`LOG_LEVEL`** (`error`|`warn`|`info`|`debug`; default `info`). Used across config-scan, skill-loader, mongo-data, base-tools, app error handler, chat/swarm streams.
- OpenTelemetry: `api/src/lib/otel.ts` — when **`OTEL_EXPORTER_OTLP_ENDPOINT`** is set (EC2 default: `http://127.0.0.1:4318`, ADOT sidecar), installs `NodeTracerProvider` + `BatchSpanProcessor` + `OTLPTraceExporter`. When unset, falls back to in-process tracing only. The Strands TS SDK auto-instruments via the global tracer provider — bump OTel deps in `api/package.json` only after checking the Strands 0.7 peer-dep matrix or you'll get two providers and silent span loss.
- TraceCollector OTel bridge: `api/src/lib/trace-collector.ts` — `start()` / `end()` / `event()` emit real OTel spans alongside the in-house event stream. Wrapped in try/catch so OTel exporter back-pressure can't destabilize the chat path. `attachEventsNested(...)` deliberately skips OTel re-emission because AgentCore Runtime emits its own `gen_ai.*` spans for the inner hop.
- Per-user cost attribution: `api/src/adapters/resolve-model.ts` instantiates `MetadataAwareBedrockModel` (a `BedrockModel` subclass) that reads `currentTrace().userId / agentId` at `stream()` time and injects them into `additionalArgs.requestMetadata`. Bedrock invocation logging surfaces them in `/aws/bedrock/invocations`, and the `<project>-cost-<env>` dashboard groups token usage by `requestMetadata.userId`. The model cache is per-agent (not per-user), so we mutate `_config` per call — relies on Strands 0.7 reading `_config` at request time.
- Custom metrics (EMF): `api/src/lib/cw-metrics.ts` emits **CloudWatch Embedded Metric Format** stdout JSON for `Multiagent/Chat`, `Multiagent/Mongo`, `Multiagent/Memory`. Call sites: `routes/chat.ts` (chat.turn.end), `adapters/agentcore-runtime.ts` (AgentCore invoke success + failure), `lib/trace-collector.ts` (bridges `mongo.query` / `mongo.vector_search` events), `lib/long-term-memory.ts` (write completion). Lock-down test: `api/tests/unit/cw-metrics.test.ts` — fails the moment a metric is renamed or a value moves off the top level of the EMF record. Disable in CI with `METRICS_EMITTER_ENABLED=0`. **Without this emitter the Phase 3 fleet dashboards stay empty and the latency / error-rate alarms go `INSUFFICIENT_DATA`.**
- OTel dependency pinning: Strands TS SDK 0.7 peers `@opentelemetry/{api,sdk-trace-*,resources,exporter-trace-otlp-http}` on the **OTel 1.30.x line** (exporters `^0.57.x`). `api/package.json` must stay inside that range or `gen_ai.*` spans silently drop — see [`memory.md`](memory.md#strands-ts-sdk--otel--global-tracer-provider-version-drift-kills-gen_ai-spans). Run `bun run validate:strands-otel` before merging any OTel dep bump.
- Prompt-body logging: `var.log_prompt_bodies` and `var.log_embedding_bodies` default to **false** in `modules/bedrock-invocation-logging`. Flip per-environment only with audit sign-off; the attached Data Protection Policy still masks PII even when bodies are on, but the body is written before scrubbing. See `docs/observability-runbook.md` §3 for the checklist.
- HTTP + SSE: `api/src/routes/chat.ts`.
- Tracing: `api/src/lib/trace-types.ts` (event union), `api/src/lib/trace-collector.ts` (per-turn collector + cost summary + byte cap + nested splice), `api/src/lib/trace-context.ts` (`AsyncLocalStorage`), `api/src/lib/trace-store.ts` (ring buffer + MongoDB persistence with TTL), `api/src/routes/trace.ts` (`GET /traces/:id`, `GET /trace`, `GET /trace/mongo`, `GET /traces`). UI: `ui/lib/inline_summary.py` (per-turn card), `ui/pages/2_Trace_Viewer.py` (full dashboard). Streamlit chat surfaces vector-search source previews via browser-native `title=` tooltips; treat `mongo.vector_search.documentPreviews[]` as the user-visible source-preview contract.

Still open (see `TASKS.md` + `DEV_STATUS.md`): **AgentCore Code Interpreter** (skill scripts still run as `.mjs` imports); customer-scoped multi-tenancy on operational collections; browser/Streamlit E2E; CI/CD as the primary deploy path; **ECS/ALB** rollout automation beyond container images + scripts.

Implemented: Streamlit **Cognito** (`streamlit-cognito-auth`, `ui/lib/cognito_gate.py`) — hosted UI or embedded login when `STREAMLIT_COGNITO_POOL_ID` + `CLIENT_ID` are set; Bearer = Cognito access token. TTL indexes on `agent_memory_facts` and `chat_messages` are auto-created on first production write; Atlas Vector Search + BM25 indexes for those collections are seeded by `db-seeding/seed-indexes.ts`. `config/environment.yaml` is parsed by `api/src/lib/environment-config.ts` for `api.port` / `api.corsOrigins` defaults.

---

## Documentation map

| Doc | Use when |
|-----|----------|
| [`memory.md`](memory.md) | Only **persistent** “do not regress” notes (see its Purpose; not every bugfix) |
| [`DEV_STATUS.md`](DEV_STATUS.md) | How to run locally, env vars, what is implemented |
| [`docs/api-reference.md`](docs/api-reference.md) | Endpoints, SSE, auth |
| [`docs/agent-authoring-guide.md`](docs/agent-authoring-guide.md) | `.agent.md` format |
| [`docs/skills-authoring-guide.md`](docs/skills-authoring-guide.md) | `SKILL.md` and progressive disclosure |
| [`docs/configuration-guide.md`](docs/configuration-guide.md) | Config and environment |
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | Target AWS/Terraform, **Docker & ECR** (reference), ECS notes |
| [`docs/architecture.md`](docs/architecture.md) | System design |
| [`docs/logging-architecture.md`](docs/logging-architecture.md) | Structured JSON logger, OpenTelemetry trace correlation, CloudWatch shipping + GenAI Observability + ADOT sidecar, audit channel, redaction |
| [`docs/observability-runbook.md`](docs/observability-runbook.md) | Day-2 ops — finding traces, log-group cheat sheet, body-logging checklist, sampling tuning, alarm authoring, SNS, per-user cost dashboard, Atlas anomalies, emergency knobs |
| [`docs/dashboards/README.md`](docs/dashboards/README.md) | CloudWatch dashboard reference — widget catalog, screenshots, alarm thresholds, console URLs, how to regenerate screenshots |
| [`docs/demo-mode-guide.md`](docs/demo-mode-guide.md) | Trace UI walkthrough + env knobs for client demos |

---

## Naming disambiguation

| Name | Meaning |
|------|--------|
| **This file (`AGENTS.md`)** | Instructions for **coding agents / developers** working on the repo |
| **`config/agents/*.agent.md`** | **Runtime** LLM agent definitions (orchestrator, order, product, troubleshoot) |

If a task says “add an agent,” it usually means a **new `.agent.md` + skill**, not editing `AGENTS.md`.
