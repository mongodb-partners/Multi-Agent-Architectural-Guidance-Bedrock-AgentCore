# AgentCore Runtime Design (5-Runtime topology)

## Overview

Production EC2 mode uses **five** AgentCore runtimes:

- `orchestrator` — legacy classification hop, invoked only when `USE_ORCHESTRATOR_RUNTIME=1`
- `troubleshooting` — specialist
- `order-management` — specialist
- `product-recommendation` — specialist
- `mongodb-mcp-runtime` — dedicated MCP server fronting the MongoDB driver (separate code base under [`mcp-runtimes/mongodb-mcp/`](../mcp-runtimes/mongodb-mcp/))

The four agent runtimes (orchestrator + 3 specialists) share **one code bundle** ([`api/src/agent-runtime-code.ts`](../api/src/agent-runtime-code.ts)). The `AGENT_ID` env var on each runtime selects the persona at boot. The MongoDB MCP runtime is built and deployed independently as an ARM64 Docker image.

Runtime artifact modes:

- **`code` (default for agent runtimes)** — S3 zip direct-code deployment on AgentCore `NODE_22`. The deployed entrypoint is `agent-runtime-code.js`, bundled with esbuild from `agent-runtime-code.ts`.
- **`container`** — ARM64 container image via ECR (`api/Dockerfile.agentcore`). Used today by `mongodb-mcp-runtime` (it needs a long-lived process for the MCP host + Mongo driver pool). The agent runtimes can also run in container mode (set `TF_VAR_agentcore_runtime_deployment_mode=container`).

## Request Flow (default — single hop)

1. UI sends `POST /chat` to the Hono API.
2. API `verifyJwt` → `assertJwksAuthConfigured` → `userId = jwt.sub`.
3. API runs the in-process classifier ([`api/src/lib/agent-classifier.ts`](../api/src/lib/agent-classifier.ts)): heuristic token/bigram overlap against the orchestrator's `handoffs:` roster, with a Bedrock Haiku 4.5 fallback when the heuristic margin is below `CLASSIFIER_HEURISTIC_MARGIN`.
4. API reads long-term memory context (hybrid `agent_memory_facts` + `chat_messages`).
5. API invokes the selected specialist's ARN (`AGENTCORE_RUNTIME_ARN_<SPECIALIST>`) via `InvokeAgentRuntime` with `Accept: text/event-stream`.
6. Specialist runtime runs `runChatStream(<specialistId>)`. **All MCP tool calls — Mongo and non-Mongo — go through the AgentCore Gateway** (`AGENTCORE_GATEWAY_URL`); the Gateway's `mongodb-mcp` target then invokes `mongodb-mcp-runtime`. Application runtimes never invoke `MONGODB_MCP_RUNTIME_ARN` / `MONGODB_MCP_RUNTIME_ENDPOINT` directly — those values are Terraform/deploy wiring for the Gateway target only. `MCP_SERVER_URL` is a local-development override.
7. The runtime streams `event: stream` (token), `event: trace` (per trace event), and `event: done` SSE frames back to the API.
8. The API forwards verbatim to the UI (no buffering).

## Request Flow (rollback — two hops)

When `USE_ORCHESTRATOR_RUNTIME=1` is set on the API:

1. API forwards every request to `AGENTCORE_ORCHESTRATOR_ARN` instead of running the in-process classifier.
2. The orchestrator runtime runs `runChatStream("orchestrator")` and classifies internally (Strands Swarm or single-agent depending on `ORCHESTRATOR_MODE`).
3. The orchestrator extracts the specialist target from a `handoff` event and invokes the matching ARN via `invokeSpecialistStream`, which is itself an SSE consumer — so streaming survives the second hop.

This path is kept as a one-release escape hatch in case a regression appears in the in-API classifier; it is not the default.

## Runtime Modes

- **EC2 production (default):** in-API classifier → specialist runtime.
- **EC2 production (rollback):** `USE_ORCHESTRATOR_RUNTIME=1` adds an orchestrator hop.
- **Local development:** in-process Strands path. `ORCHESTRATOR_MODE=swarm` for multi-agent orchestration in-process; the AgentCore runtimes are not invoked unless `AGENTCORE_ORCHESTRATOR_ARN` is set in `.env.live`.

`useOrchestratorSwarm()` is disabled when `AGENTCORE_ORCHESTRATOR_ARN` is present and the API is running in EC2 mode.

