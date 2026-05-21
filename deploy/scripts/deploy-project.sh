#!/usr/bin/env bash
# deploy-project.sh — EC2 deployment (envs/ec2 terraform)
#
# Usage:
#   ./deploy/scripts/deploy-project.sh [--auto-approve] [--skip-docker] [--env-file <path>]
#
# What it does:
#   Phase 1  — Validate prerequisites (aws, terraform, bun, python3, zip,
#              docker — docker only when --skip-docker is NOT passed)
#   Phase 2  — Source .env, verify AWS + Atlas credentials
#   Phase 3  — Bootstrap shared S3 bucket (once)
#   Phase 4  — Generate backend.hcl + terraform.tfvars for envs/ec2
#   Phase 5  — terraform apply (envs/ec2):
#                VPC + Atlas M10 + PrivateLink + EC2 + ECR + Cognito + Bedrock KB
#                + AgentCore Memory + AgentCore Gateway (no Lambda target yet)
#                (+ Voyage AI if ARN set)
#   Phase 6  — Build + push Docker images to ECR (unless --skip-docker)
#   Phase 7  — Write .env.live + copy to EC2 via SSM
#   Phase 8  — Pull images + restart multiagent-api, multiagent-ui, mongodb-mcp on EC2
#   Phase 9  — Health check, summary, manifest
#
# Embedding: explicit provider selection via EMBEDDINGS_PROVIDER.
#            titan  -> Bedrock Titan v2, no SageMaker ARN required.
#            voyage -> SageMaker endpoint from VOYAGE_MODEL_PACKAGE_ARN.
#
# Tools:     MongoDB MCP runs as a systemd service on the EC2 instance
#            (`mongodb-mcp.service`, bound to 127.0.0.1:8080) and the API talks
#            to it over loopback. Lambda + AgentCore Gateway are DEFERRED —
#            see Docs/adr/0001-mcp-on-ec2-not-lambda.md.
#
# Shell:     SSM Session Manager (no SSH keypair by default).
#
# For local dev (no EC2, direct tools), use: ./deploy/scripts/deploy-local.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_ROOT="$REPO_ROOT/deploy/terraform"
TF_DIR="$TF_ROOT/envs/ec2"
BOOTSTRAP_DIR="$TF_ROOT/bootstrap"
ENV_FILE="$REPO_ROOT/.env"
AUTO_APPROVE=false
SKIP_DOCKER=false

# Source shared agent helpers (discover_agents, write_specialist_agents_tfvars,
# build_and_upload_code_artifact, update_runtime_env_dynamic, etc.)
# shellcheck source=deploy/scripts/_agents-common.sh
source "$SCRIPT_DIR/_agents-common.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
# DB user + DB name follow the same project+env convention as .env — Mongo
# identifiers can't contain "-" so the project name is underscore-normalized.
# Always derive both from PROJECT_NAME + ENVIRONMENT when they're not already
# exported, so a stale value from a prior shell never silently leaks into
# terraform.tfvars / .env.live.
_PROJECT_SLUG="${PROJECT_NAME//-/_}"
ATLAS_DB_USER="${ATLAS_DB_USER:-${_PROJECT_SLUG}_${ENVIRONMENT}_user}"
ATLAS_DB_NAME="${ATLAS_DB_NAME:-${_PROJECT_SLUG}_${ENVIRONMENT}}"
unset _PROJECT_SLUG
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
COGNITO_SEED_USERS="${COGNITO_SEED_USERS:-true}"
COGNITO_TEST_USERS_CSV="${COGNITO_TEST_USERS_CSV:-alex@example.com,blake@example.com,casey@example.com}"
COGNITO_TEST_PASSWORD="${COGNITO_TEST_PASSWORD:-DemoUser#2026}"
COGNITO_SMOKE_USER_EMAIL="${COGNITO_SMOKE_USER_EMAIL:-alex@example.com}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve) AUTO_APPROVE=true ;;
    --skip-docker)  SKIP_DOCKER=true ;;
    --env-file)     ENV_FILE="$2"; shift ;;
    *) echo "  [ec2] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo "  [ec2] $*"; }
ok()   { echo "  [ec2] ✓ $*"; }
err()  { echo "  [ec2] ✗ $*" >&2; exit 1; }
warn() { echo "  [ec2] ⚠ $*"; }
sep()  { echo "────────────────────────────────────────────────"; }

# shellcheck source=deploy/scripts/_sg-cleanup.sh
source "$SCRIPT_DIR/_sg-cleanup.sh"

# Wrap `terraform apply` with retry-on-transient-errors.
# The MongoDB Atlas API at cloud.mongodb.com occasionally returns i/o timeouts
# or connection-resets that vanish on the next call. Terraform can also reject
# a saved plan as stale if a previous target apply, retry, or parallel operator
# changed remote state between plan and apply. We retry the apply up to
# `max_attempts - 1` times, re-planning between attempts so the saved plan stays
# consistent with the latest state. Any error that is NOT a known-transient
# failure is treated as a hard failure. We never silently swallow a real
# provider error.
apply_with_retry() {
  local plan_file="$1"
  local max_attempts=3   # initial + 2 retries, per project policy
  local attempt=1
  local log_file rc
  log_file=$(mktemp -t tf-apply.XXXXXX)

  while (( attempt <= max_attempts )); do
    if (( attempt > 1 )); then
      log "Retry $((attempt - 1))/$((max_attempts - 1)) — sleeping 30s, then re-planning to refresh against current state..."
      sleep 30
      if declare -F deploy_diag_checkpoint >/dev/null 2>&1; then
        deploy_diag_checkpoint "terraform retry plan attempt ${attempt}/${max_attempts}: terraform plan -input=false -out=${plan_file}"
      fi
      terraform plan -input=false -out="$plan_file"
      ok "re-plan complete"
    fi
    log "Apply attempt ${attempt}/${max_attempts}..."
    if declare -F deploy_diag_checkpoint >/dev/null 2>&1; then
      deploy_diag_checkpoint "terraform apply attempt ${attempt}/${max_attempts}: terraform apply -input=false ${plan_file}"
    fi
    set +e
    terraform apply -input=false "$plan_file" 2>&1 | tee "$log_file"
    rc=${PIPESTATUS[0]}
    set -e
    if (( rc == 0 )); then
      rm -f "$log_file"
      return 0
    fi
    # Transient = network/timeout error talking to Atlas, or Terraform saved-plan
    # staleness after state changed between plan and apply.
    if grep -qE 'cloud\.mongodb\.com.*(i/o timeout|connection reset|connection refused|EOF|TLS handshake timeout)|Saved plan is stale' "$log_file"; then
      warn "Transient Terraform apply error detected on attempt ${attempt} — will re-plan and retry"
      attempt=$((attempt + 1))
      continue
    fi
    if grep -qE 'DeleteSecurityGroup.*DependencyViolation|DependencyViolation: resource sg-[a-z0-9]+ has a dependent object' "$log_file"; then
      local blocked_sgs
      blocked_sgs=$(python3 - "$log_file" <<'PYEOF'
import re
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    text = fh.read()

matches = set(re.findall(r"(sg-[0-9a-f]+)", text))
print(" ".join(sorted(matches)))
PYEOF
)
      if [[ -n "$blocked_sgs" ]]; then
        warn "Security-group dependency detected; revoking stale external references before retry: ${blocked_sgs}"
        cleanup_security_group_references $blocked_sgs || true
        attempt=$((attempt + 1))
        continue
      fi
    fi
    rm -f "$log_file"
    err "terraform apply failed with a non-transient error (see output above)"
  done
  rm -f "$log_file"
  err "terraform apply failed after ${max_attempts} attempts — transient Atlas API errors did not clear"
}

wait_for_instance_status_ok() {
  local instance_id="$1"
  log "Waiting for EC2 instance checks to pass: $instance_id"
  aws ec2 wait instance-status-ok \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    || err "EC2 status checks did not pass in time for $instance_id"
  ok "EC2 status checks passed"
}

wait_for_ssm_online() {
  local instance_id="$1"
  local max_attempts=36
  log "Waiting for SSM registration (up to 6 min)..."
  for i in $(seq 1 "$max_attempts"); do
    local status=""
    # Prefer get-connection-status — describe-instance-information can lag
    # several minutes behind PingStatus=Online on fresh EC2 hosts.
    status=$(aws ssm get-connection-status \
      --region "$AWS_REGION" \
      --target "$instance_id" \
      --query "Status" \
      --output text 2>/dev/null || true)
    status="${status//$'\r'/}"
    if [[ "$status" == "connected" ]]; then
      ok "SSM agent is online"
      return 0
    fi
    # Fallback: legacy PingStatus probe (trim whitespace/null sentinels).
    status=$(aws ssm describe-instance-information \
      --region "$AWS_REGION" \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query "InstanceInformationList[0].PingStatus" \
      --output text 2>/dev/null || echo "None")
    status="${status//$'\r'/}"
    if [[ "$status" == "Online" ]]; then
      ok "SSM agent is online (PingStatus)"
      return 0
    fi
    log "  Waiting for SSM ($i/$max_attempts)... (connection=${status:-unknown})"
    sleep 10
  done
  err "SSM agent did not become online for $instance_id"
}

send_ssm_command_retry() {
  local instance_id="$1"
  local comment="$2"
  local commands_json="$3"
  local max_attempts="${4:-15}"

  local cmd_id=""
  for i in $(seq 1 "$max_attempts"); do
    cmd_id=$(aws ssm send-command \
      --region "$AWS_REGION" \
      --instance-ids "$instance_id" \
      --document-name "AWS-RunShellScript" \
      --comment "$comment" \
      --parameters "commands=${commands_json}" \
      --query "Command.CommandId" \
      --output text 2>/dev/null || true)
    if [[ -n "$cmd_id" && "$cmd_id" != "None" ]]; then
      echo "$cmd_id"
      return 0
    fi
    sleep 10
  done
  return 1
}

wait_for_ssm_command_success() {
  local command_id="$1"
  local instance_id="$2"
  local max_attempts="${3:-30}"

  for i in $(seq 1 "$max_attempts"); do
    local status
    status=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query "Status" --output text 2>/dev/null || echo "Pending")
    case "$status" in
      Success) return 0 ;;
      Failed|Cancelled|TimedOut)
        aws ssm get-command-invocation \
          --region "$AWS_REGION" \
          --command-id "$command_id" \
          --instance-id "$instance_id" \
          --query "{Status:Status,StdOut:StandardOutputContent,StdErr:StandardErrorContent}" \
          --output json 2>/dev/null || true
        return 1
        ;;
    esac
    sleep 5
  done
  return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Prerequisites
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 1 — Checking prerequisites..."
for cmd in aws terraform bun python3; do
  command -v "$cmd" &>/dev/null || err "'$cmd' not found in PATH"
done
if [[ "${AGENTCORE_RUNTIME_DEPLOYMENT_MODE:-code}" == "code" ]]; then
  command -v zip &>/dev/null || err "'zip' not found in PATH (required for AgentCore code artifacts)"
fi
# Docker is needed in Phase 6 to build + push API/UI/runtime images. Fail
# now (before Atlas + AWS resources are created) instead of 30 minutes into
# the deploy. Skip the check when --skip-docker is set.
if [[ "$SKIP_DOCKER" != "true" ]]; then
  command -v docker &>/dev/null || err "'docker' not found in PATH (required for image build/push; pass --skip-docker to bypass)"
  docker info &>/dev/null || err "'docker' is installed but the daemon is not reachable — start Docker Desktop / dockerd, or pass --skip-docker"
