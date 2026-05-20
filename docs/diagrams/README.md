# `docs/diagrams/` — HISTORICAL

The `.drawio` sources in this folder are **historical** and may show:

- The legacy Lambda MCP host (now the [`mcp-runtimes/mongodb-mcp/`](../../mcp-runtimes/mongodb-mcp/) AgentCore Runtime).
- The two-hop orchestrator → specialist request flow (now single-hop via the in-API classifier by default; orchestrator runtime is a rollback path).
- Recency-only long-term memory (now hybrid vector + BM25 with RRF + MMR).

The current canonical diagrams are the **mermaid blocks inline in [`docs/architecture.md`](../architecture.md)** — they are kept in lock-step with the code by every doc update.

The `.drawio` sources are preserved for institutional history and to seed future architecture decks; they are **not authoritative**. If you regenerate any of these for a client deck, update the mermaid in `architecture.md` first and the `.drawio` from that.

| File | Status | Replaced by |
|---|---|---|
| `01-aws-infrastructure.drawio` | Historical | [`architecture.md` § AWS infrastructure mermaid](../architecture.md) |
| `02-request-flow.drawio` | Historical | [`architecture.md` § Request flow mermaid](../architecture.md) |
| `03-memory-architecture.drawio` | Historical | [`memory-architecture.md`](../memory-architecture.md) + [`long-term-memory-design.md`](../long-term-memory-design.md) |
| `04-deployment-pipeline.drawio` | Historical | [`deployment-guide.md`](../deployment-guide.md) + [`reference/deploy-scripts.md`](../reference/deploy-scripts.md) |
| `aws-arch/*.drawio` | Historical | [`architecture.md`](../architecture.md) + [`reference/terraform-modules.md`](../reference/terraform-modules.md) |
