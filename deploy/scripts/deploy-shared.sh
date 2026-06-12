#!/usr/bin/env bash
# deploy-shared.sh — Apply the shared observability + embeddings stack (envs/shared)
#
# Usage:
#   ./deploy/scripts/deploy-shared.sh [--auto-approve] [--env-file <path>]
#
# What it does:
#   Phase 1 — Validate prereqs (aws, terraform)
#   Phase 2 — Source .env, verify AWS credentials, derive ACCOUNT_ID
#   Phase 3 — Sanity-check bootstrap S3 state bucket (envs/network must have run it)
#   Phase 4 — Generate backend.hcl + terraform.tfvars for envs/shared.
#             State key:  ${SHARED_VPC_NAME}/${AWS_REGION}/shared/terraform.tfstate
#   Phase 5 — terraform init + plan + apply (envs/shared):
#               • Voyage SageMaker endpoint (when EMBEDDINGS_PROVIDER=voyage)
#               • CloudWatch log groups: API / UI / MCP / AgentCore / OTel / OTel-Atlas
#               • Bedrock invocation logging (account-scoped singleton)
#               • Fleet + mongo + cost dashboards + 7 alarms
#               • Atlas dashboard + 2 alarms (when enable_atlas_metrics=true)
#               • SSM Parameter Store entries for cross-state discovery
#   Phase 6 — Verify SSM canary params and print summary
#
# Run ONCE per (account, region, environment) — multiple per-project deploy.sh
# invocations all consume the same SSM-published values.
#
# State location uses SHARED_VPC_NAME so all three stacks (network, shared, ec2)
# share one prefix that is operator-controlled, not hardcoded in terraform.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_ROOT="$REPO_ROOT/deploy/terraform"
TF_DIR="$TF_ROOT/envs/shared"
BOOTSTRAP_DIR="$TF_ROOT/bootstrap"

ENV_FILE="$REPO_ROOT/.env"
AUTO_APPROVE=false

# Defaults — overwritten when .env is sourced in Phase 2
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
SHARED_RESOURCE_PREFIX="${SHARED_RESOURCE_PREFIX:-multiagent}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve) AUTO_APPROVE=true ;;
    --env-file)     ENV_FILE="$2"; shift ;;
    -h|--help)
      sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "  [shared] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo "  [shared] $*"; }
ok()   { echo "  [shared] ✓ $*"; }
err()  { echo "  [shared] ✗ $*" >&2; exit 1; }
warn() { echo "  [shared] ⚠ $*"; }
sep()  { echo "────────────────────────────────────────────────"; }

# shellcheck source=deploy/scripts/_voyage-config.sh
source "$SCRIPT_DIR/_voyage-config.sh"

# Shared transient-error classifier (DNS resolver + network/transport blips).
# shellcheck source=deploy/scripts/_transient-errors.sh
source "$SCRIPT_DIR/_transient-errors.sh"

