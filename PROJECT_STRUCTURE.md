# Project Structure Guide

This document explains every folder and key file in this repository — what lives there and why it exists.

---

## Top-Level Overview

```
mongodb-aws-bedrock-multi-agent-framework/
├── api/               ← Hono/Bun backend API (the agent runtime)
├── ui/                ← Streamlit Python chat UI
├── config/            ← Agent + skill definitions (no code — markdown + JSON)
├── db-seeding/        ← Scripts to seed MongoDB Atlas with data + embeddings
├── deploy/            ← All deployment artifacts (Terraform, shell scripts, KB docs)
├── e2e/               ← Playwright end-to-end tests against the running UI
├── lambda/            ← Future Lambda adapters for AgentCore Gateway mode
├── docs/              ← Detailed documentation (architecture, guides, API reference)
└── .github/           ← CI/CD workflow (GitHub Actions)
```

---

## `api/` — Backend API (Hono + Bun + Strands)

The heart of the system. A TypeScript API server that runs the multi-agent loop and streams responses to the UI.

**Why it exists:** All agent orchestration, tool execution, session management, and streaming happen here. The UI is a thin client — everything intelligent is in this process.

```
api/
├── src/
│   ├── index.ts              ← Entry point: starts the Hono server on :3000
│   ├── app.ts                ← Registers all routes and middleware on the Hono app
│   ├── env.d.ts              ← TypeScript types for environment variables
│   │
│   ├── routes/               ← HTTP endpoint handlers
│   │   ├── chat.ts           ← POST /chat — receives messages, runs agent, streams SSE response
│   │   ├── agents.ts         ← GET /agents — lists available agents from config/agents/
│   │   ├── skills.ts         ← GET /skills — lists available skills from config/skills/
│   │   ├── sessions.ts       ← GET/DELETE /sessions — session management (user-scoped)
│   │   ├── health.ts         ← GET /health — liveness check + dependency status
│   │   └── http-tools-meta.ts← GET /http-tools — lists configured HTTP tool integrations
│   │
│   ├── middleware/           ← Request pipeline (runs before every route)
│   │   ├── auth.ts           ← JWT validation via JWKS (Cognito-compatible); always required (assertJwksAuthConfigured at boot)
│   │   ├── rate-limit.ts     ← Per-IP / per-token rate limiting
│   │   ├── request-id.ts     ← Attaches a unique requestId to every request for log correlation
│   │   └── access-log.ts     ← Structured JSON access log per request
│   │
│   ├── lib/                  ← Core business logic
│   │   ├── create-strands-agent.ts  ← Assembles a Strands Agent from an .agent.md config (persona + tools + memory)
│   │   ├── run-chat-stream.ts       ← Single-agent SSE streaming pipeline
│   │   ├── swarm-chat-stream.ts     ← Multi-agent Swarm pipeline (ORCHESTRATOR_MODE=swarm)
│   │   ├── skill-loader.ts          ← Loads SKILL.md files on demand; progressive disclosure pattern
│   │   ├── long-term-memory.ts      ← Reads/writes user memory from MongoDB agent_memory collection
│   │   ├── session-store.ts         ← In-memory or MongoDB-backed chat session storage
│   │   ├── base-tools.ts            ← Defines the 6 generic agent tools (mongodb_query, vector_search, kb_retrieve, etc.)
│   │   ├── prompt.ts                ← Builds agent system prompts (persona + skill blocks + memory context)
│   │   ├── http-tools-runtime.ts    ← Executes HTTP tool calls to Lambda/API Gateway URLs
│   │   ├── http-tools-load.ts       ← Loads root config/http-tools.json
│   │   ├── skill-http-tools-load.ts ← Loads per-skill http-tools.json files
│   │   ├── jwt-verify.ts            ← JWKS-based JWT signature verification
│   │   ├── logger.ts                ← Structured JSON logger (LOG_LEVEL env var)
│   │   ├── environment-config.ts    ← Parses config/environment.yaml for API defaults
│   │   ├── config-scan.ts           ← Scans config/ directory at startup for agents + skills
│   │   ├── orchestrator-mode.ts     ← Reads ORCHESTRATOR_MODE (swarm | single)
│   │   ├── schemas.ts               ← Zod schemas for validating .agent.md frontmatter
│   │   ├── paths.ts                 ← Canonical paths to config directories
│   │   ├── mongo-client.ts          ← Shared MongoDB Atlas client singleton
│   │   ├── chat-sessions-collection.ts ← MongoDB collection for persistent chat sessions
│   │   ├── health-status.ts         ← Builds the /health response object
│   │   └── json-safe.ts             ← Utility to safely serialize tool results
│   │
│   └── adapters/             ← Swappable backend integrations
│       ├── resolve-model.ts       ← Builds the BedrockModel for an agent
│       ├── agentcore-runtime.ts   ← invokeAgentRuntime + the AGENTCORE_ORCHESTRATOR_ARN startup guard
│       ├── voyage-embedding.ts    ← SageMaker embedding adapter for Voyage AI multimodal-3
│       └── bedrock-retrieval.ts   ← Bedrock Knowledge Base retrieve + Bedrock embedding helpers
│
├── tests/
│   ├── unit/             ← Fast tests with no network calls (mock everything)
│   ├── integration/      ← Tests that spin up the real API server with mocked AgentCore Runtime
│   ├── system/           ← Tests that call live AWS + MongoDB (requires credentials)
│   ├── fixtures/         ← Shared test data used across test suites
│   └── helpers/          ← Test utilities (SSE parser, request helpers, etc.)
│
├── scripts/
│   ├── validate-agentcore-memory.ts ← Smoke-tests the AgentCore Memory SDK connection
│   └── validate-bun-compat.ts       ← Checks Bun runtime compatibility with AWS SDK packages
│
├── Dockerfile            ← Container image for the API (used by ECS and docker-compose)
├── package.json          ← Dependencies: hono, @strands-agents/sdk, mongodb, aws-sdk, jose, zod
└── tsconfig.json         ← TypeScript config (Bun-compatible, strict mode)
```