fi
ok "All prerequisites found"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Load credentials
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 2 — Loading credentials from $ENV_FILE..."
[[ -f "$ENV_FILE" ]] || err "env file not found: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

# ── Connectivity mode (default privatelink to preserve existing behavior) ───
NETWORK_MODE="${NETWORK_MODE:-privatelink}"
ATLAS_PEERING_CIDR="${ATLAS_PEERING_CIDR:-192.168.248.0/21}"
case "$NETWORK_MODE" in
  privatelink|peering) ;;
  *) err "Invalid NETWORK_MODE='${NETWORK_MODE}' — must be 'privatelink' or 'peering'" ;;
esac
export TF_VAR_network_mode="$NETWORK_MODE"
ok "Network mode: ${NETWORK_MODE}"

export TF_VAR_atlas_db_password="${TF_VAR_atlas_db_password:-${TF_VAR_mongodb_password:-}}"
[[ -n "${TF_VAR_atlas_db_password:-}" ]] || err "Atlas DB password not set. Set TF_VAR_mongodb_password in .env"

export TF_VAR_atlas_project_id="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
[[ -n "${TF_VAR_atlas_project_id:-}" ]] || err "Atlas Project ID not set. Set TF_VAR_mongodb_atlas_project_id in .env"

export TF_VAR_atlas_public_key="${MONGODB_ATLAS_PUBLIC_KEY:-}"
export TF_VAR_atlas_private_key="${MONGODB_ATLAS_PRIVATE_KEY:-}"
[[ -n "${TF_VAR_atlas_public_key:-}" ]]  || err "MONGODB_ATLAS_PUBLIC_KEY not set in .env"
[[ -n "${TF_VAR_atlas_private_key:-}" ]] || err "MONGODB_ATLAS_PRIVATE_KEY not set in .env"

DEPLOY_DIAG_LABEL="ec2"
# shellcheck source=deploy/scripts/_deploy-diagnostics.sh
source "$SCRIPT_DIR/_deploy-diagnostics.sh"
deploy_diag_install_error_trap

# shellcheck source=deploy/scripts/_aws-auth.sh
source "$SCRIPT_DIR/_aws-auth.sh"
validate_aws_auth || err "AWS auth validation failed (see above)"
ACCOUNT_ID="$AWS_AUTH_ACCOUNT_ID"

# ── Centralized preflight checks: pre-apply (see docs/deployment-preflight-checks.md) ──
# shellcheck source=deploy/scripts/_preflight-checks.sh
source "$SCRIPT_DIR/_preflight-checks.sh"
preflight_validate project-pre-apply
deploy_diag_after_preflight "project-pre-apply" "$ENV_FILE"

ok "AWS account: $ACCOUNT_ID"
ok "Atlas project: $TF_VAR_atlas_project_id"

# ── Atlas API key validation ─────────────────────────────────────────────────
log "Verifying Atlas API key access..."
_ATLAS_HTTP=$(curl -s -o /tmp/.atlas_check.json -w "%{http_code}" \
  --user "${MONGODB_ATLAS_PUBLIC_KEY}:${MONGODB_ATLAS_PRIVATE_KEY}" \
  --digest \
  -H "Accept: application/vnd.atlas.2023-01-01+json" \
  "https://cloud.mongodb.com/api/atlas/v2/groups/${TF_VAR_atlas_project_id}" \
  2>/dev/null) || _ATLAS_HTTP="000"
case "$_ATLAS_HTTP" in
  200)
    _ATLAS_NAME=$(python3 -c "import json; d=json.load(open('/tmp/.atlas_check.json')); print(d.get('name','?'))" 2>/dev/null || echo "?")
    ok "Atlas API keys valid — project: ${_ATLAS_NAME}" ;;
  401) err "Atlas API keys invalid (HTTP 401). Check MONGODB_ATLAS_PUBLIC_KEY / MONGODB_ATLAS_PRIVATE_KEY in .env" ;;
  403) err "Atlas API keys valid but forbidden (HTTP 403). Verify the key has Project Owner role." ;;
  404) err "Atlas project not found (HTTP 404). Check TF_VAR_mongodb_atlas_project_id in .env" ;;
  000) warn "Atlas API unreachable (curl failed) — check network. Proceeding." ;;
  *)   warn "Atlas API returned HTTP $_ATLAS_HTTP — unexpected. Proceeding cautiously." ;;
esac
rm -f /tmp/.atlas_check.json

SHARED_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-${ACCOUNT_ID}"
VOYAGE_ARN="${VOYAGE_MODEL_PACKAGE_ARN:-}"
VOYAGE_INSTANCE="${VOYAGE_INSTANCE_TYPE:-ml.g6.xlarge}"
VOYAGE_REQUEST_FORMAT="${VOYAGE_REQUEST_FORMAT:-}"
VOYAGE_MARKETPLACE_MODEL="${VOYAGE_MARKETPLACE_MODEL:-}"
VOYAGE_MODEL_LABEL=""
EMBEDDINGS_MODEL_ID=""
EMBEDDINGS_SOW_ALIGNED="false"
VOYAGE_ENDPOINT_SUFFIX="${TF_VAR_voyage_endpoint_name_suffix:-}"
EC2_KEY_PAIR="${EC2_KEY_PAIR:-}"
AGENTCORE_RUNTIME_DEPLOYMENT_MODE="${AGENTCORE_RUNTIME_DEPLOYMENT_MODE:-code}"
GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
AGENTCORE_CODE_ARTIFACT_PREFIX="artifacts/agentcore-runtime/${GIT_SHA}/deployment_package.zip"

# ── Embedding provider guard: explicit opt-in, no silent fallback ─────────────
# The pipeline supports three explicit modes:
#   titan  — no SageMaker endpoint, query/doc embeddings use Bedrock Titan v2.
#   voyage — provision SageMaker from VOYAGE_MODEL_PACKAGE_ARN. Supported request
#            envelopes are selected by VOYAGE_REQUEST_FORMAT:
#              multimodal -> voyage-multimodal-3
#              legacy     -> voyage-3.5-lite / older text-only Voyage listing
EMBEDDINGS_PROVIDER="${EMBEDDINGS_PROVIDER:-}"
case "$EMBEDDINGS_PROVIDER" in
  voyage)
    if [[ -z "$VOYAGE_ARN" ]]; then
      err "EMBEDDINGS_PROVIDER=voyage but VOYAGE_MODEL_PACKAGE_ARN is empty.
       Run: ./deploy/scripts/setup-voyage-marketplace.sh   (one-time, opens Marketplace)
       Then re-source .env and re-run this script."
    fi
    # Marketplace ARN tail format:
    #   arn:aws:sagemaker:<region>:<vendor>:model-package/<package-name>
    # AWS Marketplace package names may include vendor version suffixes such as
    # `voyage-multimodal-3-5-v1-<hash>`. Keep provider routing based on the
    # canonical model family, but preserve the exact tail in deploy-manifest.json
    # so version suffixes never disappear silently.
    VOYAGE_ARN_TAIL="${VOYAGE_ARN##*/}"
    if [[ "$VOYAGE_ARN_TAIL" =~ ^voyage-multimodal-3($|-) ]]; then
      VOYAGE_MODEL_LABEL="voyage-multimodal-3"
      VOYAGE_REQUEST_FORMAT="${VOYAGE_REQUEST_FORMAT:-multimodal}"
      [[ "$VOYAGE_REQUEST_FORMAT" == "multimodal" ]] || err "voyage-multimodal-3 requires VOYAGE_REQUEST_FORMAT=multimodal"
      EMBEDDINGS_SOW_ALIGNED="true"
    elif [[ "$VOYAGE_ARN_TAIL" =~ ^voyage-3-5-lite($|-) ]]; then
      VOYAGE_MODEL_LABEL="voyage-3-5-lite"
      VOYAGE_REQUEST_FORMAT="${VOYAGE_REQUEST_FORMAT:-legacy}"
      [[ "$VOYAGE_REQUEST_FORMAT" == "legacy" ]] || err "voyage-3-5-lite requires VOYAGE_REQUEST_FORMAT=legacy"
    else
      VOYAGE_MODEL_LABEL="$VOYAGE_MARKETPLACE_MODEL"
      [[ -n "$VOYAGE_MODEL_LABEL" && "$VOYAGE_MODEL_LABEL" != "voyage-multimodal-3" ]] || err "Could not infer Voyage model from VOYAGE_MODEL_PACKAGE_ARN tail '$VOYAGE_ARN_TAIL'.
       Set VOYAGE_MARKETPLACE_MODEL to the selected custom model and VOYAGE_REQUEST_FORMAT to multimodal or legacy."
      [[ "$VOYAGE_REQUEST_FORMAT" == "multimodal" || "$VOYAGE_REQUEST_FORMAT" == "legacy" ]] || err "Custom Voyage model '$VOYAGE_MODEL_LABEL' requires VOYAGE_REQUEST_FORMAT=multimodal or legacy"
    fi
    EMBEDDINGS_MODEL_ID="$VOYAGE_ARN_TAIL"
    VOYAGE_MARKETPLACE_MODEL="$VOYAGE_MODEL_LABEL"
    if [[ -z "$VOYAGE_ENDPOINT_SUFFIX" ]]; then
      VOYAGE_ENDPOINT_SUFFIX="$(echo "$VOYAGE_MODEL_LABEL" | tr '[:upper:]' '[:lower:]' | sed -E 's/[_.]/-/g; s/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
    fi
    ok "Embeddings: ${VOYAGE_MODEL_LABEL} via SageMaker (${VOYAGE_REQUEST_FORMAT} request format; package ${VOYAGE_ARN_TAIL})"
    ;;
  titan)
    # Explicit, deliberate deviation from the SoW — Bedrock Titan v2 only. No
    # SageMaker endpoint is created; API + runtimes embed via Bedrock. Override
    # any leaked VOYAGE_ARN so the tfvars block below cannot trigger SageMaker.
    VOYAGE_ARN=""
    VOYAGE_MODEL_LABEL=""
    EMBEDDINGS_MODEL_ID="amazon.titan-embed-text-v2:0"
    VOYAGE_REQUEST_FORMAT="${VOYAGE_REQUEST_FORMAT:-multimodal}"
    warn "═══════════════════════════════════════════════════════════════════════"
    warn "  EMBEDDINGS_PROVIDER=titan — explicit deviation from SoW"
    warn "  Voyage SageMaker endpoint will NOT be provisioned."
    warn "  Embeddings: amazon.titan-embed-text-v2:0 (1024-d) via Bedrock."
    warn "  This is recorded in deploy-manifest.json. To restore SoW alignment,"
    warn "  set EMBEDDINGS_PROVIDER=voyage and re-run setup-voyage-marketplace.sh."
    warn "═══════════════════════════════════════════════════════════════════════"
    ;;
  "")
    err "EMBEDDINGS_PROVIDER is not set — refusing to deploy with an implicit default.
       Set one of the following in .env (or your shell) and re-source it:
         export EMBEDDINGS_PROVIDER=voyage   # SoW-aligned, requires Marketplace subscription
         export EMBEDDINGS_PROVIDER=titan    # explicit deviation, Bedrock Titan v2"
    ;;
  *)
    err "EMBEDDINGS_PROVIDER='$EMBEDDINGS_PROVIDER' is not recognised. Use 'voyage' or 'titan'."
    ;;
