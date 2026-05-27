# Project structure

A per-folder map of the repository as it ships today. Each entry explains **what it is** and **why it exists** so a new owner can navigate without having to grep for the canonical source.

> Companion: [`docs/README.md`](docs/README.md) — getting started entry point, reading orders.

---

## Top-level layout

```
.
├── api/                    Bun + Hono API + shared AgentCore Runtime bundle
├── ui/                     Streamlit chat UI (Chat + Sessions + Trace Viewer)
├── mcp-runtimes/
│   └── mongodb-mcp/        MongoDB MCP server as an AgentCore Runtime (ARM64 container)
├── config/
│   ├── agents/             *.agent.md — runtime LLM agent definitions
│   ├── skills/             SKILL.md folders — domain knowledge + scripts + http-tools
│   ├── environment.yaml    API defaults (port, CORS, etc.)
│   ├── demo-prompts.yaml   Sidebar "Try a prompt" entries
│   └── http-tools.json     Optional global HTTP tools + SSRF allowlist
├── db-seeding/             Atlas data + Atlas Search/vector index seed scripts
├── deploy/                 All deploy assets — Terraform, scripts, IAM
├── e2e/                    Playwright API smoke specs
├── e2e-smoke/              Python live-AWS smoke + memory recall diagnostic
├── docs/                   Canonical getting started pack (read docs/README.md first)
├── .github/workflows/      ci.yml + deploy.yml
├── compose.yaml            Local docker-compose for API + UI
├── Makefile                docker-up / docker-build / docker-down / docker-logs shortcuts
├── .env.sample             Every env var, commented (copy to .env)
├── .env.docker.example     Docker-compose overrides
├── README.md               Project overview (points at docs/README.md for getting started)
├── AGENTS.md               Contributor conventions (AI + human)
└── PROJECT_STRUCTURE.md    This file
```

`lambda/` has been retired — the MongoDB MCP tool path moved into `mcp-runtimes/mongodb-mcp/` (AgentCore Runtime).

---

## `api/` — Bun + Hono API + AgentCore Runtime bundle

TypeScript service, two entrypoints from one bundle:

| Entry | Hosted as | What it runs |
|---|---|---|
| `src/index.ts` | API process (EC2 systemd / laptop / Docker) | HTTP + SSE on port 3000, in-API classifier, sessions, trace persistence, LTM read+write |
| `src/agent-runtime-code.ts` | AgentCore Runtime (`NODE_22` code artifact) | Stateless agent loop — receives the full turn payload (message + memory context) and returns an SSE stream |

```
api/
├── src/
│   ├── index.ts                  API boot (assertJwksAuthConfigured, assertAgentcoreOrchestratorArn, …)
│   ├── agent-runtime-code.ts     Shared AgentCore Runtime entrypoint (AGENT_ID selects persona)
│   ├── routes/                   chat, sessions, agents, traces, health, agent-config-refresh, …
│   ├── middleware/               auth (jose JWT), rate-limit, request-id, otel, cors
│   ├── lib/                      Domain — agent-classifier, run-chat-stream, prompt, long-term-memory,
│   │                             session-store, trace-collector, embed-query, mongo-client, …
│   ├── adapters/                 agentcore-runtime, mongodb-mcp-client, resolve-model, voyage-embedding
│   └── lib/base-tools.ts         In-process Strands tools (bedrock_kb_retrieve, embed_multimodal_content, read_skill_resource)
├── scripts/
│   ├── validate-bun-compat.ts          Bun + Node 22 smoke
│   ├── validate-agentcore-memory.ts    AgentCore Memory SDK contract
│   ├── validate-strands-otel.ts        Strands ↔ OTel peer-dep drift
│   ├── validate-strands-retries.ts     Strands retry-hook surface (TracingRetryStrategy)
│   └── bench-chat-ttfb.ts              TTFB benchmark
├── tests/
│   ├── unit/                     Fast Bun-runner unit tests
│   ├── integration/              Real-backend integration tests (env-gated)
│   └── fixtures/                 Test fixtures
├── Dockerfile                    API image (build context = repo root, embeds config/)
├── Dockerfile.agentcore          Container-mode AgentCore Runtime image (fallback)
├── package.json                  Pinned: Strands TS 0.7, OTel 1.30.x line
├── README.md                     Developer onboarding
└── tsconfig.json
```