**Key environment variables:**

| Variable | Purpose |
|---|---|
| `AGENTCORE_ORCHESTRATOR_ARN` | **Required at startup.** ARN of the orchestrator AgentCore Runtime the API forwards every chat turn to. |
| `MONGODB_MCP_RUNTIME_ARN` / `MONGODB_MCP_RUNTIME_ENDPOINT` | Direct MongoDB MCP AgentCore Runtime target. |
| `AGENTCORE_GATEWAY_URL` / `MCP_SERVER_URL` | AgentCore Gateway MCP endpoint for non-Mongo Gateway tools. |
| `ORCHESTRATOR_MODE` | `swarm` (default for the orchestrator runtime) or `single`. |
| `MONGODB_URI` | Atlas connection string used by the API for chat session persistence and long-term memory writes. |
| `BEDROCK_KB_ID` | Bedrock Knowledge Base ID for RAG retrieval. |
| `AUTH_JWKS_URI` / `AUTH_ISSUER` | **Required at startup.** OIDC pool used to verify the Bearer JWT on every protected request (`assertJwksAuthConfigured()`). |
| `VOYAGE_SAGEMAKER_ENDPOINT` | SageMaker endpoint name for Voyage AI embeddings. |

---

## `ui/` — Streamlit Chat Interface

A Python-based web UI that users interact with. Renders the streaming chat response, shows agent handoffs and active skills in the sidebar.

**Why it exists:** The API speaks raw HTTP + SSE. The UI handles all browser-facing concerns: authentication, session management, message rendering, and streaming display. It is intentionally stateless — all data lives in the API.

