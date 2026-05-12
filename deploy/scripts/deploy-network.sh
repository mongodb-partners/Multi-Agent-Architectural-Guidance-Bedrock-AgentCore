#!/usr/bin/env bash
# deploy-network.sh — Apply the shared network stack (envs/network)
#
# Usage:
#   ./deploy/scripts/deploy-network.sh [--auto-approve] [--env-file <path>]
#
# What it does:
#   Phase 1 — Validate prereqs (aws, terraform, python3)
#   Phase 2 — Source env.sh, verify AWS + Atlas credentials
#   Phase 3 — Bootstrap shared S3 state bucket (idempotent — same as deploy.sh)
#   Phase 4 — Generate backend.hcl + terraform.tfvars for envs/network.
#             State key:  ${SHARED_VPC_NAME}/${AWS_REGION}/network/terraform.tfstate
#   Phase 5 — terraform init + plan + apply (envs/network):
#               VPC + 2x public + 2x private subnets + IGW + RT
#               Atlas Interface VPCE + Atlas-side endpoint binding
#               Atlas-PL security group (CIDR ingress on var.vpc_cidr)
#               SSM Parameter Store entries for cross-state discovery
#   Phase 6 — Verify SSM params and print summary
#
# This script is run ONCE per (account, region) — multiple per-project
# deploy.sh invocations all consume the same SSM-published values.
#
# State location uses SHARED_VPC_NAME from env.sh (default: "shared-network")
# so the path is operator-controlled, not hardcoded in terraform.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_ROOT="$REPO_ROOT/deploy/terraform"
TF_DIR="$TF_ROOT/envs/network"
BOOTSTRAP_DIR="$TF_ROOT/bootstrap"

ENV_FILE="$REPO_ROOT/env.sh"
AUTO_APPROVE=false
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve) AUTO_APPROVE=true ;;
    --env-file)     ENV_FILE="$2"; shift ;;
    -h|--help)
      sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "  [network] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo "  [network] $*"; }
ok()   { echo "  [network] ✓ $*"; }
err()  { echo "  [network] ✗ $*" >&2; exit 1; }
warn() { echo "  [network] ⚠ $*"; }
sep()  { echo "────────────────────────────────────────────────"; }