esac
export VOYAGE_REQUEST_FORMAT
export VOYAGE_MARKETPLACE_MODEL
export EMBEDDINGS_MODEL_ID
export EMBEDDINGS_SOW_ALIGNED
export VOYAGE_ENDPOINT_SUFFIX

# Re-read SHARED_VPC_NAME after sourcing .env so a .env override wins.
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Bootstrap (idempotent)
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 3 — Checking bootstrap state..."
if aws s3api head-bucket --bucket "$SHARED_BUCKET" 2>/dev/null; then
  ok "Shared bucket exists — skipping bootstrap"
else
  log "Bucket not found — running bootstrap (one-time)..."
  deploy_diag_terraform_context "bootstrap terraform" "$BOOTSTRAP_DIR" "" ""
  cd "$BOOTSTRAP_DIR"
  deploy_diag_checkpoint "terraform bootstrap init: terraform init -input=false -no-color"
  terraform init -input=false -no-color
  deploy_diag_checkpoint "terraform bootstrap apply: terraform apply -input=false -auto-approve -var account_id=<account> -var aws_region=${AWS_REGION} -var environment=${ENVIRONMENT} -var project_name=${PROJECT_NAME}"
  terraform apply -input=false -auto-approve \
    -var="account_id=$ACCOUNT_ID" \
    -var="aws_region=$AWS_REGION" \
    -var="environment=$ENVIRONMENT" \
    -var="project_name=$PROJECT_NAME"
  ok "Bootstrap complete"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3b — Verify shared network is applied
# envs/ec2 reads VPC + subnet IDs + Atlas VPCE details from SSM under
# /${SHARED_VPC_NAME}/${AWS_REGION}/. Surface a clean error if the operator
# hasn't applied envs/network yet — terraform itself would also fail with
# ParameterNotFound, but a precheck gives a nicer remediation hint.
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 3b — Verifying shared network is applied (SSM /${SHARED_VPC_NAME}/${AWS_REGION}/...)"

SHARED_SSM_PARAMS=(
  "vpc_id"
  "vpc_cidr"
  "public_subnet_ids"
  "private_subnet_ids"
  "network_mode"
)
if [[ "$NETWORK_MODE" == "privatelink" ]]; then
  MODE_SSM_PARAMS=(
    "atlas_pl_vpce_id"
    "atlas_pl_vpce_dns_name"
  )
else
  MODE_SSM_PARAMS=(
    "atlas_peering_id"
    "atlas_container_id"
    "atlas_peering_cidr"
  )
fi
REQUIRED_SSM_PARAMS=("${SHARED_SSM_PARAMS[@]}" "${MODE_SSM_PARAMS[@]}")
_MISSING=()
for p in "${REQUIRED_SSM_PARAMS[@]}"; do
  aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/${p}" \
    --query "Parameter.Value" --output text >/dev/null 2>&1 \
    || _MISSING+=("$p")
