# DEV_STATUS — operational snapshot

> **Purpose:** one place for humans to see *how to run the stack* and *what state it's in*.
> **Authoritative running architecture:** [`docs/architecture.md`](docs/architecture.md). **Implementation gaps vs SoW:** [`docs/gap-analysis.md`](docs/gap-analysis.md).

---

## Quick start cheat sheet

| Goal | Command |
|---|---|
| **Source AWS + Atlas creds** | `source env.sh && aws sts get-caller-identity` |
| **Local dev (real Bedrock + Atlas, gateway tools)** | `source env.sh && source .env.live && export ORCHESTRATOR_MODE=swarm && cd api && bun run dev` (`.env.live` carries `AUTH_JWKS_URI` + `AUTH_ISSUER` — the API refuses to start without them) |
| **Streamlit UI** | `~/.venvs/multiagent-ui/bin/streamlit run ui/app.py --server.headless true` |
| **Apply shared network** (once per region) | `./deploy/scripts/deploy-network.sh --auto-approve` |
| **Deploy to EC2** | `./deploy/scripts/deploy.sh --auto-approve` |
| **Health check** | `curl -s http://$EC2_IP:3000/health \| python3 -m json.tool` |
| **Open EC2 shell (no SSH)** | `aws ssm start-session --target $EC2_INSTANCE_ID` |
| **Tear down per-project ec2 only** | `./deploy/scripts/destroy.sh --mode ec2 --auto-approve` |

The API requires `AGENTCORE_ORCHESTRATOR_ARN` (or legacy `AGENTCORE_RUNTIME_ARN`) at startup. There is no in-process / mock loop — every chat turn is forwarded to a real AgentCore Runtime, which talks to MongoDB through the dedicated MongoDB MCP AgentCore Runtime.

For full deployment instructions: [`docs/deployment-guide.md`](docs/deployment-guide.md).

---

## What's deployed (EC2 production POC)

| | |
|---|---|
| AWS account | `483874864688` |
| Region | `us-east-1` |

| Service | Endpoint / ID |
|---|---|
| API (Hono) | `http://44.209.8.211:3000` |
| UI (Streamlit) | `http://44.209.8.211:8501` |
| EC2 instance | `i-0693ae9edd898fb2e` (t3.medium) |
| Elastic IP | `44.209.8.211` |
| Atlas cluster | `bedrock-ma-use1-dev.dcysxk.mongodb.net` (M10) |
| AgentCore Memory | `bedrock_ma_use1_memory_dev-aaTMdv52rv` |
| AgentCore Gateway | `bedrock-ma-use1-gw-dev-jslrisrr8k` (available for non-Mongo Gateway tools) |
| MongoDB MCP runtime (direct MCP target) | `bedrock-ma-use1-mongodb-mcp-runtime-dev` (AgentCore Runtime, MCP server protocol, VPC network mode) |
| Bedrock KB | `YDF16V4CRX` |
| Cognito User Pool | `us-east-1_giTk8MWzq` |

---

## How a chat turn flows

1. UI streams `POST /chat` → Hono API.
2. Hono asserts `AGENTCORE_ORCHESTRATOR_ARN` at boot, then `invokeAgentRuntime` proxies the message to the **orchestrator AgentCore Runtime**.
3. The orchestrator runtime runs Strands Swarm (or single-agent routing if `ORCHESTRATOR_MODE != swarm`); specialists run in their own runtime containers.
4. Specialists call MongoDB tools (`mongodb_query`, `mongodb_aggregate`, `mongodb_vector_search`) over **MCP directly to the MongoDB MCP AgentCore Runtime** (`mcp-runtimes/mongodb-mcp/`, MCP server protocol, VPC network mode), IAM-authorized via `bedrock-agentcore:InvokeAgentRuntime`. The Gateway remains provisioned for non-Mongo tools, but Mongo no longer registers as a Gateway `mcp_server` target because that target type cannot point at AgentCore Runtime endpoints.
5. The runtime streams its reply + nested trace events back; the API splices them into the SSE stream.

`ORCHESTRATOR_MODE` defaults to `swarm` for the orchestrator runtime. Set it to anything else (e.g. `single`) on the orchestrator runtime container to fall back to one-shot routing.

---

## What's working

