#!/usr/bin/env bash
# deploy-network.sh — Apply the shared network stack (envs/network)
#
# Usage:
#   ./deploy/scripts/deploy-network.sh [--auto-approve] [--env-file <path>]
#
# What it does:
#   Phase 1 — Validate prereqs (aws, terraform, python3)
#   Phase 2 — Source .env, verify AWS + Atlas credentials
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
# State location uses SHARED_VPC_NAME from .env (default: "shared-network")
# so the path is operator-controlled, not hardcoded in terraform.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_ROOT="$REPO_ROOT/deploy/terraform"
TF_DIR="$TF_ROOT/envs/network"
BOOTSTRAP_DIR="$TF_ROOT/bootstrap"

ENV_FILE="$REPO_ROOT/.env"
AUTO_APPROVE=false
ALLOW_MODE_SWITCH=false
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
NETWORK_MODE="${NETWORK_MODE:-privatelink}"
ATLAS_PEERING_CIDR="${ATLAS_PEERING_CIDR:-192.168.248.0/21}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve)       AUTO_APPROVE=true ;;
    --allow-mode-switch)  ALLOW_MODE_SWITCH=true ;;
    --env-file)           ENV_FILE="$2"; shift ;;
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

# Shared transient-error classifier (DNS resolver + network/transport blips).
# shellcheck source=deploy/scripts/_transient-errors.sh
source "$SCRIPT_DIR/_transient-errors.sh"

# Same retry-on-transient-error pattern as deploy-project.sh — the
# discover-or-create-pl.sh provisioner hits cloud.mongodb.com which can
# i/o timeout / TLS-handshake-timeout under load, and a local DNS resolver
# blip can also surface mid-apply.
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
    # Transient = local DNS resolver / network blip (shared classifier) OR
    # Terraform saved-plan staleness after state changed between plan and apply.
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

# Re-read env vars in case .env redefined them
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
NETWORK_MODE="${NETWORK_MODE:-privatelink}"
ATLAS_PEERING_CIDR="${ATLAS_PEERING_CIDR:-192.168.248.0/21}"

# Validate NETWORK_MODE
case "$NETWORK_MODE" in
  privatelink|peering) ;;
  *) err "Invalid NETWORK_MODE='${NETWORK_MODE}' — must be 'privatelink' or 'peering'" ;;
esac

# ── Pre-flight: CIDR overlap check (peering mode only) ──────────────────────
# Fails fast before terraform plan (saves ~30s vs catching the precondition).
if [[ "$NETWORK_MODE" == "peering" ]]; then
  python3 - <<PY || err "CIDR pre-flight failed — see message above"
import ipaddress, sys
v = ipaddress.ip_network('${VPC_CIDR}')
a = ipaddress.ip_network('${ATLAS_PEERING_CIDR}')
if v.overlaps(a):
    sys.stderr.write(
        f"CIDR overlap: VPC_CIDR={v} overlaps ATLAS_PEERING_CIDR={a}.\n"
        f"  Pick a non-overlapping ATLAS_PEERING_CIDR (Atlas default 192.168.248.0/21 is reserved\n"
        f"  and does not overlap the default vpc_cidr 10.0.0.0/16).\n"
    )
    sys.exit(1)
PY
  ok "CIDR pre-flight: ${VPC_CIDR} (VPC) and ${ATLAS_PEERING_CIDR} (Atlas) do not overlap"
fi

export TF_VAR_atlas_project_id="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
[[ -n "${TF_VAR_atlas_project_id:-}" ]] || err "Atlas Project ID not set. Set TF_VAR_mongodb_atlas_project_id in .env"

export TF_VAR_atlas_public_key="${MONGODB_ATLAS_PUBLIC_KEY:-}"
export TF_VAR_atlas_private_key="${MONGODB_ATLAS_PRIVATE_KEY:-}"
[[ -n "${TF_VAR_atlas_public_key:-}" ]]  || err "MONGODB_ATLAS_PUBLIC_KEY not set in .env"
[[ -n "${TF_VAR_atlas_private_key:-}" ]] || err "MONGODB_ATLAS_PRIVATE_KEY not set in .env"

DEPLOY_DIAG_LABEL="network"
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
preflight_validate network
deploy_diag_after_preflight "network" "$ENV_FILE"

ok "AWS account: $ACCOUNT_ID"
ok "Atlas project: $TF_VAR_atlas_project_id"
ok "Shared VPC name: $SHARED_VPC_NAME"
ok "Region: $AWS_REGION"
ok "Network mode: ${NETWORK_MODE}"
[[ "$NETWORK_MODE" == "peering" ]] && ok "Atlas peering CIDR: ${ATLAS_PEERING_CIDR}"

SHARED_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-${ACCOUNT_ID}"