# Wrap `terraform apply` with retry-on-transient-error, mirroring
# deploy-network.sh / deploy-project.sh. envs/shared provisions the Voyage
# SageMaker endpoint + observability resources; a transient local DNS resolver
# blip or Atlas/AWS i/o timeout mid-apply should re-plan and retry, not abort
# the whole shared stack. Any non-transient error is a hard failure.
apply_with_retry() {
  local plan_file="$1"
  local max_attempts=3
  local attempt=1
  local log_file rc
  log_file=$(mktemp -t tf-shared-apply.XXXXXX)

  while (( attempt <= max_attempts )); do
    if (( attempt > 1 )); then
      log "Retry $((attempt - 1))/$((max_attempts - 1)) — sleeping 30s, then re-planning..."
      sleep 30
      deploy_diag_checkpoint "terraform retry plan attempt ${attempt}/${max_attempts}: terraform plan -input=false -out=${plan_file}"
      terraform plan -input=false -out="$plan_file"
      ok "re-plan complete"
    fi
    log "Apply attempt ${attempt}/${max_attempts}..."
    deploy_diag_checkpoint "terraform apply attempt ${attempt}/${max_attempts}: terraform apply -input=false ${plan_file}"
    set +e
    terraform apply -input=false "$plan_file" 2>&1 | tee "$log_file"
    rc=${PIPESTATUS[0]}
    set -e
    if (( rc == 0 )); then
      rm -f "$log_file"
      return 0
    fi
    if deploy_log_has_transient_error "$log_file" \
       || grep -qE 'Saved plan is stale' "$log_file"; then
      warn "Transient Atlas/network error on attempt ${attempt} — will re-plan and retry"
      attempt=$((attempt + 1))
      continue
    fi
    rm -f "$log_file"
    err "terraform apply failed with a non-transient error (see output above)"
  done
  rm -f "$log_file"
  err "terraform apply failed after ${max_attempts} attempts — transient errors did not clear"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Prerequisites
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 1 — Checking prerequisites..."
for cmd in aws terraform; do
  command -v "$cmd" &>/dev/null || err "'$cmd' not found in PATH"
done
ok "All prerequisites found"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Load credentials
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 2 — Loading credentials from $ENV_FILE..."
[[ -f "$ENV_FILE" ]] || err "env file not found: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

# Re-read env vars in case .env redefined them
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
SHARED_RESOURCE_PREFIX="${SHARED_RESOURCE_PREFIX:-multiagent}"

# Voyage knobs — provider-gated; Titan ignores any leftover ARN placeholder.
EMBEDDINGS_PROVIDER="${EMBEDDINGS_PROVIDER:-}"
VOYAGE_MODEL_PACKAGE_ARN="${VOYAGE_MODEL_PACKAGE_ARN:-}"
VOYAGE_INSTANCE_TYPE="${VOYAGE_INSTANCE_TYPE:-ml.g6.xlarge}"
VOYAGE_ENDPOINT_NAME_SUFFIX_RAW="${TF_VAR_voyage_endpoint_name_suffix:-${VOYAGE_MARKETPLACE_MODEL:-voyage-multimodal-3}}"
VOYAGE_ENDPOINT_NAME_SUFFIX="$(voyage_sagemaker_endpoint_suffix "$VOYAGE_ENDPOINT_NAME_SUFFIX_RAW")"

case "$EMBEDDINGS_PROVIDER" in
  voyage)
    if [[ -z "$VOYAGE_ENDPOINT_NAME_SUFFIX" ]]; then
      err "Voyage endpoint suffix resolved to an empty SageMaker name from '${VOYAGE_ENDPOINT_NAME_SUFFIX_RAW}'"
    fi
    if [[ "$VOYAGE_ENDPOINT_NAME_SUFFIX_RAW" != "$VOYAGE_ENDPOINT_NAME_SUFFIX" ]]; then
      warn "Normalized Voyage endpoint suffix '${VOYAGE_ENDPOINT_NAME_SUFFIX_RAW}' -> '${VOYAGE_ENDPOINT_NAME_SUFFIX}' for SageMaker"
    fi
    ;;
  titan)
    if [[ -n "$VOYAGE_MODEL_PACKAGE_ARN" ]]; then
      warn "EMBEDDINGS_PROVIDER=titan — ignoring VOYAGE_MODEL_PACKAGE_ARN for shared Terraform"
    fi
    VOYAGE_MODEL_PACKAGE_ARN=""
    ;;
  "")
    # preflight_validate reports the missing required provider before Terraform runs.
    ;;
  *)
    err "EMBEDDINGS_PROVIDER='$EMBEDDINGS_PROVIDER' is not recognised. Use 'voyage' or 'titan'."
    ;;
esac

