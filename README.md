# MongoDB + AWS Bedrock Multi-Agent Framework

A **configuration-driven multi-agent reference architecture** on **AWS Bedrock** (Strands Agents TypeScript SDK), **MongoDB Atlas**, and **JWT-secured** HTTP APIs. Add specialists by editing markdown config — no TypeScript changes for most flows.

> **Start here for handover:** [`docs/README.md`](docs/README.md) is the single client-handover entry point — first-day checklist, reading orders, doc map, authoritative source files.

---

## What this is

A user types a question into a Streamlit UI → the Hono API receives it → an **in-API classifier** picks the right specialist agent → that specialist runs as an **AgentCore Runtime** on AWS Bedrock and streams the answer back over SSE. Mongo tools route through a **dedicated MongoDB MCP AgentCore Runtime** (direct `InvokeAgentRuntime`; the AgentCore Gateway handles non-Mongo tools). Memory follows the SoW split: **short-term conversation memory uses AgentCore Memory**; **long-term cross-session memory uses MongoDB Atlas** with hybrid vector + BM25. Observability lands in CloudWatch + OTel + X-Ray.

The product goal: ship a reusable foundation that MongoDB field, partner, and professional-services teams can deploy for customer-specific multi-agent solutions. Domain behavior lives in `.agent.md` + `SKILL.md` files. Add a new vertical = add a new agent + skill, redeploy.

**Five AgentCore Runtimes:** orchestrator + 3 specialists (order-management, product-recommendation, troubleshooting) + 1 MongoDB MCP runtime. The default request path is **single-hop** (in-API classifier → specialist runtime); `USE_ORCHESTRATOR_RUNTIME=1` toggles a two-hop rollback path through the orchestrator runtime.

**Two co-equal connectivity modes** (mutually exclusive per account):
- `NETWORK_MODE=privatelink` (default, partner-validated, SoW-aligned)
- `NETWORK_MODE=peering` (alternative, with experimental KB ingestion via `bedrock-kb-peering`)

Switching modes requires destroy + redeploy. KB ingestion is **private by default in both modes**; public Atlas SRV is an explicit privacy-regression opt-out only.

---

## Getting started (new clone)

### Prerequisites

Install these before your first run:

| Tool | Version | Install |
|---|---|---|
| [Bun](https://bun.sh) | latest | `curl -fsSL https://bun.sh/install \| bash` then `export PATH="$HOME/.bun/bin:$PATH"` |
| Python | 3.10+ | `python3 --version` (macOS: `brew install python@3.12`) |
| AWS CLI | v2 | [Install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| Terraform | ≥ 1.6 | [Install guide](https://developer.hashicorp.com/terraform/install) |
| Docker | latest | Required for EC2 deploys and optional local Compose; [Install guide](https://docs.docker.com/get-docker/) |
| `zip` / `curl` | — | Usually preinstalled on macOS/Linux |

You also need:

- An **AWS account** with Bedrock model access and permissions in [`deploy/iam/policy.json`](deploy/iam/policy.json). See [`deploy/iam/README.md`](deploy/iam/README.md) for IAM user vs STS/SSO setup.
- A **MongoDB Atlas** organization API key and an existing Atlas project (the deploy creates a cluster inside it).

### First-time setup

```bash
git clone <repo-url>
cd mongodb-aws-bedrock-multi-agent-framework

# 1. Create credentials file from the template (never commit .env)
cp .env.sample .env
# Edit .env — at minimum: AWS creds, Atlas keys, PROJECT_NAME, ENVIRONMENT,
# AWS_REGION, SHARED_VPC_NAME
# For simplest first deploy set EMBEDDINGS_PROVIDER=titan (.env.sample defaults to voyage)
# Full list: .env.sample and docs/reference/env-vars.md

# 2. Load env and confirm AWS auth
source .env
aws sts get-caller-identity

# 3. Install app dependencies (safe to run before any deploy)
export PATH="$HOME/.bun/bin:$PATH"
cd api && bun install && cd ..
cd ui && pip install -r requirements.txt && cd ..
```

> **Handover entry point:** [`docs/README.md`](docs/README.md) has a first-day checklist and reading orders by role.

### Choose a path

The API refuses to boot without `AUTH_JWKS_URI`, `AUTH_ISSUER`, and `AGENTCORE_ORCHESTRATOR_ARN`. A fresh clone **cannot** run `bun run dev` until a deploy writes those into `.env.live`.

| Goal | What to run |
|---|---|
| **First deploy — full runnable stack** (recommended) | `./deploy/deploy-full-with-privatelink.sh --auto-approve` then open the **UI URL** printed at the end |
| **First deploy — VPC peering mode** | `./deploy/deploy-full-with-vpc-peering.sh --auto-approve` |
| **Run API + UI on laptop** (AgentCore stays in AWS) | Full EC2 deploy first, then [Run API and UI locally](#run-api-and-ui-locally) |
| **Partial laptop infra only** (Atlas + KB; no chat stack) | `./deploy/scripts/deploy-local.sh --auto-approve` — see note below |

> **`deploy-local.sh` is not a substitute for a full deploy.** It provisions Atlas + Bedrock KB + AgentCore Memory via `envs/local`, but **not** AgentCore runtimes or Cognito JWKS. The API still will not boot until you merge `.env.live` from a full EC2 deploy. Details: [`docs/deployment-guide.md`](docs/deployment-guide.md) §4.

Optional — verify IAM permissions before the first full deploy (~5–30 min):

```bash
bash deploy/scripts/probe-resources.sh          # fast probes
bash deploy/scripts/probe-resources.sh --all    # full matrix including EC2 + Atlas + KB
```

---

## Run API and UI locally

Use this **after a full EC2 deploy** when you want to develop `api/` or `ui/` on your laptop while AgentCore runtimes remain in AWS. Requires `.env.live` from the deploy (JWKS, ARNs, Mongo URIs).

```bash
# From repo root — merge deploy output with your credentials
source .env
source .env.live

# Terminal 1 — API
export PATH="$HOME/.bun/bin:$PATH"
cd api
bun run typecheck && bun run validate:bun && bun run validate:agentcore
bun run dev

# Terminal 2 — UI (defaults to http://127.0.0.1:3000; set STREAMLIT_API_URL to override)
cd ui
streamlit run app.py
```

Open `http://localhost:8501`. Sign in via Cognito (`STREAMLIT_COGNITO_*` env vars — same pool as `AUTH_JWKS_URI`). Every API request needs a valid JWT; there is no anonymous chat mode on protected routes.

**After a full EC2 deploy**, you can also use the **cloud UI URL** printed by the deploy script (Streamlit on EC2) — no local `bun run dev` required.

**Docker Compose** (API + UI containers; still requires `.env` with JWKS + AgentCore ARNs):

```bash
docker compose up --build
```

See [`docs/deployment-guide.md`](docs/deployment-guide.md) for the full deploy runbook.

---

## Deployment

Always `source .env` (or pass `--env-file`) before running deploy scripts. Targeted redeploy scripts (`deploy-api.sh`, `deploy-ui.sh`, `deploy-agents.sh`) require a prior successful full deploy — they read Terraform state and EC2 outputs from the EC2 stack.

### `deploy-full-with-privatelink.sh`

**When:** first deploy on a new account, or any time you want the default PrivateLink connectivity mode (SoW-aligned, partner-validated).

**What it does:** probes SSM canaries and runs only the missing stacks — `network → shared → project` — then builds images, syncs `.env.live`, and restarts EC2 services.

```bash
source .env

./deploy/deploy-full-with-privatelink.sh --auto-approve

# Common flags
./deploy/deploy-full-with-privatelink.sh --auto-approve --skip-docker     # skip image build/push
./deploy/deploy-full-with-privatelink.sh --auto-approve --skip-network    # VPC already deployed
./deploy/deploy-full-with-privatelink.sh --auto-approve --skip-shared     # shared stack already applied
./deploy/deploy-full-with-privatelink.sh --env-file /path/to/.env
```

| Flag | Effect |
|---|---|
| `--auto-approve` | Non-interactive Terraform applies |
| `--skip-docker` | Skip Docker image build/push in the project phase |
| `--skip-network` | Skip network stack (use when SSM `vpc_id` already exists) |
| `--skip-shared` | Skip shared stack (use when SageMaker/log groups already exist) |
| `--env-file PATH` | Alternate credentials file (default: repo-root `.env`) |

**Post-deploy smoke:**

```bash
source .env && python3 e2e-smoke/post-deploy-smoke.py
```

**Use the app:** when the script finishes, open the **UI URL** printed in the deploy summary (Streamlit on EC2, port 8501). Sign in with the Cognito test user credentials from the output.

### `deploy-full-with-vpc-peering.sh`

**When:** you need VPC peering instead of PrivateLink. **Mutually exclusive** with PrivateLink per account — switching modes requires destroy + redeploy.

**What it does:** same 3-phase orchestration as the PrivateLink script, but exports `NETWORK_MODE=peering` and provisions `bedrock-kb-peering` (experimental KB ingestion path).

```bash
source .env

./deploy/deploy-full-with-vpc-peering.sh --auto-approve

# Same flags as deploy-full-with-privatelink.sh
./deploy/deploy-full-with-vpc-peering.sh --auto-approve --skip-network --skip-shared
./deploy/deploy-full-with-vpc-peering.sh --env-file /path/to/.env
```

Ensure `.env` includes `ATLAS_PEERING_CIDR` (default `192.168.248.0/21`). Without `--auto-approve`, the script prints an experimental KB peering warning.

### `deploy-api.sh`

**When:** only `api/` code or API-bundled config changed. Rebuilds the API image, regenerates `.env.live`, and restarts `multiagent-api` on EC2.

```bash
source .env

./deploy/deploy-api.sh
./deploy/deploy-api.sh --skip-docker    # reuse the image already in ECR
./deploy/deploy-api.sh --skip-smoke     # skip backend smoke after restart
./deploy/deploy-api.sh --env-file /path/to/.env
```

Does **not** run Terraform, rebuild the UI, or touch AgentCore runtimes. Run this first when Cognito, Atlas, or OTel env vars changed — it refreshes `.env.live`.

### `deploy-ui.sh`

**When:** only `ui/` code changed.

```bash
source .env

./deploy/deploy-ui.sh
./deploy/deploy-ui.sh --skip-docker
./deploy/deploy-ui.sh --skip-smoke
./deploy/deploy-ui.sh --env-file /path/to/.env
```

Does **not** regenerate `.env.live`. If Cognito or API URL env vars changed, run `deploy-api.sh` first.

### `deploy-agents.sh`

**When:** only `config/agents/*.agent.md` or `config/skills/` changed. Re-bundles agent code, targeted Terraform apply on AgentCore runtimes, refreshes the API agent cache — no API/UI restart.

```bash
source .env

./deploy/deploy-agents.sh --auto-approve
./deploy/deploy-agents.sh --auto-approve --skip-smoke
./deploy/deploy-agents.sh --auto-approve --allow-destroy   # confirm specialist removal
./deploy/deploy-agents.sh --auto-approve --force           # skip orchestrator handoff check
./deploy/deploy-agents.sh --env-file /path/to/.env
```

| Flag | Effect |
|---|---|
| `--auto-approve` | Non-interactive Terraform apply (still prompts on destroys unless `--allow-destroy`) |
| `--allow-destroy` | Skip extra confirmation when removing specialists |
| `--force` | Skip orchestrator handoff-consistency validation |
| `--skip-smoke` | Skip post-deploy agent smoke test |

### Other deploy scripts

```bash
source .env

# Local laptop stack (Atlas + KB + memory only — NOT a full chat stack; see Choose a path)
./deploy/scripts/deploy-local.sh --auto-approve

# Shared observability + embeddings only (singleton per account+region+env)
./deploy/scripts/deploy-shared.sh --auto-approve

# Tear down (order matters: ec2 → shared → network)
./deploy/scripts/destroy.sh --mode ec2     --auto-approve
./deploy/scripts/destroy.sh --mode shared  --auto-approve
./deploy/scripts/destroy.sh --mode network --auto-approve
./deploy/scripts/destroy.sh --mode local   --auto-approve
```

Full reference: [`docs/reference/deploy-scripts.md`](docs/reference/deploy-scripts.md).

### Terraform stack split

Four root configs share one S3 state bucket, separate state keys:

| Env | Scope | Singleton scope | State key |
|---|---|---|---|
| `envs/network` | Shared VPC + Atlas connectivity (PL or peering) + SSM publishers | account + region | `<SHARED_VPC_NAME>/<region>/network/terraform.tfstate` |
| `envs/shared` | Voyage SageMaker endpoint + CloudWatch log groups + dashboards + Bedrock invocation logging | account + region + env | `<SHARED_VPC_NAME>/<region>/<env>/shared/terraform.tfstate` |
| `envs/ec2` | Atlas M10 + Bedrock KB + EC2 + ECR + Cognito + 5 AgentCore Runtimes + AgentCore Gateway + ADOT sidecar | per-project | `<ENVIRONMENT>/ec2/terraform.tfstate` |
| `envs/local` | Atlas M10 + Bedrock KB + AgentCore Memory + CloudWatch (laptop; no EC2/runtimes/Cognito) | per-laptop | `<ENVIRONMENT>/terraform.tfstate` |

Rationale: [`deploy/terraform/.design.md`](deploy/terraform/.design.md). Module catalog: [`docs/reference/terraform-modules.md`](docs/reference/terraform-modules.md). Cross-stack SSM contract: [`docs/reference/ssm-parameters.md`](docs/reference/ssm-parameters.md).

---

## Concepts

### Agents

An **agent** is a specialist handling a specific domain. The reference ships **1 orchestrator + 3 specialists**:

| Agent | Default model | What it does |
|---|---|---|
| Orchestrator | Claude Haiku 4.5 | (Rollback path) classifier-style routing to specialists |
| Order Management | Claude Haiku 4.5 | Order lookups, status, tracking, returns |
| Product Recommendation | Claude Sonnet 4.6 | Semantic search over `products` |
| Troubleshooting | Claude Sonnet 4.6 | RAG over `troubleshooting_docs` + Bedrock KB |

Agents are defined in `config/agents/<name>.agent.md`. Add a new agent = add a new file + `./deploy/deploy-agents.sh --auto-approve`. The API rescans `config/agents/` on disk for metadata (mtime cache), but **runtime behavior** inside AgentCore requires the agents redeploy script to rebuild the code artifact.

The **default production request path** is in-API classification (`agent-classifier.ts`) → direct specialist invocation. The orchestrator AgentCore Runtime is provisioned but only invoked when `USE_ORCHESTRATOR_RUNTIME=1`.

### Tools

Tools are how agents touch systems outside the model: MongoDB Atlas, Bedrock Knowledge Bases, embeddings, skill reference files/scripts, and configured HTTPS endpoints.

The supported tool surface is intentionally configuration-driven:

- MongoDB tools: `mongodb_query`, `mongodb_vector_search`, `mongodb_aggregate` (served by the MongoDB MCP AgentCore Runtime)
- Bedrock tools: `bedrock_kb_retrieve`, `generate_embedding`
- Skill tools: `activate_skill`, `read_skill_resource`, `run_skill_script`
- HTTP tools: global tools from `config/http-tools.json` and skill-scoped tools like `order-management/notify_fulfillment_lambda`

Full developer catalog: [`docs/reference/tools.md`](docs/reference/tools.md). It explains what each tool does, where it is implemented, how to attach it to an agent, required env vars, security gates, and debugging surfaces.

### Skills

A **skill** is a package of domain knowledge an agent loads to become an expert. Skills follow the [agentskills.io specification](https://agentskills.io/specification).

```
config/skills/order-management/
├── SKILL.md              ← instructions the agent follows
├── http-tools.json       ← optional: HTTPS tools (Lambda Function URLs, etc.)
├── scripts/
│   └── validate-return.mjs   ← executable policy (run_skill_script)
└── references/
    └── order-schema.md       ← detailed docs loaded on demand (read_skill_resource)
```

**Progressive disclosure:** only the skill name + description are loaded at startup; the body is loaded when the skill is activated; references + scripts are loaded on demand.

**HTTP / Lambda tools without TypeScript:** add `http-tools.json` next to `SKILL.md`. The agent lists each tool as `<skill>/<localToolName>`. SSRF allowlists in root `config/http-tools.json` (`security` block). Full guide: [`docs/skills-authoring-guide.md`](docs/skills-authoring-guide.md).

### Memory

**Short-term:** current-session conversation history. In deployed AWS, the authoritative short-term memory backend is **AgentCore Memory** (`SHORT_TERM_MEMORY_BACKEND=agentcore`, set by the deploy scripts). The API also keeps a process-local cache and, when `MONGODB_URI` is set, mirrors sessions to MongoDB `chat_sessions` for the Sessions page, audit/debug history, and cold-read fallback. MongoDB is not the primary short-term memory backend in the SoW deployment.

**Long-term:** cross-session user facts/preferences in **MongoDB Atlas**. The primary retriever uses hybrid vector + BM25 across `agent_memory_facts` (LLM-curated facts) + `chat_messages` (per-turn mirror). Results are fused with Reciprocal Rank Fusion, recency-decayed, MMR-diversified, and prepended to the system prompt as `## Relevant prior context`. Keyed by JWT `sub` (`userId`) — requires auth + Atlas.

Enable per agent:

```yaml
# config/agents/<name>.agent.md frontmatter
memory:
  longTerm: true
```

Tune via env vars — defaults are `MEMORY_VECTOR_TOPK=14`, `MEMORY_WEIGHT_FACTS=1.5`, `MEMORY_WEIGHT_CHAT_MESSAGES=1.2`, `MEMORY_RECENCY_HALFLIFE_DAYS=90`, `MEMORY_MMR_LAMBDA=0.7`. Full catalog: [`docs/reference/env-vars.md`](docs/reference/env-vars.md). Architecture: [`docs/long-term-memory-design.md`](docs/long-term-memory-design.md).

---

## Authentication

JWKS auth is **mandatory**. The API refuses to start without `AUTH_JWKS_URI` + `AUTH_ISSUER` (`assertJwksAuthConfigured()` in `api/src/lib/jwt-verify.ts`). Every protected route requires `Authorization: Bearer <jwt>`. The JWT `sub` claim becomes `userId` for session scoping and long-term memory. No `ALLOW_UNAUTHENTICATED` / `REQUIRE_AUTH=false` bypass.

The Streamlit UI obtains tokens via Cognito (`streamlit-cognito-auth`, `ui/lib/cognito_gate.py`) when `STREAMLIT_COGNITO_POOL_ID` + `STREAMLIT_COGNITO_CLIENT_ID` are set. Local laptop dev: configure the same Cognito pool as `AUTH_JWKS_URI` / `AUTH_ISSUER` (written to `.env.live` by the full EC2 deploy).

---

## Observability

- **Structured logs:** JSON lines via `api/src/lib/logger.ts`. `LOG_LEVEL=error|warn|info|debug` (default `info`).
- **OTel + X-Ray:** when `OTEL_EXPORTER_OTLP_ENDPOINT` is set (EC2 default `http://127.0.0.1:4318`, ADOT sidecar), the API installs `NodeTracerProvider` + `BatchSpanProcessor` + `OTLPTraceExporter`. Strands TS SDK auto-instruments.
- **CloudWatch:** 6 log groups (`/<SHARED_RESOURCE_PREFIX>/<env>/{api,ui,mcp,agentcore,otel,otel-atlas}`), 4 dashboards (`<SHARED_RESOURCE_PREFIX>-{fleet,mongo,cost,atlas}-<env>`), EMF metrics for `Multiagent/{Chat,Mongo,Memory}`.
- **Trace Viewer:** debug-grade Streamlit page with `?include=core|dev|full` projections and `X-Trace-Include` enforcement.

Full runbook: [`docs/observability-runbook.md`](docs/observability-runbook.md).

---

## Project layout

```
api/             — Bun + Hono API server (SSE streaming, JWT/JWKS, rate limiting)
ui/              — Streamlit chat client (Chat + Sessions + Trace Viewer)
mcp-runtimes/    — Container-mode AgentCore Runtimes (MongoDB MCP)
config/
  agents/        — .agent.md files (one per specialist)
  skills/        — SKILL.md folders (domain knowledge packages)
  environment.yaml
  demo-prompts.yaml
db-seeding/      — Atlas data + index seed scripts
deploy/
  deploy-full-with-privatelink.sh   ← orchestrator: PrivateLink mode
  deploy-full-with-vpc-peering.sh   ← orchestrator: VPC peering mode
  deploy-api.sh / deploy-ui.sh / deploy-agents.sh
  scripts/                           — deploy-network, deploy-shared, deploy-project, destroy, etc.
  iam/                                — consolidated deploy policy + STS role
  terraform/
    bootstrap/                       — S3 state bucket + DynamoDB lock
    envs/{network,shared,ec2,local}/ — 4 root configs
    modules/                         — 25+ reusable modules
  kb-docs/                           — versioned KB sources uploaded to S3
e2e/             — Playwright API smoke specs
e2e-smoke/       — Python live-AWS smoke + memory recall diagnostic
docs/            — canonical handover pack (read docs/README.md first)
.github/workflows/  — ci.yml (typecheck + unit tests) + deploy.yml (release deploy)
.env.sample      — every env var, commented
```

Full per-folder rationale: [`PROJECT_STRUCTURE.md`](PROJECT_STRUCTURE.md).

---

## Documentation

| Document | What it covers |
|---|---|
| [`docs/README.md`](docs/README.md) | **Client handover entry point** — first-day checklist, reading orders, doc map |
| [`docs/architecture.md`](docs/architecture.md) | System overview, 5-runtime topology, request flow, AWS infra |
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | Deploy runbook (PrivateLink + VPC peering), CI/CD, teardown |
| [`docs/deployment-preflight-checks.md`](docs/deployment-preflight-checks.md) | Catalog of every pre/post-apply check, failure envelope, override knobs |
| [`docs/configuration-guide.md`](docs/configuration-guide.md) | Env vars, mode flags, agent + skill schema |
| [`docs/api-reference.md`](docs/api-reference.md) | HTTP + SSE contract, auth, projections |
| [`docs/agent-authoring-guide.md`](docs/agent-authoring-guide.md) | `.agent.md` schema |
| [`docs/skills-authoring-guide.md`](docs/skills-authoring-guide.md) | `SKILL.md`, progressive disclosure, scripts, http-tools |
| [`docs/reference/tools.md`](docs/reference/tools.md) | Every agent-facing tool, internal helper, runtime home, config, and debugging path |
| [`docs/memory-architecture.md`](docs/memory-architecture.md) + [`docs/long-term-memory-design.md`](docs/long-term-memory-design.md) | Short-term + long-term memory |
| [`docs/hybrid-search.md`](docs/hybrid-search.md) | `mongodb_vector_search` + hybrid BM25 |
| [`docs/logging-architecture.md`](docs/logging-architecture.md) + [`docs/observability-runbook.md`](docs/observability-runbook.md) | Logs, OTel, dashboards, alarms |
| [`docs/trace-ui-system-overview.md`](docs/trace-ui-system-overview.md) + Trace Viewer guides | Inline card + Trace Viewer page |
| [`docs/agentcore-runtime-design.md`](docs/agentcore-runtime-design.md) | 5-runtime topology, code vs container artifact |
| [`docs/debugging.md`](docs/debugging.md) | Developer playbook (EC2 access, common failures, persistent pitfalls, validation scripts) |
| [`docs/estimate.md`](docs/estimate.md) | Monthly AWS cost estimate |
| [`docs/demo/demo-script.md`](docs/demo/demo-script.md) + [`docs/demo/demo-mode-guide.md`](docs/demo/demo-mode-guide.md) | Demo walkthrough + trace UI knobs |
| **Reference appendix** | |
| [`docs/reference/env-vars.md`](docs/reference/env-vars.md) | Every env var |
| [`docs/reference/terraform-modules.md`](docs/reference/terraform-modules.md) | Every Terraform module |
| [`docs/reference/ssm-parameters.md`](docs/reference/ssm-parameters.md) | Cross-stack SSM contract |
| [`docs/reference/data-model.md`](docs/reference/data-model.md) | Every Mongo collection, indexes, TTL |
| [`docs/reference/smoke-tests.md`](docs/reference/smoke-tests.md) | Every `e2e-smoke/*` script |
| [`docs/reference/deploy-scripts.md`](docs/reference/deploy-scripts.md) | Every shell script under `deploy/` |
| [`AGENTS.md`](AGENTS.md) | Contributor conventions (AI + human) |
| [`PROJECT_STRUCTURE.md`](PROJECT_STRUCTURE.md) | Per-folder rationale |

---

## Built with

- [Strands Agents SDK](https://github.com/strands-agents/sdk-typescript) — agent orchestration (runs inside the AgentCore Runtime container)
- [Hono](https://hono.dev/) — HTTP API + SSE
- [jose](https://github.com/panva/jose) — JWT verification
- [MongoDB Atlas](https://www.mongodb.com/atlas) — data + vector search + long-term memory
- [AWS Bedrock](https://aws.amazon.com/bedrock/) — Claude Sonnet / Haiku + Titan embeddings + Knowledge Bases
- [Bedrock AgentCore](https://docs.aws.amazon.com/bedrock-agentcore/) — Runtime, Gateway, Memory
- [Voyage AI on SageMaker](https://aws.amazon.com/marketplace/pp/prodview-hrid2zxusacxy) — `voyage-multimodal-3` embeddings (SoW-aligned)
- [Agent Skills specification](https://agentskills.io/specification) — skill format
- [Streamlit](https://streamlit.io/) — chat client + Trace Viewer
- [OpenTelemetry](https://opentelemetry.io/) + AWS Distro for OpenTelemetry — tracing