done
if (( ${#_MISSING[@]} > 0 )); then
  err "Shared network not found / wrong mode (missing SSM params: ${_MISSING[*]}). Run ./deploy/scripts/deploy-network.sh with NETWORK_MODE=${NETWORK_MODE} first."
fi
ok "Shared network ready (${#REQUIRED_SSM_PARAMS[@]} SSM params found for mode=${NETWORK_MODE})"

# Cross-check: SSM-recorded network_mode must match this script's NETWORK_MODE.
# Catches the case where envs/network was applied in the other mode (envs/ec2
# would also catch it via the `check` block but a precheck gives a nicer
# remediation hint).
SHARED_NETWORK_MODE=$(aws ssm get-parameter \
  --region "$AWS_REGION" \
  --name "/${SHARED_VPC_NAME}/${AWS_REGION}/network_mode" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")
if [[ "$SHARED_NETWORK_MODE" != "$NETWORK_MODE" ]]; then
  err "NETWORK MODE MISMATCH: shared network reports mode='${SHARED_NETWORK_MODE}' but env says '${NETWORK_MODE}'.
     PrivateLink and VPC peering are mutually exclusive per account. To switch modes run:
       ./deploy/scripts/destroy.sh --mode ec2
       ./deploy/scripts/destroy.sh --mode shared    # optional
       ./deploy/scripts/destroy.sh --mode network
     Then re-run deploy-network.sh with the desired NETWORK_MODE before re-running this script."
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — Generate Terraform config (envs/ec2)
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 4 — Generating Terraform config for envs/ec2..."

cat > "$TF_DIR/backend.hcl" <<EOF
bucket  = "${SHARED_BUCKET}"
key     = "${ENVIRONMENT}/ec2/terraform.tfstate"
region  = "${AWS_REGION}"
encrypt = true
# dynamodb_table omitted — SCP on this account blocks DynamoDB CreateTable.
EOF
ok "backend.hcl written (state key: ${ENVIRONMENT}/ec2/terraform.tfstate)"

cat > "$TF_DIR/terraform.tfvars" <<EOF
# EC2 mode — generated by deploy.sh
aws_region         = "${AWS_REGION}"
environment        = "${ENVIRONMENT}"
project_name       = "${PROJECT_NAME}"
shared_bucket_name = "${SHARED_BUCKET}"

# Shared network (envs/network) — drives the SSM prefix this env reads from.
# VPC + subnets + Atlas-PL VPCE all come from /${SHARED_VPC_NAME}/${AWS_REGION}/.
shared_vpc_name    = "${SHARED_VPC_NAME}"

# MongoDB Atlas (cluster provisioned by Terraform in this env)
atlas_project_id = "${TF_VAR_atlas_project_id}"
atlas_db_user    = "${ATLAS_DB_USER}"
atlas_db_name    = "${ATLAS_DB_NAME}"
# atlas_db_password / atlas_public_key / atlas_private_key → TF_VAR env vars

# Bedrock KB — Titan used for ingestion (KB requires Bedrock-native embedding)
# kb_iam_role_name omitted on purpose — bedrock-kb module derives a unique
# IAM role name from project_name + environment so parallel deploys do not collide.
embed_model_id   = "amazon.titan-embed-text-v2:0"

# EC2 — SSM Session Manager for shell access (no SSH key required)
ec2_instance_type = "t3.medium"
ec2_key_pair_name = "${EC2_KEY_PAIR}"

# Voyage AI SageMaker variables intentionally NOT passed here — the SageMaker
# endpoint is provisioned once by envs/shared (deploy-shared.sh) per
# (account, region, environment) and read via SSM by this per-project ec2 stack.
# See local.shared_voyage_endpoint_{name,arn} in envs/ec2/main.tf.

# AgentCore Memory TTL
agentcore_memory_expiry_days = 30
agentcore_runtime_deployment_mode = "${AGENTCORE_RUNTIME_DEPLOYMENT_MODE}"
agentcore_code_artifact_prefix    = "${AGENTCORE_CODE_ARTIFACT_PREFIX}"

# Connectivity mode — must match the mode the shared network was applied in
# (verified by the SSM canary above and by the \`check "network_mode_matches_shared"\`
# block in envs/ec2/main.tf). Switching modes requires destroy + redeploy.
network_mode      = "${NETWORK_MODE}"
EOF

# AgentCore runtime VPCEs (ECR API, ECR DKR, Logs) are VPC-scoped singletons with
# private_dns_enabled=true — only ONE set per VPC. When a second project deploys
# into the same SHARED_VPC_NAME, creating them again fails with:
#   "conflicting DNS domain for *.dkr.ecr... in the VPC"
# Auto-detect existing endpoints and reuse via data.aws_vpc_endpoint + SG rules.
SHARED_VPC_ID=$(aws ssm get-parameter --region "$AWS_REGION" \
  --name "/${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id" \
  --query Parameter.Value --output text 2>/dev/null || echo "")
CREATE_AGENTCORE_VPCE="true"
if [[ -n "$SHARED_VPC_ID" && "$SHARED_VPC_ID" != "None" ]]; then
  MANAGED_AGENTCORE_VPCE_COUNT=$(terraform -chdir="$TF_DIR" state list 2>/dev/null \
    | python3 -c 'import sys
managed = [line.strip() for line in sys.stdin if line.strip().startswith("aws_vpc_endpoint.agentcore_runtime_")]
print(len(managed))' 2>/dev/null || echo "0")
  EXISTING_VPCE_COUNT=$(aws ec2 describe-vpc-endpoints --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${SHARED_VPC_ID}" \
    --query "length(VpcEndpoints[?ServiceName=='com.amazonaws.${AWS_REGION}.ecr.api' || ServiceName=='com.amazonaws.${AWS_REGION}.ecr.dkr' || ServiceName=='com.amazonaws.${AWS_REGION}.logs'])" \
    --output text 2>/dev/null || echo "0")
  if [[ "${MANAGED_AGENTCORE_VPCE_COUNT:-0}" -gt 0 ]]; then
    CREATE_AGENTCORE_VPCE="true"
    log "Shared VPC ${SHARED_VPC_ID} has AgentCore ECR/Logs VPCEs managed by this Terraform state — keeping ownership (create_agentcore_runtime_vpc_endpoints=true)"
  elif [[ "${EXISTING_VPCE_COUNT:-0}" -ge 3 ]]; then
    CREATE_AGENTCORE_VPCE="false"
    log "Shared VPC ${SHARED_VPC_ID} already has AgentCore ECR/Logs VPCEs — reusing (create_agentcore_runtime_vpc_endpoints=false)"
  fi
fi
echo "create_agentcore_runtime_vpc_endpoints = ${CREATE_AGENTCORE_VPCE}" >> "$TF_DIR/terraform.tfvars"

ok "terraform.tfvars written (network_mode=${NETWORK_MODE}, create_agentcore_runtime_vpc_endpoints=${CREATE_AGENTCORE_VPCE})"

# ── Phase 4a — Discover agents + write agents.auto.tfvars.json ────────────────
sep
log "Phase 4a — Discovering agents from config/agents/..."
discover_agents
validate_handoff_consistency "warn"
write_specialist_agents_tfvars

# ── Phase 4b — Build + upload AgentCore direct-code artifact ──────────────────
sep
log "Phase 4b — Building + uploading AgentCore direct-code artifact..."
build_and_upload_code_artifact

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4c — Shared-stack pre-flight check
#
# envs/ec2 reads /<SHARED_VPC_NAME>/<REGION>/voyage_sagemaker_endpoint_name
# (and the rest of the shared-stack SSM keys) at plan time. Failing inside
# `terraform plan` with a generic "ParameterNotFound" wastes a few minutes; a
# pre-flight probe surfaces the missing-prereq case with an actionable message.
# Only voyage_sagemaker_endpoint_name is enforced strictly here because the
# value-vs-"_empty_" sentinel distinction is the one downstream agent IAM
# depends on (sagemaker:InvokeEndpoint scoping).
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 4c — Shared-stack pre-flight check..."
SHARED_VOYAGE_PARAM="/${SHARED_VPC_NAME}/${AWS_REGION}/voyage_sagemaker_endpoint_name"
SHARED_VOYAGE_VAL="$(aws ssm get-parameter \
  --region "$AWS_REGION" \
  --name "$SHARED_VOYAGE_PARAM" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")"

if [[ -z "$SHARED_VOYAGE_VAL" ]]; then
  err "Shared stack has not been applied — SSM parameter $SHARED_VOYAGE_PARAM is missing.
     Run: ./deploy/scripts/deploy-shared.sh --env-file $ENV_FILE
     (or use ./deploy/deploy-full-with-privatelink.sh which does this for you.)"
fi

if [[ "$EMBEDDINGS_PROVIDER" == "voyage" ]]; then
  if [[ "$SHARED_VOYAGE_VAL" == "_empty_" ]]; then
    err "EMBEDDINGS_PROVIDER=voyage but the shared stack provisioned no SageMaker endpoint
     ($SHARED_VOYAGE_PARAM is the '_empty_' sentinel — meaning VOYAGE_MODEL_PACKAGE_ARN
     was unset when deploy-shared.sh last ran).
     Fix: export VOYAGE_MODEL_PACKAGE_ARN in .env and re-run deploy-shared.sh."
  fi
  ok "Shared Voyage endpoint: $SHARED_VOYAGE_VAL"
else
  ok "Shared stack present (voyage endpoint: ${SHARED_VOYAGE_VAL/#_empty_/<not provisioned, EMBEDDINGS_PROVIDER=titan>})"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4d — Pre-apply: build + push the mongodb-mcp runtime image
#
# The mongodb-mcp AgentCore Runtime uses container deployment mode (it's an
# Express/MCP-SDK server, not the direct-code Strands shape) and AgentCore
# refuses to bring it READY if `:latest` doesn't exist in ECR. So we apply
# JUST the ECR repo first, push the image, and then let the full apply
# create the runtime against an existing image.
#
# Skipped when --skip-docker is set.
# ══════════════════════════════════════════════════════════════════════════════
sep
cd "$TF_DIR"
deploy_diag_terraform_context "ec2 terraform init" "$TF_DIR" "$TF_DIR/backend.hcl" "$TF_DIR/.tfplan"
log "Phase 5 — terraform init..."
deploy_diag_checkpoint "terraform init start: terraform init -input=false -reconfigure -backend-config=${TF_DIR}/backend.hcl"
terraform init -input=false -reconfigure -backend-config="$TF_DIR/backend.hcl"
ok "init complete"

if [[ "$SKIP_DOCKER" != "true" ]]; then
  sep
  log "Phase 4d — Ensuring mongodb-mcp runtime ECR repo, then push image..."
  MCP_RUNTIME_REPO_NAME="${PROJECT_NAME}-mongodb-mcp-${ENVIRONMENT}"
  MCP_RUNTIME_REPO="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${MCP_RUNTIME_REPO_NAME}"

  if ! aws ecr describe-repositories \
    --region "$AWS_REGION" \
    --repository-names "$MCP_RUNTIME_REPO_NAME" >/dev/null 2>&1; then
    log "  creating ECR repo → $MCP_RUNTIME_REPO_NAME"
    aws ecr create-repository \
      --region "$AWS_REGION" \
      --repository-name "$MCP_RUNTIME_REPO_NAME" \
      --image-tag-mutability MUTABLE \
      --image-scanning-configuration scanOnPush=true >/dev/null
  fi

  # Do not use `terraform -target` here. Targeted plans break when unrelated
  # resources have moved addresses, and they can hide drift in the rest of the
  # stack. If this is a first deploy, import the repo so the following normal
  # full plan owns it and can manage the lifecycle policy idempotently.
  if ! terraform state list 2>/dev/null | awk '$0 == "aws_ecr_repository.mongodb_mcp_runtime" { found = 1 } END { exit !found }'; then
    log "  importing ECR repo into Terraform state → aws_ecr_repository.mongodb_mcp_runtime"
    deploy_diag_checkpoint "terraform import start: terraform import -input=false aws_ecr_repository.mongodb_mcp_runtime ${MCP_RUNTIME_REPO_NAME}"
    terraform import -input=false aws_ecr_repository.mongodb_mcp_runtime "$MCP_RUNTIME_REPO_NAME" >/dev/null
  fi

  ECR_REGISTRY=$(echo "$MCP_RUNTIME_REPO" | cut -d'/' -f1)
  log "  ECR login → $ECR_REGISTRY"
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null
  log "  building mongodb-mcp-runtime image (linux/arm64)..."
  docker buildx build \
    --platform linux/arm64 \
    -f "$REPO_ROOT/mcp-runtimes/mongodb-mcp/Dockerfile" \
    -t "${MCP_RUNTIME_REPO}:latest" \
    --push \
    "$REPO_ROOT/mcp-runtimes/mongodb-mcp" >/dev/null
  ok "mongodb-mcp-runtime pushed: ${MCP_RUNTIME_REPO}:latest"
fi

sep
log "Running terraform plan..."
deploy_diag_checkpoint "terraform plan start: terraform plan -input=false -out=${TF_DIR}/.tfplan"
terraform plan -input=false -out="$TF_DIR/.tfplan"
ok "plan complete"

sep
log "NOTE: First apply creates Atlas M10 (~5-10 min), AgentCore resources, and EC2."

if [[ "$AUTO_APPROVE" == "true" ]]; then
  log "Applying..."
  apply_with_retry "$TF_DIR/.tfplan"
else
  echo ""
  read -r -p "  Apply? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Cancelled."; exit 0; }
  apply_with_retry "$TF_DIR/.tfplan"
fi
ok "Terraform apply complete"

# ── Outputs ──────────────────────────────────────────────────────────────────
load_tf_outputs() {
  EC2_IP=$(terraform output -raw ec2_public_ip 2>/dev/null || echo "")
  EC2_API=$(terraform output -raw ec2_api_url 2>/dev/null || echo "")
  EC2_UI=$(terraform output -raw ec2_ui_url 2>/dev/null || echo "")
  EC2_SSM=$(terraform output -raw ec2_ssm_command 2>/dev/null || echo "")
  EC2_INSTANCE_ID=$(terraform output -raw ec2_instance_id 2>/dev/null || echo "")
  ATLAS_MONGO_HOST=$(terraform output -raw atlas_mongo_host 2>/dev/null || echo "")
  ATLAS_CONNECTION_STRING=$(terraform output -raw atlas_connection_string 2>/dev/null || echo "")
  COGNITO_POOL_ID=$(terraform output -raw cognito_user_pool_id 2>/dev/null || echo "")
  COGNITO_CLIENT_ID=$(terraform output -raw cognito_app_client_id 2>/dev/null || echo "")
  COGNITO_JWKS=$(terraform output -raw cognito_jwks_uri 2>/dev/null || echo "")
  VOYAGE_ENDPOINT=$(terraform output -raw voyage_endpoint_name 2>/dev/null || echo "")
  ECR_API_REPO=$(terraform output -raw ecr_api_repository_url 2>/dev/null || echo "")
  ECR_UI_REPO=$(terraform output -raw ecr_ui_repository_url 2>/dev/null || echo "")
  ECR_RUNTIME_REPO=$(terraform output -raw ecr_agent_runtime_repository_url 2>/dev/null || echo "")
  ECR_MCP_RUNTIME_REPO=$(terraform output -raw ecr_mongodb_mcp_runtime_repository_url 2>/dev/null || echo "")
  MONGODB_MCP_RUNTIME_ARN=$(terraform output -raw mongodb_mcp_runtime_arn 2>/dev/null || echo "")
  MONGODB_MCP_RUNTIME_ENDPOINT=$(terraform output -raw mongodb_mcp_runtime_endpoint 2>/dev/null || echo "")
  AGENTCORE_RUNTIME_DEPLOYMENT_MODE=$(terraform output -raw agentcore_runtime_deployment_mode 2>/dev/null || echo "$AGENTCORE_RUNTIME_DEPLOYMENT_MODE")
  AGENTCORE_CODE_ARTIFACT_PREFIX=$(terraform output -raw agentcore_code_artifact_prefix 2>/dev/null || echo "$AGENTCORE_CODE_ARTIFACT_PREFIX")
  AGENTCORE_MEMORY_STORE_ID=$(terraform output -raw agentcore_memory_id 2>/dev/null || echo "")
  AGENTCORE_GATEWAY_URL=$(terraform output -raw agentcore_gateway_url 2>/dev/null || echo "")
  AGENTCORE_ORCHESTRATOR_ARN=$(terraform output -raw acr_orchestrator_arn 2>/dev/null || echo "")
  AGENTCORE_ORCHESTRATOR_ID=$(terraform output -raw acr_orchestrator_id 2>/dev/null || echo "")
  # Load specialist ARNs + IDs from the for_each map outputs.
  # The list of specialist IDs comes from discover_agents (config/agents/*.agent.md),
  # so no agent IDs are hardcoded here.
  load_specialist_outputs_from_tf
  ATLAS_PRIVATELINK_ENDPOINT_ID=$(terraform output -raw atlas_privatelink_endpoint_id 2>/dev/null || echo "")
  CW_API_LOG_GROUP=$(terraform output -raw cloudwatch_api_log_group 2>/dev/null || echo "/${PROJECT_NAME}/${ENVIRONMENT}/api")
  CW_UI_LOG_GROUP=$(terraform output -raw cloudwatch_ui_log_group 2>/dev/null || echo "/${PROJECT_NAME}/${ENVIRONMENT}/ui")
}

load_tf_outputs

# Runtime outputs are file-backed by create-runtime scripts and can be empty
# immediately after apply in some edge cases. Refresh outputs once if needed.
if [[ -z "$AGENTCORE_ORCHESTRATOR_ARN" ]] || \
   ! python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d else 1)" \
     "$(terraform output -json acr_specialist_arns 2>/dev/null || echo '{}')" 2>/dev/null; then
  warn "AgentCore runtime outputs incomplete after apply; running refresh-only apply to rehydrate outputs..."
  terraform apply -refresh-only -auto-approve -input=false >/dev/null 2>&1 || true
  load_tf_outputs
fi

[[ -n "$EC2_IP" ]]        || err "EC2 instance IP not in outputs. Check terraform apply logs."
[[ -n "$ECR_API_REPO" ]]  || err "ECR API repo URL not in outputs."
[[ -n "$ATLAS_MONGO_HOST" ]] || err "Atlas host not in outputs."
[[ -n "$AGENTCORE_ORCHESTRATOR_ARN" ]] || err "AGENTCORE_ORCHESTRATOR_ARN output is empty after apply/refresh."
[[ -n "$AGENTCORE_ORCHESTRATOR_ID" ]] || err "AGENTCORE_ORCHESTRATOR_ID output is empty after apply/refresh."
[[ -n "$MONGODB_MCP_RUNTIME_ARN" ]] || err "MongoDB MCP runtime ARN output is empty after apply/refresh."
[[ -n "$MONGODB_MCP_RUNTIME_ENDPOINT" ]] || err "MongoDB MCP runtime endpoint output is empty after apply/refresh."
# Validate each discovered specialist has a runtime ARN in the map outputs.
for _spec_id in "${SPECIALIST_IDS[@]:-}"; do
  [[ -n "$(specialist_runtime_arn "$_spec_id")" ]] \
    || err "AgentCore runtime ARN for specialist '${_spec_id}' is empty after apply/refresh."
done
unset _spec_id

if [[ "$EMBEDDINGS_PROVIDER" == "voyage" ]]; then
  [[ -n "$VOYAGE_ENDPOINT" ]] || err "EMBEDDINGS_PROVIDER=voyage but Terraform output voyage_endpoint_name is empty."

  VOYAGE_ENDPOINT_STATUS="$(aws sagemaker describe-endpoint \
    --endpoint-name "$VOYAGE_ENDPOINT" \
    --region "$AWS_REGION" \
    --query 'EndpointStatus' --output text 2>/tmp/_voyage_endpoint_err.txt || true)"
  if [[ "$VOYAGE_ENDPOINT_STATUS" != "InService" ]]; then
    _VOYAGE_ERR="$(cat /tmp/_voyage_endpoint_err.txt 2>/dev/null || true)"
    err "Terraform output says Voyage endpoint '$VOYAGE_ENDPOINT' should exist, but SageMaker status is '${VOYAGE_ENDPOINT_STATUS:-missing}'.
       AWS error: ${_VOYAGE_ERR:-none}
       Refusing to continue because EMBEDDINGS_PROVIDER=voyage must not silently fall back or write a stale manifest."
  fi
  ok "Voyage endpoint verified InService: $VOYAGE_ENDPOINT"
fi

# Re-read KB ID post-apply (now sourced directly from terraform output —
# the legacy JSON state file at $KB_STATE_FILE is gone since the bedrock-kb
# module migrated to the native aws_bedrockagent_knowledge_base resource).
BEDROCK_KB_ID="$(terraform output -raw knowledge_base_id 2>/dev/null || echo "")"

# Build Mongo URI once for both runtime updates and .env.live output.
if [[ -n "$ATLAS_CONNECTION_STRING" ]]; then
  MONGODB_URI="$ATLAS_CONNECTION_STRING"
else
  MONGODB_URI="mongodb+srv://${ATLAS_DB_USER}:${TF_VAR_atlas_db_password}@${ATLAS_MONGO_HOST}/?retryWrites=true&w=majority"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5b — First-time MongoDB seeding (idempotent)
# Seed demo collections only when core collections are missing/empty.
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 5b — Checking MongoDB seed state..."

SEED_NEEDED=$(MONGODB_URI="$MONGODB_URI" MONGODB_DB="$ATLAS_DB_NAME" \
  bun -e '
    import { MongoClient } from "mongodb";
    const uri = process.env.MONGODB_URI;
    const dbName = process.env.MONGODB_DB;
    if (!dbName) { console.error("MONGODB_DB env not set"); process.exit(1); }
    const client = new MongoClient(uri, { appName: "deploy-seed-check" });
    await client.connect();
    const db = client.db(dbName);
    const required = ["customers", "products", "orders", "troubleshooting_docs"];
    let seeded = true;
    for (const coll of required) {
      const exists = (await db.listCollections({ name: coll }, { nameOnly: true }).toArray()).length > 0;
      if (!exists) {
        seeded = false;
        break;
      }
      const count = await db.collection(coll).countDocuments();
      if (count === 0) {
        seeded = false;
        break;
      }
    }
    await client.close();
    process.stdout.write(seeded ? "no" : "yes");
  ' 2>/dev/null || echo "yes")

if [[ "$SEED_NEEDED" == "yes" ]]; then
  log "Atlas appears unseeded — running first-time seed scripts..."
  (
    cd "$REPO_ROOT"
    MONGODB_URI="$MONGODB_URI" MONGODB_DB="$ATLAS_DB_NAME" bun db-seeding/seed-all.ts
  )
  ok "MongoDB seed complete (seed-all)"
else
  ok "MongoDB already seeded — skipping first-time seed step"
fi

log "Reconciling MongoDB indexes (safe to re-run)..."
(
  cd "$REPO_ROOT"
  MONGODB_URI="$MONGODB_URI" \
    MONGODB_DB="$ATLAS_DB_NAME" \
    WAIT_FOR_ATLAS_SEARCH_INDEXES=1 \
    EMBEDDING_DIMENSIONS="${EMBEDDING_DIMENSIONS:-1024}" \
    bun db-seeding/seed-indexes.ts
)
ok "MongoDB indexes verified (seed-indexes)"

# ── Centralized preflight checks: post-apply (see docs/deployment-preflight-checks.md) ──
# shellcheck source=deploy/scripts/_preflight-checks.sh
source "$SCRIPT_DIR/_preflight-checks.sh"
preflight_validate project-post-apply

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5c — API MongoDB URI normalization
#
# privatelink mode: compute Atlas's awsPrivateLink direct URI (multi-host,
#   tlsAllowInvalidHostnames=true) so the EC2 API avoids SRV DNS edge-cases.
# peering mode: compute the cluster's connectionStrings.privateSrv (when
#   "Enable Private DNS for Peering" is on) else connectionStrings.private
#   (multi-host non-SRV). Peering hostnames are in the cluster's TLS SAN list,
#   so NO tlsAllowInvalidHostnames is needed.
#
# The mongodb-mcp AgentCore Runtime gets its MONGODB_URI baked in by
# Terraform (mode-aware in envs/ec2/main.tf), so this normalization is now
# API-only in both modes.
# ══════════════════════════════════════════════════════════════════════════════
sep
if [[ "$NETWORK_MODE" == "privatelink" ]]; then
  if [[ -z "$ATLAS_PRIVATELINK_ENDPOINT_ID" ]]; then
    err "Missing Atlas PrivateLink endpoint ID for deterministic deploy (privatelink mode)"
  fi
  log "Phase 5c — Computing Atlas awsPrivateLink direct URI for the EC2 API..."
  if API_PRIVATE_URI=$(ATLAS_PROJECT_ID="$TF_VAR_atlas_project_id" \
    CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}" \
    VPCE_ID="$ATLAS_PRIVATELINK_ENDPOINT_ID" \
    BASE_MONGODB_URI="$MONGODB_URI" \
    MONGODB_ATLAS_PUBLIC_KEY="${MONGODB_ATLAS_PUBLIC_KEY:-}" \
    MONGODB_ATLAS_PRIVATE_KEY="${MONGODB_ATLAS_PRIVATE_KEY:-}" \
    python3 - <<'PY'
import json, os, subprocess, urllib.parse
project = os.environ["ATLAS_PROJECT_ID"]
cluster = os.environ["CLUSTER_NAME"]
vpce_id = os.environ["VPCE_ID"]
base_uri = os.environ["BASE_MONGODB_URI"]
public_key = os.environ.get("MONGODB_ATLAS_PUBLIC_KEY", "")
private_key = os.environ.get("MONGODB_ATLAS_PRIVATE_KEY", "")
if not public_key or not private_key:
    raise SystemExit("missing Atlas API keys")
parsed = urllib.parse.urlsplit(base_uri)
user = urllib.parse.quote(urllib.parse.unquote(parsed.username or ""))
pwd = urllib.parse.quote(urllib.parse.unquote(parsed.password or ""))
resp = subprocess.check_output([
    "curl", "-s",
    "--user", f"{public_key}:{private_key}",
    "--digest",
    "-H", "Accept: application/vnd.atlas.2023-01-01+json",
    f"https://cloud.mongodb.com/api/atlas/v2/groups/{project}/clusters/{cluster}",
], text=True)
data = json.loads(resp)
pl_map = ((data.get("connectionStrings") or {}).get("awsPrivateLink") or {})
pl_conn = pl_map.get(vpce_id, "")
if not pl_conn:
    raise SystemExit(f"no awsPrivateLink connection string for endpoint {vpce_id}")
no_scheme = pl_conn.replace("mongodb://", "", 1)
# Atlas's awsPrivateLink direct connection serves a TLS cert whose SAN does
# NOT include the per-region privatelink hostname (pl-X-us-east-1.<id>.mongodb.net),
# so default hostname verification fails with "Hostname/IP does not match
# certificate's altnames". Per Atlas's official PrivateLink docs, callers
# using the direct multi-host privatelink URI must set tlsAllowInvalidHostnames=true.
# CA + chain + expiry verification remain enforced; only the hostname check is
# skipped — acceptable here because the connection traverses an AWS PrivateLink
# (private network, MitM would require an attacker inside our VPC).
print(f"mongodb://{user}:{pwd}@{no_scheme}&retryWrites=true&w=majority&tlsAllowInvalidHostnames=true")
PY
  ); then
    MONGODB_URI="$API_PRIVATE_URI"
    ok "API MongoDB URI normalized to awsPrivateLink direct connection string"
  else
    err "Could not compute Atlas awsPrivateLink URI for the API"
  fi
else
  # ── peering mode ───────────────────────────────────────────────────────────
  log "Phase 5c — Computing Atlas peering URI for the EC2 API..."
  if API_PRIVATE_URI=$(ATLAS_PROJECT_ID="$TF_VAR_atlas_project_id" \
    CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}" \
    BASE_MONGODB_URI="$MONGODB_URI" \
    MONGODB_ATLAS_PUBLIC_KEY="${MONGODB_ATLAS_PUBLIC_KEY:-}" \
    MONGODB_ATLAS_PRIVATE_KEY="${MONGODB_ATLAS_PRIVATE_KEY:-}" \
    python3 - <<'PY'
import json, os, subprocess, urllib.parse
project = os.environ["ATLAS_PROJECT_ID"]
cluster = os.environ["CLUSTER_NAME"]
base_uri = os.environ["BASE_MONGODB_URI"]
public_key = os.environ.get("MONGODB_ATLAS_PUBLIC_KEY", "")
private_key = os.environ.get("MONGODB_ATLAS_PRIVATE_KEY", "")
if not public_key or not private_key:
    raise SystemExit("missing Atlas API keys")
parsed = urllib.parse.urlsplit(base_uri)
user = urllib.parse.quote(urllib.parse.unquote(parsed.username or ""))
pwd = urllib.parse.quote(urllib.parse.unquote(parsed.password or ""))
resp = subprocess.check_output([
    "curl", "-s",
    "--user", f"{public_key}:{private_key}",
    "--digest",
    "-H", "Accept: application/vnd.atlas.2023-01-01+json",
    f"https://cloud.mongodb.com/api/atlas/v2/groups/{project}/clusters/{cluster}",
], text=True)
data = json.loads(resp)
conn = (data.get("connectionStrings") or {})
# Prefer SRV form (when "Enable Private DNS for Peering" is on); fall back to
# the multi-host non-SRV form (connection_strings[0].private). Both resolve
# to private peering IPs from inside the peered VPC.
priv_srv = conn.get("privateSrv") or ""
priv_multi = conn.get("private") or ""
if priv_srv:
    # mongodb+srv://<host>
    host = priv_srv.replace("mongodb+srv://", "", 1)
    print(f"mongodb+srv://{user}:{pwd}@{host}/?retryWrites=true&w=majority")
elif priv_multi:
    # mongodb://<authority>[/?...]
    no_scheme = priv_multi.replace("mongodb://", "", 1)
    sep_char = "&" if "?" in no_scheme else "/?"
    # Peering hostnames (*.<id>-pri.mongodb.net) ARE in the cert SAN list — no
    # tlsAllowInvalidHostnames needed (unlike PrivateLink).
    print(f"mongodb://{user}:{pwd}@{no_scheme}{sep_char}retryWrites=true&w=majority")
else:
    raise SystemExit("Atlas cluster has neither connectionStrings.privateSrv nor connectionStrings.private — peering not active yet?")
PY
  ); then
    MONGODB_URI="$API_PRIVATE_URI"
    # Sanity check — peering URIs MUST use the private DNS token (-pri).
    # Atlas may emit either legacy (*-pri.mongodb.net) or project-scoped
    # (*-pri.<shard-id>.mongodb.net) hostnames once Private DNS for Peering is on.
    if ! echo "$MONGODB_URI" | grep -qE '\-pri\.'; then
      err "Computed peering URI does not contain '-pri.' (private peering host) — would route over the public SRV. Aborting to preserve privacy parity."
    fi
    ok "API MongoDB URI normalized to peering connection string (private DNS form: $(echo "$MONGODB_URI" | grep -q 'mongodb+srv' && echo SRV || echo multi-host))"
  else
    err "Could not compute Atlas peering URI for the API. Verify the peering connection is ACTIVE and that Atlas has populated the cluster's connectionStrings.private[Srv]."
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5d — Cognito test user seeding (idempotent)
# Creates deterministic test users for auth validation, matching seeded orders.
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$COGNITO_SEED_USERS" == "true" ]]; then
  sep
  log "Phase 5d — Seeding Cognito test users..."

  [[ -n "$COGNITO_POOL_ID" ]] || err "cognito_user_pool_id output is empty."
  [[ -n "$COGNITO_CLIENT_ID" ]] || err "cognito_app_client_id output is empty."

  seed_cognito_user() {
    local email="$1"
    local name="$2"
    if aws cognito-idp admin-get-user \
      --region "$AWS_REGION" \
      --user-pool-id "$COGNITO_POOL_ID" \
      --username "$email" >/dev/null 2>&1; then
      :
    else
      aws cognito-idp admin-create-user \
        --region "$AWS_REGION" \
        --user-pool-id "$COGNITO_POOL_ID" \
        --username "$email" \
        --user-attributes "Name=email,Value=${email}" "Name=email_verified,Value=true" "Name=name,Value=${name}" \
        --message-action SUPPRESS >/dev/null \
        || err "Failed to create Cognito user ${email}"
    fi

    aws cognito-idp admin-set-user-password \
      --region "$AWS_REGION" \
      --user-pool-id "$COGNITO_POOL_ID" \
      --username "$email" \
      --password "$COGNITO_TEST_PASSWORD" \
      --permanent >/dev/null \
      || err "Failed setting deterministic password for Cognito user ${email}"
  }

  IFS=',' read -r -a COGNITO_TEST_USERS <<<"$COGNITO_TEST_USERS_CSV"
  for email in "${COGNITO_TEST_USERS[@]}"; do
    e_trimmed="$(echo "$email" | xargs)"
    [[ -n "$e_trimmed" ]] || continue
    case "$e_trimmed" in
      alex@example.com)  seed_cognito_user "$e_trimmed" "Alex Rivera" ;;
      blake@example.com) seed_cognito_user "$e_trimmed" "Blake Chen" ;;
      casey@example.com) seed_cognito_user "$e_trimmed" "Casey Morgan" ;;
      *)                 seed_cognito_user "$e_trimmed" "Demo User" ;;
    esac
  done
  ok "Cognito users ready: ${COGNITO_TEST_USERS_CSV}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — Build + push Docker images (API + UI = amd64; agent-runtime = arm64)
