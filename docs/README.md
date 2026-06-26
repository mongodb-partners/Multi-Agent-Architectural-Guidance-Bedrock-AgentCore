# Documentation — Getting Started

This folder is the **canonical getting started pack** for the Bedrock Multi-Agent reference. Code beats docs — every claim here has been cross-checked against `api/src/`, Terraform, deploy scripts, and `config/`.

*Last refreshed: 2026-05-20.*

---

## 1. What this project is

A **configuration-driven multi-agent reference** on **AWS Bedrock** (via the [Strands Agents TypeScript SDK](https://github.com/strands-agents/sdk-typescript)) and **MongoDB Atlas**. A user types a question into a Streamlit web UI; the Hono API receives it, an **in-API classifier** picks the right specialist (or falls back to an orchestrator AgentCore Runtime), and a **specialist AgentCore Runtime** (order-management, troubleshooting, product-recommendation) streams the answer back over SSE. MongoDB tools run in a **dedicated MongoDB MCP AgentCore Runtime** behind the AgentCore Gateway. Memory uses a two-layer split: **short-term conversation memory lives in AgentCore Memory**, while **long-term cross-session memory lives in MongoDB Atlas** with hybrid vector + BM25 across `agent_memory_facts` + `chat_messages`. Observability lands in CloudWatch (logs, EMF metrics, four dashboards, alarms) plus OpenTelemetry / X-Ray.

The product goal: **add specialists by editing markdown config**, not by forking business logic for every customer. New agent = new `config/agents/<name>.agent.md` + skill folder + redeploy. Before editing live config, check `config/samples/` for reference-only examples; files there are not loaded by the API or deployed to AgentCore.

**Two co-equal connectivity modes** (mutually exclusive per account): `NETWORK_MODE=privatelink` (default, partner-validated) or `NETWORK_MODE=peering` (alternative, with experimental KB ingestion). Switching modes requires destroy + redeploy.

---

## 2. You just inherited this repo — first-day checklist

1. **Skim** [`AGENTS.md`](../AGENTS.md), this file, and [`architecture.md`](architecture.md).
2. **Configure `.env`** from [`.env.sample`](../.env.sample). Decisions to make up front:
   - `NETWORK_MODE` — `privatelink` (default), `peering`, or `public` (Bring your own MongoDB Atlas cluster over the public internet — demo only). **Mutually exclusive per account.** Switching = destroy + redeploy.
   - `ATLAS_CLUSTER_SOURCE` — `managed` (default, stack provisions the Atlas cluster) or `byo` (Bring your own existing Atlas cluster; pair with `NETWORK_MODE=public` + `MONGODB_BYO_URI`).
   - `EMBEDDINGS_PROVIDER` — `voyage` (recommended for managed/private modes, requires Marketplace subscription) or `titan` (Bedrock built-in; **recommended for the public Bring-your-own-cluster setup** — no SageMaker endpoint to provision).
   - `AUTH_MODE` — `iam` (long-lived keys) or `sts` (assumed role / SSO).
3. **Pick the matching orchestrator** and run it; deploy scripts run centralized preflight checks before applying infrastructure:
   - PrivateLink: `./deploy/deploy-full-with-privatelink.sh --auto-approve`
   - VPC peering: `./deploy/deploy-full-with-vpc-peering.sh --auto-approve`
   - Public — Bring your own MongoDB Atlas cluster (demo only): `./deploy/deploy-full-public.sh --auto-approve`
4. **Post-deploy smoke:** runs in `deploy-project.sh` Phase 11 (or `source .env && python3 e2e-smoke/post-deploy-smoke.py` to re-run).
5. **Open the Streamlit UI** (URL printed by the deploy script), log in via the seeded Cognito user, send a chat.
7. **Open the Trace Viewer** for that turn (link in the chat inline card), toggle **Show developer details**.
8. **Tail logs without SSH:** `aws ssm send-command --document-name AWS-RunShellScript --instance-ids <id> --parameters 'commands=["journalctl -u multiagent-api -n 100"]'` — see [`status/debugging.md`](status/debugging.md) §3.

If anything fails, [`status/debugging.md`](status/debugging.md) is the playbook — start with its "Common failures" table.

---

## 3. Reading orders

Pick the path that matches your role.

### 3.1 Operator / SRE (deploy + run + debug)
1. [`deployment-guide.md`](deployment-guide.md) — prerequisites, the two orchestrators, teardown (`deploy/destroy/`), CI/CD
2. [`configuration-guide.md`](configuration-guide.md) — `config/` folder: agent personas, skills, `environment.yaml`
3. [`observability-runbook.md`](observability-runbook.md) — finding traces, log groups, dashboards, alarms, emergency knobs
4. [`reference/smoke-tests.md`](reference/smoke-tests.md) — every `e2e-smoke/*` script
5. [`status/debugging.md`](status/debugging.md) — fix things when they break

### 3.2 Backend developer (add agents, skills, tools, behaviors)
1. [`architecture.md`](architecture.md) — system overview, 5-runtime topology, classifier vs orchestrator
2. [`agent-authoring-guide.md`](agent-authoring-guide.md) — `.agent.md` schema
3. [`skills-authoring-guide.md`](skills-authoring-guide.md) — `SKILL.md` schema + progressive disclosure
4. [`reference/tools.md`](reference/tools.md) — every supported agent tool, runtime home, config, and debugging path
5. [`api-reference.md`](api-reference.md) — HTTP/SSE contract
6. [`memory-architecture.md`](memory-architecture.md) + [`long-term-memory-design.md`](long-term-memory-design.md) — short-term + LTM
7. [`status/debugging.md`](status/debugging.md) — trace-driven debug, validation scripts

### 3.3 Site Reliability (logs, metrics, traces, alarms)
1. [`logging-architecture.md`](logging-architecture.md) — JSON logger, OTel + X-Ray, CloudWatch shipping, ADOT sidecar, audit channel
2. [`observability-runbook.md`](observability-runbook.md) — day-2 ops
3. [`trace-ui-system-overview.md`](trace-ui-system-overview.md) → [`trace-viewer-developer-guide.md`](trace-viewer-developer-guide.md) — debug-grade Trace Viewer
4. [`dashboards/README.md`](dashboards/README.md) — fleet / mongo / cost / atlas widget catalog
5. [`status/debugging.md`](status/debugging.md) — when alarms fire

### 3.4 Demo engineer / SE (demos)
1. [`demo/demo-script.md`](demo/demo-script.md) — narrated walkthrough
2. [`demo/demo-mode-guide.md`](demo/demo-mode-guide.md) — trace UI knobs for live demos
3. [`trace-viewer-guide.md`](trace-viewer-guide.md) — operator-friendly Trace Viewer surface

### 3.5 Advanced (optional — not required for most contributors)
1. [`advanced/deploy-tweak-guide.md`](advanced/deploy-tweak-guide.md) — mode flags, AWS ARNs, embedding provider switches, operational env knobs, local-dev wiring
2. [`reference/env-vars.md`](reference/env-vars.md) — exhaustive env var catalog

---

## 4. Documentation map

| Doc | Purpose | Last refreshed |
|---|---|---|
| [`architecture.md`](architecture.md) | System overview, 5-runtime topology, AWS infra, request flow, classifier path | 2026-05-20 |
| [`diagrams/README.md`](diagrams/README.md) | Mermaid diagram pages — AWS infrastructure, request flow, memory architecture, deployment pipeline | 2026-06-09 |
| [`deployment-guide.md`](deployment-guide.md) | How to deploy (PrivateLink + VPC peering), CI/CD, teardown, prerequisites | 2026-05-20 |
| [`configuration-guide.md`](configuration-guide.md) | `config/` folder — agent personas, skills, `environment.yaml`, `http-tools.json` | 2026-05-24 |
| [`advanced/deploy-tweak-guide.md`](advanced/deploy-tweak-guide.md) | **Advanced** — deploy/runtime tuning: mode flags, ARNs, embeddings, operational env knobs | 2026-05-24 |
| [`api-reference.md`](api-reference.md) | HTTP + SSE contract, projections, auth error codes | 2026-05-20 |
| [`agent-authoring-guide.md`](agent-authoring-guide.md) | `.agent.md` frontmatter + body | 2026-05-20 |
| [`skills-authoring-guide.md`](skills-authoring-guide.md) | `SKILL.md`, progressive disclosure, scripts, http-tools | 2026-05-20 |
| [`reference/tools.md`](reference/tools.md) | **NEW** — every supported agent tool, internal helper, runtime home, config, and debugging path | 2026-05-20 |
| [`memory-architecture.md`](memory-architecture.md) | Short-term + long-term memory at a glance | 2026-05-20 |
| [`long-term-memory-design.md`](long-term-memory-design.md) | Deep dive — schemas, write path, read path, tuning, failure modes | 2026-05-20 |
| [`hybrid-search.md`](hybrid-search.md) | `mongodb_vector_search` + hybrid BM25, agent-facing surface | 2026-05-20 |
| [`logging-architecture.md`](logging-architecture.md) | Structured logs, OTel, CloudWatch shipping, ADOT sidecar, audit | 2026-05-20 |
| [`observability-runbook.md`](observability-runbook.md) | Day-2 ops — traces, log groups, alarms, dashboards, emergency knobs | 2026-05-20 |
| [`trace-ui-system-overview.md`](trace-ui-system-overview.md) | All Trace UI surfaces — inline card, Trace Viewer, fixture harness | 2026-05-20 |
| [`trace-viewer-guide.md`](trace-viewer-guide.md) | Operator-friendly Trace Viewer tour | 2026-05-20 |
| [`trace-viewer-developer-guide.md`](trace-viewer-developer-guide.md) | Debug-grade Trace Viewer tour, `?include=core\|dev\|full` projection | 2026-05-20 |
| [`agentcore-runtime-design.md`](agentcore-runtime-design.md) | 5-runtime topology, code vs container artifact strategy | 2026-05-20 |
| [`status/README.md`](status/README.md) | Status / ops doc index | 2026-05-24 |
| [`status/debugging.md`](status/debugging.md) | Developer playbook: EC2 access, log tailing, trace-driven debug, common failures, memory diag, validation scripts, persistent pitfalls | 2026-05-20 |
| [`dashboards/README.md`](dashboards/README.md) | Widget catalog, console URLs, alarm thresholds | 2026-05-20 |
| [`estimate.md`](estimate.md) | Monthly AWS cost estimate | 2026-05-20 |
| [`demo/demo-script.md`](demo/demo-script.md) | Narrated demo walkthrough | 2026-05-20 |
| [`demo/demo-mode-guide.md`](demo/demo-mode-guide.md) | Trace UI knobs for live demos | 2026-05-20 |
| **Reference appendix** | | |
| [`reference/env-vars.md`](reference/env-vars.md) | **NEW** — every env var catalogued | 2026-05-20 |
| [`reference/tools.md`](reference/tools.md) | **NEW** — every supported agent tool catalogued | 2026-05-20 |
| [`reference/terraform-modules.md`](reference/terraform-modules.md) | **NEW** — every Terraform module summarized | 2026-05-20 |
| [`reference/ssm-parameters.md`](reference/ssm-parameters.md) | **NEW** — cross-stack SSM contract | 2026-05-20 |
| [`reference/data-model.md`](reference/data-model.md) | **NEW** — every Mongo collection, indexes, TTL, access paths | 2026-05-20 |
| [`reference/smoke-tests.md`](reference/smoke-tests.md) | **NEW** — every `e2e-smoke/*` script | 2026-05-20 |
| [`reference/deploy-scripts.md`](reference/deploy-scripts.md) | **NEW** — every shell script under `deploy/`, with flags + phase index | 2026-05-20 |
| **Adjacent READMEs** | | |
| [`../api/README.md`](../api/README.md) | API developer onboarding | 2026-05-20 |
| [`../ui/README.md`](../ui/README.md) | UI developer onboarding | 2026-05-20 |
| [`../db-seeding/README.md`](../db-seeding/README.md) | Seed scripts | 2026-05-20 |
| [`../mcp-runtimes/mongodb-mcp/README.md`](../mcp-runtimes/mongodb-mcp/README.md) | MongoDB MCP AgentCore Runtime | 2026-05-20 |
| [`../e2e/README.md`](../e2e/README.md) | Playwright E2E smoke | 2026-05-20 |
| [`../deploy/terraform/.design.md`](../deploy/terraform/.design.md) | Terraform stack rationale | 2026-05-20 |

---

## 5. Architecture diagrams

Inline mermaid blocks in [`architecture.md`](architecture.md) are the **canonical** diagrams — they are updated in lock-step with the code. The `.drawio` sources in [`diagrams/`](diagrams/) are **historical** and may show the legacy Lambda MCP / two-hop orchestrator topology; see [`diagrams/README.md`](diagrams/README.md).

---

## 6. CI/CD

`.github/workflows/`:
- **`ci.yml`** — typecheck + unit tests on every push/PR (`bun run typecheck`, `bun run validate:bun`, `bun run validate:agentcore`, `bun test tests/unit`).
- **`deploy.yml`** — manual / tag-triggered deploy. Mirrors `deploy-full-with-privatelink.sh` / `deploy-full-with-vpc-peering.sh` against a long-lived AWS environment. Cuts a tag, runs Terraform, runs smoke.

See [`deployment-guide.md` § CI/CD](deployment-guide.md) for the full breakdown.

---

## 7. Authoritative source files

Code beats docs. When in doubt, read:

| Concern | File |
|---|---|
| Request routing / classifier | [`api/src/lib/agent-classifier.ts`](../api/src/lib/agent-classifier.ts), [`api/src/routes/chat.ts`](../api/src/routes/chat.ts) |
| AgentCore invocation | [`api/src/adapters/agentcore-runtime.ts`](../api/src/adapters/agentcore-runtime.ts) |
| Strands agent construction | [`api/src/lib/create-strands-agent.ts`](../api/src/lib/create-strands-agent.ts) |
| Long-term memory | [`api/src/lib/long-term-memory.ts`](../api/src/lib/long-term-memory.ts), [`api/src/lib/vector-retrieval.ts`](../api/src/lib/vector-retrieval.ts) |
| Trace collector | [`api/src/lib/trace-collector.ts`](../api/src/lib/trace-collector.ts) |
| Deploy entrypoints | [`deploy/deploy-full-with-privatelink.sh`](../deploy/deploy-full-with-privatelink.sh), [`deploy/deploy-full-with-vpc-peering.sh`](../deploy/deploy-full-with-vpc-peering.sh), [`deploy/deploy-full-public.sh`](../deploy/deploy-full-public.sh) (Bring your own MongoDB Atlas cluster, demo) |
| Per-project infra | [`deploy/terraform/envs/ec2/main.tf`](../deploy/terraform/envs/ec2/main.tf) |
| Shared infra | [`deploy/terraform/envs/shared/main.tf`](../deploy/terraform/envs/shared/main.tf) |
| Network infra | [`deploy/terraform/envs/network/main.tf`](../deploy/terraform/envs/network/main.tf) |
| MongoDB MCP runtime | [`mcp-runtimes/mongodb-mcp/`](../mcp-runtimes/mongodb-mcp/) |
| Agent personas | [`config/agents/*.agent.md`](../config/agents/) |
| Config samples | [`config/samples/`](../config/samples/) — reference-only examples, not loaded/deployed |
| Skills | [`config/skills/`](../config/skills/) |
