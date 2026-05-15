# MongoDB + AWS Bedrock Multi-Agent Framework

A **configuration-driven multi-agent reference architecture** built on **AWS Bedrock** (Strands), **MongoDB Atlas**, and optional **JWT-secured** HTTP APIs — with **AgentCore** and fuller cloud wiring called out in [`TASKS.md`](TASKS.md). Add agents and domain behavior by editing markdown config; many paths need **no TypeScript changes**.

---

## Quick Start

The Hono API is a thin proxy in front of an AgentCore Runtime, so it requires AWS credentials and a real `AGENTCORE_ORCHESTRATOR_ARN`. The fastest local loop is to deploy the EC2 stack, copy `.env.live` into your shell, and run the API + UI against the same runtime ARN.

```bash
# 0. One-time: AWS creds + Atlas keys + a deployed AgentCore Runtime
source env.sh && source .env.live   # exports AGENTCORE_ORCHESTRATOR_ARN, AWS creds, etc.

# Terminal 1 — API
export PATH="$HOME/.bun/bin:$PATH"   # if bun is not on PATH
cd api && bun install
bun run typecheck && bun run validate:bun && bun run validate:agentcore
bun run dev

# Terminal 2 — UI
cd ui && pip install -r requirements.txt && streamlit run app.py

# Or run both with Docker (still needs AGENTCORE_ORCHESTRATOR_ARN + AWS creds)
docker compose up --build
```

See [`DEV_STATUS.md`](DEV_STATUS.md) for the full runbook (deploy, MongoDB, Swarm, auth, Docker).

---

## Deployment (run from your laptop — no CI pipeline)

All deploys are driven from your local shell. GitHub is used **only to preserve code** — there is no deploy workflow. Four scripts do the work:

| Script | Provisions | When to use |
|---|---|---|
| `deploy/scripts/deploy-network.sh` | Shared VPC + subnets + Atlas PrivateLink Interface VPCE + SSM-published IDs. **Run once per region.** | First time per region, or when changing VPC CIDR. |
| `deploy/scripts/deploy-local.sh` | Atlas M10 + Bedrock KB + Cognito + Secrets Manager. Runs API + UI on `localhost`. | Day-to-day development. |
| `deploy/scripts/deploy.sh` | Per-project EC2 stack: consumes shared VPC via SSM, provisions EC2 + ECR + Lambda MCP + AgentCore Memory + AgentCore Gateway + per-cluster Route 53 (+ optional Voyage AI SageMaker). | Full POC stack on EC2. |
| `deploy/scripts/destroy.sh` | Tears down one environment (`--mode local`, `--mode ec2`, or `--mode network`). | Cleanup. |

### One-time setup

**1. AWS IAM user.** Create a dedicated IAM user (not root, not SSO) and attach the consolidated policy shipped in this repo:

```bash
aws iam create-policy \
  --policy-name MultiAgentDeployPolicy \
  --policy-document file://deploy/iam/policy.json

aws iam attach-user-policy \
  --user-name <your-deploy-user> \
  --policy-arn arn:aws:iam::<your-account-id>:policy/MultiAgentDeployPolicy
```

The policy covers every AWS service the stack touches (EC2, VPC, ECR, Lambda, Bedrock, AgentCore, SageMaker, S3, Cognito, Secrets Manager, SSM, CloudWatch, Route 53) with **scoped IAM** — no `iam:*` wildcard, and an explicit Deny on privilege escalation (user/group/access-key mutations, SAML/OIDC providers, account password policy). See [`deploy/iam/README.md`](deploy/iam/README.md) for the full rationale and what the policy cannot do by design.

Generate an access key for this user — you'll paste it into `env.sh` below.

**2. MongoDB Atlas API key.** In Atlas → Organization → Access Manager → API Keys, create a key with **Organization Project Creator** role. Also grab your Org ID and Project ID.

**3. Create your local `env.sh`.** This file holds every secret and override; it is gitignored. A complete template with inline documentation lives at [`sample-env.sh`](sample-env.sh):

```bash
cp sample-env.sh env.sh
chmod 600 env.sh
# edit env.sh and fill in the REQUIRED values
```

Only six variables are actually required — AWS access key + secret, Atlas public + private key, Atlas project ID, and the MongoDB user password you want created. Everything else (region, project name, instance type, Voyage AI ARN) has a sensible default and is commented out in the template.

