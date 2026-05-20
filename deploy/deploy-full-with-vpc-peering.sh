#!/usr/bin/env bash
# deploy-full-with-vpc-peering.sh — Full end-to-end deployment coordinator
# for the VPC peering connectivity mode. Sister script of
# deploy-full-with-privatelink.sh; same 3-phase structure (network → shared →
# project) and same flag surface.
#
# WHAT'S DIFFERENT vs the PrivateLink orchestrator:
#   * exports NETWORK_MODE=peering before delegating, so deploy-network.sh +
#     deploy-project.sh route to their peering branches and stamp
#     network_mode='peering' into tfvars + SSM + deploy-manifest.json.
#   * envs/network provisions modules/atlas-vpc-peering (network container,
#     AWS-side accepter, route entries, Atlas IP access list) instead of
#     modules/atlas-privatelink.
#   * envs/ec2 provisions modules/bedrock-kb-peering (EXPERIMENTAL — NLB
#     fronting Atlas private peering IPs discovered via SSM dig from EC2)
#     instead of modules/bedrock-kb-privatelink, and selects the runtime
#     MONGODB_URI from the cluster's peering connection strings (no public
#     fallback — TF precondition enforces this).
#   * envs/shared is reused UNCHANGED (mode-agnostic — Voyage SageMaker +
#     CloudWatch log groups + dashboards + Bedrock invocation logging do not
#     depend on Atlas connectivity).
#
# PrivateLink and VPC peering are MUTUALLY EXCLUSIVE per account. Switching
# modes requires destroy + redeploy. This script guards against silent mode
# swaps via the SSM /<shared_vpc_name>/<region>/network_mode canary.
#
# Usage:
#   ./deploy/deploy-full-with-vpc-peering.sh [--auto-approve] [--skip-docker]
#                                            [--skip-network] [--skip-shared]
#                                            [--env-file <path>]
#
# Flags: identical to deploy-full-with-privatelink.sh.
#
# Prerequisites:
#   .env (or --env-file) must be populated, including:
#     NETWORK_MODE=peering            (or this script exports it)
#     ATLAS_PEERING_CIDR=192.168.248.0/21  (Atlas default; must not overlap VPC_CIDR)
#     TF_VAR_enable_kb_peering=true   (default — EXPERIMENTAL, see below)
#
# EXPERIMENTAL warning (suppressed under --auto-approve):
#   The Bedrock KB peering path (modules/bedrock-kb-peering) routes Bedrock-
#   managed KB ingestion through an NLB whose targets are Atlas mongod
#   private peering IPs discovered by `dig` from EC2. The TLS validation
#   path is not partner-validated by MongoDB or AWS. If ingestion fails the
#   only remediation is destroy + redeploy in PrivateLink mode (no hybrid
#   coexistence) — or set TF_VAR_enable_kb_peering=false to fall back to
#   public SRV for KB while keeping runtime traffic private over peering.

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve) AUTO_APPROVE=true ;;
    --skip-docker)  SKIP_DOCKER=true ;;
    --skip-network) SKIP_NETWORK=true ;;
    --skip-shared)  SKIP_SHARED=true ;;
    --env-file)     ENV_FILE="$2"; shift ;;
    -h|--help)
      sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "  [full-deploy-peering] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo "  [full-deploy-peering] $*"; }
ok()   { echo "  [full-deploy-peering] ✓ $*"; }
err()  { echo "  [full-deploy-peering] ✗ $*" >&2; exit 1; }
warn() { echo "  [full-deploy-peering] ⚠ $*"; }
sep()  { echo "════════════════════════════════════════════════════════════════"; }

