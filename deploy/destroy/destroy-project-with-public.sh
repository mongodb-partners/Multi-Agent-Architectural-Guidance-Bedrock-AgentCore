#!/usr/bin/env bash
# destroy-project-with-public.sh - Tear down only project resources in PUBLIC
# (Bring-your-own MongoDB Atlas cluster) mode.
#
# Usage:
#   ./deploy/destroy/destroy-project-with-public.sh [--auto-approve] [--env-file <path>] [--force]
#
# What it does:
#   - Hard-sets NETWORK_MODE=public + ATLAS_CLUSTER_SOURCE=byo for the child engine.
#   - Validates AWS auth before reading the network-mode SSM canary.
#   - Refuses to run if the deployed network mode is privatelink/peering, unless --force.
#   - Runs deploy/scripts/destroy.sh --mode ec2 only.
#
# No orphan-SG reaper: AgentCore runs PUBLIC egress in this mode (no VPC
# attachment), so there are no service-managed agentic_ai ENIs to defer.
# Your BYO Atlas cluster is NOT touched — Terraform never created it.
#
# This does NOT destroy shared observability, embeddings, VPC, or Terraform
# bootstrap state. Use destroy-shared-with-public.sh for those.

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
FORCE=false
CHILD_ENV_FILE=""

log()  { echo "  [destroy-project:${THIS_MODE}] $*"; }
err()  { echo "  [destroy-project:${THIS_MODE}] ERROR: $*" >&2; exit 1; }
warn() { echo "  [destroy-project:${THIS_MODE}] WARN: $*"; }
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
Run ./deploy/destroy/destroy-project-with-$(mode_script_suffix "$EXISTING_MODE").sh instead, or pass --force if you are cleaning up a partial teardown."
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
log "Destroying ONLY project resources (envs/ec2) in ${THIS_LABEL} mode."
log "Your BYO Atlas cluster is NOT touched. Shared/network resources are NOT touched."
log "Env file for child destroy: $CHILD_ENV_FILE"
sep

CHILD_ARGS=("--mode" "ec2" "--env-file" "$CHILD_ENV_FILE")
[[ "$AUTO_APPROVE" == "true" ]] && CHILD_ARGS+=("--auto-approve")

NETWORK_MODE="$THIS_MODE" ATLAS_CLUSTER_SOURCE="byo" bash "$DESTROY_SCRIPT" "${CHILD_ARGS[@]}"

sep
log "Project destroy complete."
log "To remove shared/network singletons, run: ./deploy/destroy/destroy-shared-with-public.sh"
