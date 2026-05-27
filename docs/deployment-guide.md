# Deployment Guide

> **Audience:** anyone who needs to deploy this system from scratch on a fresh AWS account, or update an existing deployment.
>
> **Single source of truth.** This document supersedes the older `DEV_STATUS.md` operational snapshot and `deploy/SETUP.md` setup guide; both have been folded in. The companion references in [`reference/`](reference/) hold the exhaustive catalogs (env vars, TF modules, SSM parameters, smoke tests, deploy scripts) so this guide stays prose-focused.

There are four Terraform root configs (and matching deploy scripts):

- **Network mode** — `envs/network/` provisions the **shared** VPC + subnets + the Atlas connectivity primitive matching `NETWORK_MODE` (PrivateLink Interface VPCE in privatelink mode; VPC peering accepter + Atlas-side `mongodbatlas_network_peering` in peering mode), and publishes the resulting IDs to SSM Parameter Store under `/${SHARED_VPC_NAME}/${AWS_REGION}/` (including a `network_mode` canary so downstream stacks refuse to plan against a different mode). Run **once per AWS account + region** with `deploy-network.sh`.
- **Shared mode** — `envs/shared/` provisions the **shared observability + embeddings** stack: the Voyage SageMaker endpoint, all CloudWatch log groups (`/${SHARED_RESOURCE_PREFIX}/<env>/{api,ui,mcp,agentcore,otel,otel-atlas}`), the four operational dashboards (`${SHARED_RESOURCE_PREFIX}-{fleet,mongo,cost,atlas}-<env>`), fleet + atlas alarms, metric filters, the Logs Insights query library, and the account-scoped Bedrock invocation logging configuration. Publishes its outputs to the same SSM prefix under `voyage_sagemaker_endpoint_name`, `cw_*_log_group`, and `bedrock_*_log_group` keys. Run **once per AWS account + region + environment** with `deploy-shared.sh`. Singleton — multiple per-project `envs/ec2` deployments share the resulting resources.
- **Local mode** — `envs/local/` + `deploy-local.sh`. Provisions **partial** AWS support infra on your laptop path: Atlas M10, Bedrock KB, AgentCore Memory store, and local-prefixed CloudWatch log groups. Does **not** consume the shared network or shared stack. Does **not** provision EC2, AgentCore runtimes, Cognito, or a runnable chat stack by itself — you still need `AGENTCORE_ORCHESTRATOR_ARN` + JWKS from a full EC2 deploy (see [§ 4](#4-local-mode-partial-infra-only)).
- **EC2 mode** — full cloud deployment. The frozen baseline. Reads the shared VPC's IDs and the shared SageMaker endpoint + log groups from SSM, then provisions the per-project EC2 / AgentCore Runtime / MongoDB MCP Runtime stack on top, plus a per-cluster Route 53 zone for the Atlas SRV hostname and the AWS service VPC endpoints required by the VPC-mode MongoDB MCP runtime (ECR API, ECR Docker, S3 gateway, CloudWatch Logs). Set `TF_VAR_create_agentcore_runtime_vpc_endpoints=false` when those singleton endpoints already exist in the shared VPC; EC2 mode will reuse them and ensure this deployment's security groups can reach them. The legacy Lambda MongoDB MCP host (and its Terraform module) was deleted in CLIENT_REVIEW Phase 7e. MongoDB MCP is reached through the AgentCore Gateway target.

**Apply order (clean account):** `network → shared → ec2`. The single entrypoints `deploy-full-with-privatelink.sh` (default mode) and `deploy-full-with-vpc-peering.sh` (alternative) both probe SSM canaries for each upstream stack and run the missing ones automatically; pass `--skip-network` / `--skip-shared` to bypass the canary probes when you already know they are applied. Tear down in reverse: `destroy.sh --mode ec2 → shared → network`. **PrivateLink and VPC peering are mutually exclusive per account+region** — switching modes requires destroying everything and re-running the matching orchestrator.

**Migrating an existing pre-2026-05 deployment:** if you already applied `envs/ec2` with the old module layout (SageMaker + log groups + dashboards + Bedrock invocation logging all inside `envs/ec2`), tear down with `./deploy/scripts/destroy.sh --mode ec2 --auto-approve` and re-run the orchestrator. The shared-stack split changed resource names, so in-place state surgery would not help anyway; the SSM canaries (`/<SHARED_VPC_NAME>/<region>/cw_api_log_group` etc.) drive the re-create automatically.

**Companion references** — open these alongside this guide:

- [`reference/env-vars.md`](reference/env-vars.md) — every environment variable read by the stack, with defaults and the file that consumes it.
- [`reference/terraform-modules.md`](reference/terraform-modules.md) — every reusable TF module, with inputs, outputs, and the envs that consume each.
- [`reference/ssm-parameters.md`](reference/ssm-parameters.md) — the cross-stack SSM contract (network → shared → ec2).
- [`reference/deploy-scripts.md`](reference/deploy-scripts.md) — every shell script under `deploy/`, with flags and side-effects.
- [`reference/smoke-tests.md`](reference/smoke-tests.md) — post-deploy verification harness catalog.
- [`status/debugging.md`](status/debugging.md) — when something goes wrong.

---

## 1. Prerequisites

You need:

- AWS CLI v2 (with credentials). The bundled service model must include the AgentCore Gateway MCP target shape (`targetConfiguration.mcp.mcpServer` + `credentialProvider.iamCredentialProvider`); AWS CLI 2.28.x and earlier ship a stale `botocore` and will fail at the gateway-target apply step. Preflight `pf_check_aws_cli_agentcore_gateway_model` is the source of truth — see [`docs/deployment-preflight-checks.md`](deployment-preflight-checks.md#aws-cli-agentcore-gateway-model).
- Terraform ≥ 1.6
- Bun (`curl -fsSL https://bun.sh/install | bash`)
- Python 3.10+ (for `pip install` of UI deps and seed scripts that use it)
- Docker (only for EC2 mode)
- `zip` and `unzip` on PATH (for S3 code-mode artifact)

You need an AWS account with:
- Bedrock model access enabled for **all** models referenced by `config/agents/*.agent.md` and the embedding/extraction defaults. Today that is `us.anthropic.claude-sonnet-4-6` (troubleshooting + product-recommendation), `us.anthropic.claude-haiku-4-5-20251001-v1:0` (orchestrator + order-management + LTM fact-extractor + classifier fallback), and `amazon.titan-embed-text-v2:0` (Voyage fallback). Request via the Bedrock console; takes ~15 min for Anthropic models which need a use-case form. When you change an agent model, enable access for the new one **first**.
- AWS credentials with the permissions in [`deploy/iam/policy.json`](../deploy/iam/policy.json). This can be an **IAM user** (static long-lived keys) or — for environments that prohibit IAM users — an **IAM Role assumed via STS** (see [§ 2b](#2b-sts--sso-credentials-no-iam-user) below). The same policy document covers both cases.

> **Preflight is your friend.** Every deploy script automatically runs the [`_preflight-checks.sh`](../deploy/scripts/_preflight-checks.sh) module before mutating AWS state — it validates your `.env` quality, AWS auth, IAM permissions (incl. SCPs), Bedrock model access, Atlas API key scope, project name length, network egress, local tool versions, Docker resources, and ~25 other things. If something is wrong it prints a structured failure envelope with plain-English fix steps, machine-readable `ai-fix-hint`s, and an anchor in [`docs/deployment-preflight-checks.md`](deployment-preflight-checks.md). Override with `PREFLIGHT_SKIP=<id>,<id>` (or `PREFLIGHT_SKIP=*`); preview the run with `PREFLIGHT_DRY_RUN=1`.

You need a MongoDB Atlas Organization with:
- An organization API key (public + private)
- An existing Atlas project (the deploy creates a cluster inside it; it does not create the project itself)

---

## 2. The `.env` file (credentials and project identity)

Everything starts with [`.env`](../.env) at the repo root. Copy [`.env.sample`](../.env.sample) to `.env` and fill in credentials — **`.env` is gitignored; never commit it.**

> **`AUTH_MODE` (iam | sts)** controls which credential block the deploy scripts validate. Default is `iam` for backward compatibility; set `AUTH_MODE=sts` when your account prohibits IAM users. The shared validator at [`deploy/scripts/_aws-auth.sh`](../deploy/scripts/_aws-auth.sh) refuses to proceed if the resolved caller ARN doesn't match the declared mode. See § 2b for the STS path; see [`deploy/iam/README.md`](../deploy/iam/README.md) for trust-policy setup.

```bash
# Declare HOW this deploy authenticates. Default: iam.
export AUTH_MODE="iam"   # change to "sts" if your account disallows IAM users

# AWS — populate the block matching AUTH_MODE
# ── AUTH_MODE=iam : static IAM user keys ────────────────────────────────
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
# ── AUTH_MODE=sts : STS / SSO temporary credentials ─────────────────────
# Obtain via: aws sts assume-role / aws configure export-credentials / aws sso login
# export AWS_ACCESS_KEY_ID="ASIA..."        # starts with ASIA for temp creds
# export AWS_SECRET_ACCESS_KEY="..."
# export AWS_SESSION_TOKEN="..."            # required for all STS-issued keys
# ── AUTH_MODE=sts : named AWS profile (SSO or assume-role) ──────────────
# export AWS_PROFILE="uat-deploy-role"      # profile defined in ~/.aws/config
# ────────────────────────────────────────────────────────────────────────
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
# Both names are project+env-derived in .env — no need to set them by hand.
# For PROJECT_NAME=mongodb-multiagent and ENVIRONMENT=dev they resolve to:
#   ATLAS_DB_USER="mongodb_multiagent_dev_user"
#   ATLAS_DB_NAME="mongodb_multiagent_dev"
export TF_VAR_atlas_db_password="..."

# Your laptop's public IP for Atlas IP allow list
export TF_VAR_my_ip=$(curl -s https://checkip.amazonaws.com)/32

# Embeddings. Titan works without a Voyage ARN. To use Voyage, run:
#   ./deploy/scripts/setup-voyage-marketplace.sh --model voyage-multimodal-3
# (or voyage-multimodal-3.5 — the only two supported listings; see
# docs/reference/voyage.md)
export EMBEDDINGS_PROVIDER="titan" # titan | voyage
export VOYAGE_MODEL_PACKAGE_ARN="" # required only when EMBEDDINGS_PROVIDER=voyage
export VOYAGE_MARKETPLACE_MODEL="voyage-multimodal-3"
export VOYAGE_INSTANCE_TYPE="ml.g6.xlarge" # GPU; CPU instances reject the model package
```

**Always source this file first:**

```bash
source mongodb-aws-bedrock-multi-agent-framework/.env
aws sts get-caller-identity   # confirms credentials are live
```

---

## 2b. STS / SSO credentials (no IAM user)

If your AWS account policy prohibits creating IAM users (a common enterprise security control), you can authenticate entirely through **STS-issued temporary credentials** tied to an IAM Role. The deploy scripts accept any of these three mechanisms — no code changes required.

### What permissions the role needs

The role needs **two** IAM documents:

1. **Permissions policy** — [`deploy/iam/policy.json`](../deploy/iam/policy.json), attached to the role as a managed or inline policy. Grants the AWS API actions used by `deploy-network.sh`, `deploy-project.sh`, and `deploy-agents.sh`.
2. **Trust policy** — [`deploy/iam/sts-trust-policy.json`](../deploy/iam/sts-trust-policy.json), set as the role's `AssumeRolePolicyDocument`. Defines which principals (same-account IAM, AWS IAM Identity Center / SSO, cross-account, GitHub Actions OIDC) are allowed to call `sts:AssumeRole`.

Trim `sts-trust-policy.json` to the SIDs that apply to your environment and replace the placeholders (`ACCOUNT_ID`, `PERMISSION_SET_NAME`, `TRUSTED_ACCOUNT_ID`, etc.) before creating the role. End-to-end setup with both files, including the recommended `--max-session-duration` for 20-25 min Terraform applies, is documented in [`deploy/iam/README.md` → STS-assumed role setup](../deploy/iam/README.md#sts-assumed-role-setup).

### Option A — Export STS env vars directly

Obtain short-lived keys (valid 1–12 h depending on your org's session duration) and export them into your shell before sourcing `.env`:

```bash
# via AWS CLI assume-role
CREDS=$(aws sts assume-role \
  --role-arn "arn:aws:iam::<ACCOUNT_ID>:role/<UAT_DEPLOY_ROLE>" \
  --role-session-name "multiagent-uat-deploy" \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo "$CREDS"     | python3 -c "import json,sys; print(json.load(sys.stdin)['Credentials']['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | python3 -c "import json,sys; print(json.load(sys.stdin)['Credentials']['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo "$CREDS"     | python3 -c "import json,sys; print(json.load(sys.stdin)['Credentials']['SessionToken'])")

source .env
aws sts get-caller-identity   # should show the assumed role ARN
./deploy/deploy-full-with-privatelink.sh --auto-approve
```

Or, if you already have a profile configured, export credentials from it:

```bash
eval "$(aws configure export-credentials --profile <SSO_PROFILE> --format env)"
# exports AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
```

### Option B — Use `AWS_PROFILE` (SSO or named assume-role profile)

Configure an SSO or assume-role profile in `~/.aws/config`, log in once, then set `AWS_PROFILE` in `.env`:

```ini
# ~/.aws/config
[profile uat-deploy-role]
sso_start_url   = https://my-org.awsapps.com/start
sso_region      = us-east-1
sso_account_id  = <ACCOUNT_ID>
sso_role_name   = <UAT_DEPLOY_ROLE>
region          = us-east-1
```

```bash
aws sso login --profile uat-deploy-role   # opens browser, exchanges OIDC token for STS session

# In .env (replace the AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY lines):
export AWS_PROFILE="uat-deploy-role"
export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="$AWS_REGION"
```

Terraform and all `aws` CLI calls in the deploy scripts inherit `AWS_PROFILE` from the environment automatically — no other changes needed.

### Credential expiry

STS sessions expire (typically 1–8 h). If a deploy fails with `ExpiredTokenException` mid-run, re-authenticate and restart from the failed phase:

```bash
# Re-run the full deploy — it is idempotent; completed phases are skipped.
aws sso login --profile uat-deploy-role   # or re-export env vars from Option A
./deploy/deploy-full-with-privatelink.sh --auto-approve --skip-network
```

---

## 3. EC2 deployment (the main path)

This is what `deploy/deploy-full-with-privatelink.sh` does. It handles all three phases automatically — running `deploy-network.sh` only when the shared VPC does not yet exist in SSM, then `deploy-shared.sh` only when its `cw_api_log_group` canary is missing, then `deploy-project.sh`:

```bash
cd mongodb-aws-bedrock-multi-agent-framework
source .env

# Handles everything: network (first time) + shared (first time) + project stack
./deploy/deploy-full-with-privatelink.sh --auto-approve

# Post-deploy smoke runs in deploy-project.sh Phase 11 (skip: --skip-smoke on full deploy)
# Manual re-run: source .env && python3 e2e-smoke/post-deploy-smoke.py
```

When the script finishes, open the **UI URL** printed in the deploy summary (`ec2_ui_url`, Streamlit on port 8501) and sign in with the seeded Cognito user.

Alternatively, run the phases manually:

```bash
# Once per region (creates shared VPC + Atlas PL VPCE; publishes IDs to SSM)
./deploy/scripts/deploy-network.sh --auto-approve
# Then apply the shared observability + embeddings stack — singleton per
# (account, region, environment). Idempotent; safe to re-run.
./deploy/scripts/deploy-shared.sh --auto-approve

# Per project (consumes shared VPC via SSM)
./deploy/scripts/deploy-project.sh --auto-approve
```

`deploy-project.sh` runs a Phase 3b precheck against `/${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id` SSM and **fails fast** with `Run ./deploy/scripts/deploy-network.sh first` if the shared network has not been applied yet, plus a Phase 4c precheck against `voyage_sagemaker_endpoint_name` that fails fast with `Run ./deploy/scripts/deploy-shared.sh first` if the shared observability stack is missing. When `EMBEDDINGS_PROVIDER=voyage`, the same precheck also refuses to continue if the shared stack provisioned no SageMaker endpoint (sentinel value `_empty_`).

Total time: ~5 min for `deploy-network.sh` + ~8 min for `deploy-shared.sh` (SageMaker endpoint creation is the slowest step at ~6–10 min) + ~20-25 min for `deploy-project.sh` (Atlas M10 cluster creation is the slowest step at ~10 min). `deploy-full-with-privatelink.sh` skips `deploy-network.sh` and `deploy-shared.sh` automatically on subsequent runs when their respective canaries already exist in SSM.

### <a id="vpc-peering-mode"></a>VPC peering mode (alternative to PrivateLink)

The framework supports **VPC peering** as an alternative connectivity mode for MongoDB Atlas. Use this when PrivateLink is unavailable (e.g. region/account constraints) or when you prefer routable IP connectivity over a service-endpoint model. The choice is binary per account: **PrivateLink and VPC peering are mutually exclusive — there is no hybrid mode**, and switching between them requires destroy + redeploy.

**Use the matching orchestrator:**

```bash
# Set in .env (or rely on the orchestrator to export it)
export NETWORK_MODE=peering
export ATLAS_PEERING_CIDR="192.168.248.0/21"   # Atlas default, non-overlapping

./deploy/deploy-full-with-vpc-peering.sh --auto-approve
```

The orchestrator hard-exports `NETWORK_MODE=peering` before delegating, runs the same 3-phase flow (network → shared → ec2), and refuses to proceed if SSM canary `/{SHARED_VPC_NAME}/{REGION}/network_mode` already says `privatelink` (see `./deploy/scripts/destroy.sh` to switch).

**What's different vs PrivateLink mode:**

| Layer | PrivateLink mode | VPC peering mode |
|---|---|---|
| Atlas-side networking (`envs/network`) | Interface VPCE + Atlas endpoint service | AWS-side VPC peering accepter + route entries in both route tables; Atlas-side `mongodbatlas_network_peering` + project IP access list scoped to the VPC CIDR; **Atlas Private DNS for Peering** auto-enabled via Admin API so `-pri.mongodb.net` SRV resolves to private peering IPs |
| Runtime `MONGODB_URI` (`envs/ec2`) | Atlas `awsPrivateLink` direct multi-host URI with `tlsAllowInvalidHostnames=true` | `connectionStrings.privateSrv` (when Atlas Private DNS for Peering is on) else `connectionStrings.private` (multi-host non-SRV). Peering hostnames ARE in the cluster cert SAN — no `tlsAllowInvalidHostnames` |
| Bedrock KB ingestion path | PL NLB + Atlas VPCE (partner-validated, recommended) | **EXPERIMENTAL** peering NLB whose targets are Atlas mongod private peering IPs discovered via `dig` from EC2 over SSM (`modules/bedrock-kb-peering`). Bedrock's MongoDB driver may reject the cluster TLS cert when reached through NLB-over-peering — see [`modules/bedrock-kb-peering/README.md`](../deploy/terraform/modules/bedrock-kb-peering/README.md) |
| SG egress | `0.0.0.0/0` on port 27017 + 1024-65535 (constrained by VPCE routing) | Narrowed to `ATLAS_PEERING_CIDR` for defense-in-depth |

**Operational caveats (peering KB ingestion):**

* **mongod IP drift:** the peering NLB targets are pinned at deploy time. Atlas maintenance / scaling / failover can rotate mongod private IPs and silently break KB ingestion. Recovery: re-run `./deploy/deploy-full-with-vpc-peering.sh --skip-network --skip-shared` to re-`dig` and re-pin targets.
* **TLS failure recovery:** if the experimental NLB-over-peering KB path fails TLS validation, the ingestion job will fail terraform apply with the driver error in `failureReasons` (we grep for `tls|certificate|ssl|handshake|hostname` and print a remediation banner). The **only** remediation is to destroy the peering stack and redeploy in PrivateLink mode (PL and peering are mutually exclusive). Alternative degradation: set `TF_VAR_enable_kb_peering=false` to keep peering for runtime traffic but use public Atlas SRV for KB ingestion (privacy regression — KB no longer end-to-end private).
* **CIDR conflicts:** `ATLAS_PEERING_CIDR` must not overlap `VPC_CIDR`. The orchestrator runs a Python pre-flight before plan; `envs/network` has a Terraform `check` block as a second line of defense.

### 3.0 Agent-only redeployment (partial deploy)

When only `config/agents/*.agent.md` or `config/skills/` change — no infra, API, or UI changes — use `deploy/deploy-agents.sh`. It skips Atlas, EC2, KB, Cognito, Docker image builds, `.env.live` sync, and API restart.

```bash
source .env
./deploy/deploy-agents.sh --auto-approve
```

**What it does (~3-5 min):**
1. Discovers agents from `config/agents/*.agent.md` (`id: orchestrator` is the orchestrator; all others are specialists)
2. Generates the orchestrator handoff roster from the discovered specialists at runtime
3. Writes `deploy/terraform/envs/ec2/agents.auto.tfvars.json` (drives `module.acr_specialists` `for_each`)
4. Rebuilds the AgentCore code artifact zip and uploads to S3
5. `terraform apply -target=module.acr_specialists -target=module.acr_orchestrator`
6. Injects dynamic env vars into all runtimes; verifies them
7. Calls `POST /internal/agents/refresh` on the live API with the current config snapshot and specialist ARN map, so the in-API classifier drops deleted agents and sees new/updated agents without rebuilding the API image
8. Optional smoke test against the live EC2 API

**Adding a new specialist agent** end-to-end:
1. Create `config/agents/<new-id>.agent.md`.
2. Run `./deploy/deploy-agents.sh --auto-approve` — terraform provisions `module.acr_specialists["<new-id>"]`; env injection adds `AGENTCORE_RUNTIME_ARN_<NEW_ID>` to the orchestrator, and the API refresh endpoint swaps in the generated handoff roster.

**Removing a specialist:** delete the `.agent.md` and re-run. The script detects the pending terraform destroy and requires typed confirmation (bypass with `--allow-destroy`).

**Prerequisite:** `deploy-full-with-privatelink.sh` must have been run at least once (`deploy-manifest.json` + `backend.hcl` required).

**One-time bootstrap for older deployments:** if the live API predates `POST /internal/agents/refresh`, run `./deploy/deploy-api.sh` once. After that, agent add/update/delete changes should not require an API image rebuild.

### 3.0b API-only redeployment (partial deploy)

When only API code, API-bundled config, or API runtime env wiring changes — no Terraform, UI, or AgentCore runtime changes — use `deploy/deploy-api.sh`.

```bash
source .env
./deploy/deploy-api.sh
```

**What it does (~3-5 min):**
1. Reads existing Terraform outputs; it does not run `terraform apply`
2. Discovers the current `config/agents/*.agent.md` roster
3. Builds and pushes only the API Docker image to ECR
4. Regenerates `.env.live`, including the API PrivateLink MongoDB URI and all `AGENTCORE_<SPECIALIST_ID>_ARN` values
5. Syncs `.env.live` to EC2 with SSM, pulls only the API image, and restarts only `multiagent-api`
6. Runs the deterministic backend smoke

Use `./deploy/deploy-api.sh --skip-docker` to only re-sync env and restart the API after an already-pushed image.

### 3.0c UI-only redeployment (partial deploy)

When only `ui/` changed:

```bash
source .env
./deploy/deploy-ui.sh
./deploy/deploy-ui.sh --skip-docker --skip-smoke
```

Rebuilds/pushes the UI image and restarts `multiagent-ui` only. Does **not** regenerate `.env.live` — run `deploy-api.sh` first if Cognito or API URL env vars changed.

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
| 1 | Preflight + credentials | Checks prerequisites (`aws`, `terraform`, `bun`, `python3`, `zip`) and validates AWS + Atlas credentials via [`deploy/scripts/_aws-auth.sh`](../deploy/scripts/_aws-auth.sh) → `validate_aws_auth`. The validator declares `AUTH_MODE` (`iam` or `sts`), enforces the matching env-var shape, and asserts the resolved caller ARN matches the declared mode — catching profile-override drift before any AWS write happens. Prints a one-line banner: `[auth] mode=<mode> arn=<caller-arn>`. |
| 2 | Bootstrap + config generation | Ensures shared S3 bucket exists, writes backend/tfvars for env. |
| 3 | Build AgentCore code artifact | Bundles TS runtime code and uploads zip artifact to S3 (code mode). |
| 4 | Terraform apply | Provisions/updates infrastructure and outputs. |
| 5 | Data/auth sub-phases | Idempotent Mongo seed check, API Mongo URI normalization for PrivateLink, Cognito deterministic user seeding. The MCP runtime gets its `MONGODB_URI` directly from Terraform, no script-level patching needed. |
| 6 | Docker build/push (optional) | Builds/pushes API/UI images unless `--skip-docker`. |
| 7 | AgentCore runtime env rollout | Updates runtime env vars and verifies deterministic runtime env state. |
| 8 | EC2 env sync + restart | Writes `.env.live`, copies via SSM, pulls images, restarts API/UI services. |
| 9 | Health + smoke validation | Waits for `/health`, then runs authenticated backend smoke checks. |
| 10 | Manifest write | Writes `deploy-manifest.json` with resolved runtime/resource outputs. Includes an `auth` block (`{mode, caller_arn}`) recording how this deploy authenticated — useful for post-deploy audit (`auth.caller_arn` can be diffed against the current `sts:GetCallerIdentity` to detect a stale manifest from a different principal). |

### 3.2 Observability stack (deployed by default)

Observability is **split across two stacks:**

- **`envs/shared`** (via `deploy-shared.sh`) — CloudWatch log groups (`api`, `ui`, `mcp`, `agentcore`, `otel`, `otel-atlas`), fleet/mongo/cost dashboards + alarms, Bedrock invocation logging (`/aws/bedrock/invocations`).
- **`envs/ec2`** (via `deploy-project.sh`) — GenAI observability / X-Ray Transaction Search (`enable_genai_observability`), ADOT collector sidecar (`enable_adot_collector`), per-project Atlas metrics dashboard when opted in.

Key Terraform variables (defaults tuned for low-volume dev / staging):

| Terraform variable | Default | What it does | Cost driver |
|---|---|---|---|
| `enable_genai_observability` | `true` | `aws/spans` log group, X-Ray Transaction Search, AgentCore Memory/Gateway vended log delivery | Span ingestion volume |
| `span_sampling_percent` | `100` | What % of received spans become indexed trace summaries (raw spans always land in `aws/spans`) | Indexed-trace fee |
| `enable_bedrock_invocation_logging` | `true` | `/aws/bedrock/invocations` log group, KMS-encrypted, Data Protection Policy attached. **Body logging OFF**. | Metadata records only |
| `log_prompt_bodies` | `false` | When true, raw prompts + completions land in invocation logs (still PII-masked) | Big bump — bodies dwarf metadata |
| `log_embedding_bodies` | `false` | When true, raw embedding inputs land in invocation logs | Same |
| `enable_adot_collector` | `true` | ADOT sidecar on EC2 + `/<SHARED_RESOURCE_PREFIX>/<env>/otel` log group | OTLP egress + storage |
| `enable_fleet_dashboards` | `true` | 3 dashboards + 7 alarms + SNS topic + query library (**`envs/shared`**) | Negligible |
| `alarm_email` | `""` | Subscribes a single email address to the alarms SNS topic | Free |
| `enable_atlas_metrics` | `false` | **Phase 4 opt-in.** ADOT scrapes Atlas Prometheus → `MongoDB/Atlas` CloudWatch namespace; adds Atlas dashboard + 2 alarms | Custom metrics + secret |

**Important caveats:**

- **`awscc` provider.** `modules/cloudwatch-genai` uses `awscc_xray_transaction_search_config` because the legacy `aws` provider does not yet expose it. The `awscc` provider is already added to `envs/ec2/main.tf` and authenticates via the same AWS credential chain — no extra setup.
- **`aws_bedrock_model_invocation_logging_configuration` is account-scoped.** Only one per region per AWS account. If another stack in the same account already owns it, **set `enable_bedrock_invocation_logging = false`** to avoid a Terraform clash (the apply will succeed but the singleton resource fails on conflict).
- **Sidecar ordering.** `modules/ec2/user_data.sh` orders `multiagent-api.service` and `multiagent-ui.service` with `After=aws-otel-collector.service` so the OTLP receiver is up before either app starts. If the collector unit is missing (e.g. `enable_adot_collector = false`), the `After=` is a no-op and the services start unchanged.
- **`log_prompt_bodies = true` is opt-in.** Body logging captures user inputs + model outputs. Even though the Data Protection Policy auto-masks PII, the body is written before scrubbing. Treat the flag as audit-reviewed and time-boxed. See [`docs/observability-runbook.md`](observability-runbook.md) §3 for the checklist.
- **Per-user cost wiring.** Phase 3's `MetadataAwareBedrockModel` wrapper in `api/src/adapters/resolve-model.ts` is on by default and reads `currentTrace().userId / agentId` at call time. If you fork the API to use `BedrockModel` directly, the per-user cost dashboard widget will be empty.

### 3.3 Common deploy issues

| Symptom | Cause | Fix |
|---|---|---|
| `aws sts get-caller-identity` fails | Stale credentials | Re-source `.env`, re-issue keys if needed |
| Phase 4 fails with `Operation not allowed` on Bedrock | Model access not granted | Bedrock console → Model Access → request every model referenced by `config/agents/*.agent.md` (Sonnet 4.6 + Haiku 4.5 by default) — the use-case form takes ~15 min for Anthropic models |
| Phase 4 hangs > 15 min on Atlas | Atlas M10 cluster provisioning | Normal. M10 takes 8-12 min on first apply. |
| Phase 6 fails: "no awsPrivateLink connection string" | Atlas PrivateLink not yet active | Re-run after 60s. Atlas takes a moment to attach the AWS endpoint to the cluster. |
| Phase 8: "Role validation failed" | IAM trust policy not yet propagated | The `aws_bedrockagentcore_agent_runtime` resource will retry on the next `terraform apply`; if it still fails after 30s, re-run `deploy-full-with-privatelink.sh`. |
| Terraform fails with duplicate ECR/Logs/S3 VPC endpoint or duplicate endpoint SG rule errors | Shared VPC already has singleton AWS service endpoints or access rules | Set `TF_VAR_create_agentcore_runtime_vpc_endpoints=false` before deploy. EC2 mode reuses the existing endpoints and treats duplicate endpoint access rules as success. |
| Terraform apply says "Saved plan is stale" | Remote state changed after the plan was created | Re-run `deploy-full-with-privatelink.sh`; the retry wrapper re-plans and applies against current state. |
| Deploy rejects Voyage model | `VOYAGE_MARKETPLACE_MODEL` is not a supported multimodal listing or its ARN family disagrees | Re-run `setup-voyage-marketplace.sh --model voyage-multimodal-3` (or `voyage-multimodal-3.5`). Text-only Voyage models are unsupported — use `EMBEDDINGS_PROVIDER=titan` instead. See [`docs/reference/voyage.md`](reference/voyage.md). |
| API health hangs on `mcpServer` / MCP logs are empty | Missing VPC endpoints for the VPC-mode MongoDB MCP runtime | EC2 mode should create ECR API, ECR Docker, S3 gateway, and CloudWatch Logs endpoints. Apply `envs/ec2` and verify those endpoints are `available`. |
| `/health` shows `agentcore: "inactive"` | AgentCore Memory store not `ACTIVE` (provisioning or `DELETING`) | `aws bedrock-agentcore-control list-memories` — confirm `AGENTCORE_MEMORY_STORE_ID` in `.env.live` matches an `ACTIVE` memory. Re-run `deploy-project.sh` if the store is stuck deleting. |
| `/health` shows `bedrockKnowledgeBase: "unreachable"` but KB exists | EC2 role missing Bedrock KB retrieve permission or wrong KB id | Confirm `BEDROCK_KB_ID` in `.env.live`. EC2 IAM should allow `bedrock-agent-runtime:Retrieve` (see `modules/ec2/main.tf`). API logs: `[health] bedrock KB probe`. Re-run `./deploy/deploy-api.sh` after IAM/terraform fixes. |
| `/health` shows `bedrockKnowledgeBase: "not_configured"` | `BEDROCK_KB_ID` unset in the API container | Set in Terraform `knowledge_base_id` output and regenerate `.env.live` via `deploy-api.sh` or `deploy-project.sh`. |
| Deploy exits after Docker push with code 1 | Known `docker-build-push.sh` exit anomaly | Re-run `./deploy/deploy-full-with-privatelink.sh --auto-approve --skip-docker` to apply/restart with pushed images. |

---

## 4. Local mode (partial infra only)

`deploy-local.sh` provisions supporting AWS resources via `envs/local/` — useful for Atlas/KB development, **not** a substitute for the full EC2 chat stack.

### What `deploy-local.sh` actually provisions

Terraform in `envs/local/` creates:

- MongoDB Atlas M10 cluster (+ index seed hook)
- Bedrock Knowledge Base (Titan embeddings)
- AgentCore Memory store
- CloudWatch log groups under `/multiagent-local/<env>/…`

It does **not** create: EC2, Cognito, AgentCore runtimes, MongoDB MCP runtime, or Voyage SageMaker.

The generated `.env.live` leaves `AUTH_JWKS_URI`, `AUTH_ISSUER`, and `AGENTCORE_ORCHESTRATOR_ARN` empty — **`bun run dev` will fail** until you merge values from a full EC2 deploy's `.env.live`. The script's Phase 8 may attempt to start the API anyway; treat that as legacy behavior.

### 4.1 First-time partial infra

```bash
cd mongodb-aws-bedrock-multi-agent-framework
cp .env.sample .env    # if you have not already
source .env
aws sts get-caller-identity

./deploy/scripts/deploy-local.sh --auto-approve
```

### 4.2 Daily laptop dev (after a full EC2 deploy)

For a **runnable** local API + UI loop, run the full EC2 orchestrator first, then:

**Terminal 1 — API:**

```bash
cd mongodb-aws-bedrock-multi-agent-framework
source .env && source .env.live   # JWKS + AGENTCORE_ORCHESTRATOR_ARN from deploy-project.sh
export PATH="$HOME/.bun/bin:$PATH"
cd api && bun run dev
```

**Terminal 2 — UI:**

```bash
cd ui
streamlit run app.py   # API URL defaults to http://127.0.0.1:3000 (STREAMLIT_API_URL to override)
```

Open `http://localhost:8501`. Configure `STREAMLIT_COGNITO_*` (written to `.env.live` by `deploy-project.sh`) — every protected API route requires a valid Cognito JWT.

---

## 5. Code-only update (no Terraform)

After your initial deploy, most code changes don't need a fresh Terraform apply. The fast update path:

```bash
source .env

# 1. Build + push new images (~2 min)
./deploy/scripts/docker-build-push.sh "$ECR_API_REPO" "$ECR_UI_REPO" "$AWS_REGION"

# 2. Optionally: re-zip and upload AgentCore runtime artifact
#    (only needed if you changed agent-runtime-code.ts or agent/skill configs)
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
source .env

# 1. Per-project ec2 stack (always do this first when winding down a project)
./deploy/scripts/destroy.sh --mode ec2 --auto-approve

# 2. Shared VPC + Atlas PrivateLink VPCE (only after EVERY per-project ec2
#    deployment in the region has been destroyed — they read VPC IDs from SSM)
./deploy/scripts/destroy.sh --mode network --auto-approve
```

`--mode ec2` runs `terraform destroy` on `envs/ec2/`. Order matters:
1. AgentCore Gateway → Agent runtimes → MongoDB MCP runtime (native `aws_bedrockagentcore_*` deletes, no shell shim)
2. EC2 + EIP
3. Atlas cluster (slow — ~5 min)
4. Per-cluster Route 53 zone (`atlas-privatelink-dns`)
5. Supporting services (Cognito, ECR, KB, Memory, Secrets, CloudWatch)
6. Optional `bedrock-kb-privatelink` (NLB + VPC Endpoint Service) when `enable_kb_privatelink = true`

The shared VPC, Atlas PrivateLink VPCE, and the Atlas-side endpoint binding are **not** touched by `--mode ec2`. They live in `envs/network/` and are only removed by `--mode network`. Similarly the Voyage SageMaker endpoint, the shared API/UI/MCP/AgentCore/OTel log groups, and the four operational dashboards live in `envs/shared/` and are only removed by `--mode shared`. The Atlas endpoint *service* (`com.amazonaws.vpce.<region>.vpce-svc-...`) is intentionally preserved across destroys — `discover-or-create-pl.sh` reuses it on the next `deploy-network.sh`.

**Tear down order** (when fully removing an environment):

```bash
./deploy/scripts/destroy.sh --mode ec2     --auto-approve  # per-project (run once per envs/ec2 stack)
./deploy/scripts/destroy.sh --mode shared  --auto-approve  # singleton per account+region+env
./deploy/scripts/destroy.sh --mode network --auto-approve  # singleton per account+region
```

Running these in the wrong order (e.g. `shared` before `ec2`) leaves the per-project EC2 stack pointing at deleted SSM keys; the next `deploy-project.sh` (or any `terraform plan` in `envs/ec2`) fails immediately with `ParameterNotFound`.

The S3 state bucket is **not** destroyed by default — it has versioning enabled and Terraform state for all three roots lives in it. To delete it manually after destroy (replace the bucket name with the value emitted in `deploy-manifest.json` → `shared_bucket_name`):

```bash
BUCKET=$(jq -r '.shared_bucket_name' deploy-manifest.json)
aws s3 rm "s3://$BUCKET" --recursive
aws s3 rb "s3://$BUCKET"
```

---

## 7. Verifying a deploy is healthy

After `deploy-full-with-privatelink.sh` completes:

```bash
EC2_IP=$(jq -r '.ec2_instance_public_ip' deploy-manifest.json)

# Health check — see docs/api-reference.md § GET /health for per-field meaning
curl -s "http://$EC2_IP:3000/health" | python3 -m json.tool
# Expect: status "ok", mongodb/agentcore/mcpServer "connected" when the stack is warm.
# longTermMemory "connected" requires ≥1 agent with memory.longTerm: true.
# bedrockKnowledgeBase "connected" only when BEDROCK_KB_ID is set AND Retrieve IAM works.
# agentcore "inactive" means the memory store exists but is not ACTIVE (re-run deploy-project if stuck DELETING).

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

CloudWatch log groups for full log search (where `<prefix>` = `SHARED_RESOURCE_PREFIX`, default `multiagent`):

- `/<prefix>/<env>/api` — Hono API (JSON lines from the Bun process; on EC2 also fed by **amazon-cloudwatch-agent** from `multiagent-api.service` journald)
- `/<prefix>/<env>/ui` — Streamlit UI (journald `multiagent-ui.service` → same agent)
- `/<prefix>/<env>/otel` — ADOT collector sidecar
- `/<prefix>/<env>/otel-atlas` — Atlas Prometheus → CloudWatch scrape (when `enable_atlas_metrics=true`)
- `/<prefix>/<env>/agentcore` — placeholder / optional future centralization (short retention)
- `/<prefix>/<env>/mcp` — placeholder for MCP-sidecar style hosts (short retention)
- `/aws/bedrock-agentcore/runtimes/<runtime-id>/...` — every AgentCore Runtime (orchestrator, 3 specialists, MongoDB MCP runtime) writes to its own AgentCore-managed log group; the legacy `/<prefix>/<env>/mcp` Lambda log group is gone post Phase 7e
- `/aws/bedrock/invocations` + `/aws/bedrock/invocations-audit` — Bedrock invocation logging (account+region singleton; KMS-encrypted, PII Data Protection Policy attached)
- `/aws/bedrock/knowledgebase/<KB_ID>` — Bedrock KB APPLICATION_LOGS (per-doc ingestion status)
- `aws/spans` — X-Ray + GenAI Observability spans (`gen_ai.*` Strands instrumentation)

---

## 9. CI/CD (GitHub Actions)

Two workflows ship with the repo. They are **not** the primary deploy path today (the daily driver is `deploy-full-with-privatelink.sh` from a laptop or jumphost), but they are wired and runnable.

### `.github/workflows/ci.yml`

Runs on every push and pull request against `main` / `master`. Four jobs in parallel:

| Job | What it runs |
|---|---|
| `api` | `bun install --frozen-lockfile`, `bun run typecheck`, `bun run validate:bun`, `bun run validate:agentcore`, `bun run test:all` |
| `ui` | `pip install -r requirements.txt`, `python -m pytest tests/ -v` |
| `e2e` | `bunx playwright install --with-deps chromium` then `API_URL=http://localhost:3000 bun run test` — requires a **live** API (no in-tree stub server; health/agents/skills smoke only unless you add chat specs) |
| `docker-images` | `docker build` for both `api/Dockerfile` (context = repo root) and `ui/Dockerfile` (context = `ui/`) — verifies images build cleanly |

CI runs with **no AWS credentials**. None of the live integration paths (real Bedrock, real Atlas, real AgentCore) exercise here. The default `e2e/tests/api.spec.ts` hits read-only public endpoints (`/health`, `/agents`, `/skills`) — it does not start a local API process.

Local equivalent before pushing:

```bash
cd api && bun run typecheck && bun run validate:bun && bun run validate:agentcore && bun run test:all
cd ../ui && python -m pytest tests/ -v
cd ../e2e && bun install && bunx playwright install chromium && bun run test
```

### `.github/workflows/deploy.yml` — manual cloud deploy

`workflow_dispatch` only (no auto-deploy on push). Inputs:

| Input | Default | Effect |
|---|---|---|
| `auth_mode` | `iam` | `iam` consumes `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` secrets; `sts` assumes `AWS_DEPLOY_ROLE_ARN` repo variable via OIDC |
| `auto_approve` | `true` | When `false`, runs as terraform-plan-only |
| `skip_docker` | `false` | Reuses the latest pushed images; only re-applies infra and re-syncs env |
| `network_mode` | `privatelink` | Selects which orchestrator script runs (`deploy-full-with-privatelink.sh` vs `deploy-full-with-vpc-peering.sh`) |
| `atlas_peering_cidr` | `192.168.248.0/21` | Used only when `network_mode=peering` |

The workflow uses a concurrency group so two simultaneous dispatches cannot race the Terraform state.

**Required GitHub repo secrets (for `auth_mode=iam`):**

- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`
- `MONGODB_ATLAS_PUBLIC_KEY`, `MONGODB_ATLAS_PRIVATE_KEY`, `TF_VAR_MONGODB_ATLAS_ORG_ID`, `TF_VAR_MONGODB_ATLAS_PROJECT_ID`, `TF_VAR_ATLAS_DB_PASSWORD`
- `PROJECT_NAME`, `ENVIRONMENT`, `SHARED_VPC_NAME` (repo variables, not secrets)
- For `sts`: replace AWS keys with `AWS_DEPLOY_ROLE_ARN` (repo variable). The role's trust policy must include the `AllowGitHubActionsOidcFederation` SID from [`deploy/iam/sts-trust-policy.json`](../deploy/iam/sts-trust-policy.json).

**When to use the workflow vs the laptop script:**

- Laptop / jumphost — daily driver. Iteration loop with full SSM access for debugging.
- GitHub Actions — release tags, scheduled rebuilds, or environments without local AWS credentials. Audit trail in the Actions log.

There is currently **no automatic destroy workflow**. Teardown is laptop-only (`./deploy/scripts/destroy.sh --mode {ec2,shared,network}`).

---

## 10. Critical files reference

| File | Purpose |
|---|---|
| [`.env`](../.env) | Live credentials + project identity (fill in before first deploy) |
| [`.env.live`](../.env.live) | Generated by `deploy-project.sh` Phase 7. Holds runtime config (gitignored). |
| [`deploy/deploy-full-with-privatelink.sh`](../deploy/deploy-full-with-privatelink.sh) | **Main entrypoint** — provisions network (if needed) then project stack |
| [`deploy/scripts/deploy-network.sh`](../deploy/scripts/deploy-network.sh) | Shared VPC + Atlas PrivateLink VPCE (run once per account + region) |
| [`deploy/scripts/deploy-shared.sh`](../deploy/scripts/deploy-shared.sh) | Shared observability + embeddings — Voyage SageMaker endpoint, CloudWatch log groups, fleet/mongo/cost/atlas dashboards, Bedrock invocation logging (run once per account + region + environment) |
| [`deploy/scripts/deploy-project.sh`](../deploy/scripts/deploy-project.sh) | Per-project EC2 deploy orchestrator (full infra + agents) |
| [`deploy/deploy-api.sh`](../deploy/deploy-api.sh) | API-only redeploy — rebuilds/pushes API image, syncs `.env.live`, restarts `multiagent-api`, runs backend smoke. Skips Terraform/UI/AgentCore runtime changes. |
| [`deploy/deploy-agents.sh`](../deploy/deploy-agents.sh) | Agent-only redeploy — rebuilds artifact, targeted tf apply on runtime modules, env injection, API config/cache refresh. Skips Atlas/EC2/KB/Docker/API restart. |
| [`deploy/scripts/_agents-common.sh`](../deploy/scripts/_agents-common.sh) | Shared helper sourced by `deploy-project.sh` and `deploy-agents.sh` (not run directly) |
| [`deploy/scripts/deploy-local.sh`](../deploy/scripts/deploy-local.sh) | Partial laptop infra (`envs/local`) — Atlas + KB + memory; not a full chat stack |
| [`deploy/scripts/destroy.sh`](../deploy/scripts/destroy.sh) | Tear down (`--mode local`/`ec2`/`network`) |
| [`deploy/scripts/docker-build-push.sh`](../deploy/scripts/docker-build-push.sh) | Code-only image rebuild |
| [`deploy/terraform/envs/network/main.tf`](../deploy/terraform/envs/network/main.tf) | Shared VPC + Atlas PL VPCE root module (account + region singleton) |
| [`deploy/terraform/envs/shared/main.tf`](../deploy/terraform/envs/shared/main.tf) | Shared observability + embeddings root module — SageMaker endpoint, CloudWatch log groups, fleet/atlas dashboards, Bedrock invocation logging (account + region + env singleton). Publishes `voyage_sagemaker_endpoint_*` and `cw_*_log_group` + `bedrock_*_log_group` SSM params. |
| [`deploy/terraform/envs/ec2/main.tf`](../deploy/terraform/envs/ec2/main.tf) | Per-project EC2 mode root module (consumes shared VPC + shared observability via SSM) |
| [`deploy/terraform/envs/local/main.tf`](../deploy/terraform/envs/local/main.tf) | Local mode root module |
| [`deploy/terraform/modules/atlas-privatelink/`](../deploy/terraform/modules/atlas-privatelink/) | AWS Interface VPCE + Atlas-side binding + CIDR-scoped SG (envs/network) |
| [`deploy/terraform/modules/atlas-privatelink-dns/`](../deploy/terraform/modules/atlas-privatelink-dns/) | Per-cluster Route 53 private zone + wildcard CNAME — DNS half of Atlas PrivateLink (envs/ec2) |
| [`deploy/terraform/modules/agentcore-agent-runtime/`](../deploy/terraform/modules/agentcore-agent-runtime/) | The 4-runtime module (CLI-provisioned) |
| [`deploy-manifest.json`](../deploy-manifest.json) | Output: every ARN/ID/URL/IP from last deploy |