# ══════════════════════════════════════════════════════════════════════════════
sep
if [[ "$SKIP_DOCKER" == "true" ]]; then
  warn "Phase 6 — Skipping Docker build/push (--skip-docker)"
else
  log "Phase 6 — Building and pushing Docker images to ECR..."
  # docker-build-push.sh signature:
  #   <api_repo> <ui_repo> <aws_region> [agent_runtime_repo] [mongodb_mcp_runtime_repo]
  # mongodb-mcp runtime image is rebuilt here so any code changes between Phase 4d
  # and Phase 6 (rare in normal runs) land before the runtime updates in Phase 7.
  if [[ "$AGENTCORE_RUNTIME_DEPLOYMENT_MODE" == "container" ]]; then
    "$SCRIPT_DIR/docker-build-push.sh" "$ECR_API_REPO" "$ECR_UI_REPO" "$AWS_REGION" "$ECR_RUNTIME_REPO" "$ECR_MCP_RUNTIME_REPO"
  else
    "$SCRIPT_DIR/docker-build-push.sh" "$ECR_API_REPO" "$ECR_UI_REPO" "$AWS_REGION" "" "$ECR_MCP_RUNTIME_REPO"
  fi
  ok "Images pushed to ECR"
fi

ECR_API_IMAGE="${ECR_API_REPO}:latest"
ECR_UI_IMAGE="${ECR_UI_REPO}:latest"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6b — Update AgentCore runtimes with dynamic env vars
# Terraform creates static env vars; now inject dynamic vars (MongoDB URI, KB ID,
# Gateway URL, Memory ID). Orchestrator additionally gets specialist runtime ARNs.
# ══════════════════════════════════════════════════════════════════════════════
if [[ -n "$AGENTCORE_ORCHESTRATOR_ID" ]]; then
  sep
  log "Phase 6b — Updating AgentCore Runtime environment variables..."

  if [[ -z "${AGENTCORE_GATEWAY_URL:-}" ]]; then
    err "AGENTCORE_GATEWAY_URL is empty. Provision the AgentCore Gateway first (terraform apply)."
  fi

  export AWS_REGION MONGODB_URI ATLAS_DB_NAME BEDROCK_KB_ID \
         AGENTCORE_MEMORY_STORE_ID AGENTCORE_GATEWAY_URL \
         MONGODB_MCP_RUNTIME_ARN MONGODB_MCP_RUNTIME_ENDPOINT \
         VOYAGE_ENDPOINT EMBEDDINGS_PROVIDER VOYAGE_REQUEST_FORMAT \
         AGENTCORE_RUNTIME_DEPLOYMENT_MODE SHARED_BUCKET AGENTCORE_CODE_ARTIFACT_PREFIX \
         ECR_RUNTIME_REPO

  build_dynamic_env_base
  update_runtime_env_dynamic

  log "Phase 6c — Verifying runtime environment variables..."
  verify_runtime_env_dynamic
  ok "Runtime env verification passed"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 7 — Write .env.live + copy to EC2 via SSM
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 7 — Writing .env.live and copying to EC2 via SSM..."
ensure_agent_config_refresh_token