See [`api/README.md`](api/README.md) for the validation-script catalog.

---

## `ui/` — Streamlit chat UI

```
ui/
├── app.py                        Main Chat page
├── pages/
│   ├── 1_Sessions.py             Past sessions (filtered by JWT sub)
│   └── 2_Trace_Viewer.py         Debug-grade Trace Viewer (?include=core|dev|full)
├── lib/
│   ├── api_client.py             Typed HTTP API wrapper (SSE chat, sessions, agents, traces)
│   ├── cognito_gate.py           Hosted-UI redirect / embedded login / STREAMLIT_AUTH_DISABLED
│   ├── chat_panel.py             Main chat flow + suggested prompts + sidebar
│   ├── inline_summary.py         Per-turn inline card (skills, vector search previews, LTM toast)
│   ├── client_trace_view.py      Demo-friendly Trace Viewer renderers
│   ├── developer_trace_view.py   Debug-grade Trace Viewer renderers (?include=dev lazy load)
│   ├── trace_view_helpers.py     Shared (_omittedForCoreMode sentinels, byte-cap badges)
│   └── log.py                    Structured JSON logging — grep same way as the API
├── scripts/
│   ├── render_dev_fixture.py     Render captured trace fixture for screenshot review
│   └── render_ltm_fixture.py     Render LTM fixture in isolation
├── tests/                        Pytest for helpers + Cognito gate
├── Dockerfile                    Streamlit container (build context = ui/)
├── requirements.txt
└── README.md                     Developer onboarding
```

---

## `mcp-runtimes/mongodb-mcp/` — MongoDB MCP runtime

Container-mode AgentCore Runtime (ARM64) running a streamable-HTTP MCP server on `0.0.0.0:8000/mcp`. Exposes `mongodb_query`, `mongodb_vector_search`, `mongodb_aggregate`. Reached by the API + every other AgentCore Runtime through the AgentCore Gateway target.

```
mcp-runtimes/mongodb-mcp/
├── src/
│   ├── server.ts                 MCP server boot
│   └── vendor/                   Canonical home for tool implementations
│       ├── handlers.mjs          mongodb_query / vector_search / aggregate / hybrid_search
│       ├── guards.mjs            Operation allowlist, write gate, $out/$merge denylist, limit cap
│       ├── tracing.mjs           Per-call trace collector
│       └── diagnostics.mjs       Healthcheck + introspection
├── Dockerfile                    --platform=linux/arm64 (AgentCore Runtime MCP requirement)
├── package.json
└── README.md
```

`api/src/adapters/mongodb-mcp-client.ts` is the API-side MCP client.

---

## `config/` — Runtime configuration

```
config/
├── agents/
│   ├── orchestrator.agent.md         Haiku 4.5 — rollback two-hop classifier
│   ├── order-management.agent.md     Haiku 4.5
│   ├── product-recommendation.agent.md   Sonnet 4.6
│   └── troubleshooting.agent.md      Sonnet 4.6
├── skills/
│   ├── order-management/
│   │   ├── SKILL.md
│   │   ├── scripts/validate-return.mjs
│   │   ├── references/order-schema.md
│   │   └── http-tools.example.json
│   ├── product-recommendation/
│   │   ├── SKILL.md
│   │   └── references/
│   └── troubleshooting/
│       ├── SKILL.md
│       ├── references/{common-issues,error-codes}.md
│       └── scripts/{build-ticket,escalation-checklist}.mjs
├── environment.yaml                  API port + CORS defaults
├── demo-prompts.yaml                 Streamlit "Try a prompt" entries
└── http-tools.json                   Optional global HTTP tools + SSRF host allowlist
```

The API rescans this folder on every chat request, so config-only edits hot-reload without an API restart. AgentCore Runtimes pick up changes only after `./deploy/deploy-agents.sh` rebundles + redeploys.

---

## `db-seeding/` — Atlas seeders

`bun db-seeding/seed-all.ts` seeds customers, products, troubleshooting docs, orders, then runs `seed-indexes.ts` (TTL on `agent_memory_facts`, unique `{userId, factHash}`, partial-unique `troubleshooting_docs.docId`, Atlas vector + Search BM25 indexes on 4 collections). `seed-embeddings.ts` backfills `embedding` via Voyage or Bedrock Titan.

