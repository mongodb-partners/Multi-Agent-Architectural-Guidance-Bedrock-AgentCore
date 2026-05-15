# Gap Analysis — SoW vs Current Implementation

> **Last updated:** 2026-05-14
> **Reference:** [`../Docs/Peerislands-MongoDB_AWS MultiAgent Architecture development SOW v02.docx`](../../Docs/Peerislands-MongoDB_AWS%20MultiAgent%20Architecture%20development%20SOW%20v02.docx) and the SoW architecture diagram [`../Docs/Multi-agent-architecture-bedrock-agentcore 1 (1).png`](../../Docs/Multi-agent-architecture-bedrock-agentcore%201%20(1).png).
> **Predecessor:** [`../Docs/gap-analysis-04.09.2026.md`](../../Docs/gap-analysis-04.09.2026.md) — that captured the gap *before* most AgentCore work was done. This document supersedes it.

This document compares the **frozen baseline** (see [FROZEN_E2E_DESIGN.md](FROZEN_E2E_DESIGN.md)) against the SoW. Read this when you need to know "what's still missing" before a demo, sign-off, or scope conversation.

---

## 1. The TL;DR

The system is **functionally complete against the core SoW**. The orchestrator + 3 specialists are running on AgentCore Runtimes, MongoDB tools are served exclusively through the AgentCore Gateway MCP target (Lambda backend), AgentCore Memory is wired, **Voyage AI on SageMaker is the active embedding provider for `products` + `troubleshooting_docs`** (on `voyage-3.5-lite`; `voyage-multimodal-3` migration tracked under P1-5), the UI streams SSE responses with an inline reasoning panel, and JWKS auth is mandatory end-to-end. The remaining gaps are mostly **production-hardening items** (multi-tenancy, CI/CD, AgentCore Observability) and a few SoW alignment deltas tracked in [`CLIENT_REVIEW_TASKS.md`](../CLIENT_REVIEW_TASKS.md).

---

## 2. SoW component coverage

### ✅ Implemented and aligned

| SoW Component | Status | Evidence |
|---|---|---|
| **Orchestrator + 3 Specialist Agents** | ✅ Done | 4 AgentCore Runtimes (`bedrock-ma-use1-{orchestrator, troubleshooting, order_management, product_recommendation}-dev`). One ARM64 image, `AGENT_ID` env var selects persona. |
| **Bedrock AgentCore Runtime** | ✅ Done | `deploy/terraform/modules/agentcore-agent-runtime/` provisions all 4. S3 code-mode artifacts (`NODE_22`). |
| **Bedrock Foundation Model** | ✅ Done | All agents on `us.anthropic.claude-sonnet-4-6` (per verbal client decision; SoW originally said Nova). Model access unblocked 2026-04-30. |
| **AgentCore Memory** | ✅ Done | Provisioned and active for short-term memory backend in EC2 auth mode; also used as fallback for long-term persistence when Mongo facts backend fails. |
| **MDB MCP Server** | ✅ Done (Lambda backend behind the AgentCore Gateway) | `lambda/mongodb-mcp/index.mjs` — exposes `mongodb_query`, `mongodb_vector_search`, `mongodb_aggregate`. Reached only via the AgentCore Gateway MCP target; runtimes never call `lambda:InvokeFunction` directly. |
| **MongoDB Atlas Cluster** | ✅ Done | M10 in `bedrock-ma-use1-dev`. 3 nodes, us-east-1. |
| **Atlas PrivateLink** | ✅ Done | VPC Interface Endpoint + Route 53 private zone + wildcard CNAME. Lambda MCP reaches Atlas privately. |
| **Bedrock Knowledge Base (RAG)** | ✅ Done | `troubleshooting-kb` (KB ID `YDF16V4CRX`). S3 docs, Titan embeddings, MongoDB vector store. Used by troubleshooting agent. |
| **Cognito (auth)** | ✅ Mandatory end-to-end | User pool + app client provisioned. JWKS verification wired in API; `assertJwksAuthConfigured()` refuses to boot the API without `AUTH_JWKS_URI` + `AUTH_ISSUER`. The Streamlit Cognito gate is required for the UI. |
| **Web Application (UI)** | ✅ Done | Streamlit on EC2 :8501. |
| **EC2 Compute** | ✅ Done | t3.medium + EIP. Docker + systemd. |
| **VPC + private/public subnets** | ✅ Done | 10.0.0.0/16 with 2 public + 2 private subnets. Atlas private zone. |
| **CloudWatch Logs** | ✅ Done | 4 Terraform log groups: `/<project>/<env>/{api, ui, mcp, agentcore}`. API retention **30d** (from `log_retention_days`); **ui / mcp / agentcore placeholders 7d**. On EC2 bootstrap, **amazon-cloudwatch-agent** ships `multiagent-api` + `multiagent-ui` journald → `api` + `ui` groups. |
| **IAM (per-service roles)** | ✅ Done | EC2 instance profile, Lambda execution role, 4 runtime roles, KB role, Gateway role. |
| **Secrets Manager** | ✅ Done | `<project>-bedrock-kb-creds-<env>` for KB → Atlas auth. |
| **Long-term memory in Atlas** | ✅ Wired (primary) | `agent_memory_facts` collection with TTL index (default 30 days in deploy). AgentCore is fallback for LTM failures. |
| **SSE streaming** | ✅ Done | Token streaming in Strands path. Single-burst mode for AgentCore Runtime path (compat layer). |
| **ECR images** | ✅ Done | `bedrock-ma-use1-{api, ui}` repositories. Optional `agent-runtime` repo for container mode. |
| **Configuration-driven agents/skills** | ✅ Done | `config/agents/*.agent.md` + `config/skills/*/SKILL.md`. Hot-reload with mtime cache. |

