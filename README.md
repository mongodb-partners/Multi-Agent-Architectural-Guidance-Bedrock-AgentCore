# MongoDB + AWS Bedrock Multi-Agent Framework

A **configuration-driven multi-agent reference architecture** on **AWS Bedrock** (Strands Agents TypeScript SDK), **MongoDB Atlas**, and **JWT-secured** HTTP APIs. Add specialists by editing markdown config — no code changes needed.

---

## What this is

A user types a question into a Streamlit UI → the Hono API receives it → an **in-API classifier** picks the right specialist agent → that specialist runs as an **AgentCore Runtime** on AWS Bedrock and streams the answer back over SSE. Mongo tools route through a **dedicated MongoDB MCP AgentCore Runtime**. Domain behavior lives in `.agent.md` + `SKILL.md` files — add a new vertical = add a new agent + skill, redeploy.

**Five AgentCore Runtimes:** orchestrator + 3 specialists (order-management, product-recommendation, troubleshooting) + 1 MongoDB MCP runtime. Default path: **single-hop** (in-API classifier → specialist). `USE_ORCHESTRATOR_RUNTIME=1` enables a two-hop rollback through the orchestrator.

**Connectivity** (mutually exclusive per account): `NETWORK_MODE=privatelink` (default) or `NETWORK_MODE=peering`. Switching requires destroy + redeploy.

---

## Getting started (new clone)

### Prerequisites

