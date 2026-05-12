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
9. **Use `logger` (not `console.log`) for new diagnostic output** in `api/src/`. Import from `./logger.ts` (or `../lib/logger.ts`). `console.log` / `console.error` in tests and Streamlit (`ui/`) are fine.

---

## Memory — config and setup

### Short-term memory

Conversation history is stored in `api/src/lib/session-store.ts` (in-memory `Map`) and — when `MONGODB_URI` is set — mirrored to the `chat_sessions` collection (default-on; set `PERSIST_CHAT_SESSIONS=0` to opt out). It is replayed into the Strands `Agent` as `messages: seed` on each turn under the live chat path (default; set `CHAT_MODE=stub` to disable). AgentCore-backed durable sessions are planned.

The `memory.shortTerm` frontmatter flag is parsed but has no additional runtime effect today beyond the default replay behavior. Set to `false` only for fully stateless agents (e.g. a one-shot lookup) where replaying prior turns would be wasteful.

### Long-term memory

Keyed by **`userId`** (JWT `sub` claim) and **`agentId`**. Activated only when both are present. Implementation: `api/src/lib/long-term-memory.ts`.

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
| `MONGODB_DB` | Database name. Project+env-derived (underscored) by `env.sh`, e.g. `mongodb_multiagent_dev` |
| `REQUIRE_AUTH=true` | Force Bearer token on every request |
| `AUTH_JWKS_URI` | JWKS endpoint (e.g. Cognito pool) |
| `AUTH_ISSUER` | Token issuer URL (e.g. Cognito pool URL) |
| `MEMORY_INJECT_TURNS` | Past turns to inject into system prompt (default: `5`) |

**One-time MongoDB setup** (create TTL index):

```js
// mongosh or Atlas Data Explorer
db.agent_memory.createIndex({ ts: 1 }, { expireAfterSeconds: 7776000 }) // 90 days
```

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
2. If `agent.memory.longTerm && userId`: call `readLongTermMemory(userId, agentId)` → formatted string
3. Pass `memoryContext` into `buildSystemPrompt(…)` → prepended as `## Context from previous sessions`
4. Stream completes successfully → `writeLongTermMemory(userId, agentId, userMessage, assistantReply)`

**Collection schema:** `{ userId, agentId, userMessage, assistantReply, ts: ISOString }`

**Limits:** `userMessage` capped at 2 000 chars, `assistantReply` at 4 000 chars before storage. Mock store capped at 20 entries per `userId:agentId` key.

---

## Strands / Bedrock touchpoints

- Chat streaming pipeline: `api/src/lib/run-chat-stream.ts` (gated via `chatMode()` from `runtime-defaults.ts`, default `live`), optional Swarm in `api/src/lib/swarm-chat-stream.ts` (roster built dynamically from `listAgents()` — no hardcoded list).
- Agent construction: `api/src/lib/create-strands-agent.ts` and `resolveModel` in `api/src/adapters/resolve-model.ts` (`BedrockModel` vs `DevMockModel` when **`DEV_MOCK_BACKENDS=1`**; tools, prompts, optional `memoryContext`).
- Skill loading: `api/src/lib/skill-loader.ts` (activated skill bodies + `read_skill_resource`).
- Agent metadata + persona: `api/src/lib/config-scan.ts`, `api/src/lib/prompt.ts`, `api/src/lib/schemas.ts`. `AgentDetail` exposes the `memory` object (shortTerm / longTerm flags).
- System prompt assembly: `api/src/lib/prompt.ts` — `buildSystemPrompt(persona, discoveries, activated, memoryContext?)`. Long-term memory injected before skill sections.
- Long-term memory: `api/src/lib/long-term-memory.ts` — `readLongTermMemory` / `writeLongTermMemory` against MongoDB `agent_memory` collection (or in-process mock map when **`DEV_MOCK_BACKENDS=1`**). Activated in `POST /chat` when agent has `memory.longTerm: true` and `userId` is known.
- Base tools: `api/src/lib/base-tools.ts` (includes per-skill `http-tools.json` under `config/skills/<skill>/`).
- HTTP tools metadata: `api/src/routes/http-tools-meta.ts` (`GET /http-tools`).
- Auth: `api/src/middleware/auth.ts` + `api/src/lib/jwt-verify.ts` — when **`REQUIRE_AUTH=true`** and **`AUTH_JWKS_URI`** + **`AUTH_ISSUER`** are set, JWTs are verified with **`jose`**; JWT `sub` stored in `c.get("jwtPayload")?.sub` and used for session userId scoping.
- Session userId scoping: `api/src/lib/session-store.ts` carries `userId?`; `api/src/routes/sessions.ts` filters `GET /sessions` by user and enforces `DELETE` ownership.
- Structured logging: `api/src/lib/logger.ts` — JSON lines, level controlled by **`LOG_LEVEL`** (`error`|`warn`|`info`|`debug`; default `info`). Used across config-scan, skill-loader, mongo-data, base-tools, app error handler, chat/swarm streams.
- HTTP + SSE: `api/src/routes/chat.ts`.
- Tracing: `api/src/lib/trace-types.ts` (event union), `api/src/lib/trace-collector.ts` (per-turn collector + cost summary + byte cap + nested splice), `api/src/lib/trace-context.ts` (`AsyncLocalStorage`), `api/src/lib/trace-store.ts` (ring buffer + MongoDB persistence with TTL), `api/src/routes/trace.ts` (`GET /traces/:id`, `GET /trace`, `GET /trace/mongo`, `GET /traces`). UI: `ui/lib/inline_summary.py` (per-turn card), `ui/pages/2_Trace_Viewer.py` (full dashboard).

Still open (see `TASKS.md` + `DEV_STATUS.md`): **AgentCore** (gateway, durable sessions, code interpreter — SDK smoke-tested via `bun run validate:agentcore`); production Atlas vector / Bedrock KB / embedding backends (beyond **`DEV_MOCK_BACKENDS`** stubs); **persistent** sessions across restarts; **ECS/ALB** rollout automation beyond container images + scripts.

Implemented: Streamlit **Cognito** (`streamlit-cognito-auth`, `ui/lib/cognito_gate.py`) — hosted UI or embedded login when `STREAMLIT_COGNITO_POOL_ID` + `CLIENT_ID` are set; Bearer = Cognito access token. TTL index on `agent_memory` is **auto-created** on the first production write (no manual step). `config/environment.yaml` is parsed by `api/src/lib/environment-config.ts` for `api.port` / `api.corsOrigins` defaults.

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
| [`docs/demo-mode-guide.md`](docs/demo-mode-guide.md) | Trace UI walkthrough + env knobs for client demos |

---

## Naming disambiguation

| Name | Meaning |
|------|--------|
| **This file (`AGENTS.md`)** | Instructions for **coding agents / developers** working on the repo |
| **`config/agents/*.agent.md`** | **Runtime** LLM agent definitions (orchestrator, order, product, troubleshoot) |

If a task says “add an agent,” it usually means a **new `.agent.md` + skill**, not editing `AGENTS.md`.
