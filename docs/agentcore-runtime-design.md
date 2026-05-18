# AgentCore Runtime Design (4-Runtime)

## Overview

Production EC2 mode uses four AgentCore runtimes:

- `orchestrator`
- `troubleshooting`
- `order-management`
- `product-recommendation`

Each runtime behavior is selected through `AGENT_ID`. Runtime artifact mode is configurable:

- `code` (default): S3 zip direct-code deployment (`NODE_22`)
- `container`: ARM64 container image (`api/Dockerfile.agentcore`) via ECR

In direct-code mode, the deployed entrypoint is `agent-runtime-code.js` (bundled from `api/src/agent-runtime-code.ts`).

## Request Flow

1. API `POST /chat` receives a request.
2. API reads/writes AgentCore Memory before and after model execution.
3. API invokes `AGENTCORE_ORCHESTRATOR_ARN` via `InvokeAgentRuntime`.
4. Orchestrator runtime runs `runChatStream("orchestrator")`.
5. Orchestrator extracts specialist target from `handoff` and invokes the corresponding specialist runtime ARN:
   - `AGENTCORE_RUNTIME_ARN_TROUBLESHOOTING`
   - `AGENTCORE_RUNTIME_ARN_ORDER_MANAGEMENT`
   - `AGENTCORE_RUNTIME_ARN_PRODUCT_RECOMMENDATION`
6. Specialist runtime executes one Strands agent and returns a full response payload.
7. API emits SSE response to UI (single token burst in runtime mode).

## Runtime Modes

- **EC2 production:** AgentCore runtime routing (no in-process Swarm).
- **Local development:** in-process Strands Swarm remains available (`ORCHESTRATOR_MODE=swarm` with mock/local settings).

`useOrchestratorSwarm()` is disabled when `AGENTCORE_ORCHESTRATOR_ARN` is present.

## Terraform and Deploy Script Contract

`deploy/terraform/envs/ec2/main.tf` provisions four runtime module instances:

- `module.acr_orchestrator`
- `module.acr_troubleshooting`
- `module.acr_order_management`
- `module.acr_product_recommendation`

`deploy/terraform/envs/ec2/outputs.tf` exposes runtime ARNs/IDs consumed by `deploy/scripts/deploy-project.sh`.

`deploy/scripts/deploy-project.sh` now builds and uploads the AgentCore code artifact before Terraform apply:

- TypeScript entrypoint is bundled with esbuild
- zip is uploaded to `s3://<shared-bucket>/artifacts/agentcore-runtime/<git-sha>/deployment_package.zip`
- Terraform variable `agentcore_code_artifact_prefix` points runtimes at that artifact

Phase 6b updates runtime env vars (and refreshes artifact reference on update):

- injects shared dynamic env (Mongo URI, Gateway URL, Memory ID, KB ID)
- injects specialist runtime ARNs into orchestrator runtime

## Artifact Strategy (Design Direction)

Target direction is **S3-first artifact management** for deployable code/assets.

- Lambda/package artifacts should be published to S3 and referenced by key/version.
- Build provenance (source bundle, build metadata, checksums) should be recorded in S3.
- Deploy orchestration should treat S3 as the source-of-truth artifact catalog.

### AgentCore Runtime Support (Current)

AgentCore runtime now supports both:

- `agentRuntimeArtifact.codeConfiguration` (S3 direct code)
- `agentRuntimeArtifact.containerConfiguration` (ECR container)

This stack defaults to direct code mode, while retaining container mode as a fallback.

## Non-Streaming Behavior

`InvokeAgentRuntime` is currently used as a request/response call. The API converts the full runtime response into one SSE `token` event to keep client compatibility.
