# DEV_STATUS — operational snapshot

> **Last updated:** 2026-05-01 · matches the [frozen baseline](docs/FROZEN_E2E_DESIGN.md)
> **Purpose:** one place for humans to see *how to run the stack* and *what state it's in*. Authoritative running architecture lives in [`docs/architecture.md`](docs/architecture.md). Implementation gaps vs the SoW live in [`docs/gap-analysis.md`](docs/gap-analysis.md).

---

## Quick start cheat sheet

| Goal | Command |
|---|---|
| **Source AWS + Atlas creds** | `source env.sh && aws sts get-caller-identity` |
| **Local dev — fully offline** | `export DEV_MOCK_BACKENDS=1 && cd api && bun run dev` (CHAT_MODE defaults to `live`; set `CHAT_MODE=stub` for the canned-token loop) |
| **Local dev — real Bedrock + Atlas** | `source env.sh && source .env.live && export ORCHESTRATOR_MODE=swarm && cd api && bun run dev` |
| **Streamlit UI** | `~/.venvs/multiagent-ui/bin/streamlit run ui/app.py --server.headless true` |
| **Apply shared network** (once per region; required before EC2 deploy) | `./deploy/scripts/deploy-network.sh --auto-approve` |
| **Deploy to EC2** (consumes shared network via SSM) | `./deploy/scripts/deploy.sh --auto-approve` |
| **Code-only EC2 update** | `./deploy/scripts/docker-build-push.sh ...` then SSM pull/restart |
| **Health check** | `curl -s http://$EC2_IP:3000/health \| python3 -m json.tool` |
| **Open EC2 shell (no SSH)** | `aws ssm start-session --target $EC2_INSTANCE_ID` |
| **Tear down per-project ec2 only** | `./deploy/scripts/destroy.sh --mode ec2 --auto-approve` |
| **Tear down shared network** (only when no project envs remain) | `./deploy/scripts/destroy.sh --mode network --auto-approve` |

For full deployment instructions: [`docs/deployment-guide.md`](docs/deployment-guide.md).

---

## What's deployed (EC2 production POC)

| | |
|---|---|
| AWS account | `483874864688` |
| Region | `us-east-1` |
| Branch | `feat/voyage-sagemaker-infra-v2` |
| Last commit | `d236cc0` — `fix(agentcore-deploy): stabilize 4-runtime startup and EC2 orchestration` |

| Service | Endpoint / ID |
|---|---|
| API (Hono) | `http://44.209.8.211:3000` |
| UI (Streamlit) | `http://44.209.8.211:8501` |
| EC2 instance | `i-0693ae9edd898fb2e` (t3.medium) |
| Elastic IP | `44.209.8.211` |
| Atlas cluster | `bedrock-ma-use1-dev.dcysxk.mongodb.net` (M10) |
| AgentCore Memory | `bedrock_ma_use1_memory_dev-aaTMdv52rv` |
| AgentCore Gateway | `bedrock-ma-use1-gw-dev-jslrisrr8k` (provisioned; in tool path only for runtimes listed in `GATEWAY_DEMO_RUNTIMES` — see "AgentCore Gateway opt-in" below) |
| Lambda MCP | `bedrock-ma-use1-mongodb-mcp-dev` |
| Bedrock KB | `YDF16V4CRX` |
| Cognito User Pool | `us-east-1_giTk8MWzq` |
| ECR API | `483874864688.dkr.ecr.us-east-1.amazonaws.com/bedrock-ma-use1-api` |
| ECR UI | `483874864688.dkr.ecr.us-east-1.amazonaws.com/bedrock-ma-use1-ui` |
| S3 state bucket | `bedrock-ma-use1-dev-483874864688` |

---

## Two run modes

| | **Local dev** | **EC2 production POC** |
|---|---|---|
| Where agents run | Strands SDK in-process inside the Hono API | 4 separate AgentCore Runtimes (`AGENT_ID` per runtime) |
| `ORCHESTRATOR_MODE` | `swarm` (multi-agent) or `single` | `runtime` |
| Tool execution | In-process MongoDB driver (or fixtures with `DEV_MOCK_BACKENDS=1`) | **Default:** Lambda MCP via `lambda:InvokeFunction` (`TOOL_HOSTING_MODE=lambda`).<br>**Opt-in:** AgentCore Gateway MCP authenticated with caller's Cognito JWT (`TOOL_HOSTING_MODE=gateway`, per-runtime opt-in via `GATEWAY_DEMO_RUNTIMES` in [`env.sh`](env.sh)). Mutually exclusive with lambda. |
| Long-term memory | MongoDB `agent_memory` collection (or none) | AgentCore Memory Store |
| MongoDB connection | Direct `mongodb+srv://` | PrivateLink: shared VPC Interface VPCE (envs/network) + per-cluster Route 53 zone (envs/ec2) |
| Auth | Optional (off by default) | Cognito JWT (deploy defaults to `REQUIRE_AUTH=true`) |
| Switch | `AGENTCORE_ORCHESTRATOR_ARN` unset | `AGENTCORE_ORCHESTRATOR_ARN` set |