### ⚠️ Implemented with caveats

| SoW Component | Status | Caveat |
|---|---|---|
| **AgentCore Gateway** | ✅ Done — sole tool path | The Gateway resource (`bedrock-ma-use1-gw-dev-jslrisrr8k`) fronts `lambda/mongodb-mcp/index.mjs`. Every runtime has `MCP_SERVER_URL=AGENTCORE_GATEWAY_URL` set by `deploy.sh`. Outbound auth = caller's Cognito JWT, forwarded through the AgentCore Runtime invocation payload. |
| **Streamlit Cognito hosted-UI** | ⚠️ Mandatory, not production-hardened | The Streamlit Cognito gate (`ui/lib/cognito_gate.py`, `streamlit-cognito-auth`) is required so the UI always has a Bearer token for the API. Cookie persistence and full hosted-UI multi-region QA are open. |
| **Persistent short-term sessions** | ⚠️ Hybrid | EC2 default uses AgentCore short-term events when authenticated; `session-store` remains in-memory fallback. Optional Mongo `chat_sessions` write-through still available with `PERSIST_CHAT_SESSIONS=1`. |
| **JWT-scoped customerId queries** | ⚠️ Partial | Sessions are scoped by JWT `sub`. Long-term memory is keyed by user. But agents query MongoDB by user-supplied IDs (orderId, customerId) — there is no implicit `customerId == jwt.sub` enforcement at the data layer. |
| **`agentcore` health probe** | ⚠️ Reports `unreachable` | The `ListSessions` health check requires extra IAM. Functional memory still works; only the probe is stale. Non-blocking. |

### 🔴 Not implemented (parked or pending)

