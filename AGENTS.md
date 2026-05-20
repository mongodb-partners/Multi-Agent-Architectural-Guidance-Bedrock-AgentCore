# Guidance for AI coding agents

This file is for **human and AI contributors** who edit the repository in Cursor, Copilot, or similar tools. It is **not** a Strands/Bedrock agent definition.

**Runtime agent personas** live under [`config/agents/`](config/agents/) as `.agent.md` files. **Domain knowledge** lives under [`config/skills/`](config/skills/) as `SKILL.md` trees.

---

## What this project is

A **configuration-driven multi-agent reference** on **AWS Bedrock** (via [Strands Agents SDK](https://github.com/strands-agents/sdk-typescript)) and **MongoDB Atlas**. The product goal: add specialists by editing markdown config, not by forking business logic for every customer.

**Client handover entry point:** [`docs/README.md`](docs/README.md) — doc map, first-day checklist, reading orders.

**Developer playbook:** [`docs/debugging.md`](docs/debugging.md) — EC2 access, log tailing, trace-driven debug, common failures, validation scripts, **persistent pitfalls**. When you hit a non-obvious regression that has recurred more than twice (or is a severe one-off guardrail like a hung CI / infinite Strands loop), add an entry to the **Known persistent pitfalls** section there — same PR as the fix. Ordinary bugs belong in PRs, commits, and [`docs/`](docs/).

**Reference appendix:** [`docs/reference/`](docs/reference/) — env vars, Terraform modules, SSM parameters, data model, smoke tests, deploy scripts.

---

## Repository layout

| Path | Role |
|------|------|
| `api/` | Bun + TypeScript + Hono HTTP API (SSE chat, sessions, agents/skills metadata, optional JWT/JWKS); [`Dockerfile`](api/Dockerfile) (build context = **repo root**) |
| `ui/` | Streamlit chat client (`app.py` + `pages/` e.g. **Sessions**); [`Dockerfile`](ui/Dockerfile) (context = **`ui/`**) |
| `deploy/terraform/` | AWS (and related) infrastructure; start here for IaC. **Three live Terraform envs:** [`envs/network`](deploy/terraform/envs/network) (shared VPC + Atlas PrivateLink VPCE, one per account+region), [`envs/shared`](deploy/terraform/envs/shared) (Voyage SageMaker endpoint + CloudWatch log groups + fleet/mongo/cost/atlas dashboards + Bedrock invocation logging, one per account+region+environment), and [`envs/ec2`](deploy/terraform/envs/ec2) (per-project app stack — EC2, ECR, Cognito, Bedrock KB, AgentCore). The first two are singletons that publish SSM under `/<SHARED_VPC_NAME>/<region>/`; `envs/ec2` reads them. |
| `deploy/scripts/` | `deploy-network.sh`, `deploy-shared.sh`, `deploy-project.sh`, `destroy.sh --mode {network,shared,ec2,local}`, `docker-build.sh`, `docker-push-ecr.sh` |
| `mcp-runtimes/mongodb-mcp/` | MongoDB MCP server packaged as an AgentCore Runtime (container mode, ARM64). Streamable-HTTP `0.0.0.0:8000/mcp`. Tools: `mongodb_query`, `mongodb_vector_search`, `mongodb_aggregate`. |
| `e2e/` | Playwright API smoke specs (`bun run test`) |
| `e2e-smoke/` | Python post-deploy live-AWS smoke + `memory-recall-diagnostic.py` |
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

The **implemented** layout is **`api/` + `ui/` + `mcp-runtimes/` + `deploy/`**. There is no `apps/` / `packages/` workspace split. Prefer editing what exists; if you add a new top-level directory, register it here in the layout table.

---

## Commands

See **[`docs/deployment-guide.md`](docs/deployment-guide.md)** for the full deploy matrix and **[`docs/reference/deploy-scripts.md`](docs/reference/deploy-scripts.md)** for every script flag + phase index.

**AWS auth note for all deploy scripts:** every script under [`deploy/`](deploy/) honors `AUTH_MODE` in `.env` (`iam` for long-lived IAM user keys — default; `sts` for assumed-role / SSO / OIDC temporary credentials). The shared validator at [`deploy/scripts/_aws-auth.sh`](deploy/scripts/_aws-auth.sh) refuses to proceed if the resolved caller ARN doesn't match the declared mode — catches profile-override drift. See [`deploy/iam/README.md`](deploy/iam/README.md) § STS-assumed role setup.

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

# Full deploy (recommended for first time) — pick the orchestrator that matches NETWORK_MODE
# Probes SSM canaries; runs deploy-network.sh (account+region singleton) then
# deploy-shared.sh (account+region+env singleton) only if their canaries are
# missing, then deploy-project.sh. Each sub-script is independently rerunnable.
# PrivateLink mode (default, partner-validated):
./deploy/deploy-full-with-privatelink.sh [--auto-approve] [--skip-docker] [--skip-network] [--skip-shared]
# VPC peering mode (alternative, with experimental KB ingestion):
./deploy/deploy-full-with-vpc-peering.sh [--auto-approve] [--skip-docker] [--skip-network] [--skip-shared]

# Shared-only redeploy (when only the SageMaker endpoint / dashboards /
# Bedrock invocation logging / shared log-group retention changed).
# Singleton per (account, region, environment); all per-project ec2 stacks
# read its SSM outputs. Safe to re-run — idempotent.
./deploy/scripts/deploy-shared.sh [--auto-approve]

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
4. **API surface** should stay aligned with [`docs/api-reference.md`](docs/api-reference.md) (paths, SSE event names, error shape, auth error codes such as **`INVALID_TOKEN`**). If you change the contract, update that doc in the same change. **New cloud or data integrations** should go behind **`api/src/adapters/`** (extend **`resolveModel`**, **`mongo-data`**, fixtures, and **[`docs/deployment-guide.md`](docs/deployment-guide.md)** if env-var or build behavior changes) so **`DEV_MOCK_BACKENDS=1`** stays a complete local loop.
5. **Do not commit** `.env`, keys, or Terraform state. Follow [`.gitignore`](.gitignore).
6. **When run behavior or implementation status changes**, update [`docs/deployment-guide.md`](docs/deployment-guide.md) (Step 5 + top status box), [`docs/configuration-guide.md`](docs/configuration-guide.md), and [`docs/debugging.md`](docs/debugging.md) in the same change. **Docker / Compose / ECR scripts / CI image jobs:** also align this file's layout/commands if paths or build context change.
7. **When a pitfall has recurred more than twice** (or is a critical regression worth a permanent rule), add a concise entry to the **Known persistent pitfalls** section of [`docs/debugging.md`](docs/debugging.md). Ordinary bugs belong in PRs and commits.
8. **Use `logger` (not `console.log`) for new diagnostic output** in `api/src/`. Import from `./logger.ts` (or `../lib/logger.ts`). `console.log` / `console.error` in tests and Streamlit (`ui/`) are fine. For **new Streamlit-side diagnostics**, prefer `ui/lib/log.py` (`log.info` / `warn` / `error` / `debug`) so support can grep JSON in process logs the same way as the API.
9. **Any new deploy script that needs AWS credentials** must `source "$SCRIPT_DIR/_aws-auth.sh"` (or `"$SCRIPT_DIR/scripts/_aws-auth.sh"` if you live in `deploy/`) and call `validate_aws_auth || err "..."`. Don't reimplement the `AWS_ACCESS_KEY_ID`/`AWS_PROFILE` check or call `aws sts get-caller-identity` directly for the `ACCOUNT_ID` capture — read `AWS_AUTH_ACCOUNT_ID` from the validator's exports instead. See [`deploy/iam/README.md`](deploy/iam/README.md) § 4.

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
| `MEMORY_VECTOR_TOPK` | Top-K hits after RRF + MMR (default `14`; was `6` pre-2026-05, then `10`, raised to `14` after the harness showed C/D failing when same-run profile facts crowded out fresh transient chat-message codenames) |
| `MEMORY_VECTOR_FETCHK` | Per-leg over-fetch before merge (default `24`) |
| `MEMORY_VECTOR_NUM_CANDIDATES` | `$vectorSearch.numCandidates` width (default `200`) |
| `MEMORY_SEARCH_MAX_TIME_MS` | Server/client timeout for each Atlas vector/BM25 aggregation leg (default `8000`) |
| `MEMORY_EMBED_TIMEOUT_MS` | Query embedding timeout before lexical fallback (default `5000`) |
| `MEMORY_RECENCY_HALFLIFE_DAYS` | Exponential recency decay half-life; `0` disables (default `30`) |
| `MEMORY_MMR_LAMBDA` | 1 = pure relevance, 0 = pure diversity (default `0.7`) |
| `MEMORY_WEIGHT_FACTS` | Multiplier on `agent_memory_facts` RRF score (default `1.5`) |
| `MEMORY_WEIGHT_CHAT_MESSAGES` | Multiplier on `chat_messages` RRF score (default `1.2`; raised from `1` in 2026-05 so top-ranked chat hits aren't crowded out by facts) |
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
- System prompt assembly: `api/src/lib/prompt.ts` — `buildSystemPrompt(persona, discoveries, activated, memoryContext?)`. Long-term memory injected before skill sections. The exported constant `LONG_TERM_MEMORY_RECALL_RULES` is the **framework-canonical memory-recall block**: it's appended once via `withLongTermMemory(...)` so every memory-enabled persona inherits the same four non-negotiable rules ("use context proactively / never deny memory / don't re-ask / don't make up details"). Personas MUST NOT copy these rules inline — `api/tests/unit/orchestrator-ltm-flag.test.ts` enforces it.
- Long-term memory: `api/src/lib/long-term-memory.ts` — `readLongTermMemoryContext` (hybrid vector + BM25 retrieval across `agent_memory_facts` + `chat_messages`, fused with RRF / weights / recency / MMR) and `writeLongTermMemory` (LLM fact extraction → embed → `bulkWrite` upsert on `{ userId, factHash }`). Shared retrieval primitives live in `api/src/lib/vector-retrieval.ts`. Activated in `POST /chat` when agent has `memory.longTerm: true` and `userId` is known. `POST /chat` re-persists the trace doc after the dangling `writeLongTermMemory` microtask settles, so `memory.long_term_write` / `memory.long_term_skip` events reliably land in the stored trace — the Streamlit UI surfaces them via the "Learned …" expander + `st.toast` in `ui/lib/inline_summary.py`. AgentCore Memory Store remains the fallback when MongoDB writes fail. When `MONGODB_URI` is unset (e.g. **`DEV_MOCK_BACKENDS=1`**), `getMongoDb()` returns `null` and the retriever short-circuits to `null` memory context.
- Memory recall diagnostic harness: `e2e-smoke/memory-recall-diagnostic.py` — runs the same seven scenarios (intra-session, cross-session profile fact, chat_messages mirror, assistant-role recall, long-content, aged row, fact-vs-message tie-breaker), pulls the persisted `memory.scoped_read` event for each, and maps the observed retrieval metadata to one of seven labeled hypotheses (`H1` index status → `H7` recency decay). Scenarios run in **`SCENARIO_ORDER`** (`B → C → D → E → G → F → A`) on purpose, because scenario `A`'s "what was the code I just gave you" recall lexically collides with `C`'s notebook-tag recall — running `A` last keeps `C/D/E/G` clean. Defaults pin: `MEMORY_VECTOR_TOPK=14`, `MEMORY_WEIGHT_FACTS=1.5`, `MEMORY_WEIGHT_CHAT_MESSAGES=1.2`. Use `--cleanup` (delete prior harness sessions + harness-tagged Mongo rows) and `--cleanup-after` for clean re-runs. The harness auto-loads `.env.live` and **prefers `MONGODB_URI_PUBLIC`** (the public SRV URI emitted by `deploy-api.sh`) over `MONGODB_URI` (the PrivateLink direct URI, VPC-only) — so scenarios `C`/`F` (which need to write to `chat_messages` / backdate `ts` to validate H7) work from a laptop without an SSM-into-EC2 step. The API container itself still consumes `MONGODB_URI` (PrivateLink) — `MONGODB_URI_PUBLIC` is harness-only.
- Base tools: `api/src/lib/base-tools.ts` (includes per-skill `http-tools.json` under `config/skills/<skill>/`).
- HTTP tools metadata: `api/src/routes/http-tools-meta.ts` (`GET /http-tools`).
- Auth: `api/src/middleware/auth.ts` + `api/src/lib/jwt-verify.ts` — JWKS auth is mandatory. `assertJwksAuthConfigured()` runs at boot in `api/src/index.ts` and refuses to start without **`AUTH_JWKS_URI`** + **`AUTH_ISSUER`**. Every protected request is required to carry a valid Bearer JWT verified with **`jose`**; JWT `sub` is stored in `c.get("jwtPayload")?.sub` and used for session userId scoping. There is no `ALLOW_UNAUTHENTICATED` / `REQUIRE_AUTH=false` bypass.
- Session userId scoping: `api/src/lib/session-store.ts` carries `userId?`; `api/src/routes/sessions.ts` filters `GET /sessions` by user and enforces `DELETE` ownership.
- Structured logging: `api/src/lib/logger.ts` — JSON lines, level controlled by **`LOG_LEVEL`** (`error`|`warn`|`info`|`debug`; default `info`). Used across config-scan, skill-loader, mongo-data, base-tools, app error handler, chat/swarm streams.
- OpenTelemetry: `api/src/lib/otel.ts` — when **`OTEL_EXPORTER_OTLP_ENDPOINT`** is set (EC2 default: `http://127.0.0.1:4318`, ADOT sidecar), installs `NodeTracerProvider` + `BatchSpanProcessor` + `OTLPTraceExporter`. When unset, falls back to in-process tracing only. The Strands TS SDK auto-instruments via the global tracer provider — bump OTel deps in `api/package.json` only after checking the Strands 0.7 peer-dep matrix or you'll get two providers and silent span loss.
- TraceCollector OTel bridge: `api/src/lib/trace-collector.ts` — `start()` / `end()` / `event()` emit real OTel spans alongside the in-house event stream. Wrapped in try/catch so OTel exporter back-pressure can't destabilize the chat path. `attachEventsNested(...)` deliberately skips OTel re-emission because AgentCore Runtime emits its own `gen_ai.*` spans for the inner hop.
- Per-user cost attribution: `api/src/adapters/resolve-model.ts` instantiates `MetadataAwareBedrockModel` (a `BedrockModel` subclass) that reads `currentTrace().userId / agentId` at `stream()` time and injects them into `additionalArgs.requestMetadata`. Bedrock invocation logging surfaces them in `/aws/bedrock/invocations`, and the `<project>-cost-<env>` dashboard groups token usage by `requestMetadata.userId`. The model cache is per-agent (not per-user), so we mutate `_config` per call — relies on Strands 0.7 reading `_config` at request time.
- Custom metrics (EMF): `api/src/lib/cw-metrics.ts` emits **CloudWatch Embedded Metric Format** stdout JSON for `Multiagent/Chat`, `Multiagent/Mongo`, `Multiagent/Memory`. Call sites: `routes/chat.ts` (chat.turn.end), `adapters/agentcore-runtime.ts` (AgentCore invoke success + failure), `lib/trace-collector.ts` (bridges `mongo.query` / `mongo.vector_search` events), `lib/long-term-memory.ts` (write completion). Lock-down test: `api/tests/unit/cw-metrics.test.ts` — fails the moment a metric is renamed or a value moves off the top level of the EMF record. Disable in CI with `METRICS_EMITTER_ENABLED=0`. **Without this emitter the Phase 3 fleet dashboards stay empty and the latency / error-rate alarms go `INSUFFICIENT_DATA`.**
- OTel dependency pinning: Strands TS SDK 0.7 peers `@opentelemetry/{api,sdk-trace-*,resources,exporter-trace-otlp-http}` on the **OTel 1.30.x line** (exporters `^0.57.x`). `api/package.json` must stay inside that range or `gen_ai.*` spans silently drop — see [`docs/debugging.md` § Known persistent pitfalls](docs/debugging.md). Run `bun run validate:strands-otel` before merging any OTel dep bump.
- Prompt-body logging: `var.log_prompt_bodies` and `var.log_embedding_bodies` default to **false** in `modules/bedrock-invocation-logging`. Flip per-environment only with audit sign-off; the attached Data Protection Policy still masks PII even when bodies are on, but the body is written before scrubbing. See `docs/observability-runbook.md` §3 for the checklist.
- HTTP + SSE: `api/src/routes/chat.ts`.
- Tracing: `api/src/lib/trace-types.ts` (event union), `api/src/lib/trace-collector.ts` (per-turn collector + cost summary + byte cap + nested splice + `buildSpanTree()` + `captureOtelIds()` + `recordSkillResourceRead()`), `api/src/lib/trace-context.ts` (`AsyncLocalStorage`), `api/src/lib/trace-store.ts` (ring buffer + MongoDB persistence with TTL), `api/src/routes/trace.ts` (`GET /traces/:id`, `GET /trace`, `GET /trace/mongo`, `GET /traces`), `api/src/lib/trace-projection.ts` (`projectTraceForInclude` powers `?include=core|dev|full`). UI: `ui/lib/inline_summary.py` (per-turn card), `ui/pages/2_Trace_Viewer.py` (full dashboard) wired to `ui/lib/client_trace_view.py` (demo-friendly renderers), `ui/lib/developer_trace_view.py` (debug-grade `_dev_*` sub-renderers, button-gated lazy load of `?include=dev`), and `ui/lib/trace_view_helpers.py` (shared helpers including `_omittedForCoreMode` sentinel handling). Streamlit chat surfaces vector-search source previews via browser-native `title=` tooltips; treat `mongo.vector_search.documentPreviews[]` as the user-visible source-preview contract.
- Debug-grade Trace Viewer (PR2): the Streamlit Trace Viewer fetches `?include=core` on initial load (lite projection, dev-only event types + heavy fields replaced with `{ _omittedForCoreMode: true, bytesAvailable: N, wasRedacted? }` sentinels) and `?include=dev` on demand when the user clicks "Show developer details". The API responds with `X-Trace-Include: core|dev|full`; `ui/lib/api_client.py:get_trace` asserts the header matches so a routing regression that silently downgrades the projection becomes a UI-test failure. Audit log channel emits `[trace] fetch` with `include` field for SOC2 review. Developer-only top-level fields (`release`, `correlation`, `otel`, `spanTree`) live outside `core` mode; the panel renders ServiceLens / X-Ray deep links from `trace.otel`.
- Tiered trace truncation caps + `dev.byte_cap_hit`: per-event-type cap table in `trace-collector.ts` keeps debug fields (`prompt.assembled.body`, `model.request.userMessage`, `agentcore.invoke.payload`/`responseBody`, `model.text_delta_batch.text`, `tool.call.input`/`result`, …) at 64 KB and everything else at the historical 512-char cap, with `PII_KEYS` always redacted (with a narrow `PII_EXEMPT_FIELDS` allow-list so `skill.activated.name` is not stomped to `[redacted]`). When a payload still exceeds the per-event / per-turn byte caps, a `dev.byte_cap_hit` event lands in the trace (capped at 50 emissions/turn) so the Developer details Byte-cap sub-section can show exactly which event type lost bytes — replaces the old silent-drop behavior.
- Strands SDK retry hook: model retries on the Bedrock SDK side run through `TracingRetryStrategy` (subclass of `@smithy/util-retry`'s `ConfiguredRetryStrategy` in `api/src/adapters/resolve-model.ts`) — each `refreshRetryTokenForRetry` call emits a `model.retry` event with `attempt / previousErrorClass / backoffMs`. AgentCore Runtime retries use a manual loop in `api/src/adapters/agentcore-runtime.ts` so each attempt emits `agentcore.retry` (retryable classes pinned by `isRetryableAgentcoreError`). Run `bun run validate:strands-retries` before bumping the Strands SDK to confirm the hook surface (`AfterModelCallEvent.retry`) is still exported.

Still open: **AgentCore Code Interpreter** (skill scripts still run as `.mjs` imports); customer-scoped multi-tenancy on operational collections; browser/Streamlit E2E; CI/CD as the primary deploy path beyond `ci.yml` + `deploy.yml`; **ECS/ALB** rollout automation beyond EC2 + container images.

Implemented: Streamlit **Cognito** (`streamlit-cognito-auth`, `ui/lib/cognito_gate.py`) — hosted UI or embedded login when `STREAMLIT_COGNITO_POOL_ID` + `CLIENT_ID` are set; Bearer = Cognito access token. TTL indexes on `agent_memory_facts` and `chat_messages` are auto-created on first production write; Atlas Vector Search + BM25 indexes for those collections are seeded by `db-seeding/seed-indexes.ts`. `config/environment.yaml` is parsed by `api/src/lib/environment-config.ts` for `api.port` / `api.corsOrigins` defaults.

---

## Documentation map

| Doc | Use when |
|-----|----------|
| [`docs/README.md`](docs/README.md) | **Client handover entry point** — first-day checklist, reading orders, doc map |
| [`docs/debugging.md`](docs/debugging.md) | Developer playbook — EC2 access, common failures, trace-driven debug, persistent pitfalls, validation scripts |
| [`docs/architecture.md`](docs/architecture.md) | System design, 5-runtime topology, request flow |
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | Deploy (PrivateLink + VPC peering), CI/CD, teardown |
| [`docs/configuration-guide.md`](docs/configuration-guide.md) | Env vars, mode flags, agent + skill schema |
| [`docs/api-reference.md`](docs/api-reference.md) | HTTP + SSE, projections, auth |
| [`docs/agent-authoring-guide.md`](docs/agent-authoring-guide.md) | `.agent.md` format |
| [`docs/skills-authoring-guide.md`](docs/skills-authoring-guide.md) | `SKILL.md` and progressive disclosure |
| [`docs/memory-architecture.md`](docs/memory-architecture.md) + [`docs/long-term-memory-design.md`](docs/long-term-memory-design.md) | Short-term + long-term memory |
| [`docs/hybrid-search.md`](docs/hybrid-search.md) | Vector + BM25 hybrid search |
| [`docs/logging-architecture.md`](docs/logging-architecture.md) | Structured JSON logger, OTel correlation, CloudWatch + ADOT sidecar, audit channel |
| [`docs/observability-runbook.md`](docs/observability-runbook.md) | Day-2 ops — finding traces, log groups, alarms, dashboards, emergency knobs |
| [`docs/trace-ui-system-overview.md`](docs/trace-ui-system-overview.md) + [`docs/trace-viewer-client-guide.md`](docs/trace-viewer-client-guide.md) + [`docs/trace-viewer-developer-guide.md`](docs/trace-viewer-developer-guide.md) | Trace UI surfaces |
| [`docs/agentcore-runtime-design.md`](docs/agentcore-runtime-design.md) | 5-runtime topology, artifact strategy |
| [`docs/dashboards/README.md`](docs/dashboards/README.md) | CloudWatch dashboard widget catalog, alarm thresholds |
| [`docs/demo-script.md`](docs/demo-script.md) + [`docs/demo-mode-guide.md`](docs/demo-mode-guide.md) | Demo walkthrough + trace UI knobs |
| [`docs/estimate.md`](docs/estimate.md) | Monthly AWS cost estimate |
| [`docs/reference/`](docs/reference/) | **Reference appendix** — env vars, Terraform modules, SSM, data model, smoke tests, deploy scripts |

---

## Naming disambiguation

| Name | Meaning |
|------|--------|
| **This file (`AGENTS.md`)** | Instructions for **coding agents / developers** working on the repo |
| **`config/agents/*.agent.md`** | **Runtime** LLM agent definitions (orchestrator, order, product, troubleshoot) |

If a task says “add an agent,” it usually means a **new `.agent.md` + skill**, not editing `AGENTS.md`.