if [[ -n "$VOYAGE_ENDPOINT" ]]; then
  # Best-effort: derive the model package id from VOYAGE_MODEL_PACKAGE_ARN
  # so the .env.live banner doesn't lie about which Voyage variant is live.
  # Example ARN tail: model-package/voyage-3-5-lite-9e7d9de9...
  VOYAGE_MODEL_LABEL="unknown"
  VOYAGE_MODEL_TAIL="${VOYAGE_MODEL_PACKAGE_ARN##*/}"
  if [[ "$VOYAGE_MODEL_TAIL" =~ ^(.+)-[0-9a-f]{8,}$ ]]; then
    VOYAGE_MODEL_LABEL="${BASH_REMATCH[1]}"
  fi
  EMBEDDING_LINE="Voyage AI ${VOYAGE_MODEL_LABEL} (${VOYAGE_ENDPOINT})"
else
  EMBEDDING_LINE="Bedrock Titan (amazon.titan-embed-text-v2:0)"
fi

cat > "$REPO_ROOT/.env.live" <<EOF
# EC2 mode — generated by deploy.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Embedding: ${EMBEDDING_LINE}
# Tools:     MongoDB MCP direct AgentCore Runtime; Gateway for non-Mongo tools
# NOTE: plain KEY=VALUE only — no export, no quotes, no declare -x
ORCHESTRATOR_MODE=runtime
AGENT_CONFIG_REFRESH_TOKEN=${AGENT_CONFIG_REFRESH_TOKEN}

# MongoDB Atlas
MONGODB_URI=${MONGODB_URI}
MONGODB_DB=${ATLAS_DB_NAME}

# Bedrock
BEDROCK_KB_ID=${BEDROCK_KB_ID}
AWS_REGION=${AWS_REGION}

# Embedding — explicit provider switch from deploy.sh (no silent fallback).
#   voyage  → VOYAGE_SAGEMAKER_ENDPOINT set, selected Voyage Marketplace model
#   titan   → VOYAGE_SAGEMAKER_ENDPOINT empty, Bedrock Titan v2 (deviation)
EMBEDDINGS_PROVIDER=${EMBEDDINGS_PROVIDER}
VOYAGE_SAGEMAKER_ENDPOINT=${VOYAGE_ENDPOINT}
VOYAGE_OUTPUT_DIM=1024
VOYAGE_REQUEST_FORMAT=${VOYAGE_REQUEST_FORMAT:-multimodal}
EMBEDDING_MODEL_ID=amazon.titan-embed-text-v2:0

# AgentCore — Memory store, Gateway, Agent runtimes (orchestrator + specialists)
AGENTCORE_MEMORY_STORE_ID=${AGENTCORE_MEMORY_STORE_ID}
AGENTCORE_GATEWAY_URL=${AGENTCORE_GATEWAY_URL}
AGENTCORE_ORCHESTRATOR_ARN=${AGENTCORE_ORCHESTRATOR_ARN}
EOF
# Append one AGENTCORE_<UPPER>_ARN line per discovered specialist so that
# agentcoreSpecialistArn() in api/src/adapters/agentcore-runtime.ts can pick
# them up via the legacy AGENTCORE_<UPPER>_ARN env-var fallback path.
# This replaces the former hardcoded three-line block and works for any number
# of specialist agents defined in config/agents/*.agent.md.
for _spec_id in "${SPECIALIST_IDS[@]:-}"; do
  _upper_id="$(printf '%s' "$_spec_id" | tr '[:lower:]-' '[:upper:]_')"
  _spec_arn="$(specialist_runtime_arn "$_spec_id")"
  [[ -n "$_spec_arn" ]] && echo "AGENTCORE_${_upper_id}_ARN=${_spec_arn}" >> "$REPO_ROOT/.env.live"
done
unset _spec_id _upper_id _spec_arn
cat >> "$REPO_ROOT/.env.live" <<EOF

# Tool hosting — Gateway remains for non-Mongo tools; MongoDB MCP calls go
# directly to the dedicated AgentCore Runtime.
MCP_SERVER_URL=${AGENTCORE_GATEWAY_URL}
MONGODB_MCP_RUNTIME_ARN=${MONGODB_MCP_RUNTIME_ARN}
MONGODB_MCP_RUNTIME_ENDPOINT=${MONGODB_MCP_RUNTIME_ENDPOINT}
SHORT_TERM_MEMORY_BACKEND=agentcore
PERSIST_CHAT_SESSIONS=1
MEMORY_TTL_DAYS=30

# Long-term memory fact extractor. Pinned to Claude Haiku 4.5 because the
# previous default (claude-3-5-haiku-20241022) is deprecated and silently
# AccessDenied on freshly granted Bedrock accounts. Override only if you have
# enabled a different tool-use-capable model in your account.
MEMORY_EXTRACTION_MODEL_ID=us.anthropic.claude-haiku-4-5-20251001-v1:0

# LTM / trace value gating — sourced from .env so flips are deploy-tracked
# (no SSH/SSM hand-editing of /opt/multiagent/.env.live on EC2).
#   MEMORY_TRACE_VALUES=1 → raw fact strings in trace events. Default 0 = "<redacted>".
#   TRACE_PROMPT_BODY=1   → prompt.assembled.body attached (full system prompt).
#   TRACE_REDACT=1        → blanket redactDeep pass over every event payload.
MEMORY_TRACE_VALUES=${MEMORY_TRACE_VALUES:-0}
TRACE_PROMPT_BODY=${TRACE_PROMPT_BODY:-0}
TRACE_REDACT=${TRACE_REDACT:-0}