| SoW Component | Status | Rationale / Plan |
|---|---|---|
| **Voyage `multimodal-3` migration (P1-5)** | ✅ Done — code defaults to `voyage-multimodal-3` | Voyage SageMaker is **deployed and active** for both `products` and `troubleshooting_docs` query+document embeddings. The adapter ([`api/src/adapters/voyage-embedding.ts`](../api/src/adapters/voyage-embedding.ts)) and seeder ([`db-seeding/seed-embeddings.ts`](../db-seeding/seed-embeddings.ts)) default to the `multimodal` request envelope (`voyage-multimodal-3`); fall back to `legacy` (`voyage-3.5-lite`) only if `VOYAGE_REQUEST_FORMAT=legacy`. Marketplace ARN is discovered by `setup-voyage-marketplace.sh` (defaults to `voyage-multimodal-3`) and never hard-coded. Bedrock Titan v2 stays as the documented fallback. |
| **AgentCore Code Interpreter** | 🔴 Not started | SoW's "Code Interpreter" component for sandboxed script execution. Currently `run_skill_script` does dynamic `.mjs` imports inside the API process — no sandboxing. |
| **Lambda Base-Tools (multiple Lambdas)** | 🔴 Single Lambda | SoW diagram shows 2 Lambda functions for tool execution. Implemented as one consolidated `mongodb-mcp` function. Adding more Lambdas would mean splitting `mongodb_query` from `mongodb_vector_search` etc. — not currently needed. |
| **Multi-tenancy / customerId data scoping** | 🔴 Not enforced | Agents see whatever the user types as `customerId`. JWT `sub` is not mapped to `customerId` at query construction time. |
| **Vector-similarity long-term memory recall** | 🔴 Not implemented | Current LTM is fact-extraction + recency behavior. Planned upgrade: PII-filtered extraction → embedding → vector search in `agent_memory_facts`. |
| **Production CI/CD pipeline** | 🔴 Workflow exists, not primary | `.github/workflows/deploy.yml` exists. Day-to-day deploys still run `deploy.sh` locally. |
| **Security P0 fixes from `Docs/code-review-04.20.2026.md`** | 🔴 Open | Auth bypass guard at boot, session enumeration scope, SSRF allowlist enforcement, Lambda log redaction. See [§4](#4-security-gaps-from-code-review). |
| **Browser/Streamlit E2E test suite** | 🔴 Not built | Playwright API E2E exists in `e2e/`. No browser/Streamlit UI E2E. |
| **Data enrichment (more docs/SKUs)** | 🔴 POC fixtures only | Products: 9 SKUs (target: 12+). Troubleshooting docs: 7 (target: 10+). Error codes reference: 5 (target: 12+). |
| **AgentCore Observability box** | 🔴 Stub only | Health probe reports `unreachable`. No AgentCore-native telemetry dashboard. CloudWatch logs are the operational source. |

---

## 3. Differences from `gap-analysis-04.09.2026.md`

That earlier doc captured the system **before** the AgentCore migration. Substantial movement since:

| Component | 04.09 | 05.01 |
|---|---|---|
| AgentCore Runtime | 🔴 Not started | ✅ 4 runtimes deployed |
| AgentCore Memory | 🔴 Not wired | ✅ Wired and active |
| MDB MCP | 🔴 Absent | ✅ Lambda MCP active |
| PrivateLink | 🔴 Public SRV | ✅ PrivateLink + Route 53 |
| VPC | 🔴 Empty stub | ✅ Full VPC with 4 subnets |
| Lambda agent tools | 🔴 In-process only | ✅ Lambda MCP (single function) behind the AgentCore Gateway |
| Voyage AI / SageMaker | 🔴 Not started | 🟢 Active for `products` + `troubleshooting_docs`, defaulting to `voyage-multimodal-3` (the SoW model) |
| CloudWatch | ✅ JSON + OTel fields in API; journald→CW agent on EC2 | ✅ 4 log groups (`api` 30d, `ui`/`mcp`/`agentcore` 7d), EC2 ships API+UI units |
| EC2 deployment | 🔴 No automation | ✅ Full `deploy.sh` (13 phases) |
| AgentCore Gateway | 🔴 Not started | ✅ Sole tool path (every runtime uses `MCP_SERVER_URL=AGENTCORE_GATEWAY_URL`) |
| Cognito | ⚠️ Optional | ⚠️ Optional, provisioned, JWKS-validated |

The 04.09 doc said "8 priority items to close gaps." Seven of those eight are now closed (Voyage AI is live and defaults to `voyage-multimodal-3`, the SoW model). The one item still deliberately parked is **AgentCore Code Interpreter**.

---

## 4. Security gaps from code review

From [`../Docs/code-review-04.20.2026.md`](../../Docs/code-review-04.20.2026.md) — these are now resolved (see `CLIENT_REVIEW_TASKS.md` / `CLIENT_REVIEW_EXPLAINER.md`):

1. **Auth bypass at boot** — `assertJwksAuthConfigured()` runs in `api/src/index.ts` before the listener binds; the API refuses to start without `AUTH_JWKS_URI` + `AUTH_ISSUER`. The `ALLOW_UNAUTHENTICATED` / `REQUIRE_AUTH=false` branches are gone.
2. **Session enumeration** — `listSessions(userId)` and `GET /sessions` now require an authenticated caller and scope strictly to `userId === jwt.sub`; sessions belonging to other users (or with no `userId`) are excluded.
3. **SSRF allowlist enforcement** — HTTP tool registration rejects definitions whose host is not in `security.allowedHosts` / `security.allowedHostSuffixes`; there is no dev bypass.
4. **Lambda log redaction** — `lambda/mongodb-mcp/index.mjs` redacts `args.filter` / `args.document` / `args.update` / `args.queryVector` before `console.log`.

---

## 5. Recommended priority order to close remaining gaps

If you have one more sprint, do these in order:

1. **Security P0 fixes** (4 items above) — small, high impact, zero scope risk.
2. **`agentcore: unreachable` health probe** — fix IAM / change probe call. Removes a confusing yellow flag in `/health`.
3. **Data enrichment** — products 9→12, troubleshooting docs 7→10. Improves demo quality without code changes.
4. **Multi-tenancy** — map JWT `sub` → `customerId` in query construction. Defends the demo against "what if user types another customer's ID?" questions.
5. **Vector-similarity LTM recall** — PII filter + embedding + `$vectorSearch` on `agent_memory_facts`. Real differentiation versus stock chatbot frameworks.
6. **CI/CD primary path** — make GitHub Actions the default deploy mechanism. Push protection and review gates.
7. ~~**Voyage `multimodal-3` migration (P1-5)** — done; the system defaults to `voyage-multimodal-3`.~~
8. **AgentCore Code Interpreter** — only if a use case actually needs sandboxed code execution. The current `.mjs` import is fine for the demo agents.

---

## 6. What is *not* a gap (intentional simplifications)

The following are missing from the SoW diagram but were deliberately not implemented for POC scope:

- **NAT Gateway** — $33/mo, not needed (EC2 in public subnet)
- **VPC Interface Endpoints** for Bedrock/AgentCore — ~$102/mo, not needed at POC scale
- **ALB / CloudFront / auto-scaling** — single EC2 t3.medium handles POC traffic
- **ECS/Fargate** — Docker on EC2 + systemd is simpler and cheaper
- **DynamoDB lock for Terraform state** — SCP blocks `dynamodb:CreateTable`; S3 versioning + manual coordination is sufficient

If/when this becomes a production system, these would all be reconsidered.

---

## 7. Sources

- **Authoritative target architecture**: [`../Docs/Multi-agent-architecture-bedrock-agentcore 1 (1).png`](../../Docs/Multi-agent-architecture-bedrock-agentcore%201%20(1).png) — the SoW diagram
- **Latest SoW**: [`../Docs/Peerislands-MongoDB_AWS MultiAgent Architecture development SOW v02.docx`](../../Docs/Peerislands-MongoDB_AWS%20MultiAgent%20Architecture%20development%20SOW%20v02.docx)
- **Frozen baseline** (what's actually built): [FROZEN_E2E_DESIGN.md](FROZEN_E2E_DESIGN.md)
- **Predecessor gap analysis** (pre-AgentCore state): [`../Docs/gap-analysis-04.09.2026.md`](../../Docs/gap-analysis-04.09.2026.md)
- **Security review** (P0 items): [`../Docs/code-review-04.20.2026.md`](../../Docs/code-review-04.20.2026.md)