- ✅ End-to-end chat flow: UI → API → AgentCore Orchestrator → Specialist → **MongoDB MCP AgentCore Runtime** → Atlas (PrivateLink) → SSE response. AgentCore Gateway remains available for non-Mongo tools.
- ✅ All **5** AgentCore Runtimes deployed (orchestrator + 3 specialists + `mongodb-mcp-runtime`)
- ✅ S3 direct-code artifact deployment (`NODE_22`, esbuild bundle) for the four agent runtimes; the MongoDB MCP runtime ships as an ARM64 Docker image from `mcp-runtimes/mongodb-mcp/` (TypeScript + `@modelcontextprotocol/sdk` + Express, stateless Streamable-HTTP MCP on `0.0.0.0:8000/mcp`).
- ✅ MongoDB MCP runtime serves three tools (`mongodb_query`, `mongodb_vector_search`, `mongodb_aggregate`) — operation allowlist, write gate (`MONGODB_ALLOW_WRITE`, off by default), pipeline `$out`/`$merge` denylist, server-side-JS denylist (`$where`, `$function`), database-override refusal, non-empty filter on `updateOne`, and read-limit cap (`MONGODB_MAX_LIMIT`, default 200). Tool implementations live in `mcp-runtimes/mongodb-mcp/src/vendor/` (canonical home after CLIENT_REVIEW Phase 7e physically deleted the legacy `lambda/mongodb-mcp/` host) and are bundled into the runtime image at Docker build time.
- ✅ `mongodb_vector_search` accepts `queryText` end-to-end. The MCP-client wrapper (`api/src/adapters/mongodb-mcp-client.ts` → `VectorSearchEmbedTool`) re-specs the tool schema for the LLM (queryText preferred; queryVector still accepted for advanced callers), embeds the text via Voyage AI (primary) or Bedrock (fallback) using `api/src/lib/embed-query.ts`, and forwards `queryVector` to the MCP runtime. The wrapper also defaults `index` from the collection name (`products` → `products-vector-index`, `troubleshooting_docs` → `troubleshooting-vector-index`) and emits a `mongo.vector_search` trace event with the embedding source, query text, vector preview, and per-doc similarity scores.
- ✅ Voyage AI runtime IAM is wired. The `agentcore-agent-runtime` Terraform module accepts a `voyage_sagemaker_endpoint_arn` input and conditionally appends a `SageMakerInvoke` statement to the inline `AgentCoreRuntimePermissions` policy on each of the four runtime roles, so `embedQueryText` reaches Voyage SageMaker as the primary provider (`embeddingSource: "voyage"`) instead of silently falling back to Bedrock Titan. Without the endpoint ARN configured, the conditional is skipped and the runtime cleanly degrades to Bedrock — same wrapper, no broken turn.
- ✅ MongoDB MCP runtime URI is PrivateLink-direct end-to-end. The `mongodb-atlas` Terraform module exposes a `privatelink_connection_string` output (multi-host non-SRV, with credentials + `tlsAllowInvalidHostnames=true`) keyed off the consumer VPCE id, and `envs/ec2/main.tf` passes it as `MONGODB_URI` to the `mongodb_mcp_runtime` AgentCore Runtime env (which runs in `VPC` network mode against the same subnets/SGs as the Atlas VPCE).
- ✅ MongoDB MCP runtime VPC cold-start path is private as well: EC2 mode provisions ECR API, ECR Docker, S3 gateway, and CloudWatch Logs VPC endpoints for the shared private subnets, so the VPC-mode AgentCore Runtime can pull its container image and emit logs without NAT.
- ✅ MongoDB MCP emits trace events (`mongo.intent`, `mongo.query`, `mongo.schema`, `mongo.plan`, `mongo.result`, `mongo.diagnostic`) in its MCP `content` envelope from the shared `tracing.mjs` module in `mcp-runtimes/mongodb-mcp/src/vendor/`; the agent runtime extracts and replays them, then strips them from the LLM-visible text. The Hono API's `agentcore-runtime.ts` splices nested events via `trace.attachEventsNested(...)`, so the Trace Viewer shows full `mongo.*` cards in production. Gated by `MONGO_TRACE_DIAGNOSTIC`, `MONGO_TRACE_EXPLAIN`, `MONGO_TRACE_SCHEMA_SAMPLE`.
- ✅ MongoDB Atlas M10 via PrivateLink: shared Interface VPCE in `envs/network`, per-cluster Route 53 private zone via [`atlas-cluster-dns/`](deploy/terraform/modules/atlas-cluster-dns/) in `envs/ec2`. Architectural rationale (why the VPCE is shared but the zone is per-cluster) is documented in [`docs/architecture.md`](docs/architecture.md) §7.4. **Scope:** PrivateLink covers both the **runtime** path (agent → MongoDB MCP runtime → Atlas) **and** Bedrock KB ingestion (Option A end-to-end). Set `TF_VAR_enable_kb_privatelink=true` (default in EC2 mode) to provision [`bedrock-kb-privatelink/`](deploy/terraform/modules/bedrock-kb-privatelink/) (internal NLB + VPC Endpoint Service). The `bedrock-kb` module forwards `endpointServiceName` to `mongo_db_atlas_configuration` and Bedrock-managed ingestion connects through that endpoint service — no NAT, no public Atlas SRV. Verified end-to-end: `INGESTION_JOB_STARTED → CRAWLING_COMPLETED → EMBEDDING_COMPLETED → INDEXING_COMPLETED → COMPLETE` for all 4 KB docs, then `bedrock-agent-runtime retrieve` returns the right chunks. See [CLIENT_REVIEW_EXPLAINER §P1-6](CLIENT_REVIEW_EXPLAINER.md#p1-6--bedrock-kb-bypasses-privatelink). **Diagnostic plumbing:** the `bedrock-kb` module provisions CloudWatch APPLICATION_LOGS delivery into `/aws/bedrock/knowledgebase/<KB_ID>` (`tail` from any laptop), and the ingestion null_resource hard-fails the `terraform apply` with the actual `failureReasons` instead of a silent warning — the previous "ship Option A green while every job FAILED with `error code -3`" failure mode is impossible to reproduce.
- ✅ AgentCore Memory Store wired. **Short-term backend selection is fail-closed**: `assertShortTermBackendConfigured()` (`api/src/lib/short-term-memory.ts`, called from `api/src/index.ts`) refuses to boot when `SHORT_TERM_MEMORY_BACKEND=agentcore` but `AGENTCORE_MEMORY_STORE_ID` is missing, so a deploy can no longer silently downgrade to the in-memory `Map`. Full per-turn decision tree in [`docs/memory-architecture.md`](docs/memory-architecture.md) §1. Same store also serves as the long-term memory fallback when MongoDB write fails.
- ✅ Bedrock Knowledge Base for troubleshooting RAG
- ✅ Cognito user pool + JWKS (deploy seeds deterministic test users). **JWKS auth is mandatory end-to-end** — the API refuses to boot without `AUTH_JWKS_URI` + `AUTH_ISSUER` (`assertJwksAuthConfigured()` in `api/src/lib/jwt-verify.ts`); there is no `ALLOW_UNAUTHENTICATED` / `REQUIRE_AUTH=false` bypass anywhere in the codebase, deploy scripts, compose, or UI gate.
- ✅ Session enumeration is strictly per-user. `listSessions(userId)` requires a non-empty `userId`; `getSession`, `appendUserMessage`, `appendAssistantMessage`, and `deleteSession` return a `FORBIDDEN_SESSION` sentinel (translated to 404) when the caller does not own the session, so existence is never leaked across users.
- ✅ HTTP-tools SSRF guard is registration-time strict. `assertHttpToolsFileSecure(...)` refuses to register any tool unless `config/http-tools.json` (or the per-skill file) defines `security.allowedHosts` / `security.allowedHostSuffixes`; the runtime guard returns `ssrf_blocked` if a misconfigured tool slips through. No dev-mode bypass.
- ✅ The `mongodb-mcp-runtime` AgentCore Runtime — the only MongoDB MCP host post Phase 7e — redacts PII fields (`filter`, `query`, `document`, `documents`, `update`, `queryVector`, `pipeline`, `projection`, `sort`) before any `console.log` / `console.error` via the shared `redactArgsForLog` in `mcp-runtimes/mongodb-mcp/src/vendor/handlers.mjs` — so CloudWatch never receives raw tool args. Operators can opt back in with `MCP_LOG_RAW_ARGS=true` for debugging; the deploy script never sets it.
- ✅ ECR + Docker + systemd on EC2 t3.medium
- ✅ CloudWatch logs (3 groups, 30-day retention)
- ✅ Atlas seeded: 9 products, 12 orders, 7 troubleshooting docs, 10 customers
- ✅ Streamlit UI streams SSE, shows agent handoffs / tool calls / skill loads as badges. Inline **🧠 Reasoning** panel under each assistant reply surfaces the orchestrator's classification reasoning (`agentcore.classification`) and the model's extended-thinking blocks (`model.thinking_block`), and is preserved on history replay.
- ✅ Tracing: every chat turn emits `TraceEvent`s (see [api-reference.md §13](docs/api-reference.md#13-tracing-endpoints)); persisted to MongoDB `traces` + ring buffer; Streamlit Trace Viewer at `/Trace_Viewer?traceId=…`
- ✅ Deploy fully automated: `deploy.sh --auto-approve` (~20-25 min)

## What's known-yellow

- ⚠️ `agentcore` health probe reports `unreachable` — `ListSessions` requires extra IAM. Functional memory still works.
- ⚠️ Streamlit Cognito hosted-UI works but cookie persistence + multi-region QA not done.
- ✅ Persistent short-term sessions are **on by default** when `MONGODB_URI` is set — set `PERSIST_CHAT_SESSIONS=0` (or `=false`) to opt out and keep them in-memory only.
- ✅ Long-term fact extraction always runs the LLM extractor (Bedrock Haiku via `MEMORY_EXTRACTION_MODEL_ID`, default `us.anthropic.claude-haiku-4-5-20251001-v1:0` — the previous default `us.anthropic.claude-3-5-haiku-20241022-v1:0` is deprecated and now silently AccessDenied on newly granted Bedrock accounts). On a Bedrock failure (throttling / AccessDenied / network) the write is skipped and `memory.long_term_skip` is emitted with `reason: "llm_extractor_failed"` — there is **no regex fallback**, because regex false-positives would silently pollute stored facts. Cap per-turn writes with `MEMORY_EXTRACTION_MAX_FACTS` (default 6). See [`docs/memory-architecture.md`](docs/memory-architecture.md).

## What's not done (parked or pending)

- ✅ Voyage AI on SageMaker — **active**: defaults to **voyage-multimodal-3** (the SoW model) on `ml.g6.xlarge`, 1024-d (matches the Atlas index — no rebuild needed when migrating from voyage-3.5-lite). Used by the API + all 4 AgentCore runtimes for product/troubleshoot vector search. The request envelope is selected via `VOYAGE_REQUEST_FORMAT` (`multimodal` default; `legacy` for the older voyage-3.5-lite listing). Marketplace ARN is discovered by `deploy/scripts/setup-voyage-marketplace.sh --model voyage-multimodal-3` (defaults to multimodal-3) and never hard-coded in source.
- 🔴 AgentCore Code Interpreter (skill scripts run as `.mjs` imports)
- 🔴 Multi-tenancy: agents query by user-supplied IDs, not authenticated `customerId`
- 🔴 Vector-similarity long-term memory recall (currently recency-based, last 5 turns)
- 🔴 Browser/Streamlit E2E tests (only API smoke E2E exists)
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

---

## Documentation map

| Doc | When to read |
|---|---|
| [`docs/README.md`](docs/README.md) | Entry point — pick the right doc by goal |
| [`docs/architecture.md`](docs/architecture.md) | Layman-friendly system overview with mermaid diagrams |
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | Step-by-step deploy and update procedures |
| [`docs/configuration-guide.md`](docs/configuration-guide.md) | Every env var, every config file |
| [`docs/api-reference.md`](docs/api-reference.md) | HTTP/SSE contract for the Hono API |
| [`docs/memory-architecture.md`](docs/memory-architecture.md) | Short-term + long-term memory |
| [`docs/gap-analysis.md`](docs/gap-analysis.md) | What's shipped vs SoW vs parked |
| [`docs/agent-authoring-guide.md`](docs/agent-authoring-guide.md) | How to add a new agent |
| [`docs/skills-authoring-guide.md`](docs/skills-authoring-guide.md) | How to add a new skill |
| [`docs/demo-script.md`](docs/demo-script.md) | Local demo walkthrough |

---

*Maintenance: when default env behavior, deployed components, or "how to run" changes, update this file in the same PR.*
