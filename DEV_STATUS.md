# DEV_STATUS — operational snapshot

> **Purpose:** one place for humans to see *how to run the stack* and *what state it's in*.
> **Authoritative running architecture:** [`docs/architecture.md`](docs/architecture.md). **Implementation gaps vs SoW:** [`docs/gap-analysis.md`](docs/gap-analysis.md).

---

## Quick start cheat sheet

| Goal | Command |
|---|---|
| **Source AWS + Atlas creds** | `source .env && aws sts get-caller-identity` |
| **Local dev (real Bedrock + Atlas, gateway tools)** | `source .env && source .env.live && export ORCHESTRATOR_MODE=swarm && cd api && bun run dev` (`.env.live` carries `AUTH_JWKS_URI` + `AUTH_ISSUER` — the API refuses to start without them) |
| **Streamlit UI** | `~/.venvs/multiagent-ui/bin/streamlit run ui/app.py --server.headless true` |
| **Apply shared network** (once per region) | `./deploy/scripts/deploy-network.sh --auto-approve` |
| **Deploy to EC2** (full infra + agents) | `./deploy/deploy-full-with-privatelink.sh --auto-approve` |
| **Redeploy API only** (API code/config/env) | `./deploy/deploy-api.sh` |
| **Redeploy agents only** (no infra change) | `./deploy/deploy-agents.sh --auto-approve` |
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
2. Hono asserts `AGENTCORE_ORCHESTRATOR_ARN` at boot, runs the **in-API classifier** (`api/src/lib/agent-classifier.ts`: heuristic match against orchestrator handoffs first, Bedrock Haiku fallback only when uncertain), then `invokeAgentRuntime` proxies the message **directly to the chosen specialist runtime**. Set `USE_ORCHESTRATOR_RUNTIME=1` to roll back to the legacy orchestrator-runtime hop for one release.
3. Specialist runtimes run Strands single-agent loop; the legacy orchestrator runtime still exists (Strands Swarm under `ORCHESTRATOR_MODE`) but is bypassed on the happy path. When `USE_ORCHESTRATOR_RUNTIME=1` is set, the orchestrator container classifies the message and forwards via `invokeSpecialistStream` (now itself an SSE consumer) so streaming is preserved end-to-end through the two-hop path.
4. Specialists call MongoDB tools (`mongodb_query`, `mongodb_aggregate`, `mongodb_vector_search`) over **MCP directly to the MongoDB MCP AgentCore Runtime** (`mcp-runtimes/mongodb-mcp/`, MCP server protocol, VPC network mode), IAM-authorized via `bedrock-agentcore:InvokeAgentRuntime`. The Gateway remains provisioned for non-Mongo tools, but Mongo no longer registers as a Gateway `mcp_server` target because that target type cannot point at AgentCore Runtime endpoints.
5. **End-to-end SSE streaming.** Each AgentCore Runtime invocation now opens with `Accept: text/event-stream`; the runtime container writes one of three SSE event types per frame — `event: stream` (a `ChatStreamPart` JSON), `event: trace` (a `TraceEvent` JSON), `event: done` (one final `RuntimeDonePayload`). The Hono API forwards `stream` parts to the client, throttles `model.text_delta_batch` trace forwarding (`TRACE_SSE_THROTTLE_MS`, default 100 ms) so the trace channel never contends with token frames, accumulates all `trace` events, and on `done` splices them under the parent `agentcore.invoke` wrapper via `attachEventsNested(...)`. `latency.checkpoint` trace events mark first runtime frame, first model delta/tool call, and first client token so benchmark output can separate first progress from first visible text.
6. **Boot-time pre-warm.** Both the API (`api/src/index.ts`) and the runtime container (`api/src/agent-runtime-code.ts`) fire `runStartupPrewarm()` before listening — `Promise.allSettled([getMongoDb, getMcpTools, warmAgentCache])` so the very first chat does not pay the Mongo TLS handshake, the MCP `connect`/`listTools` round-trip, or the per-agent template build on the user's clock.
7. **Per-chat reconstruction caches.** `resolve-model.ts` reads each agent's `model` / `maxTokens` / `temperature` from `.agent.md` frontmatter and caches one `BedrockModel` per `(agentId, model, maxTokens, temperature, region)`. The orchestrator and order-management agents currently use Haiku for lower routing/order-lookup latency; order-management keeps `maxTokens: 2048` as a conservative cap so status and return responses have room without the old 4096-token budget. `skill-loader.ts` caches `loadSkillInstructions` by mtime. `create-strands-agent.ts` caches `(systemPromptBase, registry, tools, model)` per agentId via `getAgentTemplate(...)` (and exposes `warmAgentCache()` for the boot-time pre-warm). Cache is bypassed for agents that opt into lazy `activate_skill` (orchestrator-style runs with `skills > 0` and `preActivateSkills=false`) so activations from one chat do not leak into the next. `deploy-agents.sh` calls `POST /internal/agents/refresh` after runtime updates so the API swaps to the latest config snapshot, refreshes specialist ARN overrides, and clears these caches without an API image rebuild.

