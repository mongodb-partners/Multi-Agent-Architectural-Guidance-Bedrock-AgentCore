#!/usr/bin/env bash
# destroy-project-with-vpc-peering.sh - Tear down only project resources in VPC peering mode.
#
# Usage:
#   ./deploy/destroy/destroy-project-with-vpc-peering.sh [--auto-approve] [--env-file <path>] [--force]
#
# What it does:
#   - Hard-sets NETWORK_MODE=peering for the child destroy engine.
#   - Validates AWS auth before reading the network-mode SSM canary.
#   - Warns if the deployed network-mode SSM canary differs; destroy still runs
#     in peering mode because this wrapper is the VPC peering entrypoint.
#   - Defers AgentCore ENI-pinned runtime security groups to the VPC peering
#     orphan SG reaper instead of blocking in the foreground.
#   - Runs deploy/scripts/destroy.sh --mode ec2 only.
#
# This does NOT destroy shared observability, embeddings, VPC, peering, or
# Terraform bootstrap state. Use destroy-shared-with-vpc-peering.sh for those.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
DESTROY_SCRIPT="$DEPLOY_DIR/scripts/destroy.sh"
AWS_AUTH_HELPER="$DEPLOY_DIR/scripts/_aws-auth.sh"
THIS_MODE="peering"
CHILD_NETWORK_MODE="peering"
THIS_LABEL="VPC peering"
ORPHAN_SG_REAPER_SCRIPT="deploy/destroy/reap-orphan-security-groups-vpc-peering.sh"

ENV_FILE="$REPO_ROOT/.env"
AUTO_APPROVE=false
FORCE=false
CHILD_ENV_FILE=""

log()  { echo "  [destroy-project:${THIS_MODE}] $*"; }
err()  { echo "  [destroy-project:${THIS_MODE}] ERROR: $*" >&2; exit 1; }
warn() { echo "  [destroy-project:${THIS_MODE}] WARN: $*"; }
sep()  { echo "------------------------------------------------"; }

usage() {
  sed -n '2,14p' "$0"
}

mode_script_suffix() {
  case "$1" in
    vpc) echo "vpc-peering" ;;
    peering) echo "vpc-peering" ;;
    privatelink) echo "privatelink" ;;
    *) echo "$1" ;;
  esac
}

mode_matches_this_script() {
  [[ "$1" == "$THIS_MODE" || "$1" == "$CHILD_NETWORK_MODE" ]]
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
    --auto-approve) AUTO_APPROVE=true ;;
    --force)        FORCE=true ;;
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
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
ATLAS_PEERING_CIDR="${ATLAS_PEERING_CIDR:-192.168.248.0/21}"

if [[ -n "${NETWORK_MODE:-}" && "$NETWORK_MODE" != "$THIS_MODE" ]]; then
  warn "Overriding NETWORK_MODE='${NETWORK_MODE}' from env file -> '${THIS_MODE}' (${THIS_LABEL} script contract)"
fi
[[ "$FORCE" == "true" ]] && warn "--force accepted for compatibility; this wrapper always destroys with NETWORK_MODE='${CHILD_NETWORK_MODE}'."
export NETWORK_MODE="$THIS_MODE"
export ATLAS_PEERING_CIDR

# shellcheck source=/dev/null
source "$AWS_AUTH_HELPER"
validate_aws_auth || err "AWS auth validation failed (see above)"

EXISTING_MODE=$(aws ssm get-parameter \
  --region "$AWS_REGION" \
  --name "/${SHARED_VPC_NAME}/${AWS_REGION}/network_mode" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")
if [[ -n "$EXISTING_MODE" ]] && ! mode_matches_this_script "$EXISTING_MODE"; then
  warn "SSM network_mode='${EXISTING_MODE}' differs from wrapper mode '${THIS_MODE}'."
  warn "Continuing with NETWORK_MODE='${CHILD_NETWORK_MODE}' because this is the VPC peering destroy wrapper."
fi

CHILD_ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/destroy-${THIS_MODE}.env.XXXXXX")"
cp "$ENV_FILE" "$CHILD_ENV_FILE"
{
  echo ""
  echo "# Added by $(basename "$0") so child destroy.sh uses VPC peering connectivity mode."
  echo "NETWORK_MODE=${CHILD_NETWORK_MODE}"
  echo "ATLAS_PEERING_CIDR=${ATLAS_PEERING_CIDR}"
  echo "ORPHAN_SG_REAPER_SCRIPT=${ORPHAN_SG_REAPER_SCRIPT}"
} >> "$CHILD_ENV_FILE"

sep
log "Destroying ONLY project resources (envs/ec2) in ${THIS_LABEL} mode."
log "Shared/network resources are NOT touched by this script."
log "Child destroy NETWORK_MODE: ${CHILD_NETWORK_MODE}"
log "Deferred SG reaper: ./${ORPHAN_SG_REAPER_SCRIPT}"
log "Env file for child destroy: $CHILD_ENV_FILE"
sep

CHILD_ARGS=("--mode" "ec2" "--env-file" "$CHILD_ENV_FILE")
[[ "$AUTO_APPROVE" == "true" ]] && CHILD_ARGS+=("--auto-approve")

NETWORK_MODE="$CHILD_NETWORK_MODE" ATLAS_PEERING_CIDR="$ATLAS_PEERING_CIDR" ORPHAN_SG_REAPER_SCRIPT="$ORPHAN_SG_REAPER_SCRIPT" bash "$DESTROY_SCRIPT" "${CHILD_ARGS[@]}"

sep
log "Project destroy complete."
log "If AgentCore ENIs pinned runtime security groups, run: ./${ORPHAN_SG_REAPER_SCRIPT} --watch"
log "To remove shared/network singletons, run: ./deploy/destroy/destroy-shared-with-vpc-peering.sh"