Idempotent — `deploy-project.sh` and `deploy-api.sh` re-run `seed-indexes.ts` on every deploy.

Companion: [`docs/reference/data-model.md`](docs/reference/data-model.md).

---

## `deploy/` — Infrastructure as Code + scripts

```
deploy/
├── deploy-full-with-privatelink.sh   Orchestrator — PrivateLink mode (default)
├── deploy-full-with-vpc-peering.sh   Orchestrator — VPC peering mode
├── deploy-api.sh                     Rebuild + push API image, refresh .env.live, restart multiagent-api
├── deploy-ui.sh                      Rebuild + push UI image, restart multiagent-ui
├── deploy-agents.sh                  Re-bundle agent code, targeted apply on runtime modules
├── scripts/
│   ├── _aws-auth.sh                  Shared AUTH_MODE=iam/sts validator
│   ├── _agents-common.sh             Shared helpers for deploy-agents.sh + deploy-project.sh agent phase
│   ├── deploy-network.sh             account+region singleton — VPC + Atlas connectivity
│   ├── deploy-shared.sh              account+region+env singleton — SageMaker + log groups + dashboards
│   ├── deploy-project.sh             per-project EC2 + ECR + AgentCore + KB
│   ├── deploy-local.sh               localhost API+UI against Atlas + Bedrock KB
│   ├── destroy.sh                    Teardown — --mode {network,shared,ec2,local}
│   ├── docker-build.sh / docker-push-ecr.sh / docker-build-push.sh
│   ├── probe-resources.sh            Pre-flight permission check (30 resources)
│   ├── list-resources.sh             Inventory deployed resources
│   ├── setup-voyage-marketplace.sh   One-time Voyage AI Marketplace subscription
│   ├── setup-troubleshooting-infra.sh / teardown-troubleshooting-infra.sh
│   └── backend-smoke.py              Backend smoke check (used by deploy-api.sh)
├── iam/
│   ├── policy.json                   Consolidated deploy policy (scoped, no iam:*)
│   ├── trust-policy.json             STS assume-role trust policy
│   └── README.md                     Rationale + attach commands + STS setup
├── terraform/
│   ├── bootstrap/                    S3 state bucket + DynamoDB lock table
│   ├── envs/
│   │   ├── network/                  account+region singleton — shared VPC + Atlas PL/peering + SSM
│   │   ├── shared/                   account+region+env singleton — SageMaker + log groups + dashboards + Bedrock invocation logging
│   │   ├── ec2/                      per-project — EC2 + ECR + Cognito + KB + 5 AgentCore Runtimes + ADOT sidecar
│   │   └── local/                    per-laptop — Cognito + KB + Secrets Manager
│   ├── modules/
│   │   ├── networking/                       VPC + subnets + IGW + route table + SG + EIP
│   │   ├── mongodb-atlas/                    Atlas M10 cluster + DB user + IP allowlist
│   │   ├── atlas-privatelink/                AWS Interface VPCE + Atlas-side binding (envs/network)
│   │   ├── atlas-privatelink-dns/            Per-cluster Route 53 zone + wildcard CNAME (envs/ec2)
│   │   ├── atlas-vpc-peering/                AWS VPC peering + Atlas network_peering + Private DNS for Peering
│   │   ├── bedrock-kb/                       Bedrock KB + data source
│   │   ├── bedrock-kb-privatelink/           Per-cluster NLB to Atlas VPCE for KB ingestion (privatelink mode)
│   │   ├── bedrock-kb-peering/               NLB to discovered Atlas peering IPs for KB ingestion (peering mode, EXPERIMENTAL)
│   │   ├── ec2/                              EC2 instance profile + user-data (SSM-only, no SSH)
│   │   ├── ecr/                              Private ECR repos for API + UI + MCP images
│   │   ├── cognito/                          User Pool + App (Cognito) (Cognito hosted UI + JWKS)
│   │   ├── agentcore-memory/                 AgentCore Memory Store
│   │   ├── agentcore-gateway/                AgentCore Gateway + mcp_server target → MongoDB MCP runtime
│   │   ├── agentcore-agent-runtime/          AgentCore Runtime (5 runtimes — 4 chat code-mode + 1 MCP container-mode)
│   │   ├── voyage-sagemaker/                 SageMaker real-time endpoint for voyage-multimodal-3
│   │   ├── cloudwatch/                       Shared log groups (envs/shared)
│   │   ├── cloudwatch-fleet-dashboards/      Fleet + Mongo + Cost dashboards + 7 fleet alarms
│   │   ├── cloudwatch-atlas-dashboard/       Atlas Prometheus scrape + dashboard + 2 alarms
│   │   ├── cloudwatch-genai/                 X-Ray sampling rules + service-map config
│   │   ├── adot-collector/                   ADOT sidecar on EC2 — OTel → X-Ray + CloudWatch
│   │   └── bedrock-invocation-logging/       Account-scoped Bedrock model invocation logging
│   └── .design.md                            Stack rationale (start here for IaC questions)
└── kb-docs/                          Versioned KB source documents uploaded to S3 on apply
```

