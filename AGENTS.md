# Guidance for AI coding agents

This file is for **human and AI contributors** who edit the repository in Cursor, Copilot, or similar tools. It is **not** a Strands/Bedrock agent definition.

**Runtime agent personas** live under [`config/agents/`](config/agents/) as `.agent.md` files. **Domain knowledge** lives under [`config/skills/`](config/skills/) as `SKILL.md` trees.

---

## What this project is

A **configuration-driven multi-agent reference** on **AWS Bedrock** (via [Strands Agents SDK](https://github.com/strands-agents/sdk-typescript)) and **MongoDB Atlas**. Add specialists by editing markdown config, not by forking business logic for every customer.

**Request path (production):** Streamlit UI → Hono API → **in-API classifier** (`agent-classifier.ts`) → specialist **AgentCore Runtime** (single hop). Mongo tools go through a dedicated **MongoDB MCP AgentCore Runtime**. `USE_ORCHESTRATOR_RUNTIME=1` enables a two-hop rollback through the orchestrator runtime.

**Five AgentCore Runtimes:** orchestrator + 3 specialists (`order-management`, `product-recommendation`, `troubleshooting`) + MongoDB MCP.

**Connectivity modes** (mutually exclusive per account+region): `NETWORK_MODE=privatelink` (default) or `NETWORK_MODE=peering`. Switching requires destroy + redeploy.

**Getting started:** [`docs/README.md`](docs/README.md) — doc map, first-day checklist, reading orders.

**Debugging:** [`docs/status/debugging.md`](docs/status/debugging.md) — EC2 access, trace-driven debug, common failures, validation scripts, **persistent pitfalls**. When a non-obvious regression recurs more than twice (or is a severe guardrail like hung CI / infinite Strands loop), add an entry to **Known persistent pitfalls** in the same PR as the fix.

**Reference appendix:** [`docs/reference/`](docs/reference/) — env vars, tools, Terraform modules, SSM parameters, data model, smoke tests, deploy scripts.

---

## Getting started (new contributor)

> **Just cloned?** Read [`README.md`](README.md) first for the full walkthrough, then return here when you change code.

### Step 1 — Install tools

Bun, Python 3.10+, AWS CLI v2, Terraform ≥ 1.6, Docker (EC2 deploys), `zip`/`curl`. Install commands: [README § Prerequisites](README.md#prerequisites).

### Step 2 — Configure `.env`

```bash
git clone <repo-url>
cd mongodb-aws-bedrock-multi-agent-framework

cp .env.sample .env    # never commit this file
```

Edit `.env` before any deploy. Minimum fields (see [`.env.sample`](.env.sample) for the full list):

| Section | What to set |
|---|---|
| AWS auth | `AUTH_MODE`, then either IAM keys or STS/`AWS_PROFILE` (see [`deploy/iam/README.md`](deploy/iam/README.md)) |
| Region + identity | `AWS_REGION`, `ENVIRONMENT`, `PROJECT_NAME`, `SHARED_VPC_NAME` |
| Atlas | `MONGODB_ATLAS_PUBLIC_KEY`, `MONGODB_ATLAS_PRIVATE_KEY`, `TF_VAR_mongodb_atlas_org_id`, `TF_VAR_mongodb_atlas_project_id`, `TF_VAR_atlas_db_password` |
| Embeddings | `EMBEDDINGS_PROVIDER` is **mandatory** in every environment (deployed and local). [`.env.sample`](.env.sample) defaults to `titan` (simplest first-deploy path — no Voyage Marketplace required). Switch to `voyage` for Voyage multimodal embeddings. Strict — no implicit default, no cross-provider fallback at runtime. Both `assertEmbeddingsProvider()` (API boot) and `deploy-project.sh` refuse to run if it's unset / unrecognised. |

Then:

```bash
source .env
aws sts get-caller-identity    # must succeed before deploy
```

### Step 3 — Install app dependencies

```bash
export PATH="$HOME/.bun/bin:$PATH"
cd api && bun install && cd ..
cd ui && pip install -r requirements.txt && cd ..
```

### Step 4 — Deploy and run

The API **refuses to boot** without `AUTH_JWKS_URI`, `AUTH_ISSUER`, and `AGENTCORE_ORCHESTRATOR_ARN` ([boot guards](#api-boot-guards)). A fresh clone cannot run `bun run dev` until a deploy writes those into `.env.live`.

#### Recommended first-time path (runnable chat stack)

Full EC2 deploy (~30–45 min). Provisions Cognito, AgentCore runtimes, EC2, Atlas, KB — everything needed to chat.

```bash
source .env
./deploy/deploy-full-with-privatelink.sh --auto-approve
# Full post-deploy smoke runs in deploy-project.sh Phase 11 (use --skip-smoke to skip).
# Re-run manually: source .env && python3 e2e-smoke/post-deploy-smoke.py
```

When the script finishes, open the **UI URL** it prints (Streamlit on EC2, port 8501). Sign in with the Cognito test user from the deploy output.

Alternative connectivity: `./deploy/deploy-full-with-vpc-peering.sh --auto-approve` (mutually exclusive with PrivateLink).

Optional IAM pre-check: `bash deploy/scripts/probe-resources.sh` (add `--all` for the full matrix).

#### Run API + UI on your laptop (after a full EC2 deploy)

Use this when developing `api/` or `ui/` code locally while AgentCore runtimes stay in AWS. Requires `.env.live` from `deploy-project.sh` / the full orchestrator (contains JWKS, ARNs, Mongo URIs).

```bash
source .env && source .env.live

# Terminal 1 — API (repo root → api/)
export PATH="$HOME/.bun/bin:$PATH"
cd api && bun run dev

# Terminal 2 — UI (defaults to http://127.0.0.1:3000 — override with STREAMLIT_API_URL if needed)
cd ui && streamlit run app.py
```

Open `http://localhost:8501`. You need a **valid Cognito JWT** — configure `STREAMLIT_COGNITO_*` in `.env.live` / your shell (same pool as `AUTH_JWKS_URI`). There is no anonymous or stub-token bypass on protected API routes.

#### `deploy-local.sh` — partial infra only (not a full chat stack)

```bash
./deploy/scripts/deploy-local.sh --auto-approve
```

Provisions Atlas M10 + Bedrock KB + AgentCore Memory store via `envs/local` — **no EC2, no AgentCore runtimes, no Cognito JWKS**. The generated `.env.live` leaves `AUTH_JWKS_URI` / `AGENTCORE_ORCHESTRATOR_ARN` empty, so **`bun run dev` will still fail** until you run a full EC2 deploy and merge its `.env.live` values. See [`docs/deployment-guide.md`](docs/deployment-guide.md) §4.

---

## API boot guards

`api/src/index.ts` runs these **before** the HTTP listener binds. There is no unauthenticated or JWKS-free escape hatch.

| Guard | Env vars | File |
|---|---|---|
| JWKS auth | `AUTH_JWKS_URI`, `AUTH_ISSUER` | `lib/jwt-verify.ts` |
| Short-term backend | `SHORT_TERM_MEMORY_BACKEND=agentcore` requires `AGENTCORE_MEMORY_STORE_ID` | `lib/short-term-memory.ts` |
| AgentCore orchestrator | `AGENTCORE_ORCHESTRATOR_ARN` (or legacy `AGENTCORE_RUNTIME_ARN`) | `adapters/agentcore-runtime.ts` |
| Embeddings provider | `EMBEDDINGS_PROVIDER` + provider-specific vars | `lib/assert-embeddings-provider.ts` |

Deploy scripts write runtime ARNs, Cognito JWKS, and memory store IDs into `.env.live`. Source both `.env` and `.env.live` for local dev.

---

## Repository layout

| Path | Role |
|---|---|
| `api/` | Bun + TypeScript + Hono HTTP API (SSE chat, sessions, agents/skills metadata, JWT/JWKS); [`Dockerfile`](api/Dockerfile) (build context = **repo root**). Also bundles `agent-runtime-code.ts` for AgentCore **code-mode** runtimes. |
| `ui/` | Streamlit chat UI (`app.py` + `pages/1_Sessions.py`, `pages/2_Trace_Viewer.py`); [`Dockerfile`](ui/Dockerfile) (context = **`ui/`**) |
| `mcp-runtimes/mongodb-mcp/` | MongoDB MCP server as AgentCore Runtime (container, ARM64). Streamable HTTP `0.0.0.0:8000/mcp`. Tools: `mongodb_query`, `mongodb_vector_search`, `mongodb_aggregate`. |
| `config/agents/` | `.agent.md` — persona YAML frontmatter + markdown body (4 shipped: orchestrator + 3 specialists) |
| `config/skills/` | `SKILL.md` + optional `references/`, `scripts/`, `http-tools.json` |
| `config/http-tools.json` | Optional global HTTP tools + `security` host allowlist |
| `config/environment.yaml` | API defaults (port, CORS) |
| `config/demo-prompts.yaml` | Sidebar "Try a prompt" entries for Streamlit |
| `db-seeding/` | Atlas demo data + vector/BM25 index seed scripts (`seed-all.ts`, `seed-indexes.ts`, …) |
| `deploy/` | Terraform (`envs/`, `modules/`, `bootstrap/`), shell scripts, IAM policy, KB doc sources |
| `deploy/deploy-full-with-privatelink.sh` | Orchestrator — network → shared → project (PrivateLink) |
| `deploy/deploy-full-with-vpc-peering.sh` | Orchestrator — same phases (VPC peering mode) |
| `deploy/deploy-api.sh` | API image-only redeploy |
| `deploy/deploy-ui.sh` | UI image-only redeploy |
| `deploy/deploy-agents.sh` | Agent config + AgentCore runtime code artifact only |
| `deploy/scripts/` | `deploy-network.sh`, `deploy-shared.sh`, `deploy-project.sh`, `deploy-local.sh`, `destroy.sh`, `probe-resources.sh`, `docker-build.sh`, … |
| `deploy/terraform/` | **Four live root configs:** [`envs/network`](deploy/terraform/envs/network) (shared VPC + Atlas connectivity, singleton per account+region), [`envs/shared`](deploy/terraform/envs/shared) (Voyage SageMaker + CloudWatch log groups + dashboards + Bedrock invocation logging, singleton per account+region+env), [`envs/ec2`](deploy/terraform/envs/ec2) (per-project EC2 + ECR + Cognito + KB + AgentCore), [`envs/local`](deploy/terraform/envs/local) (laptop — Atlas + KB + Cognito, no EC2). Network + shared publish SSM under `/<SHARED_VPC_NAME>/<region>/`; `ec2` reads them. |
| `e2e/` | Playwright API specs — run against a **live** API (`API_URL=… bun run test`) |
| `e2e-smoke/` | Python post-deploy live-AWS smoke + `memory-recall-diagnostic.py` |
| `compose.yaml` | Docker Compose for API + Streamlit (requires JWKS + AgentCore ARNs in `.env`) |
| `Makefile` | `make docker-up`, `docker-build`, `docker-down`, `docker-logs` |
| `.dockerignore` | Root ignore rules for **`api/Dockerfile`** builds |
| `docs/` | Canonical getting started pack — start at [`docs/README.md`](docs/README.md) |

The **implemented** layout is **`api/` + `ui/` + `mcp-runtimes/` + `deploy/` + `config/`**. There is no `apps/` / `packages/` workspace split. If you add a top-level directory, register it here.

---

## Commands

See [`docs/deployment-guide.md`](docs/deployment-guide.md) for the full deploy matrix and [`docs/reference/deploy-scripts.md`](docs/reference/deploy-scripts.md) for every script flag + phase index.

**AWS auth:** every script under [`deploy/`](deploy/) honors `AUTH_MODE` in `.env` (`iam` default; `sts` for SSO/OIDC). Validator: [`deploy/scripts/_aws-auth.sh`](deploy/scripts/_aws-auth.sh). See [`deploy/iam/README.md`](deploy/iam/README.md).

### Local development

After a **full EC2 deploy** (see [Step 4](#step-4--deploy-and-run)):

```bash
source .env
source .env.live   # bash-source-safe variant emitted by deploy/scripts/_env-live.sh

export PATH="$HOME/.bun/bin:$PATH"

# Terminal 1 — API
cd api
bun run typecheck && bun run validate:bun && bun run validate:agentcore
bun run dev

# Terminal 2 — UI  (API URL defaults to http://127.0.0.1:3000; set STREAMLIT_API_URL to override)
cd ui
streamlit run app.py
```

**Fixtures mode** (`DEV_MOCK_BACKENDS=1`) swaps Bedrock/Mongo tool calls for in-process fixtures. Boot guards still apply — you still need JWKS + AgentCore ARN from `.env.live`:

```bash
export DEV_MOCK_BACKENDS=1
source .env && source .env.live
cd api && bun run dev
```

Every protected route requires a **valid Cognito Bearer JWT** verified against `AUTH_JWKS_URI`. There is no `REQUIRE_AUTH=false` bypass.

> **About the two env files.** The deploy scripts emit a *pair* of files at the repo root and ship both to `/opt/multiagent/` on EC2:
>
> - **`.env.docker`** — plain `KEY=VALUE`, no quotes. Consumed by `docker run --env-file` from `multiagent-{api,ui}.service` (Docker's `--env-file` parser treats quotes as literal characters in the value, so the file MUST be unquoted).
> - **`.env.live`** — bash-source-safe `KEY="value"` with backslash/quote/dollar/backtick escapes. Always safe to `source` directly. This is the one you use for laptop dev.
>
> Both files are written from the same canonical schema by [`deploy/scripts/_env-live.sh`](deploy/scripts/_env-live.sh) — never hand-edit one without the other.

**Agent/skill config changes:** the API rescans `config/agents/` on disk (mtime cache), but specialist **behavior inside AgentCore** requires `./deploy/deploy-agents.sh --auto-approve` to rebuild the code artifact and update runtimes.

### Validation and tests (pre-PR)

Matches [`.github/workflows/ci.yml`](.github/workflows/ci.yml):

```bash
# API — run from api/
export PATH="$HOME/.bun/bin:$PATH"
cd api
bun install
bun run typecheck
bun run validate:bun
bun run validate:agentcore
bun run validate:strands-otel      # before any OTel dep bump
bun run validate:strands-retries   # before any Strands SDK bump
bun run test                       # unit tests
bun run test:all                   # unit + integration (integration is env-gated)

# UI — run from ui/
cd ui && pip install -r requirements.txt && python -m pytest tests/ -v

# Playwright — against a live API only (no in-tree stub server)
cd e2e && bun install && bunx playwright install chromium
API_URL=http://localhost:3000 bun run test

# Post-deploy live AWS smoke (auto in deploy-project.sh Phase 11; manual re-run):
source .env && python3 e2e-smoke/post-deploy-smoke.py

# Memory recall diagnostic (seven scenarios, hypothesis labels H1–H7)
source .env && python3 e2e-smoke/memory-recall-diagnostic.py --cleanup --cleanup-after
```

**MongoDB seeding** (once per environment, from repo root):

```bash
export MONGODB_URI="..." MONGODB_DB="..."
bun db-seeding/seed-all.ts
# then, with AWS creds for embeddings:
bun db-seeding/seed-embeddings.ts
```

See [`db-seeding/README.md`](db-seeding/README.md).

**Terraform sanity check:**

```bash
cd deploy/terraform/envs/ec2 && terraform init && terraform validate
```

### Deployment

Always `source .env` first (or pass `--env-file`). Targeted redeploys (`deploy-api.sh`, `deploy-ui.sh`, `deploy-agents.sh`) require a prior successful `deploy-project.sh` / full orchestrator run.

#### `deploy-full-with-privatelink.sh`

First deploy or PrivateLink mode. Probes SSM canaries; runs `network → shared → project` as needed.

```bash
source .env
./deploy/deploy-full-with-privatelink.sh --auto-approve
./deploy/deploy-full-with-privatelink.sh --auto-approve --skip-docker
./deploy/deploy-full-with-privatelink.sh --auto-approve --skip-network
./deploy/deploy-full-with-privatelink.sh --auto-approve --skip-shared
./deploy/deploy-full-with-privatelink.sh --env-file /path/to/.env
```

#### `deploy-full-with-vpc-peering.sh`

VPC peering mode — **mutually exclusive** with PrivateLink. Same flag surface.

```bash
source .env
./deploy/deploy-full-with-vpc-peering.sh --auto-approve
./deploy/deploy-full-with-vpc-peering.sh --auto-approve --skip-network --skip-shared
```

#### `deploy-api.sh`

When only `api/` or API-bundled config changed. Rebuilds API image, regenerates `.env.live`, restarts `multiagent-api`.

```bash
./deploy/deploy-api.sh
./deploy/deploy-api.sh --skip-docker --skip-smoke
./deploy/deploy-api.sh --env-file /path/to/.env
```

Run first when Cognito, Atlas, or OTel env vars changed.

#### `deploy-ui.sh`

When only `ui/` changed. Does **not** regenerate `.env.live`.

```bash
./deploy/deploy-ui.sh
./deploy/deploy-ui.sh --skip-docker --skip-smoke
```

#### `deploy-agents.sh`

When only `config/agents/*.agent.md` or `config/skills/` changed. Re-bundles code artifact, targeted Terraform on AgentCore runtimes, refreshes API agent cache — no API/UI restart.

```bash
./deploy/deploy-agents.sh --auto-approve
./deploy/deploy-agents.sh --auto-approve --skip-smoke
./deploy/deploy-agents.sh --auto-approve --allow-destroy
./deploy/deploy-agents.sh --auto-approve --force
```

#### Other deploy scripts

```bash
source .env

# Partial laptop infra (Atlas + KB + memory) — NOT a runnable chat stack alone; see Step 4
./deploy/scripts/deploy-local.sh --auto-approve

# Shared observability + embeddings only (singleton per account+region+env)
./deploy/scripts/deploy-shared.sh --auto-approve

# Tear down (order matters: ec2 → shared → network → local)
./deploy/scripts/destroy.sh --mode ec2     --auto-approve
./deploy/scripts/destroy.sh --mode shared  --auto-approve
./deploy/scripts/destroy.sh --mode network --auto-approve
./deploy/scripts/destroy.sh --mode local   --auto-approve
```

### Docker

```bash
docker compose up --build    # needs .env with JWKS + AgentCore ARNs
# or: make docker-up
# or: ./deploy/scripts/docker-build.sh && docker compose up
```

---

## Conventions for code changes

1. **Match existing style** in each area: TypeScript in `api/src` (explicit `.ts` imports, Hono route modules), Python in `ui/`, HCL in `deploy/terraform/`.
2. **Prefer extending** `api/src/lib/` (loaders, prompt assembly, chat pipeline) and `api/src/routes/` over growing a single huge file.
3. **Domain behavior** belongs in **`config/skills/`** and **`config/agents/`**, not in ad-hoc strings inside route handlers — unless clearly temporary scaffolding.
4. **API surface** stays aligned with [`docs/api-reference.md`](docs/api-reference.md) (paths, SSE events, error shape, auth codes like **`INVALID_TOKEN`**). New cloud/data integrations go behind **`api/src/adapters/`** so **`DEV_MOCK_BACKENDS=1`** remains a complete local loop where applicable.
5. **Do not commit** `.env`, keys, or Terraform state. Follow [`.gitignore`](.gitignore).
6. **When run behavior or implementation status changes**, update [`docs/deployment-guide.md`](docs/deployment-guide.md) (Step 5 + top status box), [`docs/configuration-guide.md`](docs/configuration-guide.md), and [`docs/status/debugging.md`](docs/status/debugging.md) in the same change. **Docker / Compose / ECR scripts / CI image jobs:** also align this file's layout/commands if paths or build context change.
7. **When a pitfall has recurred more than twice** (or is a critical regression worth a permanent rule), add a concise entry to the **Known persistent pitfalls** section of [`docs/status/debugging.md`](docs/status/debugging.md). Ordinary bugs belong in PRs and commits.
8. **Use `logger` (not `console.log`) for new diagnostic output** in `api/src/`. Import from `./logger.ts` (or `../lib/logger.ts`). `console.log` / `console.error` in tests and Streamlit (`ui/`) are fine. For **new Streamlit-side diagnostics**, prefer `ui/lib/log.py` (`log.info` / `warn` / `error` / `debug`) so support can grep JSON in process logs the same way as the API.
9. **Any new deploy script that needs AWS credentials** must `source "$SCRIPT_DIR/_aws-auth.sh"` (or `"$SCRIPT_DIR/scripts/_aws-auth.sh"` if you live in `deploy/`) and call `validate_aws_auth || err "..."`. Don't reimplement the `AWS_ACCESS_KEY_ID`/`AWS_PROFILE` check or call `aws sts get-caller-identity` directly for the `ACCOUNT_ID` capture — read `AWS_AUTH_ACCOUNT_ID` from the validator's exports instead. See [`deploy/iam/README.md`](deploy/iam/README.md) § 4.
10. **Any new deploy script that mutates AWS / Atlas state** must also `source "$SCRIPT_DIR/_preflight-checks.sh"` and call `preflight_validate <profile>` immediately after AWS auth. Add the new checks to the appropriate `PREFLIGHT_PROFILE_*` array in [`deploy/scripts/_preflight-checks.sh`](deploy/scripts/_preflight-checks.sh) and document them in [`docs/deployment-preflight-checks.md`](docs/deployment-preflight-checks.md). Do **not** delete or refactor the existing inline guards — preflight runs **in addition** to them. Verify with `bash deploy/scripts/_preflight-checks.sh --self-test` before merging.
11. **Voyage AI knowledge lives in the SSOT — never hand-roll it elsewhere.** All Voyage configuration, the multimodal request envelope, the embedding dimension, the supported-model list, and the env-var reads must come from exactly one of three files:
    - TS SSOT: [`api/src/adapters/voyage-embedding.ts`](api/src/adapters/voyage-embedding.ts) (`SUPPORTED_VOYAGE_MODELS`, `VOYAGE_EMBEDDING_DIMS`, `buildVoyageRequestBody`, `textToMultimodal`, `multimodalItemSchema`, env getters / assertions, `voyageGenerateEmbedding(s)`).
    - CLI bridge: [`api/scripts/voyage-print.ts`](api/scripts/voyage-print.ts) (`bun api/scripts/voyage-print.ts body|models|dims`).
    - Bash SSOT: [`deploy/scripts/_voyage-config.sh`](deploy/scripts/_voyage-config.sh) (`voyage_canonical_body`, `voyage_supported_models`, `voyage_embedding_dims`, `voyage_assert_multimodal_or_die`).

    Bash, Python, and Terraform consumers MUST shell out to `voyage-print.ts` or source `_voyage-config.sh` — never copy the body literal, the dim, the model list, or read `process.env.VOYAGE_*` directly. The architecture guard tests `api/tests/unit/voyage-ssot-guard.test.ts` (TS) and `pf_check_voyage_ssot_only_source` (bash, in `_preflight-checks.sh --self-test`) fail CI on any leak. When you change the request envelope, the supported model list, or the embedding dim, run `bun run test --bail -- voyage-ssot-guard` and update [`docs/reference/voyage.md`](docs/reference/voyage.md) in the same PR. Multimodal is the only supported Voyage path; text-only Voyage listings (`voyage-3*`, `voyage-4*`, `voyage-code-*`, …) are refused at preflight.

---

## Memory — config and setup

### Short-term memory

**Production:** deploy scripts set `SHORT_TERM_MEMORY_BACKEND=agentcore`. When `userId` is known, conversation turns are read/written via **AgentCore Memory Store** (`api/src/lib/short-term-memory.ts`, `AGENTCORE_MEMORY_STORE_ID`). If `SHORT_TERM_MEMORY_BACKEND=agentcore` but the memory store ID is missing, the API **refuses to boot**.

**Mirrors and fallback:**

- `api/src/lib/session-store.ts` — in-process `Map` for the current process.
- When `MONGODB_URI` is set, sessions mirror to `chat_sessions` (default-on; `PERSIST_CHAT_SESSIONS=0` to opt out) for the Sessions page, audit, and cold-read fallback.
- AgentCore read/write failures can fall back to the Mongo mirror when configured.

The `memory.shortTerm` frontmatter flag is parsed but has no extra runtime effect today beyond default replay. Set `shortTerm: false` only for fully stateless one-shot agents.

### Long-term memory

Keyed by **`userId`** (JWT `sub`) and **`agentId`**. Active when agent has `memory.longTerm: true` and `userId` is present. Implementation: `api/src/lib/long-term-memory.ts`. Retrieval is **hybrid vector + lexical** across `agent_memory_facts` and `chat_messages`, fused with Reciprocal Rank Fusion; primitives in `api/src/lib/vector-retrieval.ts`.

**Enable on an agent:**

```yaml
# config/agents/<name>.agent.md frontmatter
memory:
  longTerm: true
```

**Key production env vars:**

| Variable | Purpose |
|---|---|
| `MONGODB_URI` | MongoDB Atlas connection string |
| `MONGODB_DB` | Database name (project+env-derived in `.env`) |
| `AUTH_JWKS_URI` / `AUTH_ISSUER` | Required at API boot |
| `MEMORY_VECTOR_TOPK` | Top-K after RRF + MMR (default `14`) |
| `MEMORY_VECTOR_FETCHK` | Per-leg over-fetch (default `24`) |
| `MEMORY_RECENCY_HALFLIFE_DAYS` | Recency decay half-life (default `90`; README product docs use `30` for demo tuning — see [`docs/reference/env-vars.md`](docs/reference/env-vars.md)) |
| `MEMORY_MMR_LAMBDA` | Relevance vs diversity (default `0.7`) |
| `MEMORY_WEIGHT_FACTS` | RRF weight for facts (default `1.5`) |
| `MEMORY_WEIGHT_CHAT_MESSAGES` | RRF weight for chat mirror (default `1.2`) |
| `CHAT_MESSAGES_COLLECTION` | Override mirror collection name (default `chat_messages`) |

Full catalog: [`docs/reference/env-vars.md`](docs/reference/env-vars.md).

**One-time index setup:** `bun db-seeding/seed-indexes.ts` (or `seed-all.ts`). API also lazy-ensures TTL + base indexes on first write.

**`DEV_MOCK_BACKENDS=1`:** `getMongoDb()` returns `null` — LTM read/write short-circuits; chat still works against fixtures within one server run.

**Data flow per turn:**

1. `POST /chat` → `userId = c.get("jwtPayload")?.sub`
2. If `agent.memory.longTerm && userId`: `readLongTermMemoryContext(...)` → hybrid retrieval → prepended as `## Relevant prior context`
3. Every message mirrored to `chat_messages` via microtask (non-blocking TTFB)
4. On success: `writeLongTermMemory(...)` — LLM fact extraction → embed → `bulkWrite` upsert on `{ userId, factHash }`
5. Trace re-persisted after LTM microtask so `memory.long_term_write` / `memory.long_term_skip` land in stored traces (UI: `ui/lib/inline_summary.py`)

**Strict-mode embeddings (no silent provider fallback).** `EMBEDDINGS_PROVIDER` (mandatory at API boot) decides which backend `embed-query.ts` calls — `voyage` runs Voyage only, `titan` runs Bedrock Titan only. When the declared provider fails, write paths still persist the row (transcript, lexical search, audit stay complete) but with `embedding` / `embeddingModel` omitted: chat-message mirror also adds an `embeddingError: { code, message, ts }` marker and emits a `chat.mirror.embedding_failed` trace event; LTM writes add `embedding.skipped` + `embedding.skipReason` fields to the existing `memory.long_term_write` event. Operators recover via [`db-seeding/reembed-mismatched.ts`](db-seeding/reembed-mismatched.ts) (`--apply` to write). See [`docs/status/debugging.md`](docs/status/debugging.md) § "Known persistent pitfalls".

**Collections:**

- `agent_memory_facts`: `{ userId, agentId, fact, source, ts, factHash, embedding?, embeddingModel? }`
- `chat_messages`: `{ messageId, sessionId, userId?, agentId?, role, content, timestamp, ts, embedding?, embeddingModel? }`

**Diagnostic harness:** `e2e-smoke/memory-recall-diagnostic.py` — seven scenarios, hypothesis labels `H1`–`H7`, run order `B → C → D → E → G → F → A`. Prefers `MONGODB_URI_PUBLIC` from `.env.live` for laptop-side Mongo writes. UI walkthrough: [`docs/demo/memory-recall-ui-testing-guide.md`](docs/demo/memory-recall-ui-testing-guide.md).

---

## Strands / Bedrock touchpoints

- Chat streaming: `api/src/lib/run-chat-stream.ts` (`chatMode()` default `live`; `CHAT_MODE=stub` disables Strands loop). Swarm: `api/src/lib/swarm-chat-stream.ts` (roster from `listAgents()`).
- Agent construction: `api/src/lib/create-strands-agent.ts`, `resolveModel` in `api/src/adapters/resolve-model.ts` (`BedrockModel` vs `DevMockModel` when **`DEV_MOCK_BACKENDS=1`**).
- In-API routing: `api/src/lib/agent-classifier.ts` — default production path (single hop to specialist runtime).
- Skill loading: `api/src/lib/skill-loader.ts`.
- Agent metadata: `api/src/lib/config-scan.ts`, `prompt.ts`, `schemas.ts`.
- System prompt: `buildSystemPrompt(...)` in `prompt.ts`. `LONG_TERM_MEMORY_RECALL_RULES` is framework-canonical — personas must not copy inline (`api/tests/unit/orchestrator-ltm-flag.test.ts` enforces).
- Long-term memory: `readLongTermMemoryContext` / `writeLongTermMemory` in `long-term-memory.ts`. AgentCore Memory Store fallback when MongoDB writes fail.
- Base tools: `api/src/lib/base-tools.ts` + per-skill `http-tools.json`. Metadata: `GET /http-tools` in `routes/http-tools-meta.ts`.
- Auth: `middleware/auth.ts` + `lib/jwt-verify.ts` — mandatory JWKS; JWT `sub` → session scoping + LTM.
- Sessions: `lib/session-store.ts`, `routes/sessions.ts` — user-scoped list/delete.
- Logging: `lib/logger.ts` — JSON lines, `LOG_LEVEL`.
- OTel: `lib/otel.ts` — OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` set (EC2: ADOT sidecar `http://127.0.0.1:4318`). Pin OTel to Strands 0.7 peer matrix — run `bun run validate:strands-otel` before dep bumps.
- TraceCollector: `lib/trace-collector.ts` — in-house events + OTel bridge; tiered byte caps + `dev.byte_cap_hit`.
- Cost attribution: `MetadataAwareBedrockModel` in `resolve-model.ts` → Bedrock invocation logging `requestMetadata.userId`.
- EMF metrics: `lib/cw-metrics.ts` — `Multiagent/{Chat,Mongo,Memory}`. Lock-down: `api/tests/unit/cw-metrics.test.ts`. Disable in CI: `METRICS_EMITTER_ENABLED=0`.
- HTTP + SSE: `routes/chat.ts`.
- Tracing API: `routes/trace.ts` — `?include=core|dev|full` via `lib/trace-projection.ts`.
- Trace UI: `ui/lib/inline_summary.py`, `ui/pages/2_Trace_Viewer.py`, `ui/lib/client_trace_view.py`, `ui/lib/developer_trace_view.py`.
- Retries: `TracingRetryStrategy` in `resolve-model.ts` (`model.retry` events); AgentCore loop in `agentcore-runtime.ts` (`agentcore.retry` events). Validate: `bun run validate:strands-retries`.

**Still open:** AgentCore Code Interpreter for skill scripts; customer-scoped multi-tenancy on ops collections; browser/Streamlit E2E in CI; ECS/ALB automation beyond EC2.

**Implemented:** Streamlit Cognito (`ui/lib/cognito_gate.py`); TTL + vector/BM25 indexes via `db-seeding/seed-indexes.ts`; `config/environment.yaml` → `lib/environment-config.ts`.

---

## Documentation map

| Doc | Use when |
|---|---|
| [`docs/README.md`](docs/README.md) | Getting started — first-day checklist, reading orders |
| [`docs/status/debugging.md`](docs/status/debugging.md) | Developer playbook, persistent pitfalls, validation scripts |
| [`docs/architecture.md`](docs/architecture.md) | System design, 5-runtime topology, request flow |
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | Deploy (PrivateLink + VPC peering), CI/CD, teardown |
| [`docs/deployment-preflight-checks.md`](docs/deployment-preflight-checks.md) | Catalog of every pre/post-apply guard run by [`deploy/scripts/_preflight-checks.sh`](deploy/scripts/_preflight-checks.sh); failure envelope + override knobs (`PREFLIGHT_SKIP`, `PREFLIGHT_JSON`, `PREFLIGHT_DRY_RUN`, …) |
| [`docs/configuration-guide.md`](docs/configuration-guide.md) | `config/` folder — agent + skill schema |
| [`docs/advanced/deploy-tweak-guide.md`](docs/advanced/deploy-tweak-guide.md) | **Advanced** — deploy/runtime env tuning (mode flags, ARNs, embeddings) |
| [`docs/api-reference.md`](docs/api-reference.md) | HTTP + SSE, projections, auth |
| [`docs/agent-authoring-guide.md`](docs/agent-authoring-guide.md) | `.agent.md` format |
| [`docs/skills-authoring-guide.md`](docs/skills-authoring-guide.md) | `SKILL.md`, progressive disclosure |
| [`docs/reference/tools.md`](docs/reference/tools.md) | Every agent-facing tool, runtime home, config |
| [`docs/memory-architecture.md`](docs/memory-architecture.md) + [`docs/long-term-memory-design.md`](docs/long-term-memory-design.md) | Short-term + long-term memory |
| [`docs/hybrid-search.md`](docs/hybrid-search.md) | Vector + BM25 hybrid search |
| [`docs/logging-architecture.md`](docs/logging-architecture.md) + [`docs/observability-runbook.md`](docs/observability-runbook.md) | Logs, OTel, dashboards, alarms |
| [`docs/trace-ui-system-overview.md`](docs/trace-ui-system-overview.md) + Trace Viewer guides | Inline card + Trace Viewer |
| [`docs/agentcore-runtime-design.md`](docs/agentcore-runtime-design.md) | 5-runtime topology, artifact strategy |
| [`docs/dashboards/README.md`](docs/dashboards/README.md) | CloudWatch widget catalog |
| [`docs/demo/demo-script.md`](docs/demo/demo-script.md) + [`docs/demo/demo-mode-guide.md`](docs/demo/demo-mode-guide.md) | Demo walkthrough |
| [`docs/demo/memory-recall-ui-testing-guide.md`](docs/demo/memory-recall-ui-testing-guide.md) | Manual LTM recall UI scenarios |
| [`docs/estimate.md`](docs/estimate.md) | Monthly AWS cost estimate |
| [`docs/reference/`](docs/reference/) | Env vars, TF modules, SSM, data model, smoke tests, deploy scripts |
| [`README.md`](README.md) | Repo onboarding (human-first) |
| [`PROJECT_STRUCTURE.md`](PROJECT_STRUCTURE.md) | Per-folder rationale |

---

## Naming disambiguation

| Name | Meaning |
|---|---|
| **This file (`AGENTS.md`)** | Instructions for **coding agents / developers** working on the repo |
| **`config/agents/*.agent.md`** | **Runtime** LLM agent definitions (orchestrator, order, product, troubleshoot) |

If a task says “add an agent,” it usually means a **new `.agent.md` + skill**, not editing `AGENTS.md`.
