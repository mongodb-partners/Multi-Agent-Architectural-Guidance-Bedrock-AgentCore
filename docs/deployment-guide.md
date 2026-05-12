# Deployment Guide

> **Audience:** anyone who needs to deploy this system from scratch on a fresh AWS account, or update an existing deployment.

There are three Terraform root configs (and three deploy scripts):

- **Network mode** — `envs/network/` provisions the **shared** VPC + subnets + Atlas PrivateLink Interface VPCE for a region, and publishes the resulting IDs to SSM Parameter Store under `/${SHARED_VPC_NAME}/${AWS_REGION}/`. Run **once per region** with `deploy-network.sh`.
- **Local mode** — runs the API + UI on your laptop. Used for daily development and demos. Some Terraform-provisioned AWS resources are still required (Bedrock KB, Cognito, Secrets Manager). Does **not** consume the shared network.
- **EC2 mode** — full cloud deployment. The frozen baseline. Reads the shared VPC's IDs from SSM and provisions the per-project EC2 / Lambda / AgentCore stack on top, plus a per-cluster Route 53 zone for the Atlas SRV hostname.

---

## 1. Prerequisites

You need:

- AWS CLI v2 (with credentials)
- Terraform ≥ 1.6
- Bun (`curl -fsSL https://bun.sh/install | bash`)
- Python 3.10+ (for `pip install` of UI deps and seed scripts that use it)
- Docker (only for EC2 mode)
- `zip` and `unzip` on PATH (for S3 code-mode artifact)

You need an AWS account with:
- Bedrock model access enabled for `us.anthropic.claude-sonnet-4-6` and `amazon.titan-embed-text-v2:0` (request via the Bedrock console; takes ~15 min for Anthropic models which need a use-case form)
- An IAM user with admin permissions on the deploy account (the deploy script does many cross-service operations)

You need a MongoDB Atlas Organization with:
- An organization API key (public + private)
- An existing Atlas project (the deploy creates a cluster inside it; it does not create the project itself)

---

## 2. The `env.sh` file (credentials and project identity)

Everything starts with [`mongodb-aws-bedrock-multi-agent-framework/env.sh`](../env.sh). This file is **gitignored** and contains live credentials. Sample values are in [`sample-env.sh`](../sample-env.sh).

```bash
# AWS
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="$AWS_REGION"

# Project identity
export ENVIRONMENT="dev"
export PROJECT_NAME="bedrock-ma-use1"

# Shared network identity (optional; defaults to "shared-network" in the scripts).
# Drives the SSM prefix, the network env's Terraform state key, and the Network
# tag on shared VPC + Atlas PL resources. Multiple per-project deployments in
# the same region point at the same SHARED_VPC_NAME.
export SHARED_VPC_NAME="shared-network"

# MongoDB Atlas (Atlas Terraform provider reads these)
export MONGODB_ATLAS_PUBLIC_KEY="..."
export MONGODB_ATLAS_PRIVATE_KEY="..."
export TF_VAR_mongodb_atlas_org_id="..."
export TF_VAR_mongodb_atlas_project_id="..."
export TF_VAR_atlas_project_id="$TF_VAR_mongodb_atlas_project_id"

# Atlas DB
# Both names are project+env-derived in env.sh — no need to set them by hand.
# For PROJECT_NAME=mongodb-multiagent and ENVIRONMENT=dev they resolve to:
#   ATLAS_DB_USER="mongodb_multiagent_dev_user"
#   ATLAS_DB_NAME="mongodb_multiagent_dev"
export TF_VAR_atlas_db_password="..."

# Your laptop's public IP for Atlas IP allow list
export TF_VAR_my_ip=$(curl -s https://checkip.amazonaws.com)/32

# Optional: Voyage AI on SageMaker (embedding override). Leave empty to use
# Bedrock Titan v2 (1024-d). To enable, see configuration-guide.md §3.5:
#   1. Subscribe at https://aws.amazon.com/marketplace/pp/prodview-xj76cqxng4wyw
#   2. ./deploy/scripts/setup-voyage-marketplace.sh --model voyage-3-5-lite
# Then re-run deploy.sh — it provisions the SageMaker endpoint and wires
# VOYAGE_SAGEMAKER_ENDPOINT into both .env.live and all 4 AgentCore runtimes.
export VOYAGE_MODEL_PACKAGE_ARN=""
export VOYAGE_INSTANCE_TYPE="ml.g6.xlarge"  # GPU; CPU instances reject the model package
```