# Same retry-on-transient-Atlas-API-error pattern as deploy.sh — the
# discover-or-create-pl.sh provisioner hits cloud.mongodb.com which can
# i/o timeout / TLS-handshake-timeout under load.
apply_with_retry() {
  local plan_file="$1"
  local max_attempts=3
  local attempt=1
  local log_file rc
  log_file=$(mktemp -t tf-network-apply.XXXXXX)

  while (( attempt <= max_attempts )); do
    if (( attempt > 1 )); then
      log "Retry $((attempt - 1))/$((max_attempts - 1)) — sleeping 30s, re-planning..."
      sleep 30
      terraform plan -input=false -out="$plan_file"
      ok "re-plan complete"
    fi
    log "Apply attempt ${attempt}/${max_attempts}..."
    set +e
    terraform apply -input=false "$plan_file" 2>&1 | tee "$log_file"
    rc=${PIPESTATUS[0]}
    set -e
    if (( rc == 0 )); then
      rm -f "$log_file"
      return 0
    fi
    if grep -qE 'cloud\.mongodb\.com.*(i/o timeout|connection reset|connection refused|EOF|TLS handshake timeout)' "$log_file"; then
      warn "Transient Atlas API error on attempt ${attempt} — will retry"
      attempt=$((attempt + 1))
      continue
    fi
    rm -f "$log_file"
    err "terraform apply failed with a non-transient error (see output above)"
  done
  rm -f "$log_file"
  err "terraform apply failed after ${max_attempts} attempts — transient Atlas API errors did not clear"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Prerequisites
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 1 — Checking prerequisites..."
for cmd in aws terraform python3; do
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

# Re-read env vars in case env.sh redefined them
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"

export TF_VAR_atlas_project_id="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
[[ -n "${TF_VAR_atlas_project_id:-}" ]] || err "Atlas Project ID not set. Set TF_VAR_mongodb_atlas_project_id in env.sh"

export TF_VAR_atlas_public_key="${MONGODB_ATLAS_PUBLIC_KEY:-}"
export TF_VAR_atlas_private_key="${MONGODB_ATLAS_PRIVATE_KEY:-}"
[[ -n "${TF_VAR_atlas_public_key:-}" ]]  || err "MONGODB_ATLAS_PUBLIC_KEY not set in env.sh"
[[ -n "${TF_VAR_atlas_private_key:-}" ]] || err "MONGODB_ATLAS_PRIVATE_KEY not set in env.sh"

[[ -n "${AWS_ACCESS_KEY_ID:-}" ]] || err "AWS_ACCESS_KEY_ID not set. Re-authenticate and update env.sh"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "AWS credentials invalid or expired."
ok "AWS account: $ACCOUNT_ID"
ok "Atlas project: $TF_VAR_atlas_project_id"
ok "Shared VPC name: $SHARED_VPC_NAME"
ok "Region: $AWS_REGION"

SHARED_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-${ACCOUNT_ID}"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Bootstrap (idempotent)
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 3 — Checking bootstrap state..."
if aws s3api head-bucket --bucket "$SHARED_BUCKET" 2>/dev/null; then
  ok "Shared bucket exists — skipping bootstrap"
else
  log "Bucket not found — running bootstrap (one-time)..."
  cd "$BOOTSTRAP_DIR"
  terraform init -input=false -no-color
  terraform apply -input=false -auto-approve \
    -var="account_id=$ACCOUNT_ID" \
    -var="aws_region=$AWS_REGION" \
    -var="environment=$ENVIRONMENT" \
    -var="project_name=$PROJECT_NAME"
  ok "Bootstrap complete"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — Generate Terraform config (envs/network)
# State key includes SHARED_VPC_NAME so multiple shared networks can coexist
# in the same bucket if ever needed (different teams / regions).
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 4 — Generating Terraform config for envs/network..."

cat > "$TF_DIR/backend.hcl" <<EOF
bucket  = "${SHARED_BUCKET}"
key     = "${SHARED_VPC_NAME}/${AWS_REGION}/network/terraform.tfstate"
region  = "${AWS_REGION}"
encrypt = true
EOF
ok "backend.hcl written (state key: ${SHARED_VPC_NAME}/${AWS_REGION}/network/terraform.tfstate)"

cat > "$TF_DIR/terraform.tfvars" <<EOF
# Shared network — generated by deploy-network.sh
aws_region       = "${AWS_REGION}"
environment      = "${ENVIRONMENT}"
project_name     = "${PROJECT_NAME}"
shared_vpc_name  = "${SHARED_VPC_NAME}"
vpc_cidr         = "${VPC_CIDR}"
atlas_project_id = "${TF_VAR_atlas_project_id}"
# atlas_public_key / atlas_private_key → TF_VAR env vars
EOF
ok "terraform.tfvars written"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — terraform apply (envs/network)
# ══════════════════════════════════════════════════════════════════════════════
sep
cd "$TF_DIR"
log "Phase 5 — terraform init..."
terraform init -input=false -reconfigure -backend-config="$TF_DIR/backend.hcl"
ok "init complete"

log "Running terraform plan..."
terraform plan -input=false -out="$TF_DIR/.tfplan"
ok "plan complete"

sep
log "NOTE: First apply discovers/creates the Atlas PrivateLink endpoint service"
log "(reused across all per-project deployments in this Atlas project + region)."

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
# PHASE 6 — Verify SSM params + summary
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 6 — Verifying SSM params under /${SHARED_VPC_NAME}/${AWS_REGION}/..."

REQUIRED_PARAMS=(
  "vpc_id"
  "vpc_cidr"
  "public_subnet_ids"
  "private_subnet_ids"
  "atlas_pl_vpce_id"
  "atlas_pl_vpce_dns_name"
  "atlas_pl_security_group_id"
  "atlas_endpoint_service_name"
  "atlas_private_link_id"
)

for p in "${REQUIRED_PARAMS[@]}"; do
  val=$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/${p}" \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")
  [[ -n "$val" ]] || err "SSM param missing or empty: /${SHARED_VPC_NAME}/${AWS_REGION}/${p}"
done
ok "All ${#REQUIRED_PARAMS[@]} SSM params populated"

VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "")
PUB_SUBNETS=$(terraform output -json public_subnet_ids 2>/dev/null || echo "")
PRIV_SUBNETS=$(terraform output -json private_subnet_ids 2>/dev/null || echo "")
VPCE_ID=$(terraform output -raw atlas_pl_vpce_id 2>/dev/null || echo "")
VPCE_DNS=$(terraform output -raw atlas_pl_vpce_dns_name 2>/dev/null || echo "")
PL_ID=$(terraform output -raw atlas_private_link_id 2>/dev/null || echo "")

sep
ok "Shared network deployment complete!"
echo ""
echo "  Shared VPC name : ${SHARED_VPC_NAME}"
echo "  Region          : ${AWS_REGION}"
echo "  VPC             : ${VPC_ID}"
echo "  Public subnets  : ${PUB_SUBNETS}"
echo "  Private subnets : ${PRIV_SUBNETS}"
echo "  Atlas VPCE      : ${VPCE_ID}"
echo "  VPCE DNS        : ${VPCE_DNS}"
echo "  Atlas PL id     : ${PL_ID}"
echo ""
echo "  SSM prefix      : /${SHARED_VPC_NAME}/${AWS_REGION}/"
echo "  State key       : ${SHARED_VPC_NAME}/${AWS_REGION}/network/terraform.tfstate"
echo ""
echo "  Next: ./deploy/scripts/deploy.sh   (per-project ec2 deploy reads SSM here)"
sep