# CloudWatch (API + UI log groups; journald → CW agent on EC2 ships here)
CLOUDWATCH_LOG_GROUP=${CW_API_LOG_GROUP}
CLOUDWATCH_UI_LOG_GROUP=${CW_UI_LOG_GROUP}

# Cognito — JWT auth for the API. Always on; assertJwksAuthConfigured() refuses to boot
# the API without AUTH_JWKS_URI + AUTH_ISSUER (api/src/lib/jwt-verify.ts).
AUTH_JWKS_URI=${COGNITO_JWKS}
AUTH_ISSUER=https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_POOL_ID}
STREAMLIT_COGNITO_POOL_ID=${COGNITO_POOL_ID}
STREAMLIT_COGNITO_CLIENT_ID=${COGNITO_CLIENT_ID}

# EC2 URLs
STREAMLIT_API_URL=http://${EC2_IP}:3000/

# OpenTelemetry — points Bun API + Streamlit UI at the local ADOT Collector
# sidecar (modules/adot-collector). The sidecar signs SigV4 outbound to the
# AWS X-Ray OTLP endpoint, so apps never need their own credentials for
# telemetry. When OTEL_EXPORTER_OTLP_ENDPOINT is empty (e.g. enable_adot_collector
# = false in Terraform), the Bun bootstrap falls back to in-process tracing
# only and the Streamlit auto-instrumentation no-ops gracefully.
OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318}
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_SERVICE_NAME=multiagent-api
OTEL_RESOURCE_ATTRIBUTES=service.namespace=multiagent,deployment.environment=${ENVIRONMENT:-dev},service.version=${GIT_SHA:-unknown}
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=${OTEL_SAMPLE_RATIO:-1.0}
# Streamlit-side instrumentation hook (Python distro convention).
OTEL_PYTHON_LOG_CORRELATION=true
OTEL_PYTHON_LOG_FORMAT=%(asctime)s %(levelname)s [%(name)s] [trace_id=%(otelTraceID)s span_id=%(otelSpanID)s resource.service.name=%(otelServiceName)s] - %(message)s
EOF
ok ".env.live written"

wait_for_instance_status_ok "$EC2_INSTANCE_ID"
wait_for_ssm_online "$EC2_INSTANCE_ID"

# Wait for cloud-init/bootstrap completion marker.
BOOTSTRAP_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: check bootstrap marker" \
  '["test -f /opt/multiagent/.bootstrap-done && echo yes || echo no"]' \
  24) || err "Could not send bootstrap-check command via SSM"

wait_for_ssm_command_success "$BOOTSTRAP_CMD_ID" "$EC2_INSTANCE_ID" 36 \
  || err "Bootstrap check command failed on EC2"

BOOTSTRAP_OUT=$(aws ssm get-command-invocation \
  --region "$AWS_REGION" \
  --command-id "$BOOTSTRAP_CMD_ID" \
  --instance-id "$EC2_INSTANCE_ID" \
  --query "StandardOutputContent" --output text 2>/dev/null || echo "no")
if [[ "$BOOTSTRAP_OUT" != *"yes"* ]]; then
  err "EC2 bootstrap marker not found at /opt/multiagent/.bootstrap-done"
fi
ok "EC2 bootstrap marker detected"

# ── CloudWatch Agent readiness ────────────────────────────────────────────────
# The amazon-cloudwatch-agent service must be active and a log stream must be
# created in /<project>/<env>/api within 60 s of API restart, otherwise journald
# logs are never shipped to CloudWatch. We probe both before continuing.
log "Verifying amazon-cloudwatch-agent is active on EC2..."
CWA_STATUS_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: cw-agent status" \
  '["systemctl is-active amazon-cloudwatch-agent || true"]' \
  12) || warn "Failed to send cw-agent status command via SSM"

if [[ -n "$CWA_STATUS_CMD_ID" ]]; then
  wait_for_ssm_command_success "$CWA_STATUS_CMD_ID" "$EC2_INSTANCE_ID" 12 || true
  CWA_STATUS_OUT=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$CWA_STATUS_CMD_ID" \
    --instance-id "$EC2_INSTANCE_ID" \
    --query "StandardOutputContent" --output text 2>/dev/null || echo "unknown")
  CWA_STATUS_OUT="$(echo "$CWA_STATUS_OUT" | tr -d '[:space:]')"
  if [[ "$CWA_STATUS_OUT" == "active" ]]; then
    ok "amazon-cloudwatch-agent is active"
  else
    warn "amazon-cloudwatch-agent reported '${CWA_STATUS_OUT:-unknown}' (continuing; CloudWatch shipping may be delayed)"
  fi
fi

# ── Centralized preflight checks: pre-env-sync (see docs/deployment-preflight-checks.md) ──
# shellcheck source=deploy/scripts/_preflight-checks.sh
source "$SCRIPT_DIR/_preflight-checks.sh"
preflight_validate project-pre-env-sync

# Copy via SSM Session Manager — no SSH key required.
log "Copying .env.live to EC2 ($EC2_INSTANCE_ID) via SSM..."
_ENV_B64=$(base64 < "$REPO_ROOT/.env.live" | tr -d '\n')
ENV_SYNC_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: sync .env.live" \
  "[\"echo '${_ENV_B64}' | base64 -d > /opt/multiagent/.env.live && chmod 600 /opt/multiagent/.env.live\"]" \
  12) || err "Failed to send .env.live to EC2 via SSM"

wait_for_ssm_command_success "$ENV_SYNC_CMD_ID" "$EC2_INSTANCE_ID" 24 \
  || err ".env.live sync command failed on EC2"
ok ".env.live synced to /opt/multiagent/.env.live"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 8 — Restart services on EC2 + ECR docker login
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 8 — Pulling images + restarting services on EC2..."

# Interface endpoints use private DNS for ECR/Logs. If the endpoint security
# group drifts and no longer allows a consumer SG, calls resolve privately and
# then time out. Repair that ingress here as a deploy-time guardrail; Terraform's
# null_resource authorizer is idempotent but cannot detect manually removed SG
# rules after its state has already recorded success.
EC2_VPC_ID="$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$EC2_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].VpcId' \
  --output text)"
EC2_SECURITY_GROUP_IDS="$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$EC2_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' \
  --output text)"
MONGODB_MCP_RUNTIME_ID="${MONGODB_MCP_RUNTIME_ARN##*/}"
MONGODB_MCP_RUNTIME_SECURITY_GROUP_IDS="$(aws bedrock-agentcore-control get-agent-runtime \
  --region "$AWS_REGION" \
  --agent-runtime-id "$MONGODB_MCP_RUNTIME_ID" \
  --query 'networkConfiguration.networkModeConfig.securityGroups[]' \
  --output text 2>/dev/null || true)"
ENDPOINT_CONSUMER_SECURITY_GROUP_IDS="$(printf "%s\n%s\n" \
  "$EC2_SECURITY_GROUP_IDS" \
  "$MONGODB_MCP_RUNTIME_SECURITY_GROUP_IDS" | tr '\t' '\n' | sort -u)"
AWS_ENDPOINT_SECURITY_GROUP_IDS="$(aws ec2 describe-vpc-endpoints \
  --region "$AWS_REGION" \
  --filters \
    "Name=vpc-id,Values=${EC2_VPC_ID}" \
    "Name=service-name,Values=com.amazonaws.${AWS_REGION}.ecr.api,com.amazonaws.${AWS_REGION}.ecr.dkr,com.amazonaws.${AWS_REGION}.logs" \
  --query 'VpcEndpoints[].Groups[].GroupId' \
  --output text | tr '\t' '\n' | sort -u)"
if [[ -n "$AWS_ENDPOINT_SECURITY_GROUP_IDS" && "$AWS_ENDPOINT_SECURITY_GROUP_IDS" != "None" ]]; then
  for endpoint_sg_id in $AWS_ENDPOINT_SECURITY_GROUP_IDS; do
    for source_sg_id in $ENDPOINT_CONSUMER_SECURITY_GROUP_IDS; do
      [[ -n "$source_sg_id" && "$source_sg_id" != "None" ]] || continue
      OUT=$(aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$endpoint_sg_id" \
        --protocol tcp \
        --port 443 \
        --source-group "$source_sg_id" 2>&1) || {
        if [[ "$OUT" != *"InvalidPermission.Duplicate"* ]]; then
          echo "$OUT" >&2
          err "Failed to allow consumer SG $source_sg_id to reach AWS endpoint SG $endpoint_sg_id"
        fi
      }
    done
  done
  ok "ECR/Logs VPC endpoint ingress allows EC2 host and MongoDB MCP runtime"
fi

# Single SSM command: ECR login, pull latest images, restart API + UI containers.
# --skip-docker only skips local build/push; a replaced EC2 host still needs
# ECR auth and image pulls from the already-published tags.
ECR_REGISTRY=$(echo "$ECR_API_REPO" | cut -d'/' -f1)
RESTART_CMD="aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY} \
  && docker pull ${ECR_API_IMAGE} \
  && docker pull ${ECR_UI_IMAGE} \
  && systemctl daemon-reload \
  && systemctl restart multiagent-api multiagent-ui"

RESTART_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: pull images + restart services" \
  "[\"${RESTART_CMD//\"/\\\"}\"]" \
  12) || err "Failed to send restart command via SSM"
wait_for_ssm_command_success "$RESTART_CMD_ID" "$EC2_INSTANCE_ID" 36 \
  || err "EC2 service restart command failed"
ok "Restart command completed"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 9 — Health check + summary
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Waiting for API health check..."
HEALTH_OK="no"
API_HEALTH_MAX_ATTEMPTS=120
for i in $(seq 1 "$API_HEALTH_MAX_ATTEMPTS"); do
  if curl -sf --max-time 10 "http://${EC2_IP}:3000/health" > /dev/null 2>&1; then
    ok "API is healthy"
    HEALTH_OK="yes"
    break
  fi
  log "  Waiting ($i/${API_HEALTH_MAX_ATTEMPTS})..."
  sleep 5
done
if [[ "$HEALTH_OK" != "yes" ]]; then
  warn "Public /health probe timed out; verifying API health from inside EC2 via SSM..."
  HEALTH_SSM_CMD_ID=$(send_ssm_command_retry \
    "$EC2_INSTANCE_ID" \
    "multiagent: api health local probe" \
    '["curl -sf --max-time 10 http://127.0.0.1:3000/health >/dev/null && echo ok || echo fail"]' \
    12) || err "Failed to send local API health check via SSM"
  wait_for_ssm_command_success "$HEALTH_SSM_CMD_ID" "$EC2_INSTANCE_ID" 24 \
    || err "Local API health SSM command failed"
  HEALTH_SSM_OUT=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$HEALTH_SSM_CMD_ID" \
    --instance-id "$EC2_INSTANCE_ID" \
    --query "StandardOutputContent" --output text 2>/dev/null || echo "fail")
  [[ "$HEALTH_SSM_OUT" == *"ok"* ]] || err "API health check did not pass in time"
  ok "API is healthy (verified via EC2 local probe)"
fi