**Always source this file first:**

```bash
source mongodb-aws-bedrock-multi-agent-framework/env.sh
aws sts get-caller-identity   # confirms credentials are live
```

---

## 3. EC2 deployment (the main path)

This is what `deploy/scripts/deploy.sh` does. **Two commands** the first time per region — the shared network has to exist before any per-project EC2 stack can plan:

```bash
cd mongodb-aws-bedrock-multi-agent-framework
source env.sh

# Once per region (creates shared VPC + Atlas PL VPCE; publishes IDs to SSM)
./deploy/scripts/deploy-network.sh --auto-approve

# Per project (consumes shared VPC via SSM)
./deploy/scripts/deploy.sh --auto-approve
```

`deploy.sh` runs a Phase 3b precheck against `/${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id` SSM and **fails fast** with `Run ./deploy/scripts/deploy-network.sh first` if the shared network has not been applied yet.

Total time: ~5 min for `deploy-network.sh` + ~20-25 min for `deploy.sh` (Atlas M10 cluster creation is the slowest step at ~10 min). Subsequent per-project deploys in the same region skip `deploy-network.sh` entirely.

### 3.1 Deployment phases (current script)

```mermaid
flowchart LR
  A[1. Preflight + credentials] --> B[2. Bootstrap + tfvars generation]
  B --> C[3. Build AgentCore code artifact]
  C --> D[4. Terraform apply]
  D --> E[5. Data/auth sub-phases<br/>seed + URI normalize + Cognito users]
  E --> F[6. Docker build/push (or skip)]
  F --> G[7. Runtime env injection + verification]
  G --> H[8. .env.live sync + service restart]
  H --> I[9. Health + smoke validation]
  I --> J[10. deploy-manifest.json]
```

Editable diagram with descriptions: [`diagrams/04-deployment-pipeline.drawio`](diagrams/04-deployment-pipeline.drawio).

| # | Phase | What it does |
|---|---|---|
| 1 | Preflight + credentials | Checks prerequisites (`aws`, `terraform`, `bun`, `python3`, `zip`) and validates AWS + Atlas credentials. |
| 2 | Bootstrap + config generation | Ensures shared S3 bucket exists, writes backend/tfvars for env. |
| 3 | Build AgentCore code artifact | Bundles TS runtime code and uploads zip artifact to S3 (code mode). |
| 4 | Terraform apply | Provisions/updates infrastructure and outputs. |
| 5 | Data/auth sub-phases | Idempotent Mongo seed check, Lambda/API Mongo URI normalization for PrivateLink, Cognito deterministic user seeding. |
| 6 | Docker build/push (optional) | Builds/pushes API/UI images unless `--skip-docker`. |
| 7 | AgentCore runtime env rollout | Updates runtime env vars and verifies deterministic runtime env state. |
| 8 | EC2 env sync + restart | Writes `.env.live`, copies via SSM, pulls images, restarts API/UI services. |
| 9 | Health + smoke validation | Waits for `/health`, then runs authenticated backend smoke checks. |
| 10 | Manifest write | Writes `deploy-manifest.json` with resolved runtime/resource outputs. |

### 3.2 Common deploy issues

| Symptom | Cause | Fix |
|---|---|---|
| `aws sts get-caller-identity` fails | Stale credentials | Re-source `env.sh`, re-issue keys if needed |
| Phase 4 fails with `Operation not allowed` on Bedrock | Model access not granted | Bedrock console → Model Access → request Anthropic Claude Sonnet 4.6 (use-case form, ~15 min) |
| Phase 4 hangs > 15 min on Atlas | Atlas M10 cluster provisioning | Normal. M10 takes 8-12 min on first apply. |
| Phase 6 fails: "no awsPrivateLink connection string" | Atlas PrivateLink not yet active | Re-run after 60s. Atlas takes a moment to attach the AWS endpoint to the cluster. |
| Phase 8: "Role validation failed" | IAM trust policy not yet propagated | The `create-runtime.sh` script retries 10× with 15s backoff. If it still fails, wait 30s and re-run `deploy.sh`. |
| Phase 11 health check fails on `agentcore: unreachable` | Known issue — `ListSessions` health probe requires extra IAM | Non-blocking. Functional memory still works. |
| Deploy exits after Docker push with code 1 | Known `docker-build-push.sh` exit anomaly | Re-run `./deploy/scripts/deploy.sh --auto-approve --skip-docker` to apply/restart with pushed images. |