| Tool | Version | Install |
|---|---|---|
| [Bun](https://bun.sh) | latest | `curl -fsSL https://bun.sh/install \| bash` then `export PATH="$HOME/.bun/bin:$PATH"` |
| Python | 3.10+ | `python3 --version` |
| AWS CLI | v2 | [Install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| Terraform | ≥ 1.6 | [Install guide](https://developer.hashicorp.com/terraform/install) |
| Docker | latest | Required for EC2 deploys |
| `zip` / `curl` | — | Usually preinstalled |

You also need an **AWS account** ([`deploy/iam/policy.json`](deploy/iam/policy.json), [`deploy/iam/README.md`](deploy/iam/README.md)) and a **MongoDB Atlas** API key + existing project.

### First-time setup

```bash
git clone <repo-url>
cd mongodb-aws-bedrock-multi-agent-framework

cp .env.sample .env
# Edit .env — AWS creds, Atlas keys, PROJECT_NAME, ENVIRONMENT, AWS_REGION, SHARED_VPC_NAME
# Simplest first deploy: EMBEDDINGS_PROVIDER=titan (.env.sample defaults to voyage)

source .env
aws sts get-caller-identity
```

Full env catalog: [`.env.sample`](.env.sample) and [`docs/reference/env-vars.md`](docs/reference/env-vars.md). Role-based getting started: [`docs/README.md`](docs/README.md).

---

## Configure agents and skills

Most customization is **markdown only** — no API or runtime code changes.

### Agents

Specialists live in `config/agents/<name>.agent.md`. The reference ships **1 orchestrator + 3 specialists**:

| Agent | Default model | What it does |
|---|---|---|
| Orchestrator | Claude Haiku 4.5 | (Rollback path) routing to specialists |
| Order Management | Claude Haiku 4.5 | Order lookups, status, tracking, returns |
| Product Recommendation | Claude Sonnet 4.6 | Semantic search over `products` |
| Troubleshooting | Claude Sonnet 4.6 | RAG over `troubleshooting_docs` + Bedrock KB |

**Add or change an agent:** edit or add `.agent.md`, then run `./deploy/deploy-agents.sh --auto-approve` (see below). Authoring guide: [`docs/agent-authoring-guide.md`](docs/agent-authoring-guide.md).

Enable long-term memory per agent:

```yaml
# config/agents/<name>.agent.md frontmatter
memory:
  longTerm: true
```

Tune retrieval via env vars — see [`docs/reference/env-vars.md`](docs/reference/env-vars.md) and [`docs/long-term-memory-design.md`](docs/long-term-memory-design.md).

### Skills

A **skill** is domain knowledge an agent loads on demand ([agentskills.io](https://agentskills.io/specification)):

```
config/skills/order-management/
├── SKILL.md              ← instructions the agent follows
├── http-tools.json       ← optional HTTPS tools (Lambda URLs, etc.)
├── scripts/
│   └── validate-return.mjs
└── references/
    └── order-schema.md
```

**Progressive disclosure:** name + description at startup; body on activation; references/scripts on demand.

**HTTP tools without TypeScript:** add `http-tools.json` next to `SKILL.md`. SSRF allowlists in root `config/http-tools.json`. Guide: [`docs/skills-authoring-guide.md`](docs/skills-authoring-guide.md).

### Tools

Agents use configuration-driven tools:

- MongoDB: `mongodb_query`, `mongodb_vector_search`, `mongodb_aggregate` (MongoDB MCP runtime)
- Bedrock: `bedrock_kb_retrieve`, `embed_multimodal_content` (multimodal — text + image_url + image_base64)
- Skills: `activate_skill`, `read_skill_resource`, `run_skill_script`
- HTTP: `config/http-tools.json` and per-skill `http-tools.json`

Catalog: [`docs/reference/tools.md`](docs/reference/tools.md).

---

## Deployment

Always `source .env` (or `--env-file`) before deploy scripts. Targeted redeploys require a prior successful full deploy.

### First deploy (full stack)

The API needs `AUTH_JWKS_URI`, `AUTH_ISSUER`, and AgentCore ARNs from `.env.live` — a full deploy writes those.

| Goal | Command |
|---|---|
| **PrivateLink** (recommended) | `./deploy/deploy-full-with-privatelink.sh --auto-approve` |
| **VPC peering** | `./deploy/deploy-full-with-vpc-peering.sh --auto-approve` |

```bash
source .env

./deploy/deploy-full-with-privatelink.sh --auto-approve

# Common flags
./deploy/deploy-full-with-privatelink.sh --auto-approve --skip-docker
./deploy/deploy-full-with-privatelink.sh --auto-approve --skip-network
./deploy/deploy-full-with-privatelink.sh --auto-approve --skip-shared
./deploy/deploy-full-with-privatelink.sh --auto-approve --skip-smoke
./deploy/deploy-full-with-privatelink.sh --env-file /path/to/.env
```

| Flag | Effect |
|---|---|
| `--auto-approve` | Non-interactive Terraform |
| `--skip-docker` | Skip image build/push |
| `--skip-network` | VPC already deployed |
| `--skip-shared` | Shared stack already applied |
| `--env-file PATH` | Alternate credentials file |

**After deploy:**

Full post-deploy smoke runs automatically at the end of `deploy-project.sh` (Phase 11). To re-run manually:

```bash
source .env && python3 e2e-smoke/post-deploy-smoke.py
```

Open the **UI URL** from the deploy summary (Streamlit on EC2, port 8501). Sign in with the Cognito test user from the output.

**VPC peering** — mutually exclusive with PrivateLink; set `ATLAS_PEERING_CIDR` in `.env` (default `192.168.248.0/21`):

```bash
./deploy/deploy-full-with-vpc-peering.sh --auto-approve
```

Optional IAM pre-check: `bash deploy/scripts/probe-resources.sh` (`--all` for full matrix).

### `deploy-agents.sh`

**When:** only `config/agents/*.agent.md` or `config/skills/` changed.

```bash
source .env

./deploy/deploy-agents.sh --auto-approve
./deploy/deploy-agents.sh --auto-approve --skip-smoke
./deploy/deploy-agents.sh --auto-approve --allow-destroy
./deploy/deploy-agents.sh --auto-approve --force
```

| Flag | Effect |
|---|---|
| `--allow-destroy` | Confirm specialist removal |
| `--force` | Skip orchestrator handoff check |
| `--skip-smoke` | Skip post-deploy agent smoke |

The API rescans `config/agents/` for metadata, but **AgentCore runtime behavior** requires this script to rebuild the code artifact.

### `deploy-api.sh` / `deploy-ui.sh`

**When:** application code changed (not agent config).

```bash
./deploy/deploy-api.sh              # api/ only; refreshes .env.live
./deploy/deploy-ui.sh               # ui/ only
```

Use `deploy-api.sh` first if Cognito, Atlas, or OTel env vars changed.

### Other scripts

```bash
./deploy/scripts/deploy-local.sh --auto-approve    # Atlas + KB only — NOT a full chat stack
./deploy/scripts/deploy-shared.sh --auto-approve
./deploy/scripts/destroy.sh --mode ec2 --auto-approve
```

Full runbook: [`docs/deployment-guide.md`](docs/deployment-guide.md). Script reference: [`docs/reference/deploy-scripts.md`](docs/reference/deploy-scripts.md).

---

## Documentation

| Document | What it covers |
|---|---|
| [`docs/README.md`](docs/README.md) | **Getting started** — checklist, reading orders |
| [`docs/agent-authoring-guide.md`](docs/agent-authoring-guide.md) | `.agent.md` schema |
| [`docs/skills-authoring-guide.md`](docs/skills-authoring-guide.md) | `SKILL.md`, scripts, http-tools |
| [`docs/configuration-guide.md`](docs/configuration-guide.md) | `config/` folder — agent + skill schema |
| [`docs/advanced/deploy-tweak-guide.md`](docs/advanced/deploy-tweak-guide.md) | **Advanced** — deploy/runtime env tuning |
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | Deploy, CI/CD, teardown |
| [`docs/reference/env-vars.md`](docs/reference/env-vars.md) | Every env var |
| [`docs/reference/tools.md`](docs/reference/tools.md) | Every agent-facing tool |

More (architecture, API, memory, observability, debugging): see the full table in [For developers](#for-developers-working-on-this-project) below.

---

## For developers working on this project

The sections below apply when you are **changing framework code**, running the API/UI on a laptop, or debugging infrastructure — not for the typical “configure agents and deploy” workflow above.

> **Start here for getting started:** [`docs/README.md`](docs/README.md) is the single getting started entry point — first-day checklist, doc map, authoritative source files.


### Run API and UI locally

**After a full EC2 deploy.** Requires `.env.live` (JWKS, ARNs, Mongo URIs).

```bash
source .env
source .env.live

export PATH="$HOME/.bun/bin:$PATH"
cd api && bun run typecheck && bun run validate:bun && bun run validate:agentcore && bun run dev

# separate terminal
cd ui && streamlit run app.py
```

Open `http://localhost:8501`. Cognito JWT required (`STREAMLIT_COGNITO_*` = same pool as `AUTH_JWKS_URI`). No anonymous mode.

**Docker Compose** (still needs JWKS + AgentCore ARNs in `.env`):

```bash
docker compose up --build
```

`deploy-local.sh` provisions Atlas + KB but **not** runtimes or Cognito — API still won't boot until a full EC2 deploy merges `.env.live`.

### Memory (implementation)

**Short-term:** AgentCore Memory in production (`SHORT_TERM_MEMORY_BACKEND=agentcore`). Mongo `chat_sessions` mirror for Sessions page and fallback.

**Long-term:** hybrid vector + BM25 in Atlas (`agent_memory_facts` + `chat_messages`), RRF + recency + MMR. Keyed by JWT `sub`.

Architecture: [`docs/memory-architecture.md`](docs/memory-architecture.md), [`docs/long-term-memory-design.md`](docs/long-term-memory-design.md).

### Authentication

JWKS is mandatory — API won't start without `AUTH_JWKS_URI` + `AUTH_ISSUER`. JWT `sub` → `userId` for sessions and LTM. No auth bypass.

### Observability

- JSON logs: `api/src/lib/logger.ts`, `LOG_LEVEL`
- OTel + X-Ray when `OTEL_EXPORTER_OTLP_ENDPOINT` set (EC2: ADOT `http://127.0.0.1:4318`)
- CloudWatch log groups, dashboards, EMF metrics
- Trace Viewer: `ui/pages/2_Trace_Viewer.py`

Runbook: [`docs/observability-runbook.md`](docs/observability-runbook.md).

### Project layout

```
api/             — Bun + Hono API (SSE, JWT, AgentCore adapters)
ui/              — Streamlit (Chat, Sessions, Trace Viewer)
mcp-runtimes/    — MongoDB MCP AgentCore Runtime
config/
  agents/        — .agent.md specialists
  skills/        — SKILL.md domain packages
deploy/          — Terraform + deploy scripts
db-seeding/      — Atlas demo data + indexes
e2e/             — Playwright (live API)
e2e-smoke/       — Post-deploy AWS smoke
docs/            — Getting started pack
```

Rationale: [`PROJECT_STRUCTURE.md`](PROJECT_STRUCTURE.md). Contributor conventions: [`AGENTS.md`](AGENTS.md).

### Terraform stack split

| Env | Scope | Singleton |
|---|---|---|
| `envs/network` | VPC + Atlas connectivity + SSM | account + region |
| `envs/shared` | Voyage SageMaker + CloudWatch + Bedrock logging | account + region + env |
| `envs/ec2` | Atlas + KB + EC2 + Cognito + 5 AgentCore runtimes | per-project |
| `envs/local` | Laptop Atlas + KB + memory (no EC2/runtimes) | per-laptop |

Design: [`deploy/terraform/.design.md`](deploy/terraform/.design.md). Modules: [`docs/reference/terraform-modules.md`](docs/reference/terraform-modules.md).

### Full documentation index

| Document | What it covers |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | System design, 5-runtime topology |
| [`docs/api-reference.md`](docs/api-reference.md) | HTTP + SSE, auth, projections |
| [`docs/deployment-preflight-checks.md`](docs/deployment-preflight-checks.md) | Pre/post-apply guards |
| [`docs/hybrid-search.md`](docs/hybrid-search.md) | Vector + BM25 hybrid search |
| [`docs/logging-architecture.md`](docs/logging-architecture.md) | Logs, OTel |
| [`docs/trace-ui-system-overview.md`](docs/trace-ui-system-overview.md) | Trace UI |
| [`docs/agentcore-runtime-design.md`](docs/agentcore-runtime-design.md) | Runtime topology, artifacts |
| [`docs/status/debugging.md`](docs/status/debugging.md) | EC2 access, pitfalls, validation |
| [`docs/estimate.md`](docs/estimate.md) | Monthly AWS cost estimate |
| [`docs/demo/demo-script.md`](docs/demo/demo-script.md) | Demo walkthrough |
| [`docs/reference/terraform-modules.md`](docs/reference/terraform-modules.md) | Terraform modules |
| [`docs/reference/ssm-parameters.md`](docs/reference/ssm-parameters.md) | Cross-stack SSM |
| [`docs/reference/data-model.md`](docs/reference/data-model.md) | Mongo collections |
| [`docs/reference/smoke-tests.md`](docs/reference/smoke-tests.md) | e2e-smoke scripts |
| [`docs/reference/deploy-scripts.md`](docs/reference/deploy-scripts.md) | Every deploy script |

---

## Built with

- [Strands Agents SDK](https://github.com/strands-agents/sdk-typescript) — agent orchestration
- [Hono](https://hono.dev/) — HTTP API + SSE
- [MongoDB Atlas](https://www.mongodb.com/atlas) — data + vector search + long-term memory
- [AWS Bedrock](https://aws.amazon.com/bedrock/) — Claude + Titan embeddings + Knowledge Bases
- [Bedrock AgentCore](https://docs.aws.amazon.com/bedrock-agentcore/) — Runtime, Gateway, Memory
- [Agent Skills](https://agentskills.io/specification) — skill format
- [Streamlit](https://streamlit.io/) — chat + Trace Viewer
- [OpenTelemetry](https://opentelemetry.io/) + ADOT — tracing
