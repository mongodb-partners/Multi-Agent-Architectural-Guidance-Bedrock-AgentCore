# Deploy Scripts — Reference

Every shell script under [`deploy/`](../../deploy/) and [`deploy/scripts/`](../../deploy/scripts/) — what it does, its flags, prerequisites, and what it writes.

## At a glance

| Script | Layer | Mode-aware | Re-runnable | What it touches |
|---|---|---|---|---|
| [`deploy/deploy-full-with-privatelink.sh`](../../deploy/deploy-full-with-privatelink.sh) | Orchestrator | PrivateLink | yes | Network → shared → project |
| [`deploy/deploy-full-with-vpc-peering.sh`](../../deploy/deploy-full-with-vpc-peering.sh) | Orchestrator | Peering | yes | Network → shared → project |
| [`deploy/scripts/deploy-network.sh`](../../deploy/scripts/deploy-network.sh) | `envs/network` | both | yes | Shared VPC + Atlas connectivity primitives |
| [`deploy/scripts/deploy-shared.sh`](../../deploy/scripts/deploy-shared.sh) | `envs/shared` | mode-agnostic | yes | SageMaker, log groups, dashboards, invocation logging |
| [`deploy/scripts/deploy-project.sh`](../../deploy/scripts/deploy-project.sh) | `envs/ec2` | both | yes | EC2, ECR, Cognito, KB, AgentCore Runtimes, Gateway |
| [`deploy/deploy-api.sh`](../../deploy/deploy-api.sh) | App image | both | yes | API image + `.env.live` only |
| [`deploy/deploy-ui.sh`](../../deploy/deploy-ui.sh) | App image | both | yes | UI image only |
| [`deploy/deploy-agents.sh`](../../deploy/deploy-agents.sh) | AgentCore | both | yes | Targeted apply of `acr_specialists` + `acr_orchestrator` + code artifact |
| [`deploy/scripts/destroy.sh`](../../deploy/scripts/destroy.sh) | Teardown | both | yes | `terraform destroy` for one env |
| [`deploy/scripts/deploy-local.sh`](../../deploy/scripts/deploy-local.sh) | Laptop | n/a | yes | Atlas + KB + Cognito + local API/UI |
| [`deploy/scripts/probe-resources.sh`](../../deploy/scripts/probe-resources.sh) | Diagnostic | n/a | yes | CRUD smoke against AWS IAM perms |
| [`deploy/scripts/list-resources.sh`](../../deploy/scripts/list-resources.sh) | Diagnostic | n/a | yes | Tag-based inventory by service |
| [`deploy/scripts/setup-voyage-marketplace.sh`](../../deploy/scripts/setup-voyage-marketplace.sh) | Bootstrap | n/a | yes | Subscribe + write Voyage Marketplace ARN |
| [`deploy/scripts/setup-troubleshooting-infra.sh`](../../deploy/scripts/setup-troubleshooting-infra.sh) | Legacy | n/a | yes | Minimum infra for troubleshooting agent — superseded |
| [`deploy/scripts/teardown-troubleshooting-infra.sh`](../../deploy/scripts/teardown-troubleshooting-infra.sh) | Legacy | n/a | yes | Reverse of the above |
| [`deploy/scripts/docker-build.sh`](../../deploy/scripts/docker-build.sh) | Helper | n/a | yes | Build API + UI images locally |
| [`deploy/scripts/docker-push-ecr.sh`](../../deploy/scripts/docker-push-ecr.sh) | Helper | n/a | yes | Tag + push API + UI images to ECR |
| [`deploy/scripts/_aws-auth.sh`](../../deploy/scripts/_aws-auth.sh) | Helper | both | yes | `validate_aws_auth` — sourced by every deploy script |
| [`deploy/scripts/_agents-common.sh`](../../deploy/scripts/_agents-common.sh) | Helper | both | yes | Agent discovery + tfvars + code artifact build |

Every script honors `AUTH_MODE` (`iam` default, `sts` for SSO/OIDC) via `_aws-auth.sh`. See [`deploy/iam/README.md`](../../deploy/iam/README.md).

---

## 1. Orchestrators

### `deploy-full-with-privatelink.sh`
The single entrypoint for a PrivateLink deployment. Probes SSM canaries and only runs the sub-stacks that aren't already applied.

**Usage:**
```bash
./deploy/deploy-full-with-privatelink.sh [--auto-approve] [--skip-docker]
                                          [--skip-smoke] [--skip-network]
                                          [--skip-shared] [--env-file <path>]
```

**Flow:**
1. **Network existence check** — reads SSM `/<SHARED_VPC_NAME>/<region>/vpc_id`. If present, skip `deploy-network.sh`.
2. **Shared-stack existence check** — reads SSM `/<SHARED_VPC_NAME>/<region>/cw_api_log_group` (canary published only by `envs/shared`). If present, skip `deploy-shared.sh`.
3. Always runs `deploy-project.sh` last.