### Verify access before deploying

Before running a full deploy, use `probe-resources.sh` to verify this AWS account can create and delete every resource the stack needs. It creates each resource with the exact name terraform would use, validates it, deletes it, then prints an access matrix.

```bash
source env.sh

# Fast check (~5 min) — all resources except VPC, EC2, Atlas cluster, KB
bash deploy/scripts/probe-resources.sh

# Full EC2 production check (~25 min) — everything including VPC+EC2+Atlas+KB
bash deploy/scripts/probe-resources.sh --all
```

**Flags:**

| Flag | What it adds | Time |
|---|---|---|
| _(none)_ | Bedrock InvokeModel, S3, IAM (all roles), Secrets Manager, CloudWatch, ECR, Cognito, Lambda, SageMaker API, AgentCore Memory+Gateway, Route53, Atlas IP list + DB user | ~5 min |
| `--with-ec2` | VPC + 2×public + 2×private subnet + IGW + route table + SG + EIP + t3.medium launch + SSM check | +5 min |
| `--with-cluster` | Atlas M10 cluster + collection + vector search index | +20 min |
| `--with-bedrock-kb` | Bedrock KB + data source (requires `--with-cluster`) | +5 min |
| `--with-sagemaker` | SageMaker endpoint-config (requires `VOYAGE_MODEL_PACKAGE_ARN`) | +1 min |
| `--all` | All of the above | ~30 min |

**Resource coverage (30 resources, both local and EC2 modes):**

| Service | Resources probed |
|---|---|
| **Bedrock** | InvokeModel (Titan + Claude), bedrock-agent API, KB create/delete |
| **S3** | Bootstrap bucket + KB doc objects |
| **IAM** | 5 roles (KB, EC2, SageMaker, AgentCore GW, Lambda) + instance profile |
| **Secrets Manager** | `<project>-bedrock-kb-creds-<env>` (e.g. `mongodb-multiagent-bedrock-kb-creds-dev`) |
| **CloudWatch** | 3 log groups (`/<project>/<env>/{api,mcp,agentcore}`) |
| **ECR** | `{project}-api` + `{project}-ui` repositories |
| **Cognito** | User pool + app client |
| **Lambda** | Function + IAM role |
| **SageMaker** | Endpoint config (Voyage AI) |
| **AgentCore** | Memory Store + Gateway + Gateway Target |
| **VPC/EC2** | VPC, subnets (4), IGW, route table, SG, EIP, t3.medium instance, SSM |
| **Route53** | Private hosted zone (Atlas PrivateLink) |
| **MongoDB Atlas** | IP access list, DB user, M10 cluster, collection, vector search index |

### Every deploy afterwards

```bash
source env.sh
./deploy/scripts/deploy-network.sh --auto-approve  # once per region (shared VPC + Atlas PL VPCE)
./deploy/scripts/deploy-local.sh --auto-approve    # local dev
# or
./deploy/scripts/deploy.sh --auto-approve          # full EC2 POC (consumes shared VPC via SSM)
```

`deploy.sh` fails fast with a clear "run deploy-network.sh first" message if it cannot find the shared VPC's SSM parameters under `/${SHARED_VPC_NAME}/${AWS_REGION}/`.

Pulling new code? Re-read [`sample-env.sh`](sample-env.sh) — if new variables appear, copy them into your `env.sh` and re-`source`. The scripts fail fast with a clear error if a required variable is missing.

To tear down:

```bash
source env.sh
./deploy/scripts/destroy.sh --mode local   --auto-approve   # local resources only
./deploy/scripts/destroy.sh --mode ec2     --auto-approve   # one project; leaves shared VPC + Atlas PL alone
./deploy/scripts/destroy.sh --mode network --auto-approve   # shared VPC + Atlas PL — only after every ec2 env in the region is gone
```

### Voyage AI (EC2 mode, optional)

Bedrock Titan embeddings are the default and work everywhere. To use Voyage AI instead:

```bash
./deploy/scripts/setup-voyage-marketplace.sh
```

It walks you through the one-time Marketplace subscription, discovers the model package ARN via `aws sagemaker list-model-packages`, and appends `VOYAGE_MODEL_PACKAGE_ARN` to your `env.sh` automatically.

### Architecture notes

Full architecture rationale, module tree, and apply-order cheat sheet live in [`deploy/terraform/.design.md`](deploy/terraform/.design.md). Key decisions:

- **Three Terraform root configs, not conditional flags** — `envs/network/` (shared per region), `envs/local/`, and `envs/ec2/` (per project) are separate root modules with separate state keys in the same S3 bucket.
- **Shared network is consumed via SSM** — `envs/network` publishes VPC ID, subnet IDs, Atlas PL VPCE ID, and the PrivateLink DNS hostname under `/${SHARED_VPC_NAME}/${AWS_REGION}/`; `envs/ec2` reads them with `data "aws_ssm_parameter"`. No `terraform_remote_state` cross-state coupling.
- **EC2 shell is SSM only** — no port 22, no SSH keys. `deploy.sh` uses `aws ssm send-command` to push `.env.live` and restart services.
- **Atlas PrivateLink lives in the shared network env** — local mode bypasses it and uses the public SRV endpoint with your laptop IP added to the Atlas access list (see `TF_VAR_my_ip` in `sample-env.sh`). The per-cluster Route 53 zone (cluster SRV host → VPCE) is created in `envs/ec2` so each project owns its DNS without colliding.

---

## What This Is

This framework gives MongoDB field, partner, and professional services teams a reusable foundation for deploying customer-specific multi-agent solutions. The core runtime is shared across all use cases. Domain-specific behavior is defined entirely in configuration files.

A user interacts through a Streamlit chat interface. Their message is forwarded by the Hono API to an **AgentCore Runtime** that hosts the orchestrator; the orchestrator picks a specialist (also an AgentCore Runtime) using **Strands Swarm**. Each agent uses its **persona** (`.agent.md`) and **domain knowledge** (`SKILL.md`), runs against **AWS Bedrock**, and calls **MongoDB tools over MCP through the AgentCore Gateway**. JWT verification is required for long-term memory and for the gateway's tool authentication.

---

## Concepts

### Agents

An **agent** is a specialist that handles a specific domain. This framework ships with an **orchestrator** plus **three specialists** (four agent definitions total):

| Agent | What it does |
|-------|-------------|
| Orchestrator | Receives every message and routes it to the right specialist |
| Order Management | Handles order lookups, status checks, tracking, and returns |
| Product Recommendation | Finds and recommends products using semantic search |
| Troubleshooting | Diagnoses problems using knowledge base and documentation |

Agents are defined in `.agent.md` files inside `config/agents/`. Adding a new agent means creating a new file — the API **rescans `config/agents/` on each request**, so edits hot-reload without restarting the server.

### Skills

