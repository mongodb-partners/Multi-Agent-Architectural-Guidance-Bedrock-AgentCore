#!/usr/bin/env bash
# deploy-full-with-privatelink.sh — Full end-to-end deployment coordinator.
#
# This is the single entrypoint for a complete deployment. It orchestrates:
#   1. Shared network stack (VPC + Atlas PrivateLink) — via deploy-network.sh,
#      only if the VPC does not already exist in SSM.
#   2. Project stack (EC2 + ECR + Cognito + Bedrock KB + AgentCore + MongoDB)
#      — via deploy-project.sh.
#
# Usage:
#   ./deploy/deploy-full-with-privatelink.sh [--auto-approve] [--skip-docker]
#                                             [--skip-network] [--env-file <path>]
#
# Flags:
#   --auto-approve   Pass -auto-approve to both terraform applies (no interactive prompts)
#   --skip-docker    Skip Docker image build/push in deploy-project.sh
#   --skip-network   Skip the network existence check and deploy-network.sh entirely
#                    (use when you know the VPC is already deployed and want to save time)
#   --env-file PATH  Path to credentials file (default: repo-root/.env)
#
# Network existence check:
#   Reads SHARED_VPC_NAME and AWS_REGION from .env (or --env-file), then checks
#   whether the SSM parameter /<SHARED_VPC_NAME>/<REGION>/vpc_id is already
#   populated. If it is, the network stack is considered deployed and
#   deploy-network.sh is skipped.  If it is not (first run, or new region),
#   deploy-network.sh is called first.
#
# Both sub-scripts accept --env-file and propagate it correctly; this script
# passes it through so a non-default credentials path works end-to-end.
#
# Prerequisites:
#   .env (or --env-file) must be populated before running this script.
#   All tool prerequisites are validated inside the sub-scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NETWORK_SCRIPT="$REPO_ROOT/deploy/scripts/deploy-network.sh"
PROJECT_SCRIPT="$REPO_ROOT/deploy/scripts/deploy-project.sh"

ENV_FILE="$REPO_ROOT/.env"
AUTO_APPROVE=false
SKIP_DOCKER=false
SKIP_NETWORK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve) AUTO_APPROVE=true ;;
    --skip-docker)  SKIP_DOCKER=true ;;
    --skip-network) SKIP_NETWORK=true ;;
    --env-file)     ENV_FILE="$2"; shift ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "  [full-deploy] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo "  [full-deploy] $*"; }
ok()   { echo "  [full-deploy] ✓ $*"; }
err()  { echo "  [full-deploy] ✗ $*" >&2; exit 1; }
warn() { echo "  [full-deploy] ⚠ $*"; }
sep()  { echo "════════════════════════════════════════════════════════════════"; }

sep
log "Starting full deployment (network + project) ..."
log "Env file : $ENV_FILE"
log "Flags    : auto-approve=$AUTO_APPROVE  skip-docker=$SKIP_DOCKER  skip-network=$SKIP_NETWORK"
sep

# ──────────────────────────────────────────────────────────────────────────────
# Validate sub-scripts exist
# ──────────────────────────────────────────────────────────────────────────────
[[ -x "$NETWORK_SCRIPT" ]] || err "deploy-network.sh not found or not executable: $NETWORK_SCRIPT"
[[ -x "$PROJECT_SCRIPT" ]] || err "deploy-project.sh not found or not executable: $PROJECT_SCRIPT"
[[ -f "$ENV_FILE" ]]       || err "Env file not found: $ENV_FILE  (create it from .env.example)"

# ──────────────────────────────────────────────────────────────────────────────
# Source .env to obtain SHARED_VPC_NAME + AWS_REGION for the VPC existence check
# ──────────────────────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$ENV_FILE"

AWS_REGION="${AWS_REGION:-us-east-1}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Network stack (shared VPC + Atlas PrivateLink)
# ──────────────────────────────────────────────────────────────────────────────
sep
if [[ "$SKIP_NETWORK" == "true" ]]; then
  warn "Phase 1 — Skipping network stack (--skip-network flag set)"
else
  log "Phase 1 — Checking whether shared VPC already exists..."
  log "  SSM key : /${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id"

  EXISTING_VPC_ID=$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo "")

  if [[ -n "$EXISTING_VPC_ID" ]]; then
    ok "Phase 1 — Shared VPC already deployed (vpc_id=$EXISTING_VPC_ID) — skipping deploy-network.sh"
  else
    log "Phase 1 — Shared VPC not found in SSM — running deploy-network.sh ..."
    sep

    NETWORK_ARGS=("--env-file" "$ENV_FILE")
    [[ "$AUTO_APPROVE" == "true" ]] && NETWORK_ARGS+=("--auto-approve")

    bash "$NETWORK_SCRIPT" "${NETWORK_ARGS[@]}"

    sep
    ok "Phase 1 — Network stack deployed successfully"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Project stack (EC2 + infra + app)
# ──────────────────────────────────────────────────────────────────────────────
sep
log "Phase 2 — Running deploy-project.sh ..."
sep

PROJECT_ARGS=("--env-file" "$ENV_FILE")
[[ "$AUTO_APPROVE" == "true" ]] && PROJECT_ARGS+=("--auto-approve")
[[ "$SKIP_DOCKER"  == "true" ]] && PROJECT_ARGS+=("--skip-docker")

bash "$PROJECT_SCRIPT" "${PROJECT_ARGS[@]}"

sep
ok "Phase 2 — Project stack deployed successfully"
sep
echo ""
echo "  Full deployment complete."
echo "  Network : /${SHARED_VPC_NAME}/${AWS_REGION}/"
echo "  To redeploy agents only : ./deploy/deploy-agents.sh"
echo "  To redeploy API only    : ./deploy/deploy-api.sh"
echo "  To tear down            : ./deploy/scripts/destroy.sh --mode ec2"
echo "                            ./deploy/scripts/destroy.sh --mode network"
echo ""
sep