Exports `NETWORK_MODE=privatelink` before delegating so `deploy-network.sh` + `deploy-project.sh` route to their PrivateLink branches and stamp `network_mode='privatelink'` into SSM + tfvars + `deploy-manifest.json`.

### `deploy-full-with-vpc-peering.sh`
Sister script for peering mode. Same 3-phase structure, same flag surface. Differs from the PrivateLink orchestrator in three ways:

1. Exports `NETWORK_MODE=peering` before delegating.
2. `envs/network` provisions `modules/atlas-vpc-peering` instead of `modules/atlas-privatelink`.
3. `envs/ec2` provisions `modules/bedrock-kb-peering` (**EXPERIMENTAL — TLS not partner-validated**) instead of `modules/bedrock-kb-privatelink`, and selects `MONGODB_URI` from the cluster's peering connection strings (no public fallback; the TF precondition enforces this).
4. `envs/shared` is reused unchanged (mode-agnostic).

Prints an EXPERIMENTAL banner unless `--auto-approve` is set; the banner explains the TF_VAR_enable_kb_peering=false degradation path (public-SRV KB ingestion).

> PrivateLink and VPC peering are **mutually exclusive per account**. Switching modes requires destroy + redeploy. Both orchestrators guard against silent mode swaps via the SSM `/<shared_vpc_name>/<region>/network_mode` canary.

---

## 2. Per-stack scripts

### `deploy-network.sh`
Applies the shared VPC + Atlas connectivity primitives. Singleton per `(account, region)`.

**Usage:**
```bash
./deploy/scripts/deploy-network.sh [--auto-approve] [--allow-mode-switch] [--env-file <path>]
```

**Phases:**
1. Validate prereqs (`aws`, `terraform`, `python3`).
2. Source `.env`, verify AWS + Atlas creds via `_aws-auth.sh`.
3. Bootstrap shared S3 state bucket (idempotent).
4. Generate `backend.hcl` + `terraform.tfvars`. State key: `${SHARED_VPC_NAME}/${AWS_REGION}/network/terraform.tfstate`.
5. `terraform init` + plan + apply. Provisions:
   - VPC + 3 public + 3 private subnets + IGW + NAT.
   - **PrivateLink mode**: Atlas Interface VPCE + endpoint binding + security group.
   - **Peering mode**: Atlas `network_peering` accepter + Private DNS for Peering. Includes a Python CIDR pre-flight to refuse overlap between `ATLAS_PEERING_CIDR` and `VPC_CIDR`.
   - SSM Parameter Store entries (see [`ssm-parameters.md`](ssm-parameters.md)).
6. Verify SSM params, print summary.

**`--allow-mode-switch`** is the escape hatch when forcing a re-apply across modes. It bypasses the in-script mode-canary check; the `check` block in `envs/ec2` still blocks per-project applies until consumers are destroyed and re-applied.

### `deploy-shared.sh`
Applies the shared observability + embeddings stack. Singleton per `(account, region, environment)`.

**Usage:**
```bash
./deploy/scripts/deploy-shared.sh [--auto-approve] [--env-file <path>]
```

**Phases:**
1. Validate prereqs.
2. Source `.env`, verify credentials.
3. Sanity-check the bootstrap S3 bucket exists (must have run `deploy-network.sh` first).
4. Generate `backend.hcl` + `terraform.tfvars`. State key: `${SHARED_VPC_NAME}/${AWS_REGION}/<env>/shared/terraform.tfstate`.
5. `terraform init` + plan + apply. Provisions:
   - Voyage SageMaker endpoint (when `VOYAGE_MODEL_PACKAGE_ARN` set).
   - CloudWatch log groups: `api`, `ui`, `mcp`, `agentcore`, `otel`, `otel-atlas`.
   - Bedrock invocation logging (account-scoped singleton).
   - Fleet + Mongo + cost dashboards + 7 alarms.
   - Atlas dashboard + 2 alarms (when `enable_atlas_metrics=true`).
   - SSM Parameter Store entries.
6. Verify SSM canary params, print summary.

Mode-agnostic — same call in both PrivateLink and peering deployments.

### `deploy-project.sh`
The big one — applies `envs/ec2`, builds images, syncs `.env.live`, restarts EC2 services, runs smoke checks. Per `(account, region, environment, project)`.

**Usage:**
```bash
./deploy/scripts/deploy-project.sh [--auto-approve] [--skip-docker] [--skip-smoke] [--env-file <path>]
```

**Phase index** (one block per phase in the script):