Companions:
- [`docs/reference/deploy-scripts.md`](docs/reference/deploy-scripts.md) — every script + flag + phase index
- [`docs/reference/tools.md`](docs/reference/tools.md) — every supported agent tool + runtime home
- [`docs/reference/terraform-modules.md`](docs/reference/terraform-modules.md) — every module + inputs/outputs
- [`docs/reference/ssm-parameters.md`](docs/reference/ssm-parameters.md) — cross-stack SSM contract
- [`deploy/terraform/.design.md`](deploy/terraform/.design.md) — the **why** behind non-obvious Terraform choices

---

## `e2e/` + `e2e-smoke/` — Smoke tests

| Folder | Stack | When |
|---|---|---|
| `e2e/` | Playwright + Bun | Against deployed API — `/health`, `/agents`, `/skills` |
| `e2e-smoke/` | Python | Post-deploy live AWS — `post-deploy-smoke.py`, `memory-recall-diagnostic.py` |

Companion: [`docs/reference/smoke-tests.md`](docs/reference/smoke-tests.md).

---

## `docs/` — Documentation pack

```
docs/
├── README.md                          ← GETTING STARTED ENTRY POINT
├── architecture.md
├── deployment-guide.md                ← deploy + CI/CD + teardown
├── configuration-guide.md             ← config/ folder (agents, skills, yaml)
├── advanced/
│   └── deploy-tweak-guide.md          ← optional: deploy/runtime env tuning
├── api-reference.md
├── agent-authoring-guide.md
├── skills-authoring-guide.md
├── memory-architecture.md
├── long-term-memory-design.md
├── hybrid-search.md
├── logging-architecture.md
├── observability-runbook.md
├── trace-ui-system-overview.md
├── trace-viewer-guide.md
├── trace-viewer-developer-guide.md
├── agentcore-runtime-design.md
├── status/
│   ├── README.md                      ← status / ops doc index
│   └── debugging.md                   ← developer playbook + persistent pitfalls + validation scripts
├── estimate.md
├── demo/
│   ├── demo-script.md
│   └── demo-mode-guide.md
├── dashboards/
│   ├── README.md                      Widget catalog + console URLs + alarm thresholds
│   └── *.png                          (Illustrative — names will differ in your env)
├── diagrams/                          (Historical — see diagrams/README.md)
└── reference/
    ├── env-vars.md
    ├── terraform-modules.md
    ├── ssm-parameters.md
    ├── data-model.md
    ├── smoke-tests.md
    └── deploy-scripts.md
```

---

## `.github/workflows/`

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | push / PR | `bun run typecheck` + `bun run validate:bun` + `bun run validate:agentcore` + `bun test tests/unit` |
| `deploy.yml` | manual / tag | Mirror of `deploy-full-with-privatelink.sh` / `deploy-full-with-vpc-peering.sh` against a long-lived AWS environment |

Documented in [`docs/deployment-guide.md` § CI/CD](docs/deployment-guide.md).

---

## Naming disambiguation

| Name | Meaning |
|---|---|
| **`AGENTS.md`** at the repo root | Instructions for **coding agents / human contributors** |
| **`PROJECT_STRUCTURE.md`** (this file) | Per-folder map of the repo |
| **`config/agents/*.agent.md`** | Runtime LLM agent personas (orchestrator, order, product, troubleshoot) |
| **`config/skills/<name>/SKILL.md`** | Runtime skill instructions for a domain |
