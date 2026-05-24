# `api/` — Hono API + AgentCore Runtime entrypoint

TypeScript + Bun + Hono service. Hosts the chat SSE endpoint, session store, classifier, trace persistence, and the shared bundle that every AgentCore Runtime container also boots from.

> **Authoritative docs:**
>
> - [`docs/api-reference.md`](../docs/api-reference.md) — HTTP/SSE contract
> - [`docs/architecture.md`](../docs/architecture.md) — system overview
> - [`docs/agentcore-runtime-design.md`](../docs/agentcore-runtime-design.md) — the 5-runtime topology this file powers
> - [`docs/configuration-guide.md`](../docs/configuration-guide.md) — `config/` folder
> - [`docs/advanced/deploy-tweak-guide.md`](../docs/advanced/deploy-tweak-guide.md) + [`docs/reference/env-vars.md`](../docs/reference/env-vars.md) — deploy/runtime env vars
> - [`docs/reference/tools.md`](../docs/reference/tools.md) — every supported agent tool, runtime home, config, and debugging path
> - [`docs/status/debugging.md`](../docs/status/debugging.md) — debug a live turn

## Quick start

```bash
export PATH="$HOME/.bun/bin:$PATH"   # if `bun` not on PATH
bun install
bun run typecheck
bun run validate:bun
bun run validate:agentcore
bun run dev
```

`bun run dev` starts the API in watch mode on port 3000. The API refuses to boot without `AUTH_JWKS_URI` + `AUTH_ISSUER` + `AGENTCORE_ORCHESTRATOR_ARN` — source `.env` and `.env.live` first.

## Layout

| Path | Role |
|---|---|
| `src/index.ts` | Hono app boot — startup guards (`assertJwksAuthConfigured`, `assertAgentcoreOrchestratorArn`, `assertShortTermBackendConfigured`, `assertEmbeddingsProvider`), OTel bootstrap, pre-warm (`runStartupPrewarm`). |
| `src/agent-runtime-code.ts` | **AgentCore Runtime entrypoint.** Single bundle shared by orchestrator + 3 specialist runtimes; `AGENT_ID` env selects the persona. |
| `src/routes/` | One Hono route module per surface (`chat`, `sessions`, `agents`, `traces`, `health`, `agent-config-refresh`, etc.). |
| `src/middleware/` | `auth.ts` (JWT verify via `jose`), `rate-limit.ts`, `request-id.ts`, `otel.ts`, `cors.ts`. |
| `src/lib/` | Core domain: `agent-classifier.ts`, `run-chat-stream.ts`, `swarm-chat-stream.ts`, `prompt.ts`, `long-term-memory.ts`, `short-term-memory.ts`, `session-store.ts`, `trace-*.ts`, `embed-query.ts`, `mongo-client.ts`, etc. |
| `src/adapters/` | External-service adapters: `agentcore-runtime.ts`, `mongodb-mcp-client.ts`, `resolve-model.ts`, `voyage-embedding.ts`, `bedrock-retrieval.ts`. |
| `scripts/` | `validate-*.ts` (Bun + Node compat, AgentCore Memory SDK contract, Strands ↔ OTel peer-dep drift, Strands retry hook surface), `bench-chat-ttfb.ts`. |
| `tests/unit/` | Fast unit tests (Bun runner). |
| `tests/integration/` | Integration tests — gated on env (real Bedrock / real Mongo / Strands Swarm). |
| `Dockerfile` | API container image. **Build context = repo root** (so `config/` is reachable). |
| `Dockerfile.agentcore` | Container-mode AgentCore Runtime image. The default deploy uses `code` mode (S3 zip on `NODE_22`), but this Dockerfile is the fallback. |

## Validation scripts

| Command | What it checks |
|---|---|
| `bun run typecheck` | TypeScript strict |
| `bun run test` | Unit tests in `tests/unit/` |
| `bun run test:integration` | Integration tests (real backends behind flags) |
| `bun run validate:bun` | Bun + Node 22 compat smoke (top-level `await`, fetch streaming, AsyncLocalStorage) |
| `bun run validate:agentcore` | AgentCore Memory contract — `CreateEvent` / `ListEvents` shape matches the SDK version pinned in `package.json` |
| `bun run validate:strands-otel` | Strands TS SDK ↔ OTel SDK version drift — `ProxyTracerProvider → NodeTracerProvider OK`, emitted `gen_ai.*` span lands |
| `bun run validate:strands-retries` | `AfterModelCallEvent.retry` surface still exported (catches Strands SDK bumps that break `TracingRetryStrategy`) |
| `bun run bench:ttfb` | TTFB benchmark against the stub server |

CI runs typecheck + validate:bun + validate:agentcore + test:all on every PR (see `.github/workflows/ci.yml`).

## Two entrypoints, one bundle

| Entry | What runs |
|---|---|
| `src/index.ts` | The **API process** that hosts HTTP + SSE on EC2 (or on your laptop). Owns the in-API classifier, sessions, trace persistence, LTM read+write. |
| `src/agent-runtime-code.ts` | The **AgentCore Runtime process** invoked by `bedrock-agentcore:InvokeAgentRuntime`. Stateless — receives the full turn payload (message + memory context) and returns an SSE stream. |

The bundle is shared so the same Strands + tool + skill loading logic runs in both processes. The only difference is **who invokes it**: the API speaks HTTP; the runtime speaks `InvokeAgentRuntime`.

**Pinned invariants** (see `tests/unit/agent-construction-invariants.test.ts`):

- Every `new Agent(…)` site must `await getMcpTools()` and spread it into `tools`.
- `agent-runtime-code.ts` must wrap the agent run in `withGatewayJwt(userJwt, …)` so the caller's JWT scopes Gateway-hosted tool calls.
- There is exactly one runtime entrypoint — `agent-runtime-server.ts` has been deleted.

## Logging + tracing

- `src/lib/logger.ts` emits JSON lines with `trace_id` / `span_id` / `trace_flags` from the active OTel span (when present). Level via `LOG_LEVEL`.
- `src/lib/otel.ts` installs `NodeTracerProvider` + `BatchSpanProcessor` + `OTLPTraceExporter` when `OTEL_EXPORTER_OTLP_ENDPOINT` is set (EC2 default: `http://127.0.0.1:4318` → ADOT sidecar).
- `src/lib/cw-metrics.ts` emits EMF stdout JSON for `Multiagent/Chat`, `Multiagent/Mongo`, `Multiagent/Memory`. Disable in CI with `METRICS_EMITTER_ENABLED=0`.

`bun run dev` writes structured logs to stdout — pipe through `jq` for filtering.