| Phase | What it does |
|---|---|
| 1 | Validate prereqs (`aws`, `terraform`, `bun`, `python3`, `zip`; `docker` unless `--skip-docker`) |
| 2 | Source `.env`, verify AWS + Atlas creds, derive `ACCOUNT_ID` from `_aws-auth.sh` exports |
| 3 | Bootstrap shared S3 bucket (idempotent) |
| 4 | Generate `backend.hcl` + `terraform.tfvars` for `envs/ec2`. State key: `${SHARED_VPC_NAME}/${AWS_REGION}/<env>/<project>/ec2/terraform.tfstate` |
| 5 | `terraform apply` — VPC consume, Atlas M10, KB, EC2, ECR, Cognito, AgentCore Memory + Gateway + Runtimes, ADOT, GenAI observability |
| 6 | Build + push Docker images (API/UI = amd64; agent-runtime = arm64) — skipped under `--skip-docker` |
| 7 | Write `.env.live` (PUBLIC URI for harness use, PrivateLink/peering URI for runtime), copy to EC2 via SSM |
| 8 | Pull images + restart `multiagent-api` / `multiagent-ui` / `mongodb-mcp` on EC2 |
| 9 | Health + MCP probes + deterministic backend smoke (`backend-smoke.py`, phases 9a–9b) |
| 10 | Write `deploy-manifest.json` (resource inventory; consumed by smoke tests + harnesses) |
| 11 | Full post-deploy smoke (`e2e-smoke/post-deploy-smoke.py`; `--skip-smoke` to disable) |

**Outputs:** `deploy-manifest.json` at repo root, `.env.live` on EC2 (`/opt/multiagent/.env.live`), Terraform outputs (read by `deploy-api.sh` / `deploy-ui.sh` / `deploy-agents.sh`).

### `deploy-local.sh`
Laptop / non-EC2 mode. Provisions Atlas + KB + Cognito + Secrets, but skips EC2, AgentCore Runtimes, Voyage SageMaker. Uses Bedrock Titan for embeddings.

**Usage:**
```bash
./deploy/scripts/deploy-local.sh [--auto-approve] [--skip-seed] [--env-file <path>]
```

Phases mirror `deploy-project.sh` except Phase 8 runs the API + UI directly on the local machine (`bun run dev` + `streamlit run`).

---

## 3. Partial redeploy scripts

### `deploy-api.sh`
API-only redeploy. Use when only `api/` code or API-bundled config changed.

**Usage:**
```bash
./deploy/deploy-api.sh [--skip-docker] [--skip-smoke] [--env-file <path>]
```

**Does:** rebuild + push API image, regenerate `.env.live`, restart only `multiagent-api`, run backend smoke.
**Does NOT:** `terraform apply`, build UI/AgentCore images, touch AgentCore runtimes.

> When Cognito/Atlas/OTel env vars changed, this is the script to run first — it refreshes `.env.live`. `deploy-ui.sh` and `deploy-agents.sh` rely on the already-written `.env.live`.

### `deploy-ui.sh`
UI-only redeploy. Use when only `ui/` code changed.

**Usage:**
```bash
./deploy/deploy-ui.sh [--skip-docker] [--skip-smoke] [--env-file <path>]
```

**Does:** rebuild + push UI image, restart only `multiagent-ui`, Streamlit health check.
**Does NOT:** regenerate `.env.live` (run `deploy-api.sh` first if Cognito env vars changed).

### `deploy-agents.sh`
Agent-only redeploy. Use when only `config/agents/*.agent.md` or `config/skills/` changed.

**Usage:**
```bash
./deploy/deploy-agents.sh [--auto-approve] [--allow-destroy] [--force]
                          [--skip-smoke] [--env-file <path>]
```

**Phases:**
1–2. Prereqs + creds.
3. Discover agents from `config/agents/*.agent.md`, validate orchestrator handoff consistency.
4. Write `agents.auto.tfvars.json` (refuses to run before `deploy-project.sh`).
5. Build + upload code artifact (`bun build` → minified JS → zip → S3 `code/`).
6. `terraform init` + targeted apply on `acr_specialists` + `acr_orchestrator`. Refuses destroy without `--allow-destroy`.
7. Read TF outputs (specialist ARNs/IDs, orchestrator id, workload identity).
8. Inject dynamic env vars (`AGENTCORE_RUNTIME_ARN_<AGENT_ID>`, etc.) into every runtime; verify.
9. Refresh API agent cache via `POST /internal/agents/refresh` (no API restart).
10. Optional Phase 10 agent smoke (`--skip-smoke` to disable).
11. Write `deploy-manifest.agents.json`.

**Does NOT:** rebuild API/UI images, restart `multiagent-api` / `multiagent-ui`, touch network/Atlas/KB.