---

## 4. Local mode

Runs the API + UI on your laptop. Useful for daily dev. Still uses real AWS for Bedrock model calls (so credentials must be valid).

### 4.1 Install + seed

```bash
cd mongodb-aws-bedrock-multi-agent-framework
source env.sh
aws sts get-caller-identity

# First time: provision the supporting AWS resources
./deploy/scripts/deploy-local.sh --auto-approve

# Daily: just start the services
```

`deploy-local.sh` runs Terraform for `envs/local/`, which provisions:
- Bedrock KB + S3 docs
- Cognito user pool
- Secrets Manager Atlas creds

It does NOT create EC2, Lambda, AgentCore runtimes, or Atlas (you can either point at an existing Atlas cluster or use `DEV_MOCK_BACKENDS=1`).

### 4.2 Daily start

**Terminal 1 — API:**

```bash
cd mongodb-aws-bedrock-multi-agent-framework
source env.sh && source .env.live
export PATH="$HOME/.bun/bin:$PATH"
export ORCHESTRATOR_MODE=swarm   # multi-agent in-process
cd api && bun run dev
```

**Terminal 2 — UI:**

```bash
~/.venvs/multiagent-ui/bin/streamlit run ui/app.py --server.headless true
```

Open `http://localhost:8501`.

### 4.3 Fully offline (no AWS, no MongoDB)

```bash
export DEV_MOCK_BACKENDS=1   # CHAT_MODE defaults to live; uses mock Bedrock + fixture MongoDB data
cd api && bun run dev
```

The API uses `data/dev/mongo-fixtures.json` as its database. Useful for E2E tests, demos with no internet, and debugging the agent loop without burning Bedrock tokens.

---

## 5. Code-only update (no Terraform)

After your initial deploy, most code changes don't need a fresh Terraform apply. The fast update path:

```bash
source env.sh

# 1. Build + push new images (~2 min)
./deploy/scripts/docker-build-push.sh "$ECR_API_REPO" "$ECR_UI_REPO" "$AWS_REGION"

# 2. Optionally: re-zip and upload AgentCore runtime artifact
#    (only needed if you changed agent-runtime-server.ts or agent/skill configs)
cd api && bun run build:agentcore-code
zip -r deployment_package.zip agent-runtime-code.js ../config/
aws s3 cp deployment_package.zip "s3://$S3_BUCKET/artifacts/agentcore-runtime/$(git rev-parse --short HEAD)/"

# 3. Pull + restart on EC2 via SSM
aws ssm send-command \
  --region us-east-1 \
  --instance-ids "$EC2_INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters commands='["aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_REGISTRY && docker pull $ECR_API_IMAGE && docker pull $ECR_UI_IMAGE && systemctl daemon-reload && systemctl restart multiagent-api multiagent-ui"]'

# 4. Verify
curl -s "http://$EC2_IP:3000/health" | python3 -m json.tool
```

Total time: 3-5 minutes.

---

## 6. Tearing it down

```bash
source env.sh

# 1. Per-project ec2 stack (always do this first when winding down a project)
./deploy/scripts/destroy.sh --mode ec2 --auto-approve

# 2. Shared VPC + Atlas PrivateLink VPCE (only after EVERY per-project ec2
#    deployment in the region has been destroyed — they read VPC IDs from SSM)
./deploy/scripts/destroy.sh --mode network --auto-approve
```

`--mode ec2` runs `terraform destroy` on `envs/ec2/`. Order matters:
1. AgentCore runtimes (via the `null_resource` destroy provisioners)
2. Lambda
3. EC2 + EIP
4. Atlas cluster (slow — ~5 min)
5. Per-cluster Route 53 zone (`atlas-cluster-dns`)
6. Supporting services (Cognito, ECR, KB, Secrets, CloudWatch)

The shared VPC, Atlas PrivateLink VPCE, and the Atlas-side endpoint binding are **not** touched by `--mode ec2`. They live in `envs/network/` and are only removed by `--mode network`. The Atlas endpoint *service* (`com.amazonaws.vpce.<region>.vpce-svc-...`) is intentionally preserved across destroys — `discover-or-create-pl.sh` reuses it on the next `deploy-network.sh`.