# ── Validate sub-scripts exist ───────────────────────────────────────────────
[[ -x "$NETWORK_SCRIPT" ]] || err "deploy-network.sh not found or not executable: $NETWORK_SCRIPT"
[[ -x "$SHARED_SCRIPT"  ]] || err "deploy-shared.sh not found or not executable: $SHARED_SCRIPT"
[[ -x "$PROJECT_SCRIPT" ]] || err "deploy-project.sh not found or not executable: $PROJECT_SCRIPT"
[[ -f "$ENV_FILE" ]]       || err "Env file not found: $ENV_FILE  (create it from .env.sample)"

# ── Source .env (gives us SHARED_VPC_NAME / AWS_REGION / ATLAS_PEERING_CIDR) ─
# shellcheck source=/dev/null
source "$ENV_FILE"

AWS_REGION="${AWS_REGION:-us-east-1}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
ATLAS_PEERING_CIDR="${ATLAS_PEERING_CIDR:-192.168.248.0/21}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"

# ── HARD override — this orchestrator owns NETWORK_MODE=peering ──────────────
# We export so the sub-scripts see it, regardless of whether the operator
# left a stale NETWORK_MODE=privatelink in .env. This is intentional — the
# script name is the contract.
if [[ -n "${NETWORK_MODE:-}" && "$NETWORK_MODE" != "peering" ]]; then
  warn "Overriding NETWORK_MODE='${NETWORK_MODE}' from .env → 'peering' (this orchestrator is peering-only)"
fi
export NETWORK_MODE=peering
export ATLAS_PEERING_CIDR

sep
log "Starting full deployment in VPC PEERING mode"
log "  Env file           : $ENV_FILE"
log "  Mode               : VPC peering"
log "  Atlas peering CIDR : $ATLAS_PEERING_CIDR"
log "  VPC CIDR           : $VPC_CIDR"
log "  Flags              : auto-approve=$AUTO_APPROVE  skip-docker=$SKIP_DOCKER  skip-network=$SKIP_NETWORK  skip-shared=$SKIP_SHARED"
sep

# ── EXPERIMENTAL banner (skipped under --auto-approve / CI) ─────────────────
if [[ "$AUTO_APPROVE" != "true" ]]; then
  cat <<EOF
  ════════════════════════════════════════════════════════════════════
  ⚠  EXPERIMENTAL — Bedrock KB ingestion over VPC peering

  The Bedrock KB peering path (modules/bedrock-kb-peering) is NOT
  partner-validated by MongoDB or AWS. Bedrock's MongoDB driver may
  reject the cluster TLS certificate when reached through NLB-over-
  peering. If that happens, the ingestion job will fail terraform apply
  with the driver error in failureReasons.

  PrivateLink and VPC peering are MUTUALLY EXCLUSIVE per account —
  there is no hybrid mode. If KB ingestion fails, the only remediation
  is to destroy this peering stack and redeploy in PrivateLink mode:
      ./deploy/scripts/destroy.sh --mode ec2
      ./deploy/scripts/destroy.sh --mode shared    # optional
      ./deploy/scripts/destroy.sh --mode network
      # set NETWORK_MODE=privatelink (or unset) in .env
      ./deploy/deploy-full-with-privatelink.sh

  Alternative: set TF_VAR_enable_kb_peering=false in .env to use public
  Atlas SRV for KB ingestion (privacy regression — KB no longer
  end-to-end private) while keeping runtime traffic private over peering.

  mongod IP drift: the peering NLB targets are pinned at deploy time via
  `dig` from EC2. Atlas mongod IP rotations (maintenance / scaling /
  failover) silently break KB ingestion until you re-run this script
  with --skip-network --skip-shared. See modules/bedrock-kb-peering/
  README.md and docs/observability-runbook.md "Bedrock KB peering: IP
  drift recovery".
  ════════════════════════════════════════════════════════════════════
EOF
  read -r -p "  Continue with peering deploy? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Cancelled."; exit 0; }
fi

