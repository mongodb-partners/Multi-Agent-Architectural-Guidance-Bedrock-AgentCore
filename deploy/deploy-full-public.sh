#!/usr/bin/env bash
# deploy-full-public.sh — Full end-to-end deployment coordinator for the
# PUBLIC connectivity mode (BYO Atlas cluster reached over the public internet).
# Sister script of deploy-full-with-privatelink.sh / -vpc-peering.sh; same
# 3-phase structure (network → shared → project) and same flag surface.
#
# WHAT'S DIFFERENT vs the private orchestrators:
#   * exports NETWORK_MODE=public + ATLAS_CLUSTER_SOURCE=byo before delegating,
#     so the sub-scripts route to their public/BYO branches and stamp
#     network_mode='public' into tfvars + SSM + deploy-manifest.json.
#   * No Atlas cluster is provisioned — the operator's own cluster is reached
#     over public SRV using MONGODB_BYO_URI, with the Atlas IP access list set
#     to 0.0.0.0/0 by the operator (DEMO ONLY — see caveats below).
#   * AgentCore runtime runs in PUBLIC egress mode (no VPC attachment, no NAT),
#     and the EC2 host skips the Elastic IP (auto-assigned public IP instead).
#   * Atlas-private machinery (PrivateLink VPCE, VPC peering) is NOT created —
#     the count-gated resources evaluate to 0 in public mode.
#
# DEMO ONLY — do not use for anything real:
#   * 0.0.0.0/0 on the Atlas IP access list is a public-internet path to the DB.
#   * The instance public IP changes on stop/start (no EIP) — re-read
#     `terraform output` after any restart.
#   * Bedrock KB ingestion runs over public SRV in this mode (ingestion is
#     mandatory — terraform apply FAILS if the DB creds are wrong). Set
#     ATLAS_DB_USER + atlas_db_password (TF_VAR_mongodb_password) to a valid
#     Atlas DB user on the BYO cluster (same one as in MONGODB_BYO_URI);
#     ATLAS_PROJECT_ID is already required. Chat + memory use MONGODB_BYO_URI.
#
# Usage:
#   ./deploy/deploy-full-public.sh [--auto-approve] [--skip-docker]
#                                  [--skip-smoke] [--skip-network]
#                                  [--skip-shared] [--env-file <path>]
#
# Prerequisites (.env or --env-file), see .env.sample BYO block:
#   ATLAS_CLUSTER_SOURCE=byo
#   NETWORK_MODE=public
#   ALLOW_PUBLIC_ATLAS=1
#   MONGODB_BYO_URI=mongodb+srv://user:pass@cluster.xxxxx.mongodb.net/?...

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
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "  [full-deploy-public] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo "  [full-deploy-public] $*"; }
ok()   { echo "  [full-deploy-public] ✓ $*"; }
err()  { echo "  [full-deploy-public] ✗ $*" >&2; exit 1; }
warn() { echo "  [full-deploy-public] ⚠ $*"; }
sep()  { echo "════════════════════════════════════════════════════════════════"; }

[[ -x "$NETWORK_SCRIPT" ]] || err "deploy-network.sh not found or not executable: $NETWORK_SCRIPT"
[[ -x "$SHARED_SCRIPT"  ]] || err "deploy-shared.sh not found or not executable: $SHARED_SCRIPT"
[[ -x "$PROJECT_SCRIPT" ]] || err "deploy-project.sh not found or not executable: $PROJECT_SCRIPT"
[[ -f "$ENV_FILE" ]]       || err "Env file not found: $ENV_FILE  (create it from .env.sample)"

# shellcheck source=/dev/null
source "$ENV_FILE"

AWS_REGION="${AWS_REGION:-us-east-1}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"

# ── HARD override — this orchestrator owns the public/BYO contract ───────────
# The script name is the contract; export so every sub-script sees it even if
# .env still carries a stale private mode.
if [[ -n "${NETWORK_MODE:-}" && "$NETWORK_MODE" != "public" ]]; then
  warn "Overriding NETWORK_MODE='${NETWORK_MODE}' from .env → 'public' (this orchestrator is public-only)"
fi
export NETWORK_MODE=public
export ATLAS_CLUSTER_SOURCE=byo
export ALLOW_PUBLIC_ATLAS="${ALLOW_PUBLIC_ATLAS:-1}"
# ponytail: /aws/bedrock/invocations{,-audit} are account-scoped singletons. If
# another stack in this account already owns them, the shared apply dies on
# ResourceAlreadyExistsException. Default the demo to off (account-level logging,
# if any, keeps running); override to true to manage/create them from this stack.
export ENABLE_BEDROCK_INVOCATION_LOGGING="${ENABLE_BEDROCK_INVOCATION_LOGGING:-false}"
: "${MONGODB_BYO_URI:?MONGODB_BYO_URI must be set for the public/BYO demo deploy (see .env.sample)}"

# ── Neutralize managed-Atlas / private-connectivity preflight checks ─────────
# These hard-fail (or are meaningless) in BYO+public: no Atlas Admin API keys,
# 0.0.0.0/0 is intentional, and there is no PrivateLink/peering/VPCE plumbing.
# PREFLIGHT_SKIP is the library's documented bypass (see _preflight-checks.sh
# header). pf_check_kb_ingestion_complete is NOT skipped — it validates via the
# AWS bedrock-agent API (no Atlas keys needed) and KB ingestion over public SRV
# is provisioned from ATLAS_DB_USER / atlas_db_password / atlas_project_id.
# ponytail: env-var skip keeps the preflight library untouched; convert to
# real ATLAS_CLUSTER_SOURCE=byo guards inside each check if the manual 2-script
# flow needs to pass preflight without this orchestrator.
export PREFLIGHT_SKIP="pf_check_atlas_api_keys_present,pf_check_atlas_api_health,pf_check_atlas_api_key_scope,pf_check_atlas_cluster_tier,pf_check_atlas_no_public_ip_access_list,pf_check_atlas_privatelink_no_orphans,pf_check_atlas_project_quota,pf_check_privatelink_endpoint_available,pf_check_agentcore_vpcendpoints_present"