`--force` skips orchestrator handoff-consistency validation — use with care.

---

## 4. Teardown

### `destroy.sh`
Tear down one Terraform env.

**Usage:**
```bash
./deploy/scripts/destroy.sh --mode {local|ec2|shared|network} [--auto-approve] [--with-bootstrap] [--env-file <path>]
```

**Ordering — REQUIRED:** `ec2 → shared → network`. Per-project EC2 envs read SSM published by shared + network; destroying earlier stacks first leaves orphan refs.

**`--with-bootstrap`** also empties + destroys the shared S3 state bucket. Only use when no other env uses it — this deletes ALL Terraform state.

**State keys:**
- `envs/local`: `<env>/terraform.tfstate`
- `envs/ec2`: `<env>/ec2/terraform.tfstate`
- `envs/shared`: `<SHARED_VPC_NAME>/<region>/<env>/shared/terraform.tfstate`
- `envs/network`: `<SHARED_VPC_NAME>/<region>/network/terraform.tfstate`

---

## 5. Diagnostic + bootstrap helpers

### `probe-resources.sh`
Combined local + EC2 permission smoke test. For every resource defined in `envs/local` and `envs/ec2`, attempts CREATE → VALIDATE → DELETE and prints an access matrix.

```bash
bash deploy/scripts/probe-resources.sh                # fast probes (~5 min)
bash deploy/scripts/probe-resources.sh --with-ec2     # + full VPC+EC2 CRUD
bash deploy/scripts/probe-resources.sh --with-cluster # + Atlas M10 CRUD (~20 min)
bash deploy/scripts/probe-resources.sh --with-bedrock-kb
bash deploy/scripts/probe-resources.sh --with-sagemaker
bash deploy/scripts/probe-resources.sh --all          # everything
```

Use this before the first deploy on a new AWS account.

### `list-resources.sh`
Tag-based inventory by service. Reads `resourcegroupstaggingapi` plus direct calls to AgentCore (Memory + Gateway don't show up in tagging API yet).

```bash
./deploy/scripts/list-resources.sh
./deploy/scripts/list-resources.sh --project my-project --region us-east-2
```

### `setup-voyage-marketplace.sh`
One-time bootstrap for the Voyage AI Marketplace subscription. Discovers the model package ARN after EULA acceptance and rewrites `VOYAGE_MODEL_PACKAGE_ARN` in `.env` (and pushes it to GitHub Secrets when `gh` is logged in).

```bash
./deploy/scripts/setup-voyage-marketplace.sh                       # interactive
./deploy/scripts/setup-voyage-marketplace.sh --model voyage-multimodal-3
./deploy/scripts/setup-voyage-marketplace.sh --skip-env --skip-gh
```

Idempotent — re-runs do not duplicate `.env` lines.

### `setup-troubleshooting-infra.sh` / `teardown-troubleshooting-infra.sh`
**Legacy.** Provisions a minimum-viable infrastructure for the troubleshooting agent (Atlas M10 + KB + S3 + IAM + OpenSearch Serverless). Superseded by the canonical `deploy-project.sh` path. Kept for backward compatibility with older runbooks; the production path is `./deploy/deploy-full-with-privatelink.sh`.

### `docker-build.sh` / `docker-push-ecr.sh`
Manual image helpers. `docker-build.sh` builds `multi-agent-api:<TAG>` (context = repo root) and `multi-agent-streamlit:<TAG>` (context = `ui/`). `docker-push-ecr.sh` tags + pushes to ECR. Both are convenience wrappers; the canonical path is `deploy-project.sh` Phase 6.

---

## 6. Helpers (sourced, not run directly)

### `_aws-auth.sh`
Sourced by every deploy script. Validates `AUTH_MODE` (`iam` default; `sts` for assumed-role / SSO / OIDC), runs `aws sts get-caller-identity`, asserts the resolved caller matches the declared mode, and exports `AWS_AUTH_ACCOUNT_ID` + `AWS_AUTH_CALLER_ARN`. See [`deploy/iam/README.md`](../../deploy/iam/README.md) for IAM/STS setup.

### `_agents-common.sh`
Shared helpers used by `deploy-project.sh` + `deploy-agents.sh`:

- `discover_agents` — scans `config/agents/*.agent.md`.
- `write_specialist_agents_tfvars` — writes `agents.auto.tfvars.json`.
- `build_and_upload_code_artifact` — Bun bundle → zip → S3 upload + version pin.
- `update_runtime_env_dynamic` — injects `AGENTCORE_RUNTIME_ARN_<AGENT_ID>` into every runtime via `aws bedrock-agentcore-control update-agent-runtime`.

---

*Last verified: 2026-05-20 against `deploy/*.sh` + `deploy/scripts/*.sh`.*