```
ui/
├── app.py               ← Main Streamlit entrypoint; renders the chat page
├── pages/
│   └── 1_Sessions.py    ← "Sessions" page — lists and deletes active sessions
│
├── lib/
│   ├── api_client.py    ← HTTP client for the Hono API; handles SSE parsing and token streaming
│   ├── chat_panel.py    ← Chat message rendering (user/assistant bubbles, tool badges, handoff indicators)
│   ├── cognito_gate.py  ← Cognito OAuth 2.0 login flow; blocks access until user authenticates
│   ├── config.py        ← Reads env vars (API URL, Cognito IDs, feature flags)
│   ├── session_state.py ← Manages Streamlit session state (current session, history, active agent)
│   └── sidebar.py       ← Sidebar: active agent, skill badges, session controls
│
├── tests/
│   ├── test_config.py       ← Unit tests for config loading
│   └── test_cognito_gate.py ← Unit tests for the Cognito auth gate
│
├── Dockerfile           ← Container image for Streamlit (used by ECS and docker-compose)
└── requirements.txt     ← Python dependencies: streamlit, streamlit-cognito-auth, requests, sseclient
```

---

## `config/` — Agent and Skill Definitions

The configuration layer of the system. **No TypeScript code lives here** — only markdown and JSON files. Adding or changing an agent or skill requires no code changes.

**Why it exists:** The design principle of this framework is that agents are configuration, not code. A new domain (e.g., billing support) can be added by dropping in a new `.agent.md` and `SKILL.md` without touching the API codebase. Config is hot-reloaded on every request.

```
config/
├── agents/                      ← One .agent.md per agent
│   ├── orchestrator.agent.md    ← Routes messages to the right specialist; never answers directly
│   ├── order-management.agent.md    ← Handles order lookup, status, returns
│   ├── product-recommendation.agent.md ← Recommends products by need, budget, or as replacements
│   └── troubleshooting.agent.md     ← Diagnoses product issues; escalates via support tickets
│
├── skills/                      ← One directory per skill domain
│   ├── order-management/
│   │   ├── SKILL.md             ← Step-by-step instructions telling the agent what tools to call and how
│   │   ├── http-tools.json      ← HTTP tool config: Lambda URLs the agent can call (e.g. validate-return)
│   │   ├── references/          ← Deep reference docs loaded on-demand via read_skill_resource tool
│   │   └── scripts/             ← .mjs scripts the agent runs via run_skill_script tool
│   │
│   ├── product-recommendation/
│   │   ├── SKILL.md             ← Vector search patterns, ranking logic, presentation rules
│   │   ├── references/          ← Catalog field reference, search pattern examples
│   │   └── scripts/             ← score-recommendations.mjs: ranks products by relevance
│   │
│   └── troubleshooting/
│       ├── SKILL.md             ← Symptom → doc lookup → escalation workflow
│       ├── references/          ← Error code table, common issues symptom map
│       └── scripts/             ← build-ticket.mjs: generates support ticket payloads
│
├── environment.yaml             ← API defaults: port, CORS origins (overridden by env vars)
├── http-tools.json              ← Global HTTP tool allowlist + SSRF security policy
└── http-tools.example.json      ← Example of how to define HTTP tools
```

**How `.agent.md` files work:**
Each file has a YAML frontmatter block (model, tools, skills, memory settings) followed by a markdown body (the agent persona). The API parses this with Zod on every request.

**How `SKILL.md` files work:**
These are the agent's domain playbook. They tell the agent which tools to call, in what order, and how to present results. The agent sees the full SKILL.md in its system prompt once the skill is activated.

---

## `db-seeding/` — MongoDB Atlas Data Setup

Scripts to populate a fresh MongoDB Atlas cluster with the data the agents need to function.

**Why it exists:** The agents query real MongoDB data. Before the system can work in live mode, the Atlas cluster needs collections, documents, vector indexes, and embeddings. These scripts handle that one-time setup.