# ── Pre-flight: mode-switch guard ───────────────────────────────────────────
# If SSM /network_mode already exists from a previous apply, refuse to flip
# the mode without an explicit --allow-mode-switch (and even then, operator
# must have already run deploy/destroy/* — otherwise resources from both modes
# will collide).
EXISTING_MODE=$(aws ssm get-parameter \
  --region "$AWS_REGION" \
  --name "/${SHARED_VPC_NAME}/${AWS_REGION}/network_mode" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")
if [[ -n "$EXISTING_MODE" && "$EXISTING_MODE" != "$NETWORK_MODE" ]]; then
  if [[ "$ALLOW_MODE_SWITCH" != "true" ]]; then
    case "$EXISTING_MODE" in
      peering)
        DESTROY_PROJECT="./deploy/destroy/destroy-project-with-vpc-peering.sh"
        DESTROY_SHARED="./deploy/destroy/destroy-shared-with-vpc-peering.sh"
        ;;
      *)
        DESTROY_PROJECT="./deploy/destroy/destroy-project-with-privatelink.sh"
        DESTROY_SHARED="./deploy/destroy/destroy-shared-with-privatelink.sh"
        ;;
    esac
    err "MODE MISMATCH: SSM /${SHARED_VPC_NAME}/${AWS_REGION}/network_mode says '${EXISTING_MODE}' but env says '${NETWORK_MODE}'.
       PrivateLink and VPC peering are mutually exclusive per account — to switch modes run:
         ${DESTROY_PROJECT}
         ${DESTROY_SHARED}
       Then re-run with the desired NETWORK_MODE. Override with --allow-mode-switch only after the
       destroy completes successfully (otherwise resources from both modes will collide)."
  fi
  warn "MODE SWITCH detected (${EXISTING_MODE} → ${NETWORK_MODE}). --allow-mode-switch is set; proceeding."
fi

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

# Auto-detect operator public IP (CIDR /32) for the Atlas IP access list
# in peering mode. Without this, local-exec provisioners run from the
# operator machine (db-seeding, ensure-collection, Atlas curl helpers)
# can't reach the cluster after mongodb-atlas flips the default 0.0.0.0/0
# entry to var.vpc_cidr. Override via env: export OPERATOR_IP_CIDR=A.B.C.D/32.
if [[ -z "${OPERATOR_IP_CIDR:-}" && -n "${TF_VAR_my_ip:-}" ]]; then
  OPERATOR_IP_CIDR="$TF_VAR_my_ip"
fi
if [[ "$NETWORK_MODE" == "peering" && -z "${OPERATOR_IP_CIDR:-}" ]]; then
  log "Auto-detecting operator public IP via checkip.amazonaws.com (override with OPERATOR_IP_CIDR=A.B.C.D/32)..."
  DETECTED_IP=$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$DETECTED_IP" && "$DETECTED_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    OPERATOR_IP_CIDR="${DETECTED_IP}/32"
    ok "operator IP detected: $OPERATOR_IP_CIDR"
  else
    log "WARNING: could not auto-detect operator IP; Atlas IP access list will NOT include your laptop. Local-exec provisioners may fail. Set OPERATOR_IP_CIDR manually and re-run."
    OPERATOR_IP_CIDR=""
  fi
fi

cat > "$TF_DIR/terraform.tfvars" <<EOF
# Shared network — generated by deploy-network.sh
aws_region         = "${AWS_REGION}"
environment        = "${ENVIRONMENT}"
project_name       = "${PROJECT_NAME}"
shared_vpc_name    = "${SHARED_VPC_NAME}"
vpc_cidr           = "${VPC_CIDR}"
atlas_project_id   = "${TF_VAR_atlas_project_id}"
network_mode       = "${NETWORK_MODE}"
atlas_peering_cidr = "${ATLAS_PEERING_CIDR}"
operator_ip_cidr   = "${OPERATOR_IP_CIDR:-}"
# atlas_public_key / atlas_private_key → TF_VAR env vars
EOF
ok "terraform.tfvars written (network_mode=${NETWORK_MODE}, operator_ip=${OPERATOR_IP_CIDR:-unset})"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — terraform apply (envs/network)
# ══════════════════════════════════════════════════════════════════════════════
sep
cd "$TF_DIR"
deploy_diag_terraform_context "network terraform init" "$TF_DIR" "$TF_DIR/backend.hcl" "$TF_DIR/.tfplan"
log "Phase 5 — terraform init..."
deploy_diag_checkpoint "terraform init start: terraform init -input=false -reconfigure -backend-config=${TF_DIR}/backend.hcl"
terraform init -input=false -reconfigure -backend-config="$TF_DIR/backend.hcl"
ok "init complete"

log "Running terraform plan..."
deploy_diag_checkpoint "terraform plan start: terraform plan -input=false -out=${TF_DIR}/.tfplan"
terraform plan -input=false -out="$TF_DIR/.tfplan"
ok "plan complete"

sep
if [[ "$NETWORK_MODE" == "privatelink" ]]; then
  log "NOTE: First apply discovers/creates the Atlas PrivateLink endpoint service"
  log "(reused across all per-project deployments in this Atlas project + region)."
