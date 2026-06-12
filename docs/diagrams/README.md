# Architecture Diagrams

Mermaid-based architecture diagram pages. Each renders natively in GitHub and IDE Markdown preview, and is cross-checked against the canonical docs and source code so it stays accurate.

| Diagram | Covers | Primary sources |
|---|---|---|
| [01 — AWS Infrastructure](01-aws-infrastructure.md) | Three-stack Terraform topology, 5 AgentCore runtimes + Gateway + Memory, PrivateLink vs VPC-peering connectivity, resource inventory, deliberate exclusions | [`architecture.md` §5](../architecture.md), [`terraform-modules.md`](../reference/terraform-modules.md) |
| [02 — Request Flow](02-request-flow.md) | Single-hop happy path, in-API classifier decision, multi-specialist + synthesizer, SSE event lifecycle, orchestrator rollback | [`architecture.md` §4](../architecture.md), [`chat.ts`](../../api/src/routes/chat.ts), [`agent-classifier.ts`](../../api/src/lib/agent-classifier.ts) |
| [03 — Memory Architecture](03-memory-architecture.md) | Short-term vs long-term split, LTM write path, hybrid RRF + MMR read pipeline, backend matrix, tuning knobs | [`memory-architecture.md`](../memory-architecture.md), [`AGENTS.md`](../../AGENTS.md) |
| [04 — Deployment Pipeline](04-deployment-pipeline.md) | Orchestrator + SSM-canary flow, `deploy-project.sh` phases 1-11, code vs container artifacts, targeted redeploys, teardown ordering | [`deploy-scripts.md`](../reference/deploy-scripts.md), [`AGENTS.md`](../../AGENTS.md) |

These pages complement the narrative docs — start at [`docs/README.md`](../README.md) for the full doc map.
