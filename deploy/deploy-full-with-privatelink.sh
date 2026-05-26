#!/usr/bin/env bash
# deploy-full-with-privatelink.sh — Full end-to-end deployment coordinator.
#
# This is the single entrypoint for a complete deployment. It orchestrates:
#   1.  Shared network stack (VPC + Atlas PrivateLink) — via deploy-network.sh,
#       only if the VPC does not already exist in SSM.
#   1.5 Shared observability + embeddings stack (SageMaker + log groups +
#       dashboards + invocation logging) — via deploy-shared.sh, only if its
#       SSM canary (cw_api_log_group) is not already populated.
#   2.  Project stack (EC2 + ECR + Cognito + Bedrock KB + AgentCore + MongoDB)
#       — via deploy-project.sh.
#
# Usage:
#   ./deploy/deploy-full-with-privatelink.sh [--auto-approve] [--skip-docker]
#                                             [--skip-smoke] [--skip-network]
#                                             [--skip-shared] [--env-file <path>]
#
# Flags:
#   --auto-approve   Pass -auto-approve to all terraform applies (no interactive prompts)
#   --skip-docker    Skip Docker image build/push in deploy-project.sh
#   --skip-smoke     Skip Phase 11 full post-deploy smoke in deploy-project.sh
#   --skip-network   Skip the network existence check and deploy-network.sh entirely
#                    (use when you know the VPC is already deployed and want to save time)
#   --skip-shared    Skip the shared-stack existence check and deploy-shared.sh entirely
#                    (use when you know the shared stack is already applied for this
#                    account+region+environment)
#   --env-file PATH  Path to credentials file (default: repo-root/.env)
#
# Network existence check:
#   Reads SHARED_VPC_NAME and AWS_REGION from .env (or --env-file), then checks
#   whether the SSM parameter /<SHARED_VPC_NAME>/<REGION>/vpc_id is already
#   populated. If it is, the network stack is considered deployed and
#   deploy-network.sh is skipped.  If it is not (first run, or new region),
#   deploy-network.sh is called first.
#
# Shared-stack existence check:
#   Probes /<SHARED_VPC_NAME>/<REGION>/cw_api_log_group (canary published only by
#   envs/shared). If empty, deploy-shared.sh is invoked. The shared stack is a
#   singleton per (account, region, environment) — multiple per-project ec2
#   stacks read its SSM outputs.
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
SHARED_SCRIPT="$REPO_ROOT/deploy/scripts/deploy-shared.sh"
PROJECT_SCRIPT="$REPO_ROOT/deploy/scripts/deploy-project.sh"

ENV_FILE="$REPO_ROOT/.env"
AUTO_APPROVE=false
SKIP_DOCKER=false
SKIP_NETWORK=false
SKIP_SHARED=false
SKIP_SMOKE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve) AUTO_APPROVE=true ;;
    --skip-docker)  SKIP_DOCKER=true ;;
    --skip-smoke)   SKIP_SMOKE=true ;;
    --skip-network) SKIP_NETWORK=true ;;
    --skip-shared)  SKIP_SHARED=true ;;
    --env-file)     ENV_FILE="$2"; shift ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
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
log "Flags    : auto-approve=$AUTO_APPROVE  skip-docker=$SKIP_DOCKER  skip-smoke=$SKIP_SMOKE  skip-network=$SKIP_NETWORK  skip-shared=$SKIP_SHARED"
sep

# ──────────────────────────────────────────────────────────────────────────────
# Validate sub-scripts exist
# ──────────────────────────────────────────────────────────────────────────────
[[ -x "$NETWORK_SCRIPT" ]] || err "deploy-network.sh not found or not executable: $NETWORK_SCRIPT"
[[ -x "$SHARED_SCRIPT"  ]] || err "deploy-shared.sh not found or not executable: $SHARED_SCRIPT"
[[ -x "$PROJECT_SCRIPT" ]] || err "deploy-project.sh not found or not executable: $PROJECT_SCRIPT"
[[ -f "$ENV_FILE" ]]       || err "Env file not found: $ENV_FILE  (create it from .env.example)"

# ──────────────────────────────────────────────────────────────────────────────
# Source .env to obtain SHARED_VPC_NAME + AWS_REGION for the existence probes
# ──────────────────────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$ENV_FILE"

AWS_REGION="${AWS_REGION:-us-east-1}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
DEPLOY_DIAG_LABEL="full-deploy"
# shellcheck source=deploy/scripts/_deploy-diagnostics.sh
source "$REPO_ROOT/deploy/scripts/_deploy-diagnostics.sh"
deploy_diag_install_error_trap

# ── Centralized preflight checks (see docs/deployment-preflight-checks.md) ──
# Bypass with PREFLIGHT_SKIP=<id>,<id> or PREFLIGHT_SKIP=*
# shellcheck source=deploy/scripts/_preflight-checks.sh
source "$REPO_ROOT/deploy/scripts/_preflight-checks.sh"
preflight_validate orchestrator-privatelink
# shellcheck source=deploy/scripts/_aws-auth.sh
source "$REPO_ROOT/deploy/scripts/_aws-auth.sh"
validate_aws_auth || err "AWS auth validation failed after preflight (see above)"
deploy_diag_after_preflight "orchestrator-privatelink" "$ENV_FILE"