# Dashboards + invocation logging + retention — all optional with safe defaults
API_LOG_RETENTION_DAYS="${API_LOG_RETENTION_DAYS:-${LOG_RETENTION_DAYS:-30}}"
AUX_LOG_RETENTION_DAYS="${AUX_LOG_RETENTION_DAYS:-7}"
OTEL_LOG_RETENTION_DAYS="${OTEL_LOG_RETENTION_DAYS:-${LOG_RETENTION_DAYS:-$API_LOG_RETENTION_DAYS}}"
ENABLE_FLEET_DASHBOARDS="${ENABLE_FLEET_DASHBOARDS:-true}"
ENABLE_ATLAS_METRICS="${ENABLE_ATLAS_METRICS:-false}"
ENABLE_BEDROCK_INVOCATION_LOGGING="${ENABLE_BEDROCK_INVOCATION_LOGGING:-true}"
LOG_PROMPT_BODIES="${LOG_PROMPT_BODIES:-false}"
LOG_EMBEDDING_BODIES="${LOG_EMBEDDING_BODIES:-false}"
INVOCATION_RETENTION_DAYS="${INVOCATION_RETENTION_DAYS:-7}"
P99_LATENCY_THRESHOLD_MS="${P99_LATENCY_THRESHOLD_MS:-12000}"
ERROR_RATE_THRESHOLD_PCT="${ERROR_RATE_THRESHOLD_PCT:-2}"
THROTTLE_BURST_THRESHOLD="${THROTTLE_BURST_THRESHOLD:-5}"
ATLAS_REPLICATION_LAG_THRESHOLD_MS="${ATLAS_REPLICATION_LAG_THRESHOLD_MS:-5000}"

DEPLOY_DIAG_LABEL="shared"
# shellcheck source=deploy/scripts/_deploy-diagnostics.sh
source "$SCRIPT_DIR/_deploy-diagnostics.sh"
deploy_diag_install_error_trap

# shellcheck source=deploy/scripts/_aws-auth.sh
source "$SCRIPT_DIR/_aws-auth.sh"
validate_aws_auth || err "AWS auth validation failed (see above)"
ACCOUNT_ID="$AWS_AUTH_ACCOUNT_ID"

# ── Centralized preflight checks (see docs/deployment-preflight-checks.md) ──
# shellcheck source=deploy/scripts/_preflight-checks.sh
source "$SCRIPT_DIR/_preflight-checks.sh"
preflight_validate shared
deploy_diag_after_preflight "shared" "$ENV_FILE"

ok "AWS account: $ACCOUNT_ID"
ok "Shared VPC name: $SHARED_VPC_NAME"
ok "Shared resource prefix: $SHARED_RESOURCE_PREFIX"
ok "Region: $AWS_REGION / Environment: $ENVIRONMENT"
if [[ -n "$VOYAGE_MODEL_PACKAGE_ARN" ]]; then
  ok "Voyage SageMaker: $VOYAGE_ENDPOINT_NAME_SUFFIX on $VOYAGE_INSTANCE_TYPE"
else
  warn "Voyage SageMaker disabled — EMBEDDINGS_PROVIDER=${EMBEDDINGS_PROVIDER:-<unset>}"
fi

SHARED_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-${ACCOUNT_ID}"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Sanity-check the shared state bucket exists
# (envs/network bootstraps it; envs/shared must run AFTER envs/network)
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 3 — Verifying shared state bucket..."
if ! aws s3api head-bucket --bucket "$SHARED_BUCKET" 2>/dev/null; then
  err "Shared state bucket s3://${SHARED_BUCKET} does not exist. Run ./deploy/scripts/deploy-network.sh first — it bootstraps the bucket."
fi
ok "State bucket exists: s3://${SHARED_BUCKET}"

# Also sanity-check the network stack has been applied — envs/shared does not
# read network outputs directly but lives next to them under the same SSM
# prefix; if network hasn't been applied the per-project envs/ec2 stack will
# fail later for a different reason. Better to catch it here.
NETWORK_VPC_PARAM="/${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id"
if ! aws ssm get-parameter --region "$AWS_REGION" --name "$NETWORK_VPC_PARAM" \
     --query "Parameter.Value" --output text >/dev/null 2>&1; then
  warn "SSM param $NETWORK_VPC_PARAM is missing — envs/network has not been applied."
  warn "envs/shared apply will still succeed (no cross-state read), but envs/ec2 will fail later."
  warn "Recommended order: deploy-network.sh → deploy-shared.sh → deploy-project.sh"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — Generate Terraform config (envs/shared)
# State key includes SHARED_VPC_NAME + AWS_REGION + ENVIRONMENT so multiple
# environments (dev/staging/prod) in the same region keep separate state.
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 4 — Generating Terraform config for envs/shared..."

cat > "$TF_DIR/backend.hcl" <<EOF
bucket  = "${SHARED_BUCKET}"
key     = "${SHARED_VPC_NAME}/${AWS_REGION}/${ENVIRONMENT}/shared/terraform.tfstate"
region  = "${AWS_REGION}"
encrypt = true
EOF
ok "backend.hcl written (state key: ${SHARED_VPC_NAME}/${AWS_REGION}/${ENVIRONMENT}/shared/terraform.tfstate)"

