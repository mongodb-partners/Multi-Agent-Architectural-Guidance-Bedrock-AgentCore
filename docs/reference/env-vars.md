# Environment Variables — Reference

Every environment variable consumed by the stack, grouped by phase.

- **Deploy-time** variables are read by shell scripts under [`deploy/`](../../deploy/) at apply time. They live in your `.env` (see [`.env.sample`](../../.env.sample)) and are usually exported as `TF_VAR_*` so Terraform picks them up.
- **Runtime** variables are read by the Hono API ([`api/src/`](../../api/src/)), the AgentCore agent runtimes ([`api/src/agent-runtime-code.ts`](../../api/src/agent-runtime-code.ts)), and the MongoDB MCP runtime ([`mcp-runtimes/mongodb-mcp/`](../../mcp-runtimes/mongodb-mcp/)). They are written into `.env.live` (on EC2 at `/opt/multiagent/.env.live`) by `deploy-project.sh` / `deploy-api.sh`.

> **NEVER hand-edit `/opt/multiagent/.env.live` on EC2 — the next deploy overwrites it.** Change `.env`, then re-run the matching deploy script.

Conventions:

- `Default` column shows the literal value the code falls back to when the variable is unset. `—` means the value has no default (must be set explicitly).
- `Required when` column states the boot-time guard or feature gate that forces the variable to be set.
- File references point at the canonical reader of the variable (the place to grep when something looks wrong).

---

## 1. AWS authentication & identity

| Variable | Default | Effect | Required when | Reader |
|---|---|---|---|---|
| `AUTH_MODE` | `iam` | `iam` (long-lived IAM user keys) or `sts` (assumed role / SSO / OIDC) | All deploys | [`deploy/scripts/_aws-auth.sh`](../../deploy/scripts/_aws-auth.sh) |
| `AWS_ACCESS_KEY_ID` | — | Static access key | `AUTH_MODE=iam` or `sts` (with raw env vars) | `_aws-auth.sh` |
| `AWS_SECRET_ACCESS_KEY` | — | Static secret key | `AUTH_MODE=iam` or `sts` (with raw env vars) | `_aws-auth.sh` |
| `AWS_SESSION_TOKEN` | — | STS session token | `AUTH_MODE=sts` with raw env vars | `_aws-auth.sh` |
| `AWS_PROFILE` | — | Named AWS CLI profile (SSO / assume-role) | `AUTH_MODE=sts` with profile | `_aws-auth.sh` |
| `AWS_REGION` | — (read by code as `?? "us-east-1"`) | Canonical region for deploy scripts | Always | All deploy scripts + `api/src/*` |
| `AWS_DEFAULT_REGION` | — | AWS CLI/SDK region; must match `AWS_REGION` | Always | AWS CLI/SDKs |

After `validate_aws_auth` succeeds the script exports `AWS_AUTH_MODE`, `AWS_AUTH_CALLER_ARN`, `AWS_AUTH_ACCOUNT_ID` for downstream consumers.

---

## 2. Project identity & shared resources

| Variable | Default | Effect | Required when | Reader |
|---|---|---|---|---|
| `ENVIRONMENT` | `dev` | Per-deployment environment slug; goes into resource names + state keys | Always | All deploy scripts |
| `PROJECT_NAME` | — | Per-project resource prefix (e.g. `mongodb-multiagent3`) | Always | All deploy scripts |
| `SHARED_VPC_NAME` | — | SSM prefix + shared-network state-key identifier — multiple `envs/ec2` deploys in the same region read SSM under `/<SHARED_VPC_NAME>/<region>/` | Always | [`deploy/scripts/deploy-network.sh`](../../deploy/scripts/deploy-network.sh), [`envs/ec2/main.tf`](../../deploy/terraform/envs/ec2/main.tf) |
| `SHARED_RESOURCE_PREFIX` | `multiagent` | Drives shared CloudWatch log-group names (`/<prefix>/<env>/{api,ui,mcp,agentcore,otel}`), dashboard names (`<prefix>-{fleet,mongo,cost,atlas}-<env>`), alarms, metric filters, query definitions | Always (cooperative across projects sharing one shared stack) | [`envs/shared/main.tf`](../../deploy/terraform/envs/shared/main.tf) |
| `TF_VAR_shared_resource_prefix` | mirrors `SHARED_RESOURCE_PREFIX` | Same value, passed to Terraform | Always | Terraform |