## Terraform and Deploy Script Contract

`deploy/terraform/envs/ec2/main.tf` provisions:

- `module.acr_orchestrator` — one orchestrator runtime
- `module.acr_specialists["<id>"]` — `for_each` over agents discovered from `config/agents/*.agent.md`
- `module.mongodb_mcp_runtime` — separate, container-mode MCP runtime

`deploy/terraform/envs/ec2/outputs.tf` exposes runtime ARNs/IDs consumed by `deploy/scripts/deploy-project.sh` and `deploy-agents.sh`.

`deploy/scripts/deploy-project.sh` builds and uploads the AgentCore code artifact before Terraform apply:

- TypeScript entrypoint bundled with esbuild → `agent-runtime-code.js`
- Zipped together with `config/` → `s3://<shared-bucket>/artifacts/agentcore-runtime/<git-sha>/deployment_package.zip`
- Terraform variable `agentcore_code_artifact_prefix` points the four agent runtimes at that artifact

Phase 7 updates runtime env vars (and refreshes artifact reference on update):

- Injects shared dynamic env (Mongo URI, Gateway URL, Memory ID, KB ID, Voyage endpoint)
- Injects specialist runtime ARNs into the orchestrator runtime (for the `USE_ORCHESTRATOR_RUNTIME=1` rollback path)
- Injects each specialist's own `AGENT_ID`

## Artifact Strategy

S3-first artifact management for deployable code/assets:

- Code bundles published to S3 and referenced by `(git-sha, key)` so a redeploy is a Terraform variable change, not an image push.
- Build provenance (source bundle, checksums) lives alongside the zip under the same S3 prefix.
- Deploy orchestration treats S3 as the source-of-truth artifact catalog for `code` mode runtimes.

The MongoDB MCP runtime uses `container` mode because its host is a long-lived MCP server. The `bedrock-ma-use1-mongodb-mcp-runtime-dev` runtime references an ARM64 image in `<account>.dkr.ecr.<region>.amazonaws.com/<project>-mongodb-mcp-<env>`.

## Streaming Behavior

`InvokeAgentRuntime` is called with `Accept: text/event-stream`. The runtime container writes one of three SSE event types per frame:

- `event: stream` — a `ChatStreamPart` JSON (token, tool_call, skill_loaded, …)
- `event: trace` — a `TraceEvent` JSON. `model.text_delta_batch` trace events are throttled to `TRACE_SSE_THROTTLE_MS` (default 100 ms) so the trace channel does not contend with token frames; the full batch still lands in the persisted trace.
- `event: done` — terminal `RuntimeDonePayload`.

The Hono API splices nested trace events under the parent `agentcore.invoke` wrapper via `TraceCollector.attachEventsNested(...)` once `done` arrives, so the persisted Trace document is one merged hierarchy.

## Critical files

| File | Purpose |
|---|---|
| [`api/src/agent-runtime-code.ts`](../api/src/agent-runtime-code.ts) | Single entrypoint for orchestrator + 3 specialist runtimes |
| [`api/src/adapters/agentcore-runtime.ts`](../api/src/adapters/agentcore-runtime.ts) | `invokeAgentRuntime` + retry strategy + nested-trace splicing |
| [`api/src/lib/agent-classifier.ts`](../api/src/lib/agent-classifier.ts) | In-API classifier (heuristic + Haiku fallback) |
| [`api/src/lib/run-chat-stream.ts`](../api/src/lib/run-chat-stream.ts) | Strands single-agent loop shared by all four agent runtimes |
| [`api/src/lib/swarm-chat-stream.ts`](../api/src/lib/swarm-chat-stream.ts) | Strands Swarm path (`USE_ORCHESTRATOR_RUNTIME=1` + `ORCHESTRATOR_MODE=swarm`) |
| [`mcp-runtimes/mongodb-mcp/`](../mcp-runtimes/mongodb-mcp/) | MongoDB MCP runtime (separate codebase, container mode) |
| [`deploy/terraform/modules/agentcore-agent-runtime/`](../deploy/terraform/modules/agentcore-agent-runtime/) | Agent runtime Terraform module (per-agent) |
| [`deploy/terraform/modules/agentcore-mcp-runtime/`](../deploy/terraform/modules/agentcore-mcp-runtime/) | MongoDB MCP runtime Terraform module |