The S3 state bucket is **not** destroyed by default — it has versioning enabled and Terraform state for all three roots lives in it. To delete it manually after destroy:

```bash
aws s3 rm s3://bedrock-ma-use1-dev-483874864688 --recursive
aws s3 rb s3://bedrock-ma-use1-dev-483874864688
```

---

## 7. Verifying a deploy is healthy

After `deploy.sh` completes:

```bash
EC2_IP=$(jq -r '.ec2_instance_public_ip' deploy-manifest.json)

# Health check — should return all "connected"
curl -s "http://$EC2_IP:3000/health" | python3 -m json.tool

# Order tracking smoke test
curl -s -X POST "http://$EC2_IP:3000/chat" \
  -H "Content-Type: application/json" \
  -d '{"message": "Where is my order ORD-1234?", "sessionId": "smoke-test-001", "agentId": "orchestrator"}' \
  -N

# Should stream SSE events: agent_info, token, handoff, done

# UI
open "http://$EC2_IP:8501"
```

Auth-context regression check (API-level Playwright spec):

```bash
API_URL="http://$EC2_IP:3000" \
COGNITO_APP_CLIENT_ID="$(jq -r '.cognito_client_id' deploy-manifest.json)" \
E2E_AUTH_USERNAME="alex@example.com" \
E2E_AUTH_PASSWORD="DemoUser#2026" \
PW_SKIP_WEBSERVER=1 \
cd e2e && bunx playwright test auth-context.spec.ts
```

---

## 8. Operational access

The deploy uses **SSM Session Manager** for remote ops. No SSH key required.

```bash
# Open a shell on EC2
aws ssm start-session --target "$EC2_INSTANCE_ID" --region us-east-1

# Tail logs without SSH
aws ssm send-command \
  --instance-ids "$EC2_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters commands='["journalctl -u multiagent-api -n 100 --no-pager"]' \
  --region us-east-1
```

CloudWatch log groups for full log search:
- `/<project>/<env>/api` — Hono API (e.g. `/mongodb-multiagent/dev/api`)
- `/<project>/<env>/agentcore` — AgentCore runtime traces
- `/<project>/<env>/mcp` — Lambda MCP

---

## 9. Critical files reference

| File | Purpose |
|---|---|
| [`env.sh`](../env.sh) | Live credentials + project identity (gitignored) |
| [`sample-env.sh`](../sample-env.sh) | Template for `env.sh` |
| [`.env.live`](../.env.live) | Generated by Phase 9. Holds runtime config (gitignored). |
| [`deploy/scripts/deploy-network.sh`](../deploy/scripts/deploy-network.sh) | Shared VPC + Atlas PrivateLink VPCE (run once per region) |
| [`deploy/scripts/deploy.sh`](../deploy/scripts/deploy.sh) | Per-project EC2 deploy orchestrator |
| [`deploy/scripts/deploy-local.sh`](../deploy/scripts/deploy-local.sh) | Local mode supporting infra |
| [`deploy/scripts/destroy.sh`](../deploy/scripts/destroy.sh) | Tear down (`--mode local`/`ec2`/`network`) |
| [`deploy/scripts/docker-build-push.sh`](../deploy/scripts/docker-build-push.sh) | Code-only image rebuild |
| [`deploy/terraform/envs/network/main.tf`](../deploy/terraform/envs/network/main.tf) | Shared VPC + Atlas PL VPCE root module |
| [`deploy/terraform/envs/ec2/main.tf`](../deploy/terraform/envs/ec2/main.tf) | Per-project EC2 mode root module (consumes shared VPC via SSM) |
| [`deploy/terraform/envs/local/main.tf`](../deploy/terraform/envs/local/main.tf) | Local mode root module |
| [`deploy/terraform/modules/atlas-privatelink/`](../deploy/terraform/modules/atlas-privatelink/) | AWS Interface VPCE + Atlas-side binding + CIDR-scoped SG (envs/network) |
| [`deploy/terraform/modules/atlas-cluster-dns/`](../deploy/terraform/modules/atlas-cluster-dns/) | Per-cluster Route 53 private zone + wildcard CNAME (envs/ec2) |
| [`deploy/terraform/modules/agentcore-agent-runtime/`](../deploy/terraform/modules/agentcore-agent-runtime/) | The 4-runtime module (CLI-provisioned) |
| [`deploy-manifest.json`](../deploy-manifest.json) | Output: every ARN/ID/URL/IP from last deploy |