---

## 3. Network connectivity mode

The stack supports two **mutually exclusive per account** connectivity modes for MongoDB Atlas — switching modes requires destroy + redeploy.

| Variable | Default | Effect | Required when | Reader |
|---|---|---|---|---|
| `NETWORK_MODE` | `privatelink` | `privatelink` (default, partner-validated) or `peering` (alternative, with experimental KB ingestion) | Always | [`deploy/scripts/deploy-network.sh`](../../deploy/scripts/deploy-network.sh), [`envs/network/main.tf`](../../deploy/terraform/envs/network/main.tf), [`envs/ec2/main.tf`](../../deploy/terraform/envs/ec2/main.tf) |
| `ATLAS_PEERING_CIDR` | `192.168.248.0/21` | Atlas-side CIDR for peering mode; must not overlap `VPC_CIDR` | `NETWORK_MODE=peering` | `deploy-network.sh`, `envs/network/main.tf` |
| `VPC_CIDR` | `10.0.0.0/16` | AWS-side VPC CIDR | Always (peering mode validates non-overlap) | `deploy-network.sh`, `envs/network/main.tf` |
| `TF_VAR_enable_kb_privatelink` | `true` | KB ingestion through PL NLB + Atlas VPCE — partner-validated, SoW-aligned | Consulted only when `NETWORK_MODE=privatelink` | `envs/ec2/main.tf` |
| `TF_VAR_enable_kb_peering` | `true` | KB ingestion through peering NLB whose targets are Atlas private peering IPs | Consulted only when `NETWORK_MODE=peering`. **EXPERIMENTAL — TLS not partner-validated; see [`modules/bedrock-kb-peering/README.md`](../../deploy/terraform/modules/bedrock-kb-peering/README.md)** | `envs/ec2/main.tf` |

> **Public Atlas SRV for KB is NOT a default and NOT recommended.** It is reached only by explicitly setting the matching flag to `=false`. Doing so is a deliberate privacy regression (KB ingestion leaves the private fabric, though TLS + Atlas auth still apply). The one place this opt-out is documented as a risk-managed alternative is the `bedrock-kb-peering` README — for environments that cannot accept the experimental TLS path, `TF_VAR_enable_kb_peering=false` keeps runtime traffic on peering while degrading KB to public SRV.

---

## 4. MongoDB Atlas (deploy + runtime)