sep
log "Starting full deployment in PUBLIC mode (BYO Atlas over public internet)"
log "  Env file        : $ENV_FILE"
log "  Mode            : public / BYO"
log "  Network         : /${SHARED_VPC_NAME}/${AWS_REGION}/"
log "  Flags           : auto-approve=$AUTO_APPROVE skip-docker=$SKIP_DOCKER skip-network=$SKIP_NETWORK skip-shared=$SKIP_SHARED"
sep

if [[ "$AUTO_APPROVE" != "true" ]]; then
  cat <<'EOF'
  ════════════════════════════════════════════════════════════════════
  ⚠  DEMO ONLY — public-internet path to your Atlas cluster

  This deploys with NETWORK_MODE=public: the app reaches your BYO Atlas
  cluster over the public internet, expecting a 0.0.0.0/0 entry on the
  Atlas IP access list. There is no PrivateLink, no VPC peering, and no
  Elastic IP (the instance public IP changes on stop/start). Bedrock KB
  ingestion runs over public SRV and is mandatory in this mode — set
  ATLAS_DB_USER + atlas_db_password to a valid Atlas DB user on the BYO
  cluster, or terraform apply will fail.

  Do NOT use this mode for production data.
  ════════════════════════════════════════════════════════════════════
EOF
  read -r -p "  Continue with public/BYO demo deploy? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Cancelled."; exit 0; }
fi

# ── Mode-switch guard — refuse to clobber a private deployment ───────────────
EXISTING_MODE=$(aws ssm get-parameter \
  --region "$AWS_REGION" \
  --name "/${SHARED_VPC_NAME}/${AWS_REGION}/network_mode" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")
if [[ -n "$EXISTING_MODE" && "$EXISTING_MODE" != "public" ]]; then
  err "MODE MISMATCH: SSM /${SHARED_VPC_NAME}/${AWS_REGION}/network_mode says '${EXISTING_MODE}' but this script enforces 'public'.
     Tear down the existing stack before switching modes (destroy scripts under deploy/destroy/), then re-run."
fi

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Network stack (shared VPC; no Atlas-private resources in public mode)
# ──────────────────────────────────────────────────────────────────────────────
sep
if [[ "$SKIP_NETWORK" == "true" ]]; then
  warn "Phase 1 — Skipping network stack (--skip-network)"
else
  EXISTING_VPC_ID=$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id" \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")
  if [[ -n "$EXISTING_VPC_ID" ]]; then
    ok "Phase 1 — Shared VPC already deployed (vpc_id=$EXISTING_VPC_ID) — skipping deploy-network.sh"
  else
    log "Phase 1 — Running deploy-network.sh (NETWORK_MODE=public) ..."
    NETWORK_ARGS=("--env-file" "$ENV_FILE")
    [[ "$AUTO_APPROVE" == "true" ]] && NETWORK_ARGS+=("--auto-approve")
    bash "$NETWORK_SCRIPT" "${NETWORK_ARGS[@]}"
    ok "Phase 1 — Network stack deployed"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1.5 — Shared observability + embeddings stack (mode-agnostic)
# ──────────────────────────────────────────────────────────────────────────────
sep
if [[ "$SKIP_SHARED" == "true" ]]; then
  warn "Phase 1.5 — Skipping shared stack (--skip-shared)"
else
  EXISTING_SHARED=$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/cw_api_log_group" \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")
  if [[ -n "$EXISTING_SHARED" ]]; then
    ok "Phase 1.5 — Shared stack already deployed — skipping deploy-shared.sh"
  else
    log "Phase 1.5 — Running deploy-shared.sh ..."
    SHARED_ARGS=("--env-file" "$ENV_FILE")
    [[ "$AUTO_APPROVE" == "true" ]] && SHARED_ARGS+=("--auto-approve")
    bash "$SHARED_SCRIPT" "${SHARED_ARGS[@]}"
    ok "Phase 1.5 — Shared stack deployed"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Project stack (EC2 + app — public/BYO branches)
# ──────────────────────────────────────────────────────────────────────────────
sep
log "Phase 2 — Running deploy-project.sh (NETWORK_MODE=public) ..."
PROJECT_ARGS=("--env-file" "$ENV_FILE")
[[ "$AUTO_APPROVE" == "true" ]] && PROJECT_ARGS+=("--auto-approve")
[[ "$SKIP_DOCKER"  == "true" ]] && PROJECT_ARGS+=("--skip-docker")
[[ "$SKIP_SMOKE"   == "true" ]] && PROJECT_ARGS+=("--skip-smoke")
bash "$PROJECT_SCRIPT" "${PROJECT_ARGS[@]}"

sep
ok "Phase 2 — Project stack deployed"
sep
echo ""
echo "  Full public/BYO demo deployment complete."
echo "  Mode      : public (BYO Atlas over public internet)"
echo "  Network   : /${SHARED_VPC_NAME}/${AWS_REGION}/"
echo "  URLs      : cd deploy/terraform/envs/ec2 && terraform output"
echo "              (re-read after any instance stop/start — no Elastic IP)"
echo "  Tear down : deploy/destroy/ scripts"
echo ""
sep
