#!/usr/bin/env bash
# destroy-shared-with-public.sh - Tear down shared resources in PUBLIC
# (Bring-your-own MongoDB Atlas cluster) mode.
#
# Usage:
#   ./deploy/destroy/destroy-shared-with-public.sh [--auto-approve] [--env-file <path>] [--with-bootstrap] [--force]
#
# What it does:
#   - Hard-sets NETWORK_MODE=public + ATLAS_CLUSTER_SOURCE=byo for the child engine.
#   - Validates AWS auth before reading AWS state.
#   - Refuses to run if project EC2 resources still exist, unless --force is passed.
#   - Runs deploy/scripts/destroy.sh --mode shared, then --mode network.
#   - Passes --with-bootstrap only to the final network destroy step.
#
# Public mode runs AgentCore with PUBLIC egress (no VPC attachment), so there
# are no service-managed agentic_ai ENIs to wait on and no orphan-SG reaper.
# envs/network removes only the shared VPC (no Atlas VPCE/peering primitive
# exists in this mode). Your BYO Atlas cluster is never touched.
#
# Run destroy-project-with-public.sh first to remove project resources.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
DESTROY_SCRIPT="$DEPLOY_DIR/scripts/destroy.sh"
AWS_AUTH_HELPER="$DEPLOY_DIR/scripts/_aws-auth.sh"
THIS_MODE="public"
THIS_LABEL="Public (BYO Atlas)"

ENV_FILE="$REPO_ROOT/.env"
AUTO_APPROVE=false
WITH_BOOTSTRAP=false
FORCE=false
CHILD_ENV_FILE=""

log()  { echo "  [destroy-shared:${THIS_MODE}] $*"; }
err()  { echo "  [destroy-shared:${THIS_MODE}] ERROR: $*" >&2; exit 1; }
warn() { echo "  [destroy-shared:${THIS_MODE}] WARN: $*"; }
sep()  { echo "------------------------------------------------"; }

usage() {
  sed -n '2,19p' "$0"
}

mode_script_suffix() {
  case "$1" in
    peering) echo "vpc-peering" ;;
    privatelink) echo "privatelink" ;;
    *) echo "$1" ;;
  esac
}

cleanup() {
  if [[ -n "$CHILD_ENV_FILE" && -f "$CHILD_ENV_FILE" ]]; then
    rm -f "$CHILD_ENV_FILE"
  fi
  return 0
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve)   AUTO_APPROVE=true ;;
    --with-bootstrap) WITH_BOOTSTRAP=true ;;
    --force)          FORCE=true ;;
    --env-file)
      [[ $# -ge 2 ]] || err "--env-file requires a path"
      ENV_FILE="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) err "Unknown arg: $1" ;;
  esac
  shift
done

[[ -x "$DESTROY_SCRIPT" ]] || err "destroy.sh not found or not executable: $DESTROY_SCRIPT"
[[ -f "$AWS_AUTH_HELPER" ]] || err "_aws-auth.sh not found: $AWS_AUTH_HELPER"
[[ -f "$ENV_FILE" ]]       || err "env file not found: $ENV_FILE"

# shellcheck source=/dev/null
source "$ENV_FILE"

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"

if [[ -n "${NETWORK_MODE:-}" && "$NETWORK_MODE" != "$THIS_MODE" ]]; then
  warn "Overriding NETWORK_MODE='${NETWORK_MODE}' from env file -> '${THIS_MODE}' (${THIS_LABEL} script contract)"
fi
export NETWORK_MODE="$THIS_MODE"
export ATLAS_CLUSTER_SOURCE="byo"

# shellcheck source=/dev/null
source "$AWS_AUTH_HELPER"
validate_aws_auth || err "AWS auth validation failed (see above)"

EXISTING_MODE=$(aws ssm get-parameter \
  --region "$AWS_REGION" \
  --name "/${SHARED_VPC_NAME}/${AWS_REGION}/network_mode" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")
if [[ -n "$EXISTING_MODE" && "$EXISTING_MODE" != "$THIS_MODE" && "$FORCE" != "true" ]]; then
  err "SSM network_mode='${EXISTING_MODE}' but this script enforces '${THIS_MODE}'.
Run ./deploy/destroy/destroy-shared-with-$(mode_script_suffix "$EXISTING_MODE").sh instead, or pass --force if you are cleaning up a partial teardown."
fi

EC2_IDS=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:Environment,Values=${ENVIRONMENT}" "Name=tag:ManagedBy,Values=terraform" "Name=instance-state-name,Values=pending,running,stopped,stopping" \
  --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Project'].Value | [0],State.Name]" \
  --output text 2>/dev/null || echo "")
if [[ -n "$EC2_IDS" && "$EC2_IDS" != "None" && "$FORCE" != "true" ]]; then
  err "Terraform-managed EC2 project resources still exist in environment '${ENVIRONMENT}':
${EC2_IDS}
Destroy every per-project envs/ec2 stack that shares this environment first, or pass --force if you are intentionally tearing down shared resources anyway."
elif [[ -n "$EC2_IDS" && "$EC2_IDS" != "None" ]]; then
  warn "Terraform-managed EC2 project resources still exist (${EC2_IDS}); continuing because --force was passed."
fi

CHILD_ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/destroy-${THIS_MODE}.env.XXXXXX")"
cp "$ENV_FILE" "$CHILD_ENV_FILE"
{
  echo ""
  echo "# Added by $(basename "$0") so child destroy.sh uses the script's connectivity mode."
  echo "NETWORK_MODE=${THIS_MODE}"
  echo "ATLAS_CLUSTER_SOURCE=byo"
} >> "$CHILD_ENV_FILE"

sep
log "Destroying shared/singleton resources in ${THIS_LABEL} mode."
log "Order: envs/shared -> envs/network"
[[ "$WITH_BOOTSTRAP" == "true" ]] && warn "--with-bootstrap will delete the shared Terraform state bucket during the final network step."
log "Env file for child destroy: $CHILD_ENV_FILE"
sep

CHILD_ARGS=("--env-file" "$CHILD_ENV_FILE")
[[ "$AUTO_APPROVE" == "true" ]] && CHILD_ARGS+=("--auto-approve")

NETWORK_MODE="$THIS_MODE" ATLAS_CLUSTER_SOURCE="byo" bash "$DESTROY_SCRIPT" --mode shared "${CHILD_ARGS[@]}"

NETWORK_ARGS=("${CHILD_ARGS[@]}")
[[ "$WITH_BOOTSTRAP" == "true" ]] && NETWORK_ARGS+=("--with-bootstrap")
NETWORK_MODE="$THIS_MODE" ATLAS_CLUSTER_SOURCE="byo" bash "$DESTROY_SCRIPT" --mode network "${NETWORK_ARGS[@]}"

sep
log "Shared/network destroy complete."
