# E2E Smoke Tests

Run these against an already deployed AWS stack after `deploy/scripts/deploy.sh`.

## Full post-deploy smoke

```bash
source env.sh
python3 e2e-smoke/post-deploy-smoke.py
```

This checks:

- `/health` dependencies for MongoDB, AgentCore, and MCP.
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
source env.sh
bash e2e-smoke/e2e-smoke.sh
```

The shell smoke keeps older detailed checks around vector-search traces and long-term memory recall.