```
db-seeding/
├── seed-all.ts          ← Orchestrator: runs all seed scripts in the right order
├── seed-customers.ts    ← Inserts sample customer records
├── seed-orders.ts       ← Inserts sample orders (linked to customers)
├── seed-products.ts     ← Inserts product catalog with tags and metadata
├── seed-troubleshooting.ts ← Inserts troubleshooting documents (ts-1 through ts-10)
├── seed-embeddings.ts   ← Generates vector embeddings for products + troubleshooting docs
│                           Supports both Titan (Bedrock) and Voyage AI (SageMaker)
│                           Set REWIRE_EMBEDDINGS=1 to wipe and re-embed with new model
├── seed-indexes.ts      ← Creates MongoDB Atlas Vector Search indexes on the embedded collections
│                           Default dimension: 1024 (Voyage AI); Titan fallback: 1536
├── connect.ts           ← Shared Atlas connection helper used by all seed scripts
├── package.json         ← Separate package (runs with Bun or node --experimental-strip-types)
└── README.md            ← Usage instructions + env var reference
```

---

## `deploy/` — All Deployment Artifacts

Everything needed to provision infrastructure and ship the application to AWS.

```
deploy/
├── kb-docs/             ← Source documents for the Bedrock Knowledge Base
│   ├── power-boot-guide.txt          ← Troubleshooting guide: power and boot issues
│   ├── connectivity-guide.txt        ← Troubleshooting guide: Wi-Fi and connectivity
│   ├── hardware-escalation-guide.txt ← When and how to escalate hardware faults
│   └── warranty-support-tiers.txt    ← Warranty coverage and support tier policies
│
│   These .txt files are uploaded to S3 by the bedrock-kb Terraform module,
│   ingested by Bedrock, embedded, and indexed in Atlas for RAG retrieval.
│
├── scripts/
│   ├── deploy.sh                    ← MAIN DEPLOY SCRIPT — runs full stack deployment (8 phases)
│   │                                   Phase 1: Prerequisites check
│   │                                   Phase 2: Load env.sh, map credentials to TF_VAR_* env vars
│   │                                   Phase 3: Bootstrap S3 + DynamoDB (idempotent)
│   │                                   Phase 4: Generate backend.hcl + terraform.tfvars
│   │                                   Phase 5: terraform init + plan + apply
│   │                                   Phase 6: docker build API+UI → ECR push
│   │                                   Phase 7: ECS force-new-deployment + wait for stability
│   │                                   Phase 8: Write .env.live, print app URL
│   │
│   ├── destroy.sh                   ← Tears down all Terraform-managed infrastructure
│   ├── docker-build.sh              ← Builds API + UI Docker images locally
│   ├── docker-push-ecr.sh           ← Tags and pushes local images to ECR
│   ├── setup-troubleshooting-infra.sh  ← Legacy shell-based infra setup (pre-Terraform); idempotent
│   └── teardown-troubleshooting-infra.sh ← Tears down resources created by setup script
│
└── terraform/
    ├── main.tf              ← Root: providers (aws, random, mongodbatlas) + all module calls
    ├── variables.tf         ← All input variables with types, descriptions, and defaults
    ├── outputs.tf           ← Outputs exposed after apply (ALB URL, ECR URLs, Cognito IDs, etc.)
    ├── terraform.tfvars     ← Runtime variable values (gitignored; generated by deploy.sh)
    ├── terraform.tfvars.example ← Template showing all required variables with placeholders
    ├── backend.hcl          ← S3 backend config (gitignored; generated by deploy.sh)
    ├── backend.hcl.example  ← Template for backend.hcl
    │
    ├── bootstrap/           ← One-time setup: creates the S3 bucket + DynamoDB table
    │   └── main.tf          │  used for Terraform remote state. Run before main terraform init.
    │
    └── modules/             ← Reusable infrastructure modules
        │
        ├── networking/      ← VPC, subnets, routing, security groups, VPC endpoints
        │                       Creates: VPC (10.0.0.0/16), 2 public + 2 private subnets across 2 AZs,
        │                       internet gateway, NAT gateway, route tables, security groups for
        │                       ALB / ECS / VPC endpoints, interface endpoints for ECR/Bedrock/
        │                       SageMaker/Secrets Manager/CloudWatch Logs, S3 gateway endpoint.
        │                       Why: ECS tasks run in private subnets for security; VPC endpoints
        │                       keep AWS API traffic off the public internet.
        │
        ├── cognito/         ← Cognito User Pool + App Client + Hosted UI domain
        │                       Why: Provides OAuth 2.0 authentication. The API validates JWTs
        │                       issued by this pool on every request — JWKS auth is mandatory.
        │
        ├── ecr/             ← ECR repositories for the API and UI container images
        │                       Why: ECS pulls images from ECR. Repos must exist before docker push.
        │
        ├── alb/             ← Application Load Balancer: internet-facing, target groups, listeners
        │                       Routes: /ui/* → Streamlit target group, /* → API target group
        │                       Optional HTTPS when certificate_arn is provided.
        │                       Why: Single public entry point; no direct public access to ECS tasks.
        │
        ├── cloudwatch/      ← CloudWatch log groups, CPU alarms, dashboard
        │                       Log groups: /ecs/<project>-api-<env> and /ecs/<project>-ui-<env>
        │                       Why: Log groups must exist before ECS tasks start or the awslogs
        │                       driver fails. Alarms + dashboard provide production observability.
        │
        ├── ecs/             ← ECS Fargate cluster, task definitions, IAM roles, ECS services
        │                       API task: Hono/Bun, 512 CPU / 1024 MB, env vars injected directly
        │                       UI task: Streamlit, 256 CPU / 512 MB
        │                       IAM task role: Bedrock invoke, KB retrieve, SageMaker invoke,
        │                       Secrets Manager read, S3 read, CloudWatch logs
        │                       Why: Runs the application in managed, auto-scaling containers
        │                       behind the ALB without managing EC2 instances.
        │
        ├── bedrock-kb/      ← Bedrock Knowledge Base with MongoDB Atlas vector storage
        │                       Uploads kb-docs/*.txt to S3 and creates the KB + S3 data source
        │                       via native aws_bedrockagent_knowledge_base + aws_bedrockagent_data_source
        │                       (provider 6.27+, MONGO_DB_ATLAS storage supported). A small null_resource
        │                       still triggers the ingestion job and bootstraps the Atlas collection — both
        │                       are actions, not infrastructure, so no native resource exists for them.
        │                       Why: Provides RAG retrieval for the troubleshooting agent.
        │
        ├── voyage-sagemaker/← SageMaker model + endpoint for Voyage AI multimodal-3 embeddings
        │                       Conditional: only deployed when voyage_model_package_arn is set
        │                       (requires AWS Marketplace subscription).
        │                       Why: Voyage AI produces higher-quality embeddings than Titan.
        │                       The API routes generate_embedding calls to this endpoint when
        │                       VOYAGE_SAGEMAKER_ENDPOINT is set; falls back to Titan otherwise.
        │
        ├── atlas-privatelink/← AWS Interface VPCE + Atlas-side endpoint binding (envs/network only)
        │                       Creates the AWS VPC interface endpoint, the Atlas-side
        │                       privatelink_endpoint_service binding, and a CIDR-scoped security
        │                       group (ingress on var.vpc_cidr, no per-app SG references).
        │                       Owned by the shared envs/network root config so a single VPCE
        │                       per region is reused by every per-project envs/ec2 deployment.
        │                       Why: Without PrivateLink, Atlas traffic goes over the public
        │                       internet. PrivateLink keeps all MongoDB traffic inside the VPC.
        │
        └── atlas-privatelink-dns/ ← per-cluster Route 53 private hosted zone + wildcard CNAME — DNS half of Atlas PrivateLink
                                 (envs/ec2 only). One zone per Atlas cluster SRV host, attached
                                 to the shared VPC. Splits per-cluster DNS away from the shared
                                 PrivateLink VPCE so each project owns its own zone without
                                 collisions.
```