# ── HARD override — this orchestrator owns NETWORK_MODE=privatelink ─────────
# Export so sub-scripts see it even if the shell still has NETWORK_MODE=peering
# from a prior peering deploy in the same session.
if [[ -n "${NETWORK_MODE:-}" && "$NETWORK_MODE" != "privatelink" ]]; then
  warn "Overriding NETWORK_MODE='${NETWORK_MODE}' → 'privatelink' (this orchestrator is PrivateLink-only)"
fi
export NETWORK_MODE=privatelink

# Fail fast if SSM says this shared VPC was applied in peering mode.
deploy_diag_checkpoint "checking network mode canary: aws ssm get-parameter --region ${AWS_REGION} --name /${SHARED_VPC_NAME}/${AWS_REGION}/network_mode"
EXISTING_MODE=$(aws ssm get-parameter \
  --region "$AWS_REGION" \
  --name "/${SHARED_VPC_NAME}/${AWS_REGION}/network_mode" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")
if [[ -n "$EXISTING_MODE" && "$EXISTING_MODE" != "privatelink" ]]; then
  err "MODE MISMATCH: SSM /${SHARED_VPC_NAME}/${AWS_REGION}/network_mode says '${EXISTING_MODE}' but this script enforces 'privatelink'.
     PrivateLink and VPC peering are mutually exclusive per shared VPC. To switch modes run:
       ./deploy/scripts/destroy.sh --mode ec2
       ./deploy/scripts/destroy.sh --mode shared    # optional
       ./deploy/scripts/destroy.sh --mode network
     Then re-run this script for a clean PrivateLink deploy."
fi

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Network stack (shared VPC + Atlas PrivateLink)
# ──────────────────────────────────────────────────────────────────────────────
sep
if [[ "$SKIP_NETWORK" == "true" ]]; then
  warn "Phase 1 — Skipping network stack (--skip-network flag set)"
else
  log "Phase 1 — Checking whether shared VPC already exists..."
  log "  SSM key : /${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id"
  deploy_diag_checkpoint "checking network VPC canary: aws ssm get-parameter --region ${AWS_REGION} --name /${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id"

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

    deploy_diag_checkpoint "launching child script: bash ${NETWORK_SCRIPT} ${NETWORK_ARGS[*]}"
    bash "$NETWORK_SCRIPT" "${NETWORK_ARGS[@]}"

    sep
    ok "Phase 1 — Network stack deployed successfully"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1.5 — Shared observability + embeddings stack (SageMaker, log groups,
# dashboards, Bedrock invocation logging). Singleton per (account, region,
# environment); all per-project ec2 stacks read its SSM outputs.
# ──────────────────────────────────────────────────────────────────────────────
sep
if [[ "$SKIP_SHARED" == "true" ]]; then
  warn "Phase 1.5 — Skipping shared stack (--skip-shared flag set)"
else
  log "Phase 1.5 — Checking whether shared stack already exists..."
  log "  SSM key : /${SHARED_VPC_NAME}/${AWS_REGION}/cw_api_log_group"
  deploy_diag_checkpoint "checking shared stack canary: aws ssm get-parameter --region ${AWS_REGION} --name /${SHARED_VPC_NAME}/${AWS_REGION}/cw_api_log_group"

  EXISTING_SHARED=$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/cw_api_log_group" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo "")

  if [[ -n "$EXISTING_SHARED" ]]; then
    ok "Phase 1.5 — Shared stack already deployed (cw_api_log_group=$EXISTING_SHARED) — skipping deploy-shared.sh"
    log "          Re-apply with: bash $SHARED_SCRIPT --env-file $ENV_FILE"
  else
    log "Phase 1.5 — Shared stack not found in SSM — running deploy-shared.sh ..."
    sep

    SHARED_ARGS=("--env-file" "$ENV_FILE")
    [[ "$AUTO_APPROVE" == "true" ]] && SHARED_ARGS+=("--auto-approve")

    deploy_diag_checkpoint "launching child script: bash ${SHARED_SCRIPT} ${SHARED_ARGS[*]}"
    bash "$SHARED_SCRIPT" "${SHARED_ARGS[@]}"

    sep
    ok "Phase 1.5 — Shared stack deployed successfully"
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
[[ "$SKIP_SMOKE"   == "true" ]] && PROJECT_ARGS+=("--skip-smoke")

deploy_diag_checkpoint "launching child script: bash ${PROJECT_SCRIPT} ${PROJECT_ARGS[*]}"
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
echo "                            ./deploy/scripts/destroy.sh --mode shared"
echo "                            ./deploy/scripts/destroy.sh --mode network"
echo ""
sep