# Build tfvars. Voyage block only emitted for the Voyage provider so the
# voyage_model_package_arn validation in envs/shared/variables.tf doesn't fire
# on Titan deployments that keep a placeholder ARN in .env.
{
  echo "# envs/shared — generated by deploy-shared.sh"
  echo "aws_region              = \"${AWS_REGION}\""
  echo "environment             = \"${ENVIRONMENT}\""
  echo "project_name            = \"${PROJECT_NAME}\""
  echo "shared_vpc_name         = \"${SHARED_VPC_NAME}\""
  echo "shared_bucket_name      = \"${SHARED_BUCKET}\""
  echo "shared_resource_prefix  = \"${SHARED_RESOURCE_PREFIX}\""
  echo "api_log_retention_days  = ${API_LOG_RETENTION_DAYS}"
  echo "aux_log_retention_days  = ${AUX_LOG_RETENTION_DAYS}"
  echo "otel_log_retention_days = ${OTEL_LOG_RETENTION_DAYS}"
  if [[ -n "$VOYAGE_MODEL_PACKAGE_ARN" ]]; then
    echo "voyage_model_package_arn    = \"${VOYAGE_MODEL_PACKAGE_ARN}\""
    echo "voyage_instance_type        = \"${VOYAGE_INSTANCE_TYPE}\""
    echo "voyage_endpoint_name_suffix = \"${VOYAGE_ENDPOINT_NAME_SUFFIX}\""
  fi
  echo "enable_fleet_dashboards            = ${ENABLE_FLEET_DASHBOARDS}"
  echo "p99_latency_threshold_ms           = ${P99_LATENCY_THRESHOLD_MS}"
  echo "error_rate_threshold_pct           = ${ERROR_RATE_THRESHOLD_PCT}"
  echo "throttle_burst_threshold           = ${THROTTLE_BURST_THRESHOLD}"
  echo "enable_atlas_metrics               = ${ENABLE_ATLAS_METRICS}"
  echo "atlas_replication_lag_threshold_ms = ${ATLAS_REPLICATION_LAG_THRESHOLD_MS}"
  echo "enable_bedrock_invocation_logging  = ${ENABLE_BEDROCK_INVOCATION_LOGGING}"
  echo "log_prompt_bodies                  = ${LOG_PROMPT_BODIES}"
  echo "log_embedding_bodies               = ${LOG_EMBEDDING_BODIES}"
  echo "invocation_retention_days          = ${INVOCATION_RETENTION_DAYS}"
} > "$TF_DIR/terraform.tfvars"

TFVARS_CONTENT="$(<"$TF_DIR/terraform.tfvars")"
case "$EMBEDDINGS_PROVIDER" in
  voyage)
    if [[ "$TFVARS_CONTENT" != *"voyage_model_package_arn"* ]]; then
      err "Internal error: EMBEDDINGS_PROVIDER=voyage but terraform.tfvars omitted voyage_model_package_arn"
    fi
    ;;
  titan)
    if [[ "$TFVARS_CONTENT" == *"voyage_model_package_arn"* ]]; then
      err "Internal error: EMBEDDINGS_PROVIDER=titan but terraform.tfvars includes voyage_model_package_arn"
    fi
    ;;
esac

ok "terraform.tfvars written"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — terraform apply (envs/shared)
# ══════════════════════════════════════════════════════════════════════════════
sep
cd "$TF_DIR"
deploy_diag_terraform_context "shared terraform init" "$TF_DIR" "$TF_DIR/backend.hcl" "$TF_DIR/.tfplan"
log "Phase 5 — terraform init..."
deploy_diag_checkpoint "terraform init start: terraform init -input=false -reconfigure -backend-config=${TF_DIR}/backend.hcl"
terraform init -input=false -reconfigure -backend-config="$TF_DIR/backend.hcl"
ok "init complete"

log "Running terraform plan..."
deploy_diag_checkpoint "terraform plan start: terraform plan -input=false -out=${TF_DIR}/.tfplan"
terraform plan -input=false -out="$TF_DIR/.tfplan"
ok "plan complete"