---

## `e2e/` — End-to-End Tests (Playwright)

Browser-level tests that drive the Streamlit UI and verify complete user workflows — from sending a message to confirming the right agent responded with the right data.

**Why it exists:** Unit and integration tests verify the API in isolation. E2E tests verify the complete stack: UI → API → agents → MongoDB → UI rendering. These catch integration failures that unit tests cannot.

```
e2e/
├── playwright.config.ts      ← Playwright config: browser targets, base URL, timeouts
├── helpers.ts                ← Shared utilities: waitForResponse, getLastMessage, etc.
│
├── tests/
│   └── api.spec.ts           ← API-level E2E tests (no browser; calls /chat endpoint directly)
│
├── orchestrator.spec.ts      ← Tests that the orchestrator routes to the right specialist
├── order-management.spec.ts  ← Order lookup, status queries, return flows
├── product-recommendation.spec.ts ← Product search, replacement, budget filter flows
├── troubleshooting.spec.ts   ← Symptom diagnosis, error code lookup, ticket escalation
│
└── demo-videos/              ← Recorded Playwright videos of successful E2E runs
    ├── order-management/
    ├── product-recommendation/
    └── troubleshooting/
```

---

## `lambda/` — Future AgentCore Gateway Adapters

Placeholder directories for Lambda functions that will wrap the base tools when AgentCore Gateway mode is activated (Phase 4).