# ── CloudWatch Logs streams probe ────────────────────────────────────────────
# After the API restarted, the CW agent should have created at least one log
# stream in $CW_API_LOG_GROUP from the multiagent-api journald unit within 60s.
# We probe up to 12 times every 5s — non-fatal so a flaky agent doesn't block
# the deploy, but we surface a loud warn() so an operator notices.
if [[ -n "${CW_API_LOG_GROUP:-}" ]]; then
  log "Probing CloudWatch log streams in ${CW_API_LOG_GROUP}..."
  CW_STREAMS_OK="no"
  for i in $(seq 1 12); do
    STREAM_COUNT=$(aws logs describe-log-streams \
      --region "$AWS_REGION" \
      --log-group-name "$CW_API_LOG_GROUP" \
      --max-items 1 \
      --query 'length(logStreams)' --output text 2>/dev/null || echo 0)
    if [[ "$STREAM_COUNT" =~ ^[0-9]+$ ]] && (( STREAM_COUNT >= 1 )); then
      CW_STREAMS_OK="yes"
      break
    fi
    sleep 5
  done
  if [[ "$CW_STREAMS_OK" == "yes" ]]; then
    ok "CloudWatch agent is shipping API logs (${CW_API_LOG_GROUP})"
  else
    warn "No log streams found in ${CW_API_LOG_GROUP} after 60s — CloudWatch agent may not be shipping. Check journalctl -u amazon-cloudwatch-agent on EC2."
  fi
fi

sep
log "Phase 9a2 — /health dependency smoke (mongodb + agentcore must report 'connected'; mcpServer warns if unreachable)..."
HEALTH_PAYLOAD=$(curl -sf --max-time 10 "http://${EC2_IP}:3000/health" 2>/dev/null || echo "")
if [[ -n "$HEALTH_PAYLOAD" ]]; then
  python3 - "$HEALTH_PAYLOAD" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
deps = payload.get("dependencies", {})
required = {
    # Atlas: must be connected (we just seeded data there).
    "mongodb": "connected",
    # AgentCore Memory Store: probe must classify "Actor not found"
    # for the synthetic health-probe actor as `connected` — the API
    # round-trip succeeded, IAM is fine, the memory store exists.
    # If this regresses to `unreachable`, somebody dropped the
    # `ResourceNotFoundException` + `/actor/i` carve-out in
    # api/src/lib/health-status.ts.
    "agentcore": "connected",
}
mismatches = []
for key, want in required.items():
    got = deps.get(key)
    if got != want:
        mismatches.append(f"  {key}: want={want}  got={got}")
if mismatches:
    raise SystemExit(
        "Phase 9a2 failed — /health reported wrong dependency status.\n"
        "Full /health payload:\n"
        + json.dumps(payload, indent=2)
        + "\nMismatches:\n" + "\n".join(mismatches)
    )
mcp = deps.get("mcpServer")
if mcp != "connected":
    print(f"  warning: mcpServer={mcp}; API deploy can proceed, but Mongo MCP tool calls may be degraded")
else:
    print("  /health dependencies all 'connected' as expected")
PY
  ok "/health dependency smoke passed"
else
  warn "/health probe returned no body — skipping dependency smoke"
fi

sep
log "Phase 9b — Deterministic backend smoke validation..."
SMOKE_SESSION_ID="deploy-smoke-$(date +%s)"
EC2_API_URL="http://${EC2_IP}:3000"
BACKEND_SMOKE_SCRIPT="${SCRIPT_DIR}/backend-smoke.py"
SMOKE_ID_TOKEN=$(aws cognito-idp initiate-auth \
  --region "$AWS_REGION" \
  --client-id "$COGNITO_CLIENT_ID" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=${COGNITO_SMOKE_USER_EMAIL},PASSWORD=${COGNITO_TEST_PASSWORD}" \
  --query "AuthenticationResult.IdToken" \
  --output text 2>/dev/null || echo "")
[[ -n "$SMOKE_ID_TOKEN" && "$SMOKE_ID_TOKEN" != "None" ]] || err "Could not obtain Cognito IdToken for smoke user ${COGNITO_SMOKE_USER_EMAIL}"

python3 "$BACKEND_SMOKE_SCRIPT" \
  --api-url "$EC2_API_URL" \
  --session-id "$SMOKE_SESSION_ID" \
  --id-token "$SMOKE_ID_TOKEN" \
  --check-session-user
ok "Backend smoke validation passed"

sep
ok "EC2 deployment complete!"
echo ""
echo "  API        : ${EC2_API}"
echo "  UI         : ${EC2_UI}"
echo "  EC2 IP     : ${EC2_IP}"
echo "  Shell      : ${EC2_SSM}"
echo ""
echo "  Atlas      : ${ATLAS_MONGO_HOST}"
echo "  Bedrock KB : ${BEDROCK_KB_ID:-'(not yet provisioned)'}"
echo "  Embedding  : ${VOYAGE_ENDPOINT:-'Titan (amazon.titan-embed-text-v2:0)'}"
echo "  AgentCore  : memory=${AGENTCORE_MEMORY_STORE_ID:-?}"
echo "               gateway=${AGENTCORE_GATEWAY_URL:-?}"
echo "  Tools/MCP  : MongoDB direct runtime ${MONGODB_MCP_RUNTIME_ARN:-?}"
echo "               Gateway available for non-Mongo tools ${AGENTCORE_GATEWAY_URL:-?}"
echo "  Auth       : Cognito JWKS required (no bypass)"
echo "               Cognito users=${COGNITO_TEST_USERS_CSV}"
echo "               Password=${COGNITO_TEST_PASSWORD}"
echo ""
echo "  Logs       : aws ssm start-session --target ${EC2_INSTANCE_ID} --region ${AWS_REGION}"
echo "               then: journalctl -u multiagent-api -f"
echo ""
echo "  For local dev: ./deploy/scripts/deploy-local.sh"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 10 — Write resource manifest
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 10 — Writing resource manifest..."
MANIFEST_FILE="$REPO_ROOT/deploy-manifest.json"

export _MANIFEST_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
export _M_ACCOUNT="$ACCOUNT_ID"  _M_REGION="$AWS_REGION"   _M_ENV="$ENVIRONMENT"
export _M_BUCKET="$SHARED_BUCKET" _M_KB="$BEDROCK_KB_ID"
export _M_EC2_IP="$EC2_IP"        _M_EC2_ID="$EC2_INSTANCE_ID"
export _M_EC2_API="$EC2_API"      _M_EC2_UI="$EC2_UI"
export _M_COGNITO_POOL="$COGNITO_POOL_ID" _M_COGNITO_CLIENT="$COGNITO_CLIENT_ID"
export _M_VOYAGE="$VOYAGE_ENDPOINT"
export _M_EMBEDDINGS_PROVIDER="$EMBEDDINGS_PROVIDER"
export _M_EMBEDDINGS_MODEL="$EMBEDDINGS_MODEL_ID"
export _M_EMBEDDINGS_SOW_ALIGNED="$EMBEDDINGS_SOW_ALIGNED"
export _M_ECR_API="$ECR_API_REPO"  _M_ECR_UI="$ECR_UI_REPO"
export _M_AC_MEM="$AGENTCORE_MEMORY_STORE_ID" _M_AC_GW="$AGENTCORE_GATEWAY_URL" _M_MCP_RUNTIME_ARN="$MONGODB_MCP_RUNTIME_ARN" _M_MCP_RUNTIME_ENDPOINT="$MONGODB_MCP_RUNTIME_ENDPOINT"
export _M_ATLAS_PROJ="$TF_VAR_atlas_project_id" _M_ATLAS_HOST="$ATLAS_MONGO_HOST"
export _M_TOOL_MODE="hybrid"
export _M_KB_SECRET_NAME="${PROJECT_NAME}-bedrock-kb-creds-${ENVIRONMENT}"
# Capture how this deploy authenticated so post-deploy smoke / audit tooling
# can detect a stale manifest (deploy ran under a different principal than
# the current sts:GetCallerIdentity). validate_aws_auth populates the
# AWS_AUTH_* exports earlier in Phase 1.
export _M_AUTH_MODE="${AWS_AUTH_MODE:-${AUTH_MODE:-iam}}"
export _M_AUTH_CALLER_ARN="${AWS_AUTH_CALLER_ARN:-$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown)}"
# Connectivity mode + KB connectivity for post-deploy smoke / dashboards.
export _M_NETWORK_MODE="$NETWORK_MODE"
export _M_ATLAS_PEERING_CIDR="${ATLAS_PEERING_CIDR:-}"
export _M_ATLAS_PEERING_CONN_ID="$(terraform output -raw atlas_peering_connection_id 2>/dev/null || echo "")"
export _M_KB_CONNECTIVITY_MODE="$(terraform output -raw kb_connectivity_mode 2>/dev/null || echo "")"

python3 - <<'PYEOF' > "$MANIFEST_FILE"
import json, os
def v(k): return os.environ.get(k, "")
manifest = {
  "generated_at":  v("_MANIFEST_TS"),
  "mode":          "ec2",
  "script":        "deploy.sh",
  "aws_account":   v("_M_ACCOUNT"),
  "aws_region":    v("_M_REGION"),
  "environment":   v("_M_ENV"),
  "network": {
    "mode":                     v("_M_NETWORK_MODE"),
    "atlas_peering_cidr":       v("_M_ATLAS_PEERING_CIDR"),
    "atlas_peering_conn_id":    v("_M_ATLAS_PEERING_CONN_ID"),
    "kb_connectivity_mode":     v("_M_KB_CONNECTIVITY_MODE"),
  },
  "auth": {
    "mode":        v("_M_AUTH_MODE"),
    "caller_arn":  v("_M_AUTH_CALLER_ARN"),
  },
  "resources": {
    "s3_state_bucket":            v("_M_BUCKET"),
    "bedrock_kb_id":              v("_M_KB"),
    "secrets_manager_secret":     v("_M_KB_SECRET_NAME"),
    "ec2_instance_id":            v("_M_EC2_ID"),
    "ec2_public_ip":              v("_M_EC2_IP"),
    "ec2_api_url":                v("_M_EC2_API"),
    "ec2_ui_url":                 v("_M_EC2_UI"),
    "cognito_user_pool_id":       v("_M_COGNITO_POOL"),
    "cognito_client_id":          v("_M_COGNITO_CLIENT"),
    "voyage_sagemaker_endpoint":  v("_M_VOYAGE"),
    "embeddings_provider":        v("_M_EMBEDDINGS_PROVIDER"),
    "embeddings_model":           v("_M_EMBEDDINGS_MODEL"),
    "embeddings_sow_aligned":     v("_M_EMBEDDINGS_SOW_ALIGNED") == "true",
    "ecr_api_repo":               v("_M_ECR_API"),
    "ecr_ui_repo":                v("_M_ECR_UI"),
    "agentcore_memory_id":        v("_M_AC_MEM"),
    "agentcore_gateway_url":      v("_M_AC_GW"),
    "agentcore_gateway_target":   "reserved for non-Mongo Gateway-hosted tools",
    "mongodb_mcp_runtime_arn":    v("_M_MCP_RUNTIME_ARN"),
    "mongodb_mcp_runtime_endpoint": v("_M_MCP_RUNTIME_ENDPOINT"),
    "atlas_project_id":           v("_M_ATLAS_PROJ"),
    "atlas_srv_host":             v("_M_ATLAS_HOST"),
    "tool_hosting_mode":          v("_M_TOOL_MODE"),
    "mcp_server":                 "MongoDB MCP direct AgentCore Runtime; other tools via AgentCore Gateway",
  }
}
print(json.dumps(manifest, indent=2))
PYEOF
ok "Resource manifest written: $MANIFEST_FILE"
sep