The runtime mode flips on a single env var check in [`api/src/routes/chat.ts:88`](api/src/routes/chat.ts).

---

## What's working

- ✅ End-to-end chat flow: UI → API → AgentCore Orchestrator → Specialist → Lambda MCP → Atlas → SSE response
- ✅ All 4 AgentCore Runtimes deployed (orchestrator + 3 specialists)
- ✅ S3 direct-code artifact deployment (`NODE_22`, esbuild bundle)
- ✅ Lambda MCP for MongoDB tools (`mongodb_query`, `mongodb_vector_search`, `mongodb_aggregate`) — operation allowlist, write gate (`MONGODB_ALLOW_WRITE`, off by default), pipeline `$out`/`$merge` denylist, server-side-JS denylist (`$where`, `$function`), database-override refusal, non-empty filter on `updateOne`, and read-limit cap (`MONGODB_MAX_LIMIT`, default 200). The exact same validation lives in `lambda/mongodb-mcp/guards.mjs` and is imported by **both** the Lambda handler and `api/src/adapters/mongo-data.ts`, so the in-process and Lambda paths apply identical rules. `api/Dockerfile` copies the shared `guards.mjs` + `guards.d.mts` into the image.
- ✅ **Lambda MCP emits the same trace events as the in-process path** (`mongo.intent`, `mongo.query`, `mongo.schema`, `mongo.plan`, `mongo.result`, `mongo.diagnostic`). Events are packed into the MCP `content` envelope; the `mongodb-mcp-client.ts` wrapper inside the agent-runtime extracts and replays them into the runtime's local trace, then strips them from the LLM-visible text. The Hono API's `agentcore-runtime.ts` already splices nested events via `trace.attachEventsNested(...)`, so the Trace Viewer shows full `mongo.*` cards in the production AgentCore (demo) path. Gated by `MONGO_TRACE_DIAGNOSTIC`, `MONGO_TRACE_EXPLAIN`, `MONGO_TRACE_SCHEMA_SAMPLE` (same env vars as the in-process path).
- ✅ MongoDB Atlas M10 via PrivateLink: shared Interface VPCE in `envs/network`, per-cluster Route 53 private zone in `envs/ec2`
- ✅ AgentCore Memory Store wired (long-term memory)
- ✅ Bedrock Knowledge Base for troubleshooting RAG
- ✅ Cognito user pool + JWKS (deploy now seeds deterministic test users)
- ✅ ECR + Docker + systemd on EC2 t3.medium
- ✅ CloudWatch logs (3 groups, 30-day retention)
- ✅ Atlas seeded: 9 products, 12 orders, 7 troubleshooting docs, 10 customers
- ✅ Streamlit UI streams SSE, shows agent handoffs / tool calls / skill loads as badges
- ✅ **Tracing**: every chat turn emits `TraceEvent`s (see [api-reference.md §13](docs/api-reference.md#13-tracing-endpoints)); persisted to MongoDB `traces` + ring buffer; Streamlit Trace Viewer at `/Trace_Viewer?traceId=…`
- ✅ Deploy fully automated: `deploy.sh --auto-approve` (~20-25 min)
- ✅ Code-only update path via SSM (no full redeploy needed)
- ✅ Health probe ok (`mongodb`, `longTermMemory`, `mcpServer` all `connected`)

## What's known-yellow

- ⚠️ `agentcore` health probe reports `unreachable` — `ListSessions` requires extra IAM. Functional memory still works.
- ⚠️ AgentCore Gateway is wired but **default-off**. Runtimes opt in per-name via `GATEWAY_DEMO_RUNTIMES` in [`env.sh`](env.sh); listed runtimes flip to `TOOL_HOSTING_MODE=gateway` on the next `deploy.sh`. Empty list (default) = every runtime uses lambda. Gateway mode requires `REQUIRE_AUTH=true` + Cognito wired (the runtime forwards the caller's JWT on every MCP call); not usable in local dev.
- ⚠️ Streamlit Cognito hosted-UI works but cookie persistence + multi-region QA not done.
- ✅ Persistent short-term sessions are **on by default** when `MONGODB_URI` is set — set `PERSIST_CHAT_SESSIONS=0` (or `=false`) to opt out and keep them in-memory only.
- ✅ Chat path defaults to `CHAT_MODE=live` — set `CHAT_MODE=stub` to use the canned-token fallback (no Bedrock).

## What's not done (parked or pending)

- ✅ Voyage AI on SageMaker — **active**: voyage-3.5-lite on ml.g6.xlarge, 1024-d (matches Atlas index), used by API + all 4 AgentCore runtimes for product/troubleshoot vector search. Endpoint: `mongodb-multiagent3-voyage-3-dev`. Bedrock Titan v2 still configured as fallback.
- 🔴 AgentCore Code Interpreter (skill scripts run as `.mjs` imports)
- 🔴 Multi-tenancy: agents query by user-supplied IDs, not authenticated `customerId`
- 🔴 Vector-similarity long-term memory recall (currently recency-based, last 5 turns)
- 🔴 Security P0 fixes (auth boot guard, session enumeration scope, SSRF allowlist enforcement, Lambda log redaction)
- 🔴 Browser/Streamlit E2E tests (only API E2E exists)
- 🔴 CI/CD as primary deploy path (workflow exists but `deploy.sh` is the daily driver)

For the full delta vs SoW: [`docs/gap-analysis.md`](docs/gap-analysis.md).

---

## Common operations

### Verify the EC2 deployment is healthy

```bash
EC2_IP=$(jq -r '.ec2_instance_public_ip' deploy-manifest.json)
curl -s "http://$EC2_IP:3000/health" | python3 -m json.tool
```

Expected: all dependencies `connected`, `agentcore` may show `unreachable` (non-blocking).

### Smoke-test a chat flow

```bash
curl -s -X POST "http://$EC2_IP:3000/chat" \
  -H "Content-Type: application/json" \
  -d '{"message": "Where is my order ORD-1234?", "sessionId": "smoke-001"}'
```

Expected SSE events: `agent_info` → `token` → `handoff` → `done`.

### Tail EC2 logs without SSH

```bash
aws ssm send-command \
  --instance-ids "$EC2_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters commands='["journalctl -u multiagent-api -n 100 --no-pager"]' \
  --region us-east-1
```

Or use CloudWatch:

```bash
# Log group name is /<project>/<env>/api — substitute your PROJECT_NAME + ENVIRONMENT
aws logs tail /mongodb-multiagent/dev/api --follow --region us-east-1
```

### Rebuild + ship code change to EC2 (no Terraform)

```bash
source env.sh
./deploy/scripts/docker-build-push.sh "$ECR_API_REPO" "$ECR_UI_REPO" "$AWS_REGION"
aws ssm send-command --instance-ids "$EC2_INSTANCE_ID" --document-name AWS-RunShellScript \
  --parameters commands='["aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_REGISTRY && docker pull $ECR_API_IMAGE && systemctl restart multiagent-api"]'
```

### Restart from stale credentials

```bash
source env.sh
aws sts get-caller-identity   # verify token is valid

# If API on EC2 was started with old creds:
aws ssm send-command --instance-ids "$EC2_INSTANCE_ID" --document-name AWS-RunShellScript \
  --parameters commands='["systemctl restart multiagent-api multiagent-ui"]'
```

---

## Documentation map

| Doc | When to read |
|---|---|
| [`docs/README.md`](docs/README.md) | Entry point — pick the right doc by goal |
| [`docs/FROZEN_E2E_DESIGN.md`](docs/FROZEN_E2E_DESIGN.md) | Frozen baseline (canonical) |
| [`docs/architecture.md`](docs/architecture.md) | Layman-friendly system overview with mermaid diagrams |
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | Step-by-step deploy and update procedures |
| [`docs/configuration-guide.md`](docs/configuration-guide.md) | Every env var, every config file |
| [`docs/api-reference.md`](docs/api-reference.md) | HTTP/SSE contract for the Hono API |
| [`docs/memory-architecture.md`](docs/memory-architecture.md) | Short-term + long-term memory, both backends |
| [`docs/gap-analysis.md`](docs/gap-analysis.md) | What's shipped vs SoW vs parked |
| [`docs/estimate.md`](docs/estimate.md) | AWS cost estimate (~$200-260/mo active) |
| [`docs/agent-authoring-guide.md`](docs/agent-authoring-guide.md) | How to add a new agent |
| [`docs/skills-authoring-guide.md`](docs/skills-authoring-guide.md) | How to add a new skill |
| [`docs/demo-script.md`](docs/demo-script.md) | Local demo walkthrough |
| [`docs/diagrams/`](docs/diagrams/) | Editable draw.io files: AWS infra, request flow, memory, deploy pipeline |

---

## Project rules (from `CLAUDE.md`)

- **Models:** Claude Sonnet 4.6 for ALL agents (`us.anthropic.claude-sonnet-4-6`)
- **Embeddings:** Bedrock Titan (`amazon.titan-embed-text-v2:0`) for both modes
- **Compute:** EC2 t3.medium + Elastic IP + Docker + systemd. No ALB, ECS, NAT Gateway, auto-scaling.
- **Voyage AI:** active. voyage-3.5-lite on ml.g6.xlarge, 1024-d. Set `VOYAGE_MODEL_PACKAGE_ARN` in env.sh; deploy.sh wires `VOYAGE_SAGEMAKER_ENDPOINT` + `VOYAGE_OUTPUT_DIM=1024` into both `.env.live` (EC2 API) and AgentCore runtime env vars.
- **AgentCore Gateway in tool path:** wired as an opt-in alternative; lambda direct invoke remains the production default. Flip per-runtime via `GATEWAY_DEMO_RUNTIMES` in `env.sh` and re-run `deploy.sh` (no `terraform apply` needed).
- **This is a permanent POC** — never add production-grade complexity unless explicitly asked.

---

*Maintenance: when default env behavior, deployed components, or "how to run" changes, update this file in the same PR.*