else
  log "NOTE: First apply discovers/creates the Atlas network container for VPC peering"
  log "(reused across all per-project deployments in this Atlas project + region)."
  log "Atlas Private DNS for Peering is auto-enabled via the Admin API. If the API"
  log "key lacks GROUP_OWNER scope the toggle fails (warning only) and the runtime"
  log "URI silently falls back to the multi-host non-SRV form (still private)."
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
# PHASE 6 — Verify SSM params + summary
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 6 — Verifying SSM params under /${SHARED_VPC_NAME}/${AWS_REGION}/..."

SHARED_PARAMS=(
  "vpc_id"
  "vpc_cidr"
  "public_subnet_ids"
  "private_subnet_ids"
  "network_mode"
)

if [[ "$NETWORK_MODE" == "privatelink" ]]; then
  MODE_PARAMS=(
    "atlas_pl_vpce_id"
    "atlas_pl_vpce_dns_name"
    "atlas_pl_security_group_id"
    "atlas_endpoint_service_name"
    "atlas_private_link_id"
  )
else
  MODE_PARAMS=(
    "atlas_peering_id"
    "atlas_container_id"
    "atlas_peering_cidr"
    "atlas_private_dns_enabled"
  )
fi

REQUIRED_PARAMS=("${SHARED_PARAMS[@]}" "${MODE_PARAMS[@]}")

for p in "${REQUIRED_PARAMS[@]}"; do
  val=$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/${p}" \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")
  [[ -n "$val" ]] || err "SSM param missing or empty: /${SHARED_VPC_NAME}/${AWS_REGION}/${p}"
done
ok "All ${#REQUIRED_PARAMS[@]} SSM params populated (${#SHARED_PARAMS[@]} shared + ${#MODE_PARAMS[@]} ${NETWORK_MODE})"

VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "")
PUB_SUBNETS=$(terraform output -json public_subnet_ids 2>/dev/null || echo "")
PRIV_SUBNETS=$(terraform output -json private_subnet_ids 2>/dev/null || echo "")

sep
ok "Shared network deployment complete!"
echo ""
echo "  Shared VPC name : ${SHARED_VPC_NAME}"
echo "  Region          : ${AWS_REGION}"
echo "  Network mode    : ${NETWORK_MODE}"
echo "  VPC             : ${VPC_ID}"
echo "  Public subnets  : ${PUB_SUBNETS}"
echo "  Private subnets : ${PRIV_SUBNETS}"

if [[ "$NETWORK_MODE" == "privatelink" ]]; then
  VPCE_ID=$(terraform output -raw atlas_pl_vpce_id 2>/dev/null || echo "")
  VPCE_DNS=$(terraform output -raw atlas_pl_vpce_dns_name 2>/dev/null || echo "")
  PL_ID=$(terraform output -raw atlas_private_link_id 2>/dev/null || echo "")
  echo "  Atlas VPCE      : ${VPCE_ID}"
  echo "  VPCE DNS        : ${VPCE_DNS}"
  echo "  Atlas PL id     : ${PL_ID}"
else
  PEERING_ID=$(terraform output -raw atlas_peering_connection_id 2>/dev/null || echo "")
  CONTAINER_ID=$(terraform output -raw atlas_network_container_id 2>/dev/null || echo "")
  ATLAS_CIDR=$(terraform output -raw atlas_peering_cidr 2>/dev/null || echo "")
  PRIVATE_DNS=$(terraform output -raw atlas_private_dns_enabled 2>/dev/null || echo "false")
  echo "  Atlas peering id: ${PEERING_ID}"
  echo "  Atlas container : ${CONTAINER_ID}"
  echo "  Atlas CIDR      : ${ATLAS_CIDR}"
  echo "  Private DNS     : ${PRIVATE_DNS} (when true, SRV-form peering URI is used; multi-host non-SRV is always available as fallback)"
  if [[ "$PRIVATE_DNS" != "true" ]]; then
    echo ""
    warn "Atlas 'Private DNS for Peering' is NOT enabled — the runtime uses the multi-host non-SRV"
    warn "peering URI. To enable the SRV form, either:"
    warn "  1. Re-run with an Atlas API key that has GROUP_OWNER scope (auto-enable will retry)"
    warn "  2. Enable it manually in Atlas: Project → Network Access → Peering → 'Use private IPs/DNS'"
  fi
fi

echo ""
echo "  SSM prefix      : /${SHARED_VPC_NAME}/${AWS_REGION}/"
echo "  State key       : ${SHARED_VPC_NAME}/${AWS_REGION}/network/terraform.tfstate"
echo ""
if [[ "$NETWORK_MODE" == "privatelink" ]]; then
  echo "  Next: ./deploy/deploy-full-with-privatelink.sh   (or ./deploy/scripts/deploy-project.sh directly)"
else
  echo "  Next: ./deploy/deploy-full-with-vpc-peering.sh   (or ./deploy/scripts/deploy-project.sh directly)"
fi
sep