A **skill** is a package of domain knowledge that an agent loads to become an expert in a specific area. Skills follow the [agentskills.io open specification](https://agentskills.io/specification) and are inspired by [how Claude Code implements agent skills](https://docs.claude.com/en/docs/agent-sdk/skills).

Each skill lives in `config/skills/` as a directory:

```
config/skills/
└── order-management/
    ├── SKILL.md            ← instructions the agent follows
    ├── http-tools.json     ← optional: HTTPS tools (e.g. Lambda Function URLs)
    ├── scripts/            ← optional executable policy (`.mjs`) + on-demand assets
    │   └── validate-return.mjs
    └── references/         ← detailed docs loaded on demand
        └── order-schema.md
```

When an agent is asked an order-related question, it activates the `order-management` skill. The skill tells the agent exactly which queries to run, how to format responses, and how to handle edge cases — without any of that logic living in code.

**Lambda / API calls without new TypeScript:** optional **`http-tools.json`** next to `SKILL.md` defines HTTP tools (URLs, methods, JSON bodies). The agent lists them as **`order-management/my_lambda_tool`**. Same **skill allowlist + activation** rules as `read_skill_resource`. Host allowlists for SSRF live in root **`config/http-tools.json`**. See [`docs/configuration-guide.md`](docs/configuration-guide.md#http-tools-lambda--api-gateway) and [`docs/api-reference.md`](docs/api-reference.md#list-http-tools-lambda--api-config).

Skills use **progressive disclosure** to stay efficient:

1. At startup, only the skill name and description are loaded (a few tokens each).
2. When an agent activates a skill, the full `SKILL.md` instructions are loaded into the system prompt.
3. During a conversation, reference files and scripts are loaded only if the agent needs them.

### How Agents and Skills Work Together

```
config/agents/order-management.agent.md
 ├── persona     →  who the agent is and how it behaves
 ├── skills      →  ['order-management']  ← which domain knowledge to load
 ├── tools       →  which data tools are available
 └── handoffs    →  which agents to delegate to and when

config/skills/order-management/SKILL.md
 ├── description →  used to decide when this skill is relevant
 └── body        →  step-by-step instructions, query patterns, edge cases
```

At runtime the agent's system prompt is assembled as: **persona + loaded skill instructions**. The agent then uses **generic data tools** (MongoDB, vector search, knowledge base retrieval), **skill scripts** (`run_skill_script`), and optional **skill HTTP tools** (Lambda/API Gateway via `http-tools.json`), guided by the skill's instructions.

### Memory

**Short-term (today):** conversation history for a `sessionId` is replayed into the Strands agent on each turn. **Default:** stored in an in-memory `Map` in the API process — lost on restart. **Optional durability:** set **`PERSIST_CHAT_SESSIONS=1`** and **`MONGODB_URI`** to persist the same history in MongoDB (`chat_sessions` by default; see [Configuration Guide](docs/configuration-guide.md#short-term-memory) and [API Reference](docs/api-reference.md#health-check)). **`GET /health`** reports `dependencies.chatSessions` as `memory`, `mongodb`, or `unavailable`. AgentCore Memory as the primary session store remains planned.

**Long-term (Phase 5 MVP — implemented):** per-user conversation history that persists across sessions, injected into the agent's system prompt on each new turn.

#### How to enable long-term memory

**Step 1 — opt the agent in** (`.agent.md` frontmatter):

```yaml
memory:
  longTerm: true
  # Optional: override the collection name (default: agent_memory)
  longTermCollection: agent_memory
```

**Step 2 — ensure the caller is authenticated.** Memory is keyed by the JWT `sub` claim (`userId`). Auth is mandatory: the API refuses to boot without `AUTH_JWKS_URI` + `AUTH_ISSUER` (see [Authentication](docs/api-reference.md#authentication)) and every protected request must carry a valid Bearer JWT.

**Step 3 — point at MongoDB** (production):

```bash
MONGODB_URI=mongodb+srv://user:pass@cluster.mongodb.net
# Project+env-derived (underscored). For PROJECT_NAME=mongodb-multiagent and
# ENVIRONMENT=dev this resolves to mongodb_multiagent_dev.
MONGODB_DB=mongodb_multiagent_dev
```

The TTL index on `agent_memory` is **auto-created on the first production write** (90-day expiry). No manual `createIndex` step is required. To use a different TTL, set `MEMORY_TTL_DAYS` before starting the API:

```bash
MEMORY_TTL_DAYS=30   # default: 90
```

**Step 4 — tune injection** (optional):

```bash
MEMORY_INJECT_TURNS=5   # how many past turns to prepend (default: 5)
```

#### What gets stored

Each completed assistant turn stores `{ userId, agentId, userMessage[0..2000], assistantReply[0..4000], ts }`. On the next request for the same `userId` + `agentId`, the API fetches the last `MEMORY_INJECT_TURNS` records and prepends:

```
## Context from previous sessions (long-term memory)
[2024-01-15] User: … / Assistant: …
---
[2024-01-16] User: … / Assistant: …
```

**Future:** PII-filtered fact extraction + vector embedding for semantic recall instead of recency-based retrieval. See [`TASKS.md`](TASKS.md) Phase 5.

---

## Defining Agents

Create a file at `config/agents/<name>.agent.md`. The frontmatter declares configuration; the markdown body is the agent's persona and core instructions.

```markdown
---
name: My Agent
description: One sentence used by the orchestrator to decide when to route here
id: my-agent
skills: ['my-skill']
tools: ['mongodb_query', 'mongodb_vector_search']
model: anthropic.claude-3-5-sonnet-20240620-v1:0
# Optional: temperature (default 0.7), maxTokens (default 4096), handoffs: []
---

# My Agent

You are a [role]. Your job is to [purpose].

## Guidelines
- Guideline one
- Guideline two
```

**Fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Display name |
| `description` | Yes | Short description used by orchestrator for routing |
| `id` | Yes | Unique slug, matches filename |
| `skills` | Yes | List of skill names to load into system prompt |
| `tools` | Yes | List of data tools available to this agent |
| `model` | No | Bedrock model ID (defaults to Claude Sonnet) |
| `maxTokens` | No | Default: 4096 |
| `temperature` | No | Default: 0.7 |
| `memory.shortTerm` | No | Enable in-session history replay (default: true) |
| `memory.longTerm` | No | Write/read cross-session memory in `agent_memory` (requires `userId` from JWT `sub`) |
| `handoffs` | No | Agents this agent can delegate to (omit when empty) |

Omit **`maxTokens`**, **`temperature`** (when 0.7 is fine), and **`handoffs`** when you do not need to override defaults.

---

## Defining Skills

Create a directory at `config/skills/<name>/` with a `SKILL.md` file. Follow the [agentskills.io specification](https://agentskills.io/specification).

See [`docs/skills-authoring-guide.md`](docs/skills-authoring-guide.md) for the full authoring guide with examples and best practices.

**Minimal example:**

```markdown
---
name: my-skill
description: >-
  What this skill does and when it should be used. Write this carefully —
  the agent uses this to decide when to activate the skill.
---

# My Skill

## What you can do

Describe the available data and tools.

## How to handle common requests

Step-by-step instructions for the most frequent tasks.

## Edge cases

How to handle ambiguous, missing, or unexpected inputs.
```

**With references, scripts, and optional HTTP tools:**

```
config/skills/my-skill/
├── SKILL.md
├── http-tools.json     ← optional: POST/GET to Lambda URLs; list as my-skill/tool_name in agent tools:
├── references/
│   └── schema.md       ← loaded by agent on demand via read_skill_resource
└── scripts/
    └── helper.mjs      ← invoked via run_skill_script (dynamic import)
```

Reference files are not loaded by default — the agent requests them during a conversation when it needs deeper context. Keep `SKILL.md` under 500 lines and move detail into `references/`.

---

## Adding a New Use Case

1. Create `config/skills/<domain>/SKILL.md` with instructions for the new domain.
2. Create `config/agents/<name>.agent.md` referencing that skill.
3. Save the files — the next API request picks up the new agent and skill (no restart required for config-only changes).

No TypeScript changes required for markdown-only flows. To call **AWS Lambda** (Function URL or API Gateway) from an agent, add **`http-tools.json`** under the skill and list **`skill-folder/tool_name`** in the agent’s `tools:` — still no API code changes. Terraform/IaC only if you provision new cloud resources.

---

## Project Layout

```
config/
  agents/       ← .agent.md files (one per specialist agent)
  skills/       ← SKILL.md directories (domain knowledge packages)
  environment.yaml

api/            ← Bun + Hono API server (SSE streaming, optional JWT/JWKS, rate limiting)
  Dockerfile    ← production image (build from **repo root**; embeds `config/`)
  src/
    lib/        ← skill loader, prompt builder, Strands agent factory, tools, jwt-verify,
    |             logger (LOG_LEVEL → JSON lines), long-term-memory (agent_memory read/write)
    routes/     ← chat, agents, skills, sessions, health, http-tools (metadata)
    middleware/ ← auth (Bearer + optional JWKS), rate-limit, request-id
    adapters/   ← resolve-model (BedrockModel), agentcore-runtime, bedrock-retrieval, mongodb-mcp-client

compose.yaml    ← `docker compose up` — API + UI (still needs AGENTCORE_ORCHESTRATOR_ARN + AWS creds)
Makefile        ← `make docker-up` / `docker-build` (optional)

ui/             ← Streamlit chat interface (Python)
  Dockerfile    ← container image (Chat + Sessions pages)
  app.py        ← main **Chat** page
  pages/        ← multipage UI (e.g. **Sessions** — list, open in chat, delete)
  lib/          ← settings, API client, sidebar, chat panel

sample-env.sh   ← committed template; copy to `env.sh` (gitignored) and fill in secrets

deploy/
  scripts/
    deploy.sh                       ← per-project EC2 POC: consumes shared VPC, provisions EC2 + Lambda + AgentCore
    deploy-network.sh               ← shared VPC + Atlas PrivateLink VPCE (run once per region; SSM-publishes IDs)
    deploy-local.sh                 ← localhost API/UI against Atlas + Bedrock KB (no EC2)
    destroy.sh                      ← teardown; `--mode local|ec2|network` required, `--with-bootstrap` optional
    setup-voyage-marketplace.sh     ← one-time Voyage AI Marketplace subscription + ARN discovery
    docker-build.sh / docker-push-ecr.sh / docker-build-push.sh   ← API + UI image helpers
  iam/
    policy.json   ← consolidated IAM policy for the deploy user (scoped, no iam:* wildcard)
    README.md     ← rationale, attach commands, privilege-escalation Deny list
  terraform/
    bootstrap/    ← one-time: shared S3 state bucket + DynamoDB lock table
    envs/
      network/    ← root module for deploy-network.sh (VPC + Atlas PrivateLink VPCE + SSM publishers)
      local/      ← root module for deploy-local.sh (Atlas + KB + Cognito + Secrets Manager)
      ec2/        ← root module for deploy.sh (consumes shared VPC via SSM; EC2/AgentCore/Lambda + per-cluster Route 53)
    modules/
      networking/          ← VPC, subnets, EIP, security groups, S3 gateway endpoint
      mongodb-atlas/       ← Atlas M10 cluster + DB user + IP allowlist
      atlas-privatelink/   ← AWS Interface VPCE + Atlas-side endpoint binding + CIDR-scoped SG (envs/network)
      atlas-privatelink-dns/ ← per-cluster Route 53 private zone + wildcard CNAME — DNS half of Atlas PrivateLink (envs/ec2)
      ec2/                 ← EC2 instance profile + user-data (SSM-only, no SSH)
      ecr/                 ← private ECR repos for API + UI images
      cognito/             ← Cognito User Pool + App Client for JWT auth
      bedrock-kb/          ← Bedrock Knowledge Base (native aws_bedrockagent_knowledge_base + data_source)
      lambda-mcp/          ← MongoDB MCP Lambda (rollback target — not the active tool path)
      agentcore-memory/    ← AgentCore Memory Store (native aws_bedrockagentcore_memory)
      agentcore-gateway/   ← AgentCore Gateway + mcp_server target → MongoDB MCP runtime (native aws_bedrockagentcore_gateway)
      agentcore-agent-runtime/ ← AgentCore Runtime (native aws_bedrockagentcore_agent_runtime; 4 chat agents + 1 MongoDB MCP runtime)
      voyage-sagemaker/    ← optional Voyage AI SageMaker endpoint (embeddings)
      cloudwatch/          ← log groups for every service (/<project>/<env>/*)
  kb-docs/        ← versioned KB source documents (.txt) uploaded to S3 on apply

.dockerignore   ← excludes ui/tests/docs from API image build context

docs/           ← authoring guides and API reference
```

### Structured logging

The API emits **JSON log lines** to stdout/stderr. Control verbosity with the **`LOG_LEVEL`** env var:

```
LOG_LEVEL=debug   # error | warn | info (default) | debug
```

Each line: `{ "level": "info", "ts": "…", "msg": "…", ...ctx }`. Errors and warnings go to stderr; info and debug go to stdout. Useful for containerized deployments where log aggregators (CloudWatch, Datadog) consume JSON streams.

### Session user-scoping

The JWT `sub` claim is attached to every `SessionRecord`. `GET /sessions` only returns the calling user's sessions; `DELETE /sessions/:id` enforces ownership; sessions belonging to other users are 404 from `GET /sessions/:id`.

### API authentication

JWKS auth is **always required**. The API refuses to start without **`AUTH_JWKS_URI`** + **`AUTH_ISSUER`** (`assertJwksAuthConfigured()` in `api/src/lib/jwt-verify.ts`). Every protected route requires `Authorization: Bearer <jwt>` from the configured Cognito (or other OIDC) pool. Optional **`AUTH_APP_CLIENT_ID`** and **`AUTH_TOKEN_USE`** match Cognito ID vs access tokens. There is no `ALLOW_UNAUTHENTICATED` / `REQUIRE_AUTH=false` bypass — local dev uses the same security posture as the deploy. Copy [`.env.example`](.env.example) and see **[Authentication](docs/api-reference.md#authentication)** in the API reference.

The Streamlit UI obtains API **`Authorization: Bearer`** tokens **only via Cognito** when **`STREAMLIT_COGNITO_*`** is set (`streamlit-cognito-auth`); there is no static UI token env var (see [`.env.example`](.env.example) and [`docs/configuration-guide.md`](docs/configuration-guide.md)).

### Docker (full stack)

From the repository root:

```bash
docker compose up --build
# or: make docker-up
```

Serves the API at **http://localhost:3000** and Streamlit at **http://localhost:8501**. The API still requires **`AGENTCORE_ORCHESTRATOR_ARN`** and AWS credentials in your shell or `.env` file; without them the API refuses to start. The API image **bakes in** [`config/`](config/) at build time, so changing agents/skills means rebuilding the API image.

See [`.env.docker.example`](.env.docker.example) for **`API_PORT`**, **`STREAMLIT_PORT`**, and optional **`MONGODB_URI`**, **AWS**, and **auth** overrides.

Full deploy commands (driven from your laptop — no CI):

- **Shared network (per region, run once):** `./deploy/scripts/deploy-network.sh --auto-approve` (VPC + subnets + Atlas PrivateLink VPCE + SSM publishers)
- **Local dev stack:** `./deploy/scripts/deploy-local.sh --auto-approve` (Atlas + Bedrock KB; API + UI on `localhost`)
- **Full EC2 POC:** `./deploy/scripts/deploy.sh --auto-approve` (consumes shared VPC via SSM, adds EC2, Lambda MCP, AgentCore Memory + Gateway, per-cluster Route 53)
- **Tear down:** `./deploy/scripts/destroy.sh --mode local --auto-approve`, `--mode ec2`, or `--mode network` (only after every per-project `--mode ec2` in the region is destroyed). Add `--with-bootstrap` to also remove the shared S3 state bucket + DynamoDB lock table.
- **Build both images:** `./deploy/scripts/docker-build.sh` (optional **`TAG=mytag`**)
- **Push to ECR:** `./deploy/scripts/docker-push-ecr.sh` (requires **`AWS_ACCOUNT_ID`**, **`AWS_REGION`**; optional **`SOURCE_TAG`**, **`ECR_PREFIX`**, **`TAG`** — see [`docs/deployment-guide.md`](docs/deployment-guide.md#step-5--build-and-push-application-images))

All four deploy/destroy scripts source `env.sh` from the repo root — see the [Deployment](#deployment-run-from-your-laptop--no-ci-pipeline) section at the top for the one-time setup (IAM policy, Atlas API key, `sample-env.sh` → `env.sh`).

---

## Documentation

| Document | What it covers |
|----------|----------------|
| [`DEV_STATUS.md`](DEV_STATUS.md) | How to run locally, env vars, what is implemented vs planned |
| [`TASKS.md`](TASKS.md) | Implementation checklist vs the action plan |
| [`memory.md`](memory.md) | **Persistent** pitfalls only (same issue >2× or critical guardrails; see file header) |
| [`AGENTS.md`](AGENTS.md) | Contributor conventions for this repo (AI + human) |
| [`docs/agent-authoring-guide.md`](docs/agent-authoring-guide.md) | How to define agents with `.agent.md` files |
| [`docs/skills-authoring-guide.md`](docs/skills-authoring-guide.md) | How to write effective `SKILL.md` files |
| [`docs/configuration-guide.md`](docs/configuration-guide.md) | Agents, models, memory, **HTTP/Lambda tools** (`http-tools.json`) |
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | Terraform (target AWS), **Docker / Compose / ECR** (implemented), ECS alignment notes |
| [`docs/demo-script.md`](docs/demo-script.md) | Step-by-step “wow” demo (local mock + Swarm) |
| [`docs/api-reference.md`](docs/api-reference.md) | API endpoints, SSE format, auth |
| [`docs/architecture.md`](docs/architecture.md) | System design with diagrams |
| [`ACTION_PLAN.md`](ACTION_PLAN.md) | Full implementation plan |

---

## Built With

- [Strands Agents SDK](https://github.com/strands-agents/sdk-typescript) — agent orchestration (runs inside the AgentCore Runtime container)
- [Hono](https://hono.dev/) — HTTP API
- [jose](https://github.com/panva/jose) — JWT verification when JWKS env vars are set
- [MongoDB Atlas](https://www.mongodb.com/atlas) — data and (when wired) vector search / long-term memory
- [AWS Bedrock](https://aws.amazon.com/bedrock/) — language models, knowledge bases
- [Bedrock AgentCore SDK](https://github.com/aws/bedrock-agentcore-sdk-typescript) — planned for cloud runtime, gateway, identity ([`TASKS.md`](TASKS.md))
- [Agent Skills specification](https://agentskills.io/specification) — skill format