# ── Mode-switch guard ───────────────────────────────────────────────────────
# If SSM /network_mode already says 'privatelink', refuse to clobber. The
# sub-scripts also enforce this but we fail-fast here so the operator gets a
# clear remediation before any AWS/Atlas calls.
EXISTING_MODE=$(aws ssm get-parameter \
  --region "$AWS_REGION" \
  --name "/${SHARED_VPC_NAME}/${AWS_REGION}/network_mode" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")
if [[ -n "$EXISTING_MODE" && "$EXISTING_MODE" != "peering" ]]; then
  err "MODE MISMATCH: SSM /${SHARED_VPC_NAME}/${AWS_REGION}/network_mode says '${EXISTING_MODE}' but this script enforces 'peering'.
     PrivateLink and VPC peering are mutually exclusive per account. To switch modes run:
       ./deploy/scripts/destroy.sh --mode ec2
       ./deploy/scripts/destroy.sh --mode shared    # optional
       ./deploy/scripts/destroy.sh --mode network
     Then re-run this script for a clean peering deploy."
fi

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Network stack (shared VPC + Atlas VPC peering)
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
    log "Phase 1 — Shared VPC not found in SSM — running deploy-network.sh (NETWORK_MODE=peering) ..."
    sep

    NETWORK_ARGS=("--env-file" "$ENV_FILE")
    [[ "$AUTO_APPROVE" == "true" ]] && NETWORK_ARGS+=("--auto-approve")

    NETWORK_MODE=peering ATLAS_PEERING_CIDR="$ATLAS_PEERING_CIDR" bash "$NETWORK_SCRIPT" "${NETWORK_ARGS[@]}"

    sep
    ok "Phase 1 — Network stack (peering) deployed successfully"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1.5 — Shared observability + embeddings stack (UNCHANGED from PL path)
# Singleton per (account, region, environment); mode-agnostic.
# ──────────────────────────────────────────────────────────────────────────────
sep
if [[ "$SKIP_SHARED" == "true" ]]; then
  warn "Phase 1.5 — Skipping shared stack (--skip-shared flag set)"
else
  log "Phase 1.5 — Checking whether shared stack already exists..."
  log "  SSM key : /${SHARED_VPC_NAME}/${AWS_REGION}/cw_api_log_group"

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

    bash "$SHARED_SCRIPT" "${SHARED_ARGS[@]}"

    sep
    ok "Phase 1.5 — Shared stack deployed successfully"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Project stack (EC2 + infra + app — peering branches)
# ──────────────────────────────────────────────────────────────────────────────
sep
log "Phase 2 — Running deploy-project.sh (NETWORK_MODE=peering) ..."
sep

PROJECT_ARGS=("--env-file" "$ENV_FILE")
[[ "$AUTO_APPROVE" == "true" ]] && PROJECT_ARGS+=("--auto-approve")
[[ "$SKIP_DOCKER"  == "true" ]] && PROJECT_ARGS+=("--skip-docker")

NETWORK_MODE=peering ATLAS_PEERING_CIDR="$ATLAS_PEERING_CIDR" bash "$PROJECT_SCRIPT" "${PROJECT_ARGS[@]}"

sep
ok "Phase 2 — Project stack (peering) deployed successfully"
sep
echo ""
echo "  Full peering deployment complete."
echo "  Mode               : VPC peering"
echo "  Atlas peering CIDR : ${ATLAS_PEERING_CIDR}"
echo "  Network            : /${SHARED_VPC_NAME}/${AWS_REGION}/"
echo "  To redeploy agents only : ./deploy/deploy-agents.sh"
echo "  To redeploy API only    : ./deploy/deploy-api.sh"
echo "  To re-discover Atlas IPs (operator after Atlas maintenance) :"
echo "    $0 --skip-network --skip-shared"
echo "  To tear down            : ./deploy/scripts/destroy.sh --mode ec2"
echo "                            ./deploy/scripts/destroy.sh --mode shared"
echo "                            ./deploy/scripts/destroy.sh --mode network"
echo ""
sep
