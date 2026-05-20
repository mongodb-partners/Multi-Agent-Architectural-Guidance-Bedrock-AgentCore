# MongoDB + AWS Bedrock Multi-Agent Framework

A **configuration-driven multi-agent reference architecture** on **AWS Bedrock** (Strands Agents TypeScript SDK), **MongoDB Atlas**, and **JWT-secured** HTTP APIs. Add specialists by editing markdown config — no TypeScript changes for most flows.

> **Start here for handover:** [`docs/README.md`](docs/README.md) is the single client-handover entry point — first-day checklist, reading orders, doc map, authoritative source files.

---

## What this is

A user types a question into a Streamlit UI → the Hono API receives it → an **in-API classifier** picks the right specialist agent → that specialist runs as an **AgentCore Runtime** on AWS Bedrock and streams the answer back over SSE. Mongo tools route through a **dedicated MongoDB MCP AgentCore Runtime** behind the AgentCore Gateway. Long-term memory is **hybrid vector + BM25** across Atlas. Observability lands in CloudWatch + OTel + X-Ray.

The product goal: ship a reusable foundation that MongoDB field, partner, and professional-services teams can deploy for customer-specific multi-agent solutions. Domain behavior lives in `.agent.md` + `SKILL.md` files. Add a new vertical = add a new agent + skill, redeploy.

**Five AgentCore Runtimes:** orchestrator + 3 specialists (order-management, product-recommendation, troubleshooting) + 1 MongoDB MCP runtime. The default request path is **single-hop** (in-API classifier → specialist runtime); `USE_ORCHESTRATOR_RUNTIME=1` toggles a two-hop rollback path through the orchestrator runtime.

**Two co-equal connectivity modes** (mutually exclusive per account):
- `NETWORK_MODE=privatelink` (default, partner-validated, SoW-aligned)
- `NETWORK_MODE=peering` (alternative, with experimental KB ingestion via `bedrock-kb-peering`)

Switching modes requires destroy + redeploy. KB ingestion is **private by default in both modes**; public Atlas SRV is an explicit privacy-regression opt-out only.

---

## Quick start

```bash
# 0. One-time: AWS creds + Atlas keys + deployed AgentCore Runtimes
source .env && source .env.live

# Terminal 1 — API
export PATH="$HOME/.bun/bin:$PATH"
cd api && bun install
bun run typecheck && bun run validate:bun && bun run validate:agentcore
bun run dev

# Terminal 2 — UI
cd ui && pip install -r requirements.txt && streamlit run app.py

# Or run both with Docker (still needs AGENTCORE_ORCHESTRATOR_ARN + AWS creds)
docker compose up --build
```

See [`docs/deployment-guide.md`](docs/deployment-guide.md) for the full deploy runbook.

---

## Deployment

```bash
source .env

# Verify AWS permissions (probes 30 resources, ~5–30 min)
bash deploy/scripts/probe-resources.sh [--all]

# Run the orchestrator that matches your NETWORK_MODE
./deploy/deploy-full-with-privatelink.sh --auto-approve     # PrivateLink (default)
# or
./deploy/deploy-full-with-vpc-peering.sh --auto-approve     # VPC peering

# Post-deploy smoke
python3 e2e-smoke/post-deploy-smoke.py

# Targeted redeploys
./deploy/deploy-api.sh                # API image only
./deploy/deploy-ui.sh                 # UI image only
./deploy/deploy-agents.sh             # Re-bundle agent code + AgentCore Runtimes only
./deploy/scripts/deploy-shared.sh     # SageMaker + log groups + dashboards (singleton per account+region+env)

# Tear down (run ec2 → shared → network)
./deploy/scripts/destroy.sh --mode local   --auto-approve
./deploy/scripts/destroy.sh --mode ec2     --auto-approve
./deploy/scripts/destroy.sh --mode shared  --auto-approve
./deploy/scripts/destroy.sh --mode network --auto-approve
```

Full reference: [`docs/reference/deploy-scripts.md`](docs/reference/deploy-scripts.md).

### Terraform stack split

Four root configs share one S3 state bucket, separate state keys:

| Env | Scope | Singleton scope | State key |
|---|---|---|---|
| `envs/network` | Shared VPC + Atlas connectivity (PL or peering) + SSM publishers | account + region | `<SHARED_VPC_NAME>/<region>/network/terraform.tfstate` |
| `envs/shared` | Voyage SageMaker endpoint + 6 CloudWatch log groups + 4 dashboards + alarms + Bedrock invocation logging | account + region + env | `<env>/shared/terraform.tfstate` |
| `envs/ec2` | Atlas M10 + Bedrock KB + EC2 + ECR + Cognito + 5 AgentCore Runtimes + AgentCore Gateway + ADOT sidecar | per-project | `<env>/ec2/terraform.tfstate` |
| `envs/local` | Cognito + Bedrock KB + Secrets Manager for laptop dev | per-laptop | `<env>/terraform.tfstate` |

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

