# E2E Smoke Tests

Run these against an already deployed AWS stack after `./deploy/deploy-full-with-privatelink.sh`.

## Full post-deploy smoke

```bash
source .env
python3 e2e-smoke/post-deploy-smoke.py
```

This checks:

- `/health` dependencies: `mongodb`, `longTermMemory`, `agentcore`, `mcpServer`, and `bedrockKnowledgeBase` when a KB is configured.
- `/agents` metadata for all four configured agents.
- Manifest alignment for `embeddings_provider`, exact Voyage model package, and SoW alignment.
- SageMaker endpoint existence and `InService` status when `EMBEDDINGS_PROVIDER=voyage`.
- Terraform outputs for Voyage endpoint and Bedrock KB PrivateLink.
- Bedrock KB `ACTIVE` status with Atlas `-pl` endpoint and `endpointServiceName`.
- Authenticated `/chat` flows for `orchestrator`, `order-management`, `product-recommendation`, and `troubleshooting`.

Useful overrides:

```bash
DEPLOY_MANIFEST_PATH=deploy-manifest.json python3 e2e-smoke/post-deploy-smoke.py
SKIP_TERRAFORM_CHECKS=1 python3 e2e-smoke/post-deploy-smoke.py
SKIP_CHAT_CHECKS=1 python3 e2e-smoke/post-deploy-smoke.py
E2E_USER=alex@example.com E2E_PASS='DemoUser#2026' python3 e2e-smoke/post-deploy-smoke.py
```

## Legacy deep smoke

```bash
source .env
bash e2e-smoke/e2e-smoke.sh
```

The shell smoke keeps older detailed checks around vector-search traces and long-term memory recall.

To run the focused long-term-memory vector/hybrid suite after the broad shell smoke:

```bash
RUN_LTM_DEEP=1 bash e2e-smoke/e2e-smoke.sh
```

## Long-term memory vector smoke

```bash
source .env
bash e2e-smoke/ltm/ltm-smoke.sh
```

This suite writes fresh memory, recalls it across sessions, fetches persisted traces, and fails unless `agent_memory_facts` and `chat_messages` participate in hybrid/vector retrieval.

## Failure drills

```bash
source .env
python3 e2e-smoke/failure-drills/run_all.py
```

The failure-drill suite covers auth edge cases, CloudWatch alarm state transitions, a non-destructive Bedrock throttling alarm drill, Mongo outage/recovery, AgentCore runtime failure/recovery, and API image rollback/restore. See `failure-drills/README.md` for individual drill commands and safety notes.