| Variable | Default | Effect | Required when | Reader |
|---|---|---|---|---|
| `MONGODB_ATLAS_PUBLIC_KEY` | — | Atlas API key (Atlas Terraform provider) | All deploys touching Atlas | Atlas provider |
| `MONGODB_ATLAS_PRIVATE_KEY` | — | Atlas API key secret | All deploys touching Atlas | Atlas provider |
| `TF_VAR_mongodb_atlas_org_id` | — | Atlas org | All deploys touching Atlas | Atlas provider |
| `TF_VAR_mongodb_atlas_project_id` | — | Atlas project | All deploys touching Atlas | Atlas provider |
| `TF_VAR_atlas_project_id` | mirrors `TF_VAR_mongodb_atlas_project_id` | Module-side alias | Same | [`modules/mongodb-atlas/`](../../deploy/terraform/modules/mongodb-atlas/) |
| `ATLAS_DB_USER` | `${PROJECT_NAME//-/_}_${ENVIRONMENT}_user` (derived) | Atlas DB user | Always | `deploy-project.sh`, seeding scripts |
| `ATLAS_DB_NAME` | `${PROJECT_NAME//-/_}_${ENVIRONMENT}` (derived) | Atlas DB name (Mongo identifiers can't contain `-`) | Always | `deploy-project.sh`, seeding scripts |
| `TF_VAR_atlas_db_password` | — | DB user password (canonical) | Always | `envs/{ec2,local}/main.tf` |
| `TF_VAR_mongodb_password` | mirrors `TF_VAR_atlas_db_password` | Legacy alias | Same | Legacy modules |
| `TF_VAR_my_ip` | `$(curl -s https://checkip.amazonaws.com)/32` | Developer IP added to Atlas access list (laptop access via public SRV) | Local mode / Atlas access debugging | `envs/local/main.tf`, `envs/ec2/main.tf` |
| `MONGODB_URI` | — | Atlas connection URI used by the API + MCP runtime. **Set in `.env.live`** by `deploy-project.sh` / `deploy-api.sh`; never hand-edited. Mode-aware: PL multi-host with `tlsAllowInvalidHostnames=true` in privatelink mode; `connectionStrings.privateSrv` (or multi-host non-SRV fallback) in peering mode | API short-term + LTM + chat-message mirror; MCP runtime | [`api/src/lib/mongo-client.ts`](../../api/src/lib/mongo-client.ts), [`mcp-runtimes/mongodb-mcp/src/`](../../mcp-runtimes/mongodb-mcp/src/) |
| `MONGODB_URI_PUBLIC` | — | Public SRV form of `MONGODB_URI`, written to `.env.live` for off-VPC tooling. Used by `e2e-smoke/memory-recall-diagnostic.py` so harnesses can write to `chat_messages` from a laptop | Memory diagnostic harness | `e2e-smoke/memory-recall-diagnostic.py` |
| `MONGODB_DB` | `bedrock_agents` | Database name override | Always (set in `.env.live`) | `api/src/lib/mongo-client.ts` |
| `MONGODB_MCP_RUNTIME_ARN` | — | ARN of the dedicated MongoDB MCP AgentCore Runtime | API runtime; required for chat to work | [`api/src/adapters/mongodb-mcp-client.ts`](../../api/src/adapters/mongodb-mcp-client.ts) |
| `MONGODB_MCP_RUNTIME_ENDPOINT` | — | Optional HTTP endpoint override for the MCP runtime | Bypass IAM-authorized AgentCore invoke | `mongodb-mcp-client.ts` |
| `MONGODB_MCP_RUNTIME_SESSION_ID` | derived | Stable per-process MCP session ID | API runtime | `mongodb-mcp-client.ts` |
| `MONGODB_ALLOW_WRITE` | `false` | MCP write gate. When false, the MCP runtime rejects `updateOne`/`insertOne`/`replaceOne`/`deleteOne` | Set to `true` for explicit write workloads | MCP runtime |
| `MONGODB_MAX_LIMIT` | `200` | Cap on `mongodb_query` result size | Always | MCP runtime |
| `MONGODB_PUBLIC_COLLECTIONS` | — (all collections allowed) | Comma-separated allow-list of collection names the MCP runtime is permitted to read | Tenant isolation | `api/src/adapters/mongodb-mcp-client.ts` |
| `MCP_LOG_RAW_ARGS` | `false` | Disable PII redaction of MCP tool args in logs | Debug only — leave OFF in prod | MCP runtime |

---

## 5. AgentCore runtimes

| Variable | Default | Effect | Required when | Reader |
|---|---|---|---|---|
| `AGENTCORE_ORCHESTRATOR_ARN` | — | ARN of the orchestrator AgentCore Runtime the API forwards chat turns to. `assertAgentcoreOrchestratorArn()` refuses to boot without it | API boot | [`api/src/adapters/agentcore-runtime.ts`](../../api/src/adapters/agentcore-runtime.ts), [`api/src/index.ts`](../../api/src/index.ts) |
| `AGENTCORE_RUNTIME_ARN` | — | Legacy alias for `AGENTCORE_ORCHESTRATOR_ARN` | Back-compat | `agentcore-runtime.ts` |
| `AGENTCORE_RUNTIME_ARN_<AGENT_ID>` | — | ARN per specialist (uppercase + underscores). Read by the orchestrator runtime when it streams to a specialist | Set in `.env.live` per discovered specialist | [`api/src/agent-runtime-code.ts`](../../api/src/agent-runtime-code.ts) |
| `AGENTCORE_<AGENT_ID>_ARN` | — | Alternative naming for the same; also injected by `deploy-api.sh` | Same | `agent-runtime-code.ts` |
| `AGENTCORE_GATEWAY_URL` | — | AgentCore Gateway MCP endpoint (used for non-Mongo Gateway tools) | When non-Mongo gateway tools are wired | `mongodb-mcp-client.ts`, gateway helpers |
| `MCP_SERVER_URL` | — | Override the Gateway URL for local MCP testing | Local dev | `mongodb-mcp-client.ts` |
| `AGENTCORE_MEMORY_STORE_ID` | — | AgentCore Memory Store ID (short-term backend; LTM fallback) | `SHORT_TERM_MEMORY_BACKEND=agentcore` | [`api/src/lib/short-term-memory.ts`](../../api/src/lib/short-term-memory.ts) |
| `SHORT_TERM_MEMORY_BACKEND` | unset (in-memory `Map`) | `agentcore` → use AgentCore Memory Store. `assertShortTermBackendConfigured()` refuses to boot if set without `AGENTCORE_MEMORY_STORE_ID` | API boot | `short-term-memory.ts`, `index.ts` |
| `USE_ORCHESTRATOR_RUNTIME` | unset (off) | `1` → route every turn through the orchestrator runtime instead of the in-API classifier (one-release rollback path) | Rollback only | [`api/src/routes/chat.ts`](../../api/src/routes/chat.ts) |
| `ORCHESTRATOR_MODE` | `swarm` | `swarm` (Strands Swarm) or `single` — read by the orchestrator runtime container | Orchestrator runtime container | [`api/src/lib/swarm-chat-stream.ts`](../../api/src/lib/swarm-chat-stream.ts) |
| `SWARM_MAX_STEPS` | `8` (capped at 12) | Max Strands Swarm loop iterations | Performance tuning | `swarm-chat-stream.ts` |
| `AGENT_ID` | `orchestrator` | Per-runtime identity used by the AgentCore-deployed bundle | AgentCore runtime container | `agent-runtime-code.ts` |
| `AGENT_CONFIG_REFRESH_TOKEN` | — | Bearer token validating the `POST /internal/agents/refresh` endpoint used by `deploy-agents.sh` | Agent cache refresh path | [`api/src/routes/agent-config-refresh.ts`](../../api/src/routes/agent-config-refresh.ts) |
| `CONFIG_ROOT` | repo `config/` | Override the path scanned for agents/skills | Tests / alternate config | [`api/src/lib/paths.ts`](../../api/src/lib/paths.ts) |

---

## 6. In-API classifier

The default chat path classifies the user message in the API (`api/src/lib/agent-classifier.ts`) and invokes the matching specialist runtime directly. Set `USE_ORCHESTRATOR_RUNTIME=1` to fall back to the legacy two-hop path through the orchestrator runtime.

| Variable | Default | Effect | Reader |
|---|---|---|---|
| `CLASSIFIER_BACKEND` | unset (heuristic + Haiku fallback) | `heuristic` disables the Bedrock Haiku fallback (heuristic-only) | `agent-classifier.ts` |
| `CLASSIFIER_MODEL_ID` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Override the Bedrock model used by the Haiku fallback | `agent-classifier.ts` |
| `CLASSIFIER_HEURISTIC_MIN_SCORE` | `1.5` | Top-score threshold below which we fall through to Haiku | `agent-classifier.ts` |
| `CLASSIFIER_HEURISTIC_MARGIN` | `0.75` | Required margin between top and runner-up before the heuristic accepts | `agent-classifier.ts` |

---

## 7. JWT authentication (mandatory)

| Variable | Default | Effect | Required when | Reader |
|---|---|---|---|---|
| `AUTH_JWKS_URI` | — | OIDC JWKS endpoint used to verify Bearer JWTs | API boot. `assertJwksAuthConfigured()` refuses to start without it. **No bypass.** | [`api/src/lib/jwt-verify.ts`](../../api/src/lib/jwt-verify.ts), [`api/src/index.ts`](../../api/src/index.ts) |
| `AUTH_ISSUER` | — | Token issuer URL (e.g. Cognito pool URL) | API boot. Same | `jwt-verify.ts` |
| `AUTH_APP_CLIENT_ID` | — | Cognito app client ID; checked against the JWT `aud` / `client_id` claim | Cognito deployments | `jwt-verify.ts` |
| `AUTH_TOKEN_USE` | unset (accept either) | `access` or `id` — match Cognito ID vs access tokens | Tightening | `jwt-verify.ts` |
| `AUTH_CONTEXT_CACHE_TTL_MS` | `90000` (90 s) | TTL for the per-`(userId, hash(bearer))` auth-context LRU cache. `0` disables | Performance tuning | [`api/src/lib/auth-user-context.ts`](../../api/src/lib/auth-user-context.ts) |

There is no `REQUIRE_AUTH=false` / `ALLOW_UNAUTHENTICATED` bypass.

---

## 8. Embedding provider (must be explicit)

| Variable | Default | Effect | Required when | Reader |
|---|---|---|---|---|
| `EMBEDDINGS_PROVIDER` | — | `voyage` (SoW) or `titan` (explicit deviation). `assertEmbeddingsProvider()` rejects unset / unrecognized values | API boot | [`api/src/lib/assert-embeddings-provider.ts`](../../api/src/lib/assert-embeddings-provider.ts), [`api/src/lib/embed-query.ts`](../../api/src/lib/embed-query.ts) |
| `VOYAGE_MODEL_PACKAGE_ARN` | — | Marketplace ARN for the Voyage model. Pinned to `voyage-multimodal-3` by the deploy validator | `EMBEDDINGS_PROVIDER=voyage` | `deploy-project.sh`, [`modules/voyage-sagemaker/`](../../deploy/terraform/modules/voyage-sagemaker/) |
| `VOYAGE_MARKETPLACE_MODEL` | `voyage-multimodal-3` | SoW model pin; override only with written deviation | Default-on | `setup-voyage-marketplace.sh` |
| `VOYAGE_INSTANCE_TYPE` | `ml.g6.xlarge` | SageMaker real-time endpoint instance | Default-on for SoW | `modules/voyage-sagemaker` |
| `VOYAGE_REQUEST_FORMAT` | `multimodal` | `multimodal` (voyage-multimodal-3) or `legacy` (voyage-3.5-lite / voyage-3) | Per-model contract | [`api/src/adapters/voyage-embedding.ts`](../../api/src/adapters/voyage-embedding.ts) |
| `VOYAGE_OUTPUT_DIM` | `1024` | Voyage output dimension; must match Atlas vector index | Legacy format only | `voyage-embedding.ts` |
| `VOYAGE_SAGEMAKER_ENDPOINT` | — | SageMaker endpoint name written to `.env.live` by `deploy-project.sh` | `EMBEDDINGS_PROVIDER=voyage` | `voyage-embedding.ts`, `embed-query.ts` |
| `TF_VAR_voyage_endpoint_name_suffix` | `voyage-multimodal-3` | Naming fragment | Voyage path | `modules/voyage-sagemaker` |
| `EMBEDDING_MODEL_ID` | — | Bedrock embedding model id (Titan v2 = `amazon.titan-embed-text-v2:0`) | `EMBEDDINGS_PROVIDER=titan` | `assert-embeddings-provider.ts`, `embed-query.ts` |

---

## 9. Long-term memory

Hybrid (vector + BM25) retrieval over `agent_memory_facts` (LLM-curated) and `chat_messages` (mirror of every turn). All retrieval knobs are read per-call so tests can override at runtime.

| Variable | Default | Effect | Reader |
|---|---|---|---|
| `MEMORY_VECTOR_TOPK` | `14` | Top-K hits after RRF + MMR (raised from `6` → `10` → `14` after harness regression) | [`api/src/lib/long-term-memory.ts`](../../api/src/lib/long-term-memory.ts) |
| `MEMORY_VECTOR_FETCHK` | `24` | Per-leg over-fetch before fusion | `long-term-memory.ts` |
| `MEMORY_VECTOR_NUM_CANDIDATES` | `200` | Atlas `$vectorSearch.numCandidates` width | `long-term-memory.ts` |
| `MEMORY_RECENCY_HALFLIFE_DAYS` | `30` | Exponential recency decay half-life; `0` disables | `long-term-memory.ts` |
| `MEMORY_MMR_LAMBDA` | `0.7` | 1 = pure relevance, 0 = pure diversity | `long-term-memory.ts` |
| `MEMORY_MIN_SCORE` | `0` | Drop hits with fused score below this | `long-term-memory.ts` |
| `MEMORY_WEIGHT_FACTS` | `1.5` | Multiplier on `agent_memory_facts` RRF score | `long-term-memory.ts` |
| `MEMORY_WEIGHT_CHAT_MESSAGES` | `1.2` | Multiplier on `chat_messages` RRF score (raised from `1.0` so chat hits aren't crowded out by facts) | `long-term-memory.ts` |
| `MEMORY_INCLUDE_ASSISTANT_MESSAGES` | `true` | Include assistant turns in the chat-message mirror retrieval leg | `long-term-memory.ts` |
| `MEMORY_SEARCH_MAX_TIME_MS` | `8000` | Per-leg Atlas vector / BM25 timeout | `long-term-memory.ts` |
| `MEMORY_EMBED_TIMEOUT_MS` | `5000` | Query-embedding timeout before lexical fallback | `long-term-memory.ts` |
| `MEMORY_INJECT_TURNS` | `5` | Past turns to inject in legacy reader fallback path | `long-term-memory.ts` |
| `MEMORY_TTL_DAYS` | `90` (production deploy sets `30`) | TTL on `agent_memory_facts` + `chat_messages` | `long-term-memory.ts` |
| `MEMORY_EXTRACTION_MODEL_ID` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Bedrock model for LLM fact extraction | [`api/src/lib/llm-fact-extractor.ts`](../../api/src/lib/llm-fact-extractor.ts) |
| `MEMORY_EXTRACTION_MAX_FACTS` | `6` | Cap on facts extracted per turn | `llm-fact-extractor.ts` |
| `CHAT_MESSAGES_COLLECTION` | `chat_messages` | Override the vector-searchable chat-message mirror collection | [`api/src/lib/chat-messages-collection.ts`](../../api/src/lib/chat-messages-collection.ts) |
| `CHAT_SESSIONS_COLLECTION` | `chat_sessions` | Override the persistent session collection | [`api/src/lib/chat-sessions-collection.ts`](../../api/src/lib/chat-sessions-collection.ts) |
| `TRACES_COLLECTION` | `traces` | Override the trace persistence collection | [`api/src/lib/trace-store.ts`](../../api/src/lib/trace-store.ts) |
| `PERSIST_CHAT_SESSIONS` | `true` (when `MONGODB_URI` is set) | `0` / `false` opts out and keeps sessions in-memory only | `chat-sessions-collection.ts` |

LTM skip reasons emitted as `memory.long_term_skip` events: `no_user_id`, `mongodb_unavailable`, `llm_extractor_failed`.

---

## 10. Tracing

Per-turn trace events live in MongoDB `traces` (TTL-controlled) and in a ring buffer for fast `GET /trace`. The Streamlit Trace Viewer renders `?include=core|dev|full` projections.

| Variable | Default | Effect | Reader |
|---|---|---|---|
| `TRACING_ENABLED` | `true` | Master switch for the per-turn collector | [`api/src/lib/trace-collector.ts`](../../api/src/lib/trace-collector.ts) |
| `TRACE_MAX_EVENT_BYTES` | `16384` (16 KB) | Per-event byte cap; oversize fields are stripped/redacted | `trace-collector.ts` |
| `TRACE_MAX_TURN_BYTES` | `2097152` (2 MB) | Per-turn byte cap; oversize low-priority events are dropped with `dev.byte_cap_hit` | `trace-collector.ts` |
| `TRACE_PENDING_TEXT_BYTES` | `4096` | FIFO window of pending assistant text used for handoff-reasoning capture | `trace-collector.ts` |
| `TRACE_PROMPT_BODY` | `0` (off) | `1` includes the full assembled system prompt body in trace events (audit-reviewed only) | `trace-collector.ts`, `run-chat-stream.ts` |
| `MEMORY_TRACE_VALUES` | `1` (on) | `0` replaces every fact/queryText/factCandidate/factsExtracted string with `<redacted>` in stored traces — toggle via `.env` then re-deploy API + agents | `trace-collector.ts`, `long-term-memory.ts` |
| `TRACE_REDACT` | `0` (off) | `1` runs a blanket `redactDeep` pass over every payload (independent of `MEMORY_TRACE_VALUES`) | `trace-collector.ts` |
| `TRACE_SSE_THROTTLE_MS` | `100` | Min interval between `model.text_delta_batch` trace frames forwarded to the UI (full batch still lands in the persisted trace) | `chat.ts` |

---

## 11. OpenTelemetry

| Variable | Default | Effect | Reader |
|---|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | — | When set, installs `NodeTracerProvider` + `BatchSpanProcessor` + `OTLPTraceExporter`. EC2 default: `http://127.0.0.1:4318` (ADOT sidecar) | [`api/src/lib/otel.ts`](../../api/src/lib/otel.ts) |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | derived from `…_OTLP_ENDPOINT` | Explicit traces-only endpoint override | `otel.ts` |
| `OTEL_SERVICE_NAME` | set by `initOtel({ serviceName })` | Service tag on every span | `otel.ts` |
| `OTEL_EXPORTER_OTLP_HEADERS` | — | OTLP exporter headers | OTel SDK |
| `OTEL_EXPORTER_OTLP_TIMEOUT` | OTel default | OTLP exporter timeout | OTel SDK |
| `OTEL_TRACES_SAMPLER` / `OTEL_TRACES_SAMPLER_ARG` | OTel default | Span sampling | OTel SDK |
| `GIT_SHA` | `dev` | Becomes `service.version` resource attribute + `release` field in trace | `otel.ts`, `chat.ts` |
| `DEPLOY_TS` | — | Deploy timestamp; surfaces in trace `release` | `chat.ts` |
| `DEPLOY_ENV` | falls back to `NODE_ENV` | Trace `release.env` | `chat.ts` |

---

## 12. Logging + metrics

| Variable | Default | Effect | Reader |
|---|---|---|---|
| `LOG_LEVEL` | `info` | `error` \| `warn` \| `info` \| `debug` | [`api/src/lib/logger.ts`](../../api/src/lib/logger.ts) |
| `LOG_LEVEL_API` | falls back to `LOG_LEVEL` | API-specific override | `logger.ts` |
| `LOG_LEVEL_AGENT_RUNTIME` | falls back to `LOG_LEVEL` | Agent-runtime-specific override | `logger.ts` |
| `LOG_LEVEL_MCP` | falls back to `LOG_LEVEL` | MCP runtime override | `logger.ts` |
| `STRANDS_LOG_REDIRECT` | unset (off) | `1` redirects Strands SDK `console.*` output into the structured logger | [`api/src/lib/strands-console-redirect.ts`](../../api/src/lib/strands-console-redirect.ts) |
| `METRICS_EMITTER_ENABLED` | `true` | When false the API skips EMF stdout writes (Phase 3 dashboards go empty). Used in CI | [`api/src/lib/cw-metrics.ts`](../../api/src/lib/cw-metrics.ts) |

---

## 13. Bedrock Knowledge Base + embeddings

| Variable | Default | Effect | Reader |
|---|---|---|---|
| `BEDROCK_KB_ID` | — | Default KB id used by the `bedrock_kb_retrieve` tool when callers omit it | [`api/src/lib/base-tools.ts`](../../api/src/lib/base-tools.ts) |
| `SKILL_RESOURCE_MAX_BYTES` | `500000` (500 KB) | Cap on bytes returned by `read_skill_resource` | [`api/src/lib/skill-loader.ts`](../../api/src/lib/skill-loader.ts) |

---

## 14. HTTP tools (skill-scoped + global)

| Variable | Default | Effect | Reader |
|---|---|---|---|
| `HTTP_TOOLS_CONFIG_PATH` | repo `config/http-tools.json` | Override the global HTTP-tools config path | [`api/src/lib/http-tools-load.ts`](../../api/src/lib/http-tools-load.ts) |
| `HTTP_TOOLS_MOCK` | unset (off) | `1` / `true` makes HTTP tool calls return synthetic fixtures (test-only) | [`api/src/lib/http-tools-runtime.ts`](../../api/src/lib/http-tools-runtime.ts) |

---

## 15. Rate limiting

| Variable | Default | Effect | Reader |
|---|---|---|---|
| `RATE_LIMIT_PER_MIN` | `60` | Per-IP / per-token request budget | [`api/src/middleware/rate-limit.ts`](../../api/src/middleware/rate-limit.ts) |
| `RATE_LIMIT_DISABLED` | `false` | `true` / `1` disables rate limiting (CI / local) | `rate-limit.ts` |

---

## 16. Streamlit UI

These are read by `ui/lib/config.py` + `ui/lib/cognito_gate.py`. See [`ui/README.md`](../../ui/README.md) for the UI dev loop.

| Variable | Default | Effect |
|---|---|---|
| `API_URL` | `http://localhost:3000` | Hono API base URL |
| `STREAMLIT_COGNITO_POOL_ID` | — | Cognito user pool id; required for hosted-UI login. Pool id already encodes the region (`<region>_<id>`), so a separate region var is not required. |
| `STREAMLIT_COGNITO_CLIENT_ID` | — | Cognito app client id |
| `STREAMLIT_COGNITO_CLIENT_SECRET` | — | Cognito app client secret (required when the client is configured "with secret" in Cognito) |
| `STREAMLIT_COGNITO_DOMAIN` | — | Hosted-UI domain (optional; embedded login otherwise) |
| `STREAMLIT_COGNITO_REDIRECT_URI` | — | Hosted-UI callback URL |
| `STREAMLIT_PORT` | `8501` | Streamlit listen port (Docker / compose `compose.yaml` only — Streamlit itself binds 8501) |

---

## 17. Voyage / SageMaker tuning (advanced)

These are set in `deploy-project.sh` from `.env` and rarely overridden by hand.

| Variable | Default | Effect |
|---|---|---|
| `TF_VAR_voyage_endpoint_name_suffix` | `voyage-multimodal-3` | Endpoint name fragment |
| `VOYAGE_INSTANCE_TYPE` | `ml.g6.xlarge` | SageMaker endpoint instance type (GPU required — `ml.g6.xlarge` or `ml.g5.xlarge`). Set in `.env`, consumed by `deploy-shared.sh` |
| `VOYAGE_REQUEST_FORMAT` | `multimodal` | Voyage request envelope — `multimodal` (default, `voyage-multimodal-3`) or `legacy` (`voyage-3.5-lite` / `voyage-3`) |
| `VOYAGE_MARKETPLACE_MODEL` | `voyage-multimodal-3` | Pinned to the SoW model; override only for explicit written deviation |

> The `voyage-sagemaker` module's `instance_count` Terraform variable defaults to `1` and is not currently sourced from an env var — edit the module call in `envs/shared/main.tf` if you need to scale beyond one instance.

---

## 18. Deprecated / explicitly forbidden

These exist in old docs but are **not consumed by current code** — do not set them:

| Variable | Replacement |
|---|---|
| `REQUIRE_AUTH` | None — JWKS auth is mandatory and unconditional |
| `ALLOW_UNAUTHENTICATED` | Same |
| `CHAT_MODE=stub` | None — there is no stub chat loop; all chat goes through AgentCore Runtime |
| `DEV_MOCK_BACKENDS` | None — boot guards require a real orchestrator ARN + embeddings provider |

If you encounter these in a fork or older deployment, they have no effect.

---

*Last verified: 2026-05-20 against `api/src/`, `deploy/scripts/`, `deploy/terraform/`, and `.env.sample`.*