Agents are defined in `config/agents/<name>.agent.md`. Add a new agent = add a new file, redeploy. The API rescans `config/agents/` on every request, so config-only edits hot-reload without a restart.

The **default production request path** is in-API classification (`agent-classifier.ts`) → direct specialist invocation. The orchestrator AgentCore Runtime is provisioned but only invoked when `USE_ORCHESTRATOR_RUNTIME=1`.

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

**Short-term:** conversation history is replayed into the Strands `Agent` on each turn. Stored in an in-memory `Map` plus (when `MONGODB_URI` is set) the `chat_sessions` collection. Default-on; opt out with `PERSIST_CHAT_SESSIONS=0`. AgentCore Memory as the primary store is wired and feature-flagged.

**Long-term:** hybrid vector + BM25 retrieval across `agent_memory_facts` (LLM-curated facts) + `chat_messages` (per-turn mirror). Fused with Reciprocal Rank Fusion, recency-decayed, MMR-diversified, and prepended to the system prompt as `## Relevant prior context`. Keyed by JWT `sub` (`userId`) — requires auth + Atlas.

Enable per agent:

```yaml
# config/agents/<name>.agent.md frontmatter
memory:
  longTerm: true
```

Tune via env vars — defaults are `MEMORY_VECTOR_TOPK=14`, `MEMORY_WEIGHT_FACTS=1.5`, `MEMORY_WEIGHT_CHAT_MESSAGES=1.2`, `MEMORY_RECENCY_HALFLIFE_DAYS=30`, `MEMORY_MMR_LAMBDA=0.7`. Full catalog: [`docs/reference/env-vars.md`](docs/reference/env-vars.md). Architecture: [`docs/long-term-memory-design.md`](docs/long-term-memory-design.md).

---

## Authentication

JWKS auth is **mandatory**. The API refuses to start without `AUTH_JWKS_URI` + `AUTH_ISSUER` (`assertJwksAuthConfigured()` in `api/src/lib/jwt-verify.ts`). Every protected route requires `Authorization: Bearer <jwt>`. The JWT `sub` claim becomes `userId` for session scoping and long-term memory. No `ALLOW_UNAUTHENTICATED` / `REQUIRE_AUTH=false` bypass.

The Streamlit UI obtains tokens via Cognito (`streamlit-cognito-auth`) when `STREAMLIT_COGNITO_*` is set. Local dev: `DEV_MOCK_BACKENDS=1` + any non-empty stub Bearer token.

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
| [`docs/configuration-guide.md`](docs/configuration-guide.md) | Env vars, mode flags, agent + skill schema |
| [`docs/api-reference.md`](docs/api-reference.md) | HTTP + SSE contract, auth, projections |
| [`docs/agent-authoring-guide.md`](docs/agent-authoring-guide.md) | `.agent.md` schema |
| [`docs/skills-authoring-guide.md`](docs/skills-authoring-guide.md) | `SKILL.md`, progressive disclosure, scripts, http-tools |
| [`docs/memory-architecture.md`](docs/memory-architecture.md) + [`docs/long-term-memory-design.md`](docs/long-term-memory-design.md) | Short-term + long-term memory |
| [`docs/hybrid-search.md`](docs/hybrid-search.md) | `mongodb_vector_search` + hybrid BM25 |
| [`docs/logging-architecture.md`](docs/logging-architecture.md) + [`docs/observability-runbook.md`](docs/observability-runbook.md) | Logs, OTel, dashboards, alarms |
| [`docs/trace-ui-system-overview.md`](docs/trace-ui-system-overview.md) + Trace Viewer guides | Inline card + Trace Viewer page |
| [`docs/agentcore-runtime-design.md`](docs/agentcore-runtime-design.md) | 5-runtime topology, code vs container artifact |
| [`docs/debugging.md`](docs/debugging.md) | Developer playbook (EC2 access, common failures, persistent pitfalls, validation scripts) |
| [`docs/estimate.md`](docs/estimate.md) | Monthly AWS cost estimate |
| [`docs/demo-script.md`](docs/demo-script.md) + [`docs/demo-mode-guide.md`](docs/demo-mode-guide.md) | Demo walkthrough + trace UI knobs |
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