**Why it exists:** MongoDB tool calls go through the dedicated MongoDB MCP AgentCore Runtime. Other agent tools (`bedrock_kb_retrieve`, embedding generation, per-skill HTTP tools) still run in-process inside the AgentCore Runtime container. These per-tool Lambda placeholders are reserved for a future migration where each tool becomes its own gateway target.

```
lambda/
└── base-tools/
    ├── README.md             ← Explains the purpose and future implementation plan
    ├── mongodb-query/        ← Future: Lambda handler for mongodb_query tool
    ├── mongodb-vector-search/← Future: Lambda handler for mongodb_vector_search tool
    ├── bedrock-kb-retrieve/  ← Future: Lambda handler for bedrock_kb_retrieve tool
    ├── generate-embedding/   ← Future: Lambda handler for generate_embedding tool
    └── read-skill-resource/  ← Future: Lambda handler for read_skill_resource tool
```

---

## `docs/` — Technical Documentation

In-depth documentation for developers working on or extending the system.

```
docs/
├── architecture.md          ← Full system design: components, data flows, sequence diagrams
├── api-reference.md         ← Every HTTP endpoint: method, path, request/response schema
├── agent-authoring-guide.md ← How to write a new .agent.md file (frontmatter fields, persona)
├── skills-authoring-guide.md← How to write SKILL.md, references/, and scripts/
├── configuration-guide.md   ← All environment variables and config/environment.yaml options
├── deployment-guide.md      ← Step-by-step guide to deploy to AWS
└── demo-script.md           ← Scripted demo walkthrough for showing the system to stakeholders
```

---

## `.github/` — CI/CD

```
.github/
└── workflows/
    └── ci.yml    ← GitHub Actions: runs on every push/PR
                     Steps: install deps → typecheck → unit tests → integration tests
                     Mocks the AgentCore Runtime invoker so no AWS credentials are needed in CI
```

---

## Root-Level Files

| File | Purpose |
|---|---|
| `README.md` | Project overview and quick-start instructions |
| `AGENTS.md` | Summary of the four agents and their responsibilities |
| `TASKS.md` | Implementation task tracker with validation gates (G0–G6) |
| `ACTION_PLAN.md` | Phased delivery plan (Phase 1–5) aligned to the SOW |
| `DEV_STATUS.md` | Current implementation status — what's live vs planned |
| `compose.yaml` | Docker Compose file for running the full stack locally (API + UI) |
| `Makefile` | Convenience targets: `make dev`, `make test`, `make build`, `make seed` |
| `env.sh` | AWS + Atlas credentials for local development (gitignored — never commit) |
| `.env.live` | Runtime env vars generated by deploy.sh after terraform apply (gitignored) |
| `.env.example` | Template for local development env vars |
| `.env.docker.example` | Template for Docker Compose env vars |
| `.gitignore` | Excludes: `env.sh`, `.env.live`, `terraform.tfvars`, `*.tfstate`, `node_modules` |
| `memory.md` | Dev session notes (internal working document) |