`ORCHESTRATOR_MODE` defaults to `swarm` for the orchestrator runtime. Set it to anything else (e.g. `single`) on the orchestrator runtime container to fall back to one-shot routing. The orchestrator runtime path is only reached when `USE_ORCHESTRATOR_RUNTIME=1` is set on the API; otherwise the in-API classifier picks the specialist directly.

**Streaming + classifier env knobs:**

| Variable | Default | Purpose |
|----------|---------|---------|
| `USE_ORCHESTRATOR_RUNTIME` | unset (off) | Set to `1` to route through the orchestrator runtime instead of the in-API classifier (one-release rollback path). |
| `CLASSIFIER_BACKEND` | unset (heuristic + Haiku) | Set to `heuristic` to disable the Bedrock Haiku fallback. |
| `CLASSIFIER_MODEL_ID` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Override the Bedrock model used by the Haiku classifier. |
| `CLASSIFIER_HEURISTIC_MIN_SCORE` | `1.5` | Heuristic top-score threshold below which we fall through to Haiku. |
| `CLASSIFIER_HEURISTIC_MARGIN` | `0.75` | Required margin between top and runner-up before the heuristic accepts. |
| `TRACE_SSE_THROTTLE_MS` | `100` | Min interval between `model.text_delta_batch` trace frames forwarded to the UI (full batch still lands in the persisted trace). |
| `TRACE_PROMPT_BODY` | unset (off) | Set to `1` to include the full assembled system prompt body in trace events. By default only prompt sizes/hashes are recorded to reduce pre-token trace payload. |
| `AUTH_CONTEXT_CACHE_TTL_MS` | `90000` | TTL for the per-`(userId, hash(bearer))` auth-context LRU. Set to `0` to disable. |

Benchmark TTFB before/after with `bun run bench:ttfb` (env: `API_URL`, `BEARER_TOKEN`, `AGENT_ID`, `ITERATIONS`). The benchmark now reports `firstEventMs`, `firstProgressMs`, `firstTraceMs`, `firstToolMs`, and `firstTokenMs` so tool-planned turns can show responsiveness before final text starts streaming.

---

## What's working