sep
if [[ -n "$VOYAGE_MODEL_PACKAGE_ARN" ]]; then
  log "NOTE: First apply provisions the SageMaker endpoint — this takes ~6–10 min."
  log "      Subsequent applies are fast (log group / dashboard updates only)."
else
  log "NOTE: Voyage SageMaker is disabled; apply only updates shared observability resources."
fi

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

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — Verify SSM canary params + summary
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 6 — Verifying SSM params under /${SHARED_VPC_NAME}/${AWS_REGION}/..."

REQUIRED_PARAMS=(
  "voyage_sagemaker_endpoint_name"
  "voyage_sagemaker_endpoint_arn"
  "cw_api_log_group"
  "cw_ui_log_group"
  "cw_mcp_log_group"
  "cw_agentcore_log_group"
  "cw_otel_log_group"
  "cw_otel_atlas_log_group"
  "bedrock_invocation_log_group"
  "bedrock_audit_log_group"
)

for p in "${REQUIRED_PARAMS[@]}"; do
  val=$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/${p}" \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")
  [[ -n "$val" ]] || err "SSM param missing or empty: /${SHARED_VPC_NAME}/${AWS_REGION}/${p}"
done
ok "All ${#REQUIRED_PARAMS[@]} SSM params populated"

# Post-apply preflight: confirm the freshly-provisioned Voyage SageMaker
# endpoint actually accepts the canonical multimodal envelope produced by
# `voyage_canonical_body` (== `buildVoyageRequestBody`). Skipped automatically
# when EMBEDDINGS_PROVIDER != voyage. Catches the case
# where VOYAGE_MARKETPLACE_MODEL claims voyage-multimodal-3 but
# VOYAGE_MODEL_PACKAGE_ARN points at a text-only Voyage listing — without
# this, db-seeding/seed-embeddings.ts is the first place to hit the 4xx,
# minutes after Phase 11 of deploy-project.sh has already started.
#
# Export VOYAGE_SAGEMAKER_ENDPOINT so the check uses the just-published name
# (matches what deploy-project.sh writes into .env.live a few phases later).
if [[ -n "$VOYAGE_MODEL_PACKAGE_ARN" ]]; then
  VOYAGE_ENDPOINT_FROM_TF="$(terraform output -raw voyage_endpoint_name 2>/dev/null || echo "")"
  if [[ -n "$VOYAGE_ENDPOINT_FROM_TF" ]]; then
    export VOYAGE_SAGEMAKER_ENDPOINT="$VOYAGE_ENDPOINT_FROM_TF"
  fi
  preflight_validate shared-post-apply
fi

VOYAGE_NAME=$(terraform output -raw voyage_endpoint_name 2>/dev/null || echo "")
API_LG=$(terraform output -raw cloudwatch_api_log_group 2>/dev/null || echo "")
FLEET_URL=$(terraform output -raw fleet_dashboard_url 2>/dev/null || echo "")
MONGO_URL=$(terraform output -raw mongo_dashboard_url 2>/dev/null || echo "")
COST_URL=$(terraform output -raw cost_dashboard_url 2>/dev/null || echo "")

sep
ok "Shared stack deployment complete!"
echo ""
echo "  Resource prefix : ${SHARED_RESOURCE_PREFIX}"
echo "  Environment     : ${ENVIRONMENT}"
echo "  Region          : ${AWS_REGION}"
echo ""
echo "  Voyage endpoint : ${VOYAGE_NAME:-<disabled — EMBEDDINGS_PROVIDER=${EMBEDDINGS_PROVIDER:-unset}>}"
echo "  API log group   : ${API_LG}"
echo ""
echo "  Fleet dashboard : ${FLEET_URL}"
echo "  Mongo dashboard : ${MONGO_URL}"
echo "  Cost dashboard  : ${COST_URL}"
echo ""
echo "  SSM prefix      : /${SHARED_VPC_NAME}/${AWS_REGION}/"
echo "  State key       : ${SHARED_VPC_NAME}/${AWS_REGION}/${ENVIRONMENT}/shared/terraform.tfstate"
echo ""
echo "  Next: ./deploy/scripts/deploy-project.sh   (per-project ec2 stack)"
sep