- ✅ End-to-end chat flow: UI → API → AgentCore Orchestrator → Specialist → **MongoDB MCP AgentCore Runtime** → Atlas (PrivateLink) → SSE response. AgentCore Gateway remains available for non-Mongo tools.
- ✅ All **5** AgentCore Runtimes deployed (orchestrator + 3 specialists + `mongodb-mcp-runtime`)
- ✅ S3 direct-code artifact deployment (`NODE_22`, esbuild bundle) for the four agent runtimes; the MongoDB MCP runtime ships as an ARM64 Docker image from `mcp-runtimes/mongodb-mcp/` (TypeScript + `@modelcontextprotocol/sdk` + Express, stateless Streamable-HTTP MCP on `0.0.0.0:8000/mcp`).
- ✅ MongoDB MCP runtime serves three tools (`mongodb_query`, `mongodb_vector_search`, `mongodb_aggregate`) — operation allowlist, write gate (`MONGODB_ALLOW_WRITE`, off by default), pipeline `$out`/`$merge` denylist, server-side-JS denylist (`$where`, `$function`), database-override refusal, non-empty filter on `updateOne`, and read-limit cap (`MONGODB_MAX_LIMIT`, default 200). Tool implementations live in `mcp-runtimes/mongodb-mcp/src/vendor/` (canonical home after CLIENT_REVIEW Phase 7e physically deleted the legacy `lambda/mongodb-mcp/` host) and are bundled into the runtime image at Docker build time.
- ✅ `mongodb_vector_search` accepts `queryText` end-to-end. The MCP-client wrapper (`api/src/adapters/mongodb-mcp-client.ts` → `VectorSearchEmbedTool`) re-specs the tool schema for the LLM (queryText preferred; queryVector still accepted for advanced callers), embeds the text via Voyage AI (primary) or Bedrock (fallback) using `api/src/lib/embed-query.ts`, and forwards `queryVector` to the MCP runtime. The wrapper also defaults `index` from the collection name (`products` → `products-vector-index`, `troubleshooting_docs` → `troubleshooting-vector-index`) and emits a `mongo.vector_search` trace event with the embedding source, query text, vector preview, and per-doc similarity scores.
- ✅ Voyage AI runtime IAM is wired. The `agentcore-agent-runtime` Terraform module accepts a `voyage_sagemaker_endpoint_arn` input and conditionally appends a `SageMakerInvoke` statement to the inline `AgentCoreRuntimePermissions` policy on each of the four runtime roles, so `embedQueryText` reaches Voyage SageMaker as the primary provider (`embeddingSource: "voyage"`) instead of silently falling back to Bedrock Titan. Without the endpoint ARN configured, the conditional is skipped and the runtime cleanly degrades to Bedrock — same wrapper, no broken turn.
- ✅ MongoDB MCP runtime URI is PrivateLink-direct end-to-end. The `mongodb-atlas` Terraform module exposes a `privatelink_connection_string` output (multi-host non-SRV, with credentials + `tlsAllowInvalidHostnames=true`) keyed off the consumer VPCE id, and `envs/ec2/main.tf` passes it as `MONGODB_URI` to the `mongodb_mcp_runtime` AgentCore Runtime env (which runs in `VPC` network mode against the same subnets/SGs as the Atlas VPCE).
- ✅ MongoDB MCP runtime VPC cold-start path is private as well: EC2 mode provisions ECR API, ECR Docker, S3 gateway, and CloudWatch Logs VPC endpoints for the shared private subnets, or reuses existing shared endpoints when `TF_VAR_create_agentcore_runtime_vpc_endpoints=false`, so the VPC-mode AgentCore Runtime can pull its container image and emit logs without NAT.
- ✅ MongoDB MCP emits trace events (`mongo.intent`, `mongo.query`, `mongo.schema`, `mongo.plan`, `mongo.result`, `mongo.diagnostic`) in its MCP `content` envelope from the shared `tracing.mjs` module in `mcp-runtimes/mongodb-mcp/src/vendor/`; the agent runtime extracts and replays them, then strips them from the LLM-visible text. The Hono API's `agentcore-runtime.ts` splices nested events via `trace.attachEventsNested(...)`, so the Trace Viewer shows full `mongo.*` cards in production. Gated by `MONGO_TRACE_DIAGNOSTIC`, `MONGO_TRACE_EXPLAIN`, `MONGO_TRACE_SCHEMA_SAMPLE`.
- ✅ MongoDB Atlas M10 via PrivateLink: shared Interface VPCE in `envs/network`, per-cluster Route 53 private zone via [`atlas-privatelink-dns/`](deploy/terraform/modules/atlas-privatelink-dns/) in `envs/ec2`. Architectural rationale (why the VPCE is shared but the zone is per-cluster) is documented in [`docs/architecture.md`](docs/architecture.md) §7.4. **Scope:** PrivateLink covers both the **runtime** path (agent → MongoDB MCP runtime → Atlas) **and** Bedrock KB ingestion (Option A end-to-end). Set `TF_VAR_enable_kb_privatelink=true` (default in EC2 mode) to provision [`bedrock-kb-privatelink/`](deploy/terraform/modules/bedrock-kb-privatelink/) (internal NLB + VPC Endpoint Service). The `bedrock-kb` module forwards `endpointServiceName` to `mongo_db_atlas_configuration` and Bedrock-managed ingestion connects through that endpoint service — no NAT, no public Atlas SRV. Verified end-to-end: `INGESTION_JOB_STARTED → CRAWLING_COMPLETED → EMBEDDING_COMPLETED → INDEXING_COMPLETED → COMPLETE` for all 4 KB docs, then `bedrock-agent-runtime retrieve` returns the right chunks. See [CLIENT_REVIEW_EXPLAINER §P1-6](CLIENT_REVIEW_EXPLAINER.md#p1-6--bedrock-kb-bypasses-privatelink). **Diagnostic plumbing:** the `bedrock-kb` module provisions CloudWatch APPLICATION_LOGS delivery into `/aws/bedrock/knowledgebase/<KB_ID>` (`tail` from any laptop), and the ingestion null_resource hard-fails the `terraform apply` with the actual `failureReasons` instead of a silent warning — the previous "ship Option A green while every job FAILED with `error code -3`" failure mode is impossible to reproduce.
- ✅ AgentCore Memory Store wired. **Short-term backend selection is fail-closed**: `assertShortTermBackendConfigured()` (`api/src/lib/short-term-memory.ts`, called from `api/src/index.ts`) refuses to boot when `SHORT_TERM_MEMORY_BACKEND=agentcore` but `AGENTCORE_MEMORY_STORE_ID` is missing, so a deploy can no longer silently downgrade to the in-memory `Map`. Full per-turn decision tree in [`docs/memory-architecture.md`](docs/memory-architecture.md) §1. Same store also serves as the long-term memory fallback when MongoDB write fails.
- ✅ Bedrock Knowledge Base for troubleshooting RAG
- ✅ Cognito user pool + JWKS (deploy seeds deterministic test users). **JWKS auth is mandatory end-to-end** — the API refuses to boot without `AUTH_JWKS_URI` + `AUTH_ISSUER` (`assertJwksAuthConfigured()` in `api/src/lib/jwt-verify.ts`); there is no `ALLOW_UNAUTHENTICATED` / `REQUIRE_AUTH=false` bypass anywhere in the codebase, deploy scripts, compose, or UI gate.
- ✅ Session enumeration is strictly per-user. `listSessions(userId)` requires a non-empty `userId`; `getSession`, `appendUserMessage`, `appendAssistantMessage`, and `deleteSession` return a `FORBIDDEN_SESSION` sentinel (translated to 404) when the caller does not own the session, so existence is never leaked across users.
- ✅ HTTP-tools SSRF guard is registration-time strict. `assertHttpToolsFileSecure(...)` refuses to register any tool unless `config/http-tools.json` (or the per-skill file) defines `security.allowedHosts` / `security.allowedHostSuffixes`; the runtime guard returns `ssrf_blocked` if a misconfigured tool slips through. No dev-mode bypass.
- ✅ The `mongodb-mcp-runtime` AgentCore Runtime — the only MongoDB MCP host post Phase 7e — redacts PII fields (`filter`, `query`, `document`, `documents`, `update`, `queryVector`, `pipeline`, `projection`, `sort`) before any `console.log` / `console.error` via the shared `redactArgsForLog` in `mcp-runtimes/mongodb-mcp/src/vendor/handlers.mjs` — so CloudWatch never receives raw tool args. Operators can opt back in with `MCP_LOG_RAW_ARGS=true` for debugging; the deploy script never sets it.
- ✅ ECR + Docker + systemd on EC2 t3.medium
- ✅ CloudWatch logs: **4** Terraform-managed groups under `/<project>/<env>/{api,ui,mcp,agentcore}` — API/UI **30-day / 7-day** retention respectively (`api_retention_days` / `aux_retention_days` in `modules/cloudwatch`); EC2 user-data installs **amazon-cloudwatch-agent** to ship `multiagent-api` + `multiagent-ui` journald streams into the `api` and `ui` groups. AgentCore runtimes continue to use AgentCore-managed log groups under `/aws/bedrock-agentcore/...`.
- ✅ Atlas seeded: 9 products, 12 orders, 7 troubleshooting docs, 10 customers
- ✅ Deploy retry wrapper re-plans on transient Atlas API failures and Terraform "Saved plan is stale" state drift before retrying apply.
- ✅ Streamlit UI streams SSE, shows agent handoffs / tool calls / skill loads as badges. Inline **🧠 Reasoning** panel under each assistant reply surfaces the orchestrator's classification reasoning (`agentcore.classification`) and the model's extended-thinking blocks (`model.thinking_block`), and is preserved on history replay.
- ✅ Tracing: every chat turn emits `TraceEvent`s (see [api-reference.md §14](docs/api-reference.md#14-tracing-endpoints)); persisted to MongoDB `traces` + ring buffer; Streamlit Trace Viewer at `/Trace_Viewer?traceId=…`
- ✅ Deploy fully automated: `deploy-full-with-privatelink.sh --auto-approve` (~20-25 min)
- ✅ API-only redeploy: `./deploy/deploy-api.sh` (~3-5 min) — rebuilds/pushes only the API Docker image, regenerates `.env.live` from Terraform outputs (including dynamic specialist ARNs and the API PrivateLink MongoDB URI), restarts only `multiagent-api`, and runs backend smoke. Skips Terraform apply, UI, and AgentCore runtime image/artifact changes.
- ✅ Agent-only redeploy: `./deploy/deploy-agents.sh --auto-approve` (~3-5 min) — rebuilds code artifact, targeted terraform apply on `module.acr_specialists` + `module.acr_orchestrator`, re-injects dynamic env vars, verifies, calls the API config/cache refresh endpoint, then runs optional smoke. Skips Atlas/EC2/KB/Cognito/API-UI changes and does not restart `multiagent-api`.

## What's known-yellow

- ⚠️ `agentcore` health probe reports `unreachable` — `ListSessions` requires extra IAM. Functional memory still works.
- ⚠️ Streamlit Cognito hosted-UI works but cookie persistence + multi-region QA not done.
- ✅ Persistent short-term sessions are **on by default** when `MONGODB_URI` is set — set `PERSIST_CHAT_SESSIONS=0` (or `=false`) to opt out and keep them in-memory only.
- ✅ Long-term fact extraction always runs the LLM extractor (Bedrock Haiku via `MEMORY_EXTRACTION_MODEL_ID`, default `us.anthropic.claude-haiku-4-5-20251001-v1:0` — the previous default `us.anthropic.claude-3-5-haiku-20241022-v1:0` is deprecated and now silently AccessDenied on newly granted Bedrock accounts). On a Bedrock failure (throttling / AccessDenied / network) the write is skipped and `memory.long_term_skip` is emitted with `reason: "llm_extractor_failed"` — there is **no regex fallback**, because regex false-positives would silently pollute stored facts. Cap per-turn writes with `MEMORY_EXTRACTION_MAX_FACTS` (default 6). See [`docs/memory-architecture.md`](docs/memory-architecture.md).
- ✅ **Vector-backed long-term memory**: every accepted fact is embedded at write time (Voyage primary, Bedrock Titan v2 fallback) and stored in `agent_memory_facts` with an `embedding`, an `embeddingModel`, and a `factHash` dedup key — the write uses `bulkWrite` upsert on `{ userId, factHash }` so re-stating the same fact is idempotent. Every chat message is mirrored to a new `chat_messages` collection with the same embedding shape; `DELETE /sessions/:id` cascade-deletes the mirror rows. The chat route reads memory through `readLongTermMemoryContext(userId, message, { agentId })`, which runs **hybrid vector + Atlas Search BM25** across both collections, fuses with Reciprocal Rank Fusion (k=60), applies per-collection weights + exponential recency decay (`MEMORY_RECENCY_HALFLIFE_DAYS`, default 30d), and MMR-diversifies the top-K (`MEMORY_VECTOR_TOPK`, default 6) before injecting as `## Relevant prior context`. Query embedding is bounded by `MEMORY_EMBED_TIMEOUT_MS` (default 5000) and each Atlas leg by `MEMORY_SEARCH_MAX_TIME_MS` (default 8000); if either stalls, the route uses lexical/scoped fallback instead of denying known facts. Other knobs: `MEMORY_VECTOR_FETCHK`, `MEMORY_VECTOR_NUM_CANDIDATES`, `MEMORY_MMR_LAMBDA`, `MEMORY_MIN_SCORE`, `MEMORY_WEIGHT_FACTS`, `MEMORY_WEIGHT_CHAT_MESSAGES`. The two old readers (`readLongTermMemory` / `readSharedLongTermMemory`) still exist as wrappers but the route uses the unified hybrid path.
- ✅ **Hybrid retrieval also exposed to chat-invoked tools**: `mongodb_vector_search` accepts `hybrid: true`. The API-side wrapper rewrites args and routes to the Mongo MCP runtime's internal-only `mongodb_hybrid_search` handler (it never bypasses MCP for chat tools). The hybrid helper is filtered out of `tools/list` so agents see exactly the same `mongodb_*` surface as before. Atlas Search indexes for `products`, `troubleshooting_docs`, `agent_memory_facts`, and `chat_messages` are created by `db-seeding/seed-indexes.ts`.

## What's not done (parked or pending)

- ✅ Embeddings provider modes — **explicit**: `EMBEDDINGS_PROVIDER=titan` works without any Voyage ARN and uses Bedrock Titan v2 (1024-d); `EMBEDDINGS_PROVIDER=voyage` provisions SageMaker from `VOYAGE_MODEL_PACKAGE_ARN`. Supported Voyage paths are `voyage-multimodal-3` with `VOYAGE_REQUEST_FORMAT=multimodal` (SoW-aligned) and `voyage-3-5-lite` with `VOYAGE_REQUEST_FORMAT=legacy` + `VOYAGE_OUTPUT_DIM=1024`. Current semantic-search data readiness covers `products`, `troubleshooting_docs`, `agent_memory_facts`, and `chat_messages`; `orders`, `customers`, `chat_sessions`, and `traces` stay structured-only.
- 🔴 AgentCore Code Interpreter (skill scripts run as `.mjs` imports)
- 🔴 Multi-tenancy: agents query by user-supplied IDs, not authenticated `customerId`
- 🔴 Browser/Streamlit E2E tests (only API smoke E2E exists)
- 🔴 CI/CD as primary deploy path (workflow exists but `deploy-full-with-privatelink.sh` is the daily driver)

For the full delta vs SoW: [`docs/gap-analysis.md`](docs/gap-analysis.md).

---

## Common operations

### Deploying just the API

Use `deploy/deploy-api.sh` when only `api/`, API-bundled `config/`, or API runtime env wiring changed and the existing EC2/AgentCore infrastructure should stay in place.

```bash
source .env
./deploy/deploy-api.sh

# Re-sync .env.live and restart API without rebuilding/pushing an image:
./deploy/deploy-api.sh --skip-docker
```

**What it skips:** Terraform apply, UI image rebuilds, Streamlit restart, AgentCore runtime artifact rebuilds, MongoDB/Cognito seeding, network/bootstrap.

**What it still refreshes:** `.env.live` with Terraform outputs, the Atlas PrivateLink direct MongoDB URI, and one `AGENTCORE_<SPECIALIST_ID>_ARN` line for each discovered specialist so the in-API classifier can route directly to specialists.

### Deploying just agents (no infra change)

Use `deploy/deploy-agents.sh` whenever only `config/agents/*.agent.md` or `config/skills/` changed.

```bash
# 1. Edit your agent or skill file (e.g. tweak the order-management persona):
#    config/agents/order-management.agent.md

# 2. Redeploy agents only (~3-5 min; no EC2/Atlas/KB changes):
source .env
./deploy/deploy-agents.sh --auto-approve

# 3. Add a brand-new specialist agent:
#    a. Create config/agents/<new-id>.agent.md
#    b. Run deploy-agents.sh — discover_agents picks it up automatically;
#       terraform creates module.acr_specialists["<new-id>"];
#       AGENTCORE_RUNTIME_ARN_<NEW_ID> is injected into the orchestrator runtime;
#       the API generates the orchestrator handoff roster from config/agents.
./deploy/deploy-agents.sh --auto-approve

# 4. Remove a specialist:
#    a. Delete config/agents/<id>.agent.md
#    b. deploy-agents.sh detects the pending terraform destroy and requires
#       interactive confirmation (override with --allow-destroy).
./deploy/deploy-agents.sh --auto-approve
```

**What it skips:** API/UI image rebuilds, `.env.live` regeneration, EC2 service restart, MongoDB/Cognito seeding, network/bootstrap.

**API cache refresh:** after AgentCore runtime env verification, the script posts the current `config/` snapshot plus the Terraform `acr_specialist_arns` map to `POST /internal/agents/refresh`. The endpoint is protected by Cognito auth plus `AGENT_CONFIG_REFRESH_TOKEN` from `.env.live`, then clears agent/config/classifier/template/skill caches. This is what makes agent add/update/delete visible to the API without `deploy-api.sh`.

**Propagation latency:** changes are live immediately for new sessions; warm sessions pick them up within `idle_runtime_session_timeout` (default 15 min).

**Prerequisite:** `deploy-full-with-privatelink.sh` must have been run at least once (`deploy-manifest.json` + `backend.hcl` required).

### One-time state migration: `atlas-cluster-dns` → `atlas-privatelink-dns` (2026-05-15)

The Terraform module that owns the per-cluster Route 53 private zone was renamed from `atlas-cluster-dns` to `atlas-privatelink-dns` (folder + module block). **Run this once on any pre-existing `envs/ec2` state** before the next `deploy-full-with-privatelink.sh`, otherwise Terraform will plan to destroy the live Route 53 zone + wildcard CNAME and recreate them (brief Atlas resolution outage on the EC2 host).

```bash
cd deploy/terraform/envs/ec2
terraform init  # picks up the new module path

terraform state mv module.atlas_cluster_dns module.atlas_privatelink_dns

terraform plan  # should now show "No changes" for the Route 53 zone + CNAME
```

Fresh deploys are unaffected — there is no old state to migrate.

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
