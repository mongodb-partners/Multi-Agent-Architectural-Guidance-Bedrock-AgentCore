#!/usr/bin/env bash
# deploy-project.sh — EC2 deployment (envs/ec2 terraform)
#
# Usage:
#   ./deploy/scripts/deploy-project.sh [--auto-approve] [--skip-docker] [--skip-smoke]
#                                     [--env-file <path>]
#
# What it does:
#   Phase 1  — Validate prerequisites (aws, terraform, bun, python3, zip,
#              docker — docker only when --skip-docker is NOT passed)
#   Phase 2  — Source .env, verify AWS + Atlas credentials
#   Phase 3  — Bootstrap shared S3 bucket (once)
#   Phase 4  — Generate backend.hcl + terraform.tfvars for envs/ec2
#   Phase 5  — terraform apply (envs/ec2):
#                VPC + Atlas M10 + PrivateLink + EC2 + ECR + Cognito + Bedrock KB
#                + AgentCore Memory + AgentCore Gateway (no Lambda target yet)
#                (+ Voyage AI if ARN set)
#   Phase 6  — Build + push Docker images to ECR (unless --skip-docker)
#   Phase 7  — Write .env.live + copy to EC2 via SSM
#   Phase 8  — Pull images + restart multiagent-api, multiagent-ui, mongodb-mcp on EC2
#   Phase 9  — Health + deterministic backend smoke (9a–9b)
#   Phase 10 — Write deploy-manifest.json
#   Phase 11 — Full post-deploy smoke (e2e-smoke/post-deploy-smoke.py; --skip-smoke to disable)
#
# Embedding: explicit provider selection via EMBEDDINGS_PROVIDER.
#            titan  -> Bedrock Titan v2, no SageMaker ARN required.
#            voyage -> SageMaker endpoint from VOYAGE_MODEL_PACKAGE_ARN.
#
# Tools:     MongoDB MCP runs as a systemd service on the EC2 instance
#            (`mongodb-mcp.service`, bound to 127.0.0.1:8080) and the API talks
#            to it over loopback. Lambda + AgentCore Gateway are DEFERRED —
#            see Docs/adr/0001-mcp-on-ec2-not-lambda.md.
#
# Shell:     SSM Session Manager (no SSH keypair by default).
#
# For local dev (no EC2, direct tools), use: ./deploy/scripts/deploy-local.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_ROOT="$REPO_ROOT/deploy/terraform"
TF_DIR="$TF_ROOT/envs/ec2"
BOOTSTRAP_DIR="$TF_ROOT/bootstrap"
ENV_FILE="$REPO_ROOT/.env"
AUTO_APPROVE=false
SKIP_DOCKER=false
SKIP_SMOKE=false

# Source shared agent helpers (discover_agents, write_specialist_agents_tfvars,
# build_and_upload_code_artifact, update_runtime_env_dynamic, etc.)
# shellcheck source=deploy/scripts/_agents-common.sh
source "$SCRIPT_DIR/_agents-common.sh"
# shellcheck source=deploy/scripts/_voyage-config.sh
source "$SCRIPT_DIR/_voyage-config.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
# DB user + DB name follow the same project+env convention as .env — Mongo
# identifiers can't contain "-" so the project name is underscore-normalized.
# Always derive both from PROJECT_NAME + ENVIRONMENT when they're not already
# exported, so a stale value from a prior shell never silently leaks into
# terraform.tfvars / .env.live.
# Remember whether the operator set ATLAS_DB_USER explicitly — the BYO block
# below derives it from MONGODB_BYO_URI, but only when it wasn't given by hand.
_ATLAS_DB_USER_EXPLICIT="${ATLAS_DB_USER:+1}"
_PROJECT_SLUG="${PROJECT_NAME//-/_}"
ATLAS_DB_USER="${ATLAS_DB_USER:-${_PROJECT_SLUG}_${ENVIRONMENT}_user}"
ATLAS_DB_NAME="${ATLAS_DB_NAME:-${_PROJECT_SLUG}_${ENVIRONMENT}}"
unset _PROJECT_SLUG
# Canonical DB name is ATLAS_DB_NAME (used in terraform.tfvars and seed
# scripts). Mirror it into MONGODB_DB so every downstream helper that reads
# the application-side env var name (preflight checks, ad-hoc bun probes,
# Mongo MCP runtime sync, etc.) sees the same value without re-deriving it.
# The .env.live emitted in Phase 7 already does this for the EC2 host; this
# extra export ensures the deploy script's own shell (and the preflight calls
# it runs before .env.live exists on disk) see the canonical value too.
export MONGODB_DB="$ATLAS_DB_NAME"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
COGNITO_SEED_USERS="${COGNITO_SEED_USERS:-true}"
COGNITO_TEST_USERS_CSV="${COGNITO_TEST_USERS_CSV:-alex@example.com,blake@example.com,casey@example.com}"
COGNITO_TEST_PASSWORD="${COGNITO_TEST_PASSWORD:-DemoUser#2026}"
COGNITO_SMOKE_USER_EMAIL="${COGNITO_SMOKE_USER_EMAIL:-alex@example.com}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve)    AUTO_APPROVE=true ;;
    --skip-docker)     SKIP_DOCKER=true ;;
    --skip-smoke)      SKIP_SMOKE=true ;;
    --env-file)        ENV_FILE="$2"; shift ;;
    *) echo "  [ec2] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo "  [ec2] $*"; }
ok()   { echo "  [ec2] ✓ $*"; }
err()  { echo "  [ec2] ✗ $*" >&2; exit 1; }
warn() { echo "  [ec2] ⚠ $*"; }
sep()  { echo "────────────────────────────────────────────────"; }
urlencode_component() {
  local LC_ALL=C
  local value="$1"
  local out=""
  local i ch encoded

  for ((i = 0; i < ${#value}; i++)); do
    ch="${value:i:1}"
    case "$ch" in
      [a-zA-Z0-9.~_-])
        out+="$ch"
        ;;
      *)
        printf -v encoded '%%%02X' "'$ch"
        out+="$encoded"
        ;;
    esac
  done

  printf '%s' "$out"
}

# shellcheck source=deploy/scripts/_sg-cleanup.sh
source "$SCRIPT_DIR/_sg-cleanup.sh"

# shellcheck source=deploy/scripts/_mongo-connect.sh
source "$SCRIPT_DIR/_mongo-connect.sh"

# shellcheck source=deploy/scripts/_seed-embeddings.sh
source "$SCRIPT_DIR/_seed-embeddings.sh"

# Wrap `terraform apply` with retry-on-transient-errors.
# The MongoDB Atlas API at cloud.mongodb.com occasionally returns i/o timeouts
# or connection-resets that vanish on the next call. Terraform can also reject
# a saved plan as stale if a previous target apply, retry, or parallel operator
# changed remote state between plan and apply. We retry the apply up to
# `max_attempts - 1` times, re-planning between attempts so the saved plan stays
# consistent with the latest state. Any error that is NOT a known-transient
# failure is treated as a hard failure. We never silently swallow a real
# provider error.
apply_with_retry() {
  local plan_file="$1"
  local max_attempts=3   # initial + 2 retries, per project policy
  local attempt=1
  local log_file rc
  log_file=$(mktemp -t tf-apply.XXXXXX)

  while (( attempt <= max_attempts )); do
    if (( attempt > 1 )); then
      log "Retry $((attempt - 1))/$((max_attempts - 1)) — sleeping 30s, then re-planning to refresh against current state..."
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
      warn "Transient Terraform apply error detected on attempt ${attempt} — will re-plan and retry"
      attempt=$((attempt + 1))
      continue
    fi
    if grep -qE 'DeleteSecurityGroup.*DependencyViolation|DependencyViolation: resource sg-[a-z0-9]+ has a dependent object' "$log_file"; then
      local blocked_sgs
      blocked_sgs=$(python3 - "$log_file" <<'PYEOF'
import re
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    text = fh.read()

matches = set(re.findall(r"(sg-[0-9a-f]+)", text))
print(" ".join(sorted(matches)))
PYEOF
)
      if [[ -n "$blocked_sgs" ]]; then
        warn "Security-group dependency detected; revoking stale external references before retry: ${blocked_sgs}"
        cleanup_security_group_references $blocked_sgs || true
        attempt=$((attempt + 1))
        continue
      fi
    fi
    rm -f "$log_file"
    err "terraform apply failed with a non-transient error (see output above)"
  done
  rm -f "$log_file"
  err "terraform apply failed after ${max_attempts} attempts — transient Atlas API errors did not clear"
}

wait_for_instance_status_ok() {
  local instance_id="$1"
  log "Waiting for EC2 instance checks to pass: $instance_id"
  aws ec2 wait instance-status-ok \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    || err "EC2 status checks did not pass in time for $instance_id"
  ok "EC2 status checks passed"
}

wait_for_ssm_online() {
  local instance_id="$1"
  local max_attempts=36
  log "Waiting for SSM registration (up to 6 min)..."
  for i in $(seq 1 "$max_attempts"); do
    local status=""
    # Prefer get-connection-status — describe-instance-information can lag
    # several minutes behind PingStatus=Online on fresh EC2 hosts.
    status=$(aws ssm get-connection-status \
      --region "$AWS_REGION" \
      --target "$instance_id" \
      --query "Status" \
      --output text 2>/dev/null || true)
    status="${status//$'\r'/}"
    if [[ "$status" == "connected" ]]; then
      ok "SSM agent is online"
      return 0
    fi
    # Fallback: legacy PingStatus probe (trim whitespace/null sentinels).
    status=$(aws ssm describe-instance-information \
      --region "$AWS_REGION" \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query "InstanceInformationList[0].PingStatus" \
      --output text 2>/dev/null || echo "None")
    status="${status//$'\r'/}"
    if [[ "$status" == "Online" ]]; then
      ok "SSM agent is online (PingStatus)"
      return 0
    fi
    log "  Waiting for SSM ($i/$max_attempts)... (connection=${status:-unknown})"
    sleep 10
  done
  err "SSM agent did not become online for $instance_id"
}

# Robust `terraform output` reader.
# ponytail: a single `terraform output` over a flaky network can draw a half-open
# socket that stalls ~13min on the OS TCP retransmit timeout, then returns empty —
# silently corrupting a critical read (e.g. EC2_IP) and failing the deploy far
# downstream at the `[[ -n "$EC2_IP" ]]` gate. Wrap every read: kill a call
# stalled >30s and retry on a fresh connection. Drop-in for `terraform output`;
# callers keep their own `|| echo ""` fallbacks.
# ponytail: per-call timeout=30s, 5 retries; collapse the ~37 reads into one
# cached `tfo -json` if read latency on a healthy network matters.
tfo() {
  local tmp p w rc
  tmp=$(mktemp)
  for _ in 1 2 3 4 5; do
    terraform output "$@" >"$tmp" 2>/dev/null &
    p=$!
    w=0
    while kill -0 "$p" 2>/dev/null && [ "$w" -lt 30 ]; do sleep 1; w=$((w+1)); done
    if kill -0 "$p" 2>/dev/null; then
      kill -KILL "$p" 2>/dev/null || true
      wait "$p" 2>/dev/null || true
      continue   # stalled socket — retry on a fresh connection
    fi
    rc=0; wait "$p" || rc=$?
    if [ "$rc" -eq 0 ]; then cat "$tmp"; rm -f "$tmp"; return 0; fi
    rm -f "$tmp"; return "$rc"   # genuine error (e.g. output absent) — no retry-spin
  done
  rm -f "$tmp"; return 1
}

send_ssm_command_retry() {
  local instance_id="$1"
  local comment="$2"
  local commands_json="$3"
  local max_attempts="${4:-15}"

  local cmd_id=""
  for i in $(seq 1 "$max_attempts"); do
    cmd_id=$(aws ssm send-command \
      --region "$AWS_REGION" \
      --instance-ids "$instance_id" \
      --document-name "AWS-RunShellScript" \
      --comment "$comment" \
      --parameters "commands=${commands_json}" \
      --query "Command.CommandId" \
      --output text 2>/dev/null || true)
    if [[ -n "$cmd_id" && "$cmd_id" != "None" ]]; then
      echo "$cmd_id"
      return 0
    fi
    sleep 10
  done
  return 1
}

wait_for_ssm_command_success() {
  local command_id="$1"
  local instance_id="$2"
  local max_attempts="${3:-30}"

  for i in $(seq 1 "$max_attempts"); do
    local status
    status=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query "Status" --output text 2>/dev/null || echo "Pending")
    case "$status" in
      Success) return 0 ;;
      Failed|Cancelled|TimedOut)
        aws ssm get-command-invocation \
          --region "$AWS_REGION" \
          --command-id "$command_id" \
          --instance-id "$instance_id" \
          --query "{Status:Status,StdOut:StandardOutputContent,StdErr:StandardErrorContent}" \
          --output json 2>/dev/null || true
        return 1
        ;;
    esac
    sleep 5
  done
  return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Prerequisites
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 1 — Checking prerequisites..."
for cmd in aws terraform bun python3; do
  command -v "$cmd" &>/dev/null || err "'$cmd' not found in PATH"
done
if [[ "${AGENTCORE_RUNTIME_DEPLOYMENT_MODE:-code}" == "code" ]]; then
  command -v zip &>/dev/null || err "'zip' not found in PATH (required for AgentCore code artifacts)"
fi
# Docker is needed in Phase 6 to build + push API/UI/runtime images. Fail
# now (before Atlas + AWS resources are created) instead of 30 minutes into
# the deploy. Skip the check when --skip-docker is set.
if [[ "$SKIP_DOCKER" != "true" ]]; then
  command -v docker &>/dev/null || err "'docker' not found in PATH (required for image build/push; pass --skip-docker to bypass)"
  docker info &>/dev/null || err "'docker' is installed but the daemon is not reachable — start Docker Desktop / dockerd, or pass --skip-docker"
fi
ok "All prerequisites found"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Load credentials
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 2 — Loading credentials from $ENV_FILE..."
[[ -f "$ENV_FILE" ]] || err "env file not found: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

# ── Connectivity mode (default privatelink to preserve existing behavior) ───
NETWORK_MODE="${NETWORK_MODE:-privatelink}"
ATLAS_PEERING_CIDR="${ATLAS_PEERING_CIDR:-192.168.248.0/21}"
case "$NETWORK_MODE" in
  privatelink|peering|public) ;;
  *) err "Invalid NETWORK_MODE='${NETWORK_MODE}' — must be 'privatelink', 'peering', or 'public'" ;;
esac
export TF_VAR_network_mode="$NETWORK_MODE"
ok "Network mode: ${NETWORK_MODE}"

# ── Cluster source (managed | byo) ──────────────────────────────────────────
# byo: operator owns a pre-existing Atlas cluster — Terraform creates nothing in
# Atlas and consumes the supplied connection string. network_mode=public is
# BYO-only and reaches Atlas over the public internet (demo; 0.0.0.0/0 allowlist).
ATLAS_CLUSTER_SOURCE="${ATLAS_CLUSTER_SOURCE:-managed}"
case "$ATLAS_CLUSTER_SOURCE" in
  managed|byo) ;;
  *) err "Invalid ATLAS_CLUSTER_SOURCE='${ATLAS_CLUSTER_SOURCE}' — must be 'managed' or 'byo'" ;;
esac
export TF_VAR_cluster_source="$ATLAS_CLUSTER_SOURCE"
# Convenience flag: the BYO-over-public demo path (no Atlas API keys, no managed cluster).
BYO_PUBLIC=false
if [[ "$ATLAS_CLUSTER_SOURCE" == "byo" && "$NETWORK_MODE" == "public" ]]; then
  BYO_PUBLIC=true
fi
if [[ "$NETWORK_MODE" == "public" && "$ATLAS_CLUSTER_SOURCE" != "byo" ]]; then
  err "NETWORK_MODE=public requires ATLAS_CLUSTER_SOURCE=byo (managed clusters must use privatelink or peering)."
fi
ok "Cluster source: ${ATLAS_CLUSTER_SOURCE}"

if [[ "$ATLAS_CLUSTER_SOURCE" == "byo" ]]; then
  : "${MONGODB_BYO_URI:?MONGODB_BYO_URI must be set for ATLAS_CLUSTER_SOURCE=byo}"
  export TF_VAR_byo_connection_string="$MONGODB_BYO_URI"
  # Derive the SRV host from the URI if not supplied explicitly.
  export TF_VAR_byo_srv_host="${MONGODB_BYO_SRV_HOST:-$(printf '%s' "$MONGODB_BYO_URI" | sed -E 's#^mongodb(\+srv)?://[^@]*@##; s#[/?].*$##; s#:[0-9]+$##')}"
  # BYO cluster name for the Atlas Admin API (vector-index create). The SRV host
  # prefix is lowercased so it CAN'T recover the real name's case — operator must
  # supply it. Empty => envs/ec2 falls back to the managed synthetic name.
  export TF_VAR_byo_cluster_name="${MONGODB_BYO_CLUSTER_NAME:-}"
  # The Bedrock KB + ensure-collection.ts rebuild their OWN connection string from
  # atlas_db_user/atlas_db_password (urlencode()'d in modules/bedrock-kb), NOT from
  # MONGODB_BYO_URI. Derive both from the URI userinfo, percent-DECODED so the
  # module's re-encode round-trips, so creds live in ONE place. Explicit
  # ATLAS_DB_USER / TF_VAR_atlas_db_password still win (set above / below).
  _byo_ui="$(python3 - "$MONGODB_BYO_URI" <<'PY' 2>/dev/null || true
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
sys.stdout.write((u.unquote(p.username or "")) + "\n" + (u.unquote(p.password or "")))
PY
)"
  _byo_user="${_byo_ui%%$'\n'*}"
  _byo_pass="${_byo_ui#*$'\n'}"
  [[ -z "$_ATLAS_DB_USER_EXPLICIT" && -n "$_byo_user" ]] && ATLAS_DB_USER="$_byo_user"
  _BYO_DB_PASSWORD_FROM_URI="$_byo_pass"
  unset _byo_ui _byo_user _byo_pass
  if [[ "$BYO_PUBLIC" == "true" ]]; then
    export TF_VAR_allow_public_atlas=true
    [[ "${ALLOW_PUBLIC_ATLAS:-}" == "1" ]] || err "NETWORK_MODE=public is a public-internet regression. Set ALLOW_PUBLIC_ATLAS=1 in .env to acknowledge (demo only)."
  fi
fi

# ── Bedrock KB ingestion path auto-derived from NETWORK_MODE ────────────────
# envs/ec2 only consults the flag matching the active mode (the other is
# silently ignored — see locals.use_kb_* in envs/ec2/main.tf). So the
# operator never has to set both. We default the active flag to "true" (recommended
# private path) and force the inactive one to "false" for clarity.
# Override either in .env to drop KB onto Atlas public SRV — this is a
# privacy regression and the only documented escape hatch for the
# experimental peering-NLB TLS path (see modules/bedrock-kb-peering/README.md).
case "$NETWORK_MODE" in
  privatelink)
    export TF_VAR_enable_kb_privatelink="${TF_VAR_enable_kb_privatelink:-true}"
    export TF_VAR_enable_kb_peering="${TF_VAR_enable_kb_peering:-false}"
    ;;
  peering)
    export TF_VAR_enable_kb_privatelink="${TF_VAR_enable_kb_privatelink:-false}"
    export TF_VAR_enable_kb_peering="${TF_VAR_enable_kb_peering:-true}"
    ;;
  public)
    # No private KB plumbing — KB ingestion (if any) goes over Atlas public SRV.
    export TF_VAR_enable_kb_privatelink="false"
    export TF_VAR_enable_kb_peering="false"
    ;;
esac
ok "KB ingestion: privatelink=${TF_VAR_enable_kb_privatelink} peering=${TF_VAR_enable_kb_peering}"

export TF_VAR_atlas_db_password="${TF_VAR_atlas_db_password:-${TF_VAR_mongodb_password:-${_BYO_DB_PASSWORD_FROM_URI:-}}}"
export TF_VAR_atlas_project_id="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
export TF_VAR_atlas_public_key="${MONGODB_ATLAS_PUBLIC_KEY:-}"
export TF_VAR_atlas_private_key="${MONGODB_ATLAS_PRIVATE_KEY:-}"

if [[ "$BYO_PUBLIC" == "true" ]]; then
  # BYO + public never calls the Atlas Admin API and never creates a cluster, so
  # project ID + API keys stay optional. But the Bedrock KB DOES connect to the
  # cluster as atlas_db_user/atlas_db_password (derived from MONGODB_BYO_URI
  # above), so those must resolve to real creds or KB ingestion fails auth.
  [[ -n "$ATLAS_DB_USER" && -n "${TF_VAR_atlas_db_password:-}" ]] || \
    err "BYO public: no Atlas DB credentials. Embed them in MONGODB_BYO_URI (mongodb+srv://USER:PASS@host) or set ATLAS_DB_USER + TF_VAR_atlas_db_password — the Bedrock KB connects with these."
  ok "BYO public mode — KB auths as DB user '${ATLAS_DB_USER}' (project-id / API keys optional)"
else
  [[ -n "${TF_VAR_atlas_db_password:-}" ]] || err "Atlas DB password not set. Set TF_VAR_mongodb_password in .env"
  [[ -n "${TF_VAR_atlas_project_id:-}" ]] || err "Atlas Project ID not set. Set TF_VAR_mongodb_atlas_project_id in .env"
  [[ -n "${TF_VAR_atlas_public_key:-}" ]]  || err "MONGODB_ATLAS_PUBLIC_KEY not set in .env"
  [[ -n "${TF_VAR_atlas_private_key:-}" ]] || err "MONGODB_ATLAS_PRIVATE_KEY not set in .env"
fi

# MCP write gate — propagate MONGODB_ALLOW_WRITE from .env into Terraform so the
# mongodb-mcp AgentCore Runtime is baked with MONGODB_ALLOW_WRITE=1 (insertOne /
# updateOne). Mirrors parseBoolEnv() truthy set in mongodb-mcp guards.mjs.
# Normalize to a literal true/false (not 1) to avoid HCL bool-coercion ambiguity.
case "$(printf '%s' "${MONGODB_ALLOW_WRITE:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
  1|true|yes|on) export TF_VAR_mongodb_allow_write=true ;;
  *)            export TF_VAR_mongodb_allow_write=false ;;
esac
ok "MCP write gate: mongodb_allow_write=${TF_VAR_mongodb_allow_write}"

# Terraform cannot call the TS Voyage SSOT directly. Resolve the optional
# VOYAGE_OUTPUT_DIM env knob through the bash bridge once, then expose the
# validated value to envs/ec2 as var.voyage_output_dim.
export TF_VAR_voyage_output_dim="$(voyage_embedding_dims)"
ok "Voyage embedding output dim: ${TF_VAR_voyage_output_dim}"

DEPLOY_DIAG_LABEL="ec2"
# shellcheck source=deploy/scripts/_deploy-diagnostics.sh
source "$SCRIPT_DIR/_deploy-diagnostics.sh"
deploy_diag_install_error_trap

# shellcheck source=deploy/scripts/_aws-auth.sh
source "$SCRIPT_DIR/_aws-auth.sh"
validate_aws_auth || err "AWS auth validation failed (see above)"
ACCOUNT_ID="$AWS_AUTH_ACCOUNT_ID"

# ── Centralized preflight checks: pre-apply (see docs/deployment-preflight-checks.md) ──
# shellcheck source=deploy/scripts/_preflight-checks.sh
source "$SCRIPT_DIR/_preflight-checks.sh"
preflight_validate project-pre-apply
deploy_diag_after_preflight "project-pre-apply" "$ENV_FILE"

ok "AWS account: $ACCOUNT_ID"

# ── Atlas API key validation ─────────────────────────────────────────────────
# BYO + public never touches the Atlas Admin API — skip the whole probe.
if [[ "$BYO_PUBLIC" == "true" ]]; then
  ok "BYO public mode — skipping Atlas Admin API validation"
else
ok "Atlas project: $TF_VAR_atlas_project_id"
log "Verifying Atlas API key access..."
_ATLAS_HTTP=$(curl -s -o /tmp/.atlas_check.json -w "%{http_code}" \
  --user "${MONGODB_ATLAS_PUBLIC_KEY}:${MONGODB_ATLAS_PRIVATE_KEY}" \
  --digest \
  -H "Accept: application/vnd.atlas.2023-01-01+json" \
  "https://cloud.mongodb.com/api/atlas/v2/groups/${TF_VAR_atlas_project_id}" \
  2>/dev/null) || _ATLAS_HTTP="000"
case "$_ATLAS_HTTP" in
  200)
    _ATLAS_NAME=$(python3 -c "import json; d=json.load(open('/tmp/.atlas_check.json')); print(d.get('name','?'))" 2>/dev/null || echo "?")
    ok "Atlas API keys valid — project: ${_ATLAS_NAME}" ;;
  401) err "Atlas API keys invalid (HTTP 401). Check MONGODB_ATLAS_PUBLIC_KEY / MONGODB_ATLAS_PRIVATE_KEY in .env" ;;
  403) err "Atlas API keys valid but forbidden (HTTP 403). Verify the key has Project Owner role." ;;
  404) err "Atlas project not found (HTTP 404). Check TF_VAR_mongodb_atlas_project_id in .env" ;;
  000) warn "Atlas API unreachable (curl failed) — check network. Proceeding." ;;
  *)   warn "Atlas API returned HTTP $_ATLAS_HTTP — unexpected. Proceeding cautiously." ;;
esac
rm -f /tmp/.atlas_check.json
fi

SHARED_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-${ACCOUNT_ID}"
VOYAGE_ARN="${VOYAGE_MODEL_PACKAGE_ARN:-}"
VOYAGE_INSTANCE="${VOYAGE_INSTANCE_TYPE:-ml.g6.xlarge}"
VOYAGE_MARKETPLACE_MODEL="${VOYAGE_MARKETPLACE_MODEL:-}"
VOYAGE_MODEL_LABEL=""
EMBEDDINGS_MODEL_ID=""
EMBEDDINGS_VOYAGE_MULTIMODAL="false"
VOYAGE_ENDPOINT_SUFFIX="${TF_VAR_voyage_endpoint_name_suffix:-}"
EC2_KEY_PAIR="${EC2_KEY_PAIR:-}"
AGENTCORE_RUNTIME_DEPLOYMENT_MODE="${AGENTCORE_RUNTIME_DEPLOYMENT_MODE:-code}"
GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
AGENTCORE_CODE_ARTIFACT_PREFIX="artifacts/agentcore-runtime/${GIT_SHA}/deployment_package.zip"

# ── Embedding provider guard: explicit opt-in, no silent fallback ─────────────
# The pipeline supports two explicit modes:
#   voyage — provision SageMaker from VOYAGE_MODEL_PACKAGE_ARN. Multimodal-only —
#            VOYAGE_MARKETPLACE_MODEL must be in SUPPORTED_VOYAGE_MODELS
#            (see api/src/adapters/voyage-embedding.ts). The legacy
#            text-only envelope (voyage-3-5-lite / voyage-3 / voyage-4) is removed.
#   titan  — no SageMaker endpoint, query/doc embeddings use Bedrock Titan v2.
EMBEDDINGS_PROVIDER="${EMBEDDINGS_PROVIDER:-}"
case "$EMBEDDINGS_PROVIDER" in
  voyage)
    if [[ -z "$VOYAGE_ARN" ]]; then
      err "EMBEDDINGS_PROVIDER=voyage but VOYAGE_MODEL_PACKAGE_ARN is empty.
       Subscribe to the supported Voyage AI Marketplace listing, then set VOYAGE_MODEL_PACKAGE_ARN in .env.
       Then re-source .env and re-run this script."
    fi
    # Marketplace ARN tail format:
    #   arn:aws:sagemaker:<region>:<vendor>:model-package/<package-name>
    # AWS Marketplace package names may include vendor version suffixes (e.g.
    # `voyage-multimodel-3-updated-…` / `voyage-multimodal-3-5-v1-…`). We
    # normalise the family from the ARN tail and then refuse anything that is
    # NOT a supported multimodal model — the legacy envelope is gone, so a
    # text-only subscription cannot ride the multimodal wire.
    VOYAGE_ARN_TAIL="${VOYAGE_ARN##*/}"
    if [[ "$VOYAGE_ARN_TAIL" =~ ^voyage-multimo(dal|del)-3-5($|-) ]]; then
      VOYAGE_MODEL_LABEL="voyage-multimodal-3.5"
    elif [[ "$VOYAGE_ARN_TAIL" =~ ^voyage-multimo(dal|del)-3($|-) ]]; then
      VOYAGE_MODEL_LABEL="voyage-multimodal-3"
    else
      VOYAGE_MODEL_LABEL="${VOYAGE_MARKETPLACE_MODEL:-}"
    fi
    if [[ -z "$VOYAGE_MODEL_LABEL" ]]; then
      err "Could not infer a multimodal Voyage model from VOYAGE_MODEL_PACKAGE_ARN tail '$VOYAGE_ARN_TAIL'.
       Set VOYAGE_MARKETPLACE_MODEL in .env to voyage-multimodal-3 or voyage-multimodal-3.5."
    fi
    # Hard gate: only multimodal models are allowed end-to-end. The bash SSOT
    # (deploy/scripts/_voyage-config.sh) reads SUPPORTED_VOYAGE_MODELS from
    # api/src/adapters/voyage-embedding.ts so adding a new model is one TS edit.
    voyage_assert_multimodal_or_die "$VOYAGE_MODEL_LABEL"
    EMBEDDINGS_VOYAGE_MULTIMODAL="true"
    EMBEDDINGS_MODEL_ID="$VOYAGE_ARN_TAIL"
    VOYAGE_MARKETPLACE_MODEL="$VOYAGE_MODEL_LABEL"
    VOYAGE_ENDPOINT_SUFFIX_RAW="${VOYAGE_ENDPOINT_SUFFIX:-$VOYAGE_MODEL_LABEL}"
    VOYAGE_ENDPOINT_SUFFIX="$(voyage_sagemaker_endpoint_suffix "$VOYAGE_ENDPOINT_SUFFIX_RAW")"
    if [[ -z "$VOYAGE_ENDPOINT_SUFFIX" ]]; then
      err "Voyage endpoint suffix resolved to an empty SageMaker name from '${VOYAGE_ENDPOINT_SUFFIX_RAW}'"
    fi
    if [[ "$VOYAGE_ENDPOINT_SUFFIX_RAW" != "$VOYAGE_ENDPOINT_SUFFIX" ]]; then
      warn "Normalized Voyage endpoint suffix '${VOYAGE_ENDPOINT_SUFFIX_RAW}' -> '${VOYAGE_ENDPOINT_SUFFIX}' for SageMaker"
    fi
    ok "Embeddings: ${VOYAGE_MODEL_LABEL} via SageMaker (multimodal-only; package ${VOYAGE_ARN_TAIL})"
    ;;
  titan)
    # Explicit, deliberate non-default embeddings provider — Bedrock Titan v2 only. No
    # SageMaker endpoint is created; API + runtimes embed via Bedrock. Override
    # any leaked VOYAGE_ARN so the tfvars block below cannot trigger SageMaker.
    VOYAGE_ARN=""
    VOYAGE_MODEL_LABEL=""
    EMBEDDINGS_MODEL_ID="amazon.titan-embed-text-v2:0"
    warn "═══════════════════════════════════════════════════════════════════════"
    warn "  EMBEDDINGS_PROVIDER=titan — explicit non-default embeddings provider"
    warn "  Voyage SageMaker endpoint will NOT be provisioned."
    warn "  Embeddings: amazon.titan-embed-text-v2:0 (1024-d) via Bedrock."
    warn "  This is recorded in deploy-manifest.json. To restore the Voyage multimodal default,"
    warn "  set EMBEDDINGS_PROVIDER=voyage plus VOYAGE_MODEL_PACKAGE_ARN / VOYAGE_MARKETPLACE_MODEL."
    warn "═══════════════════════════════════════════════════════════════════════"
    ;;
  "")
    err "EMBEDDINGS_PROVIDER is not set — refusing to deploy with an implicit default.
       Set one of the following in .env (or your shell) and re-source it:
         export EMBEDDINGS_PROVIDER=voyage   # Voyage multimodal default; requires Marketplace subscription
         export EMBEDDINGS_PROVIDER=titan    # explicit deviation, Bedrock Titan v2"
    ;;
  *)
    err "EMBEDDINGS_PROVIDER='$EMBEDDINGS_PROVIDER' is not recognised. Use 'voyage' or 'titan'."
    ;;
esac
export VOYAGE_MARKETPLACE_MODEL
export EMBEDDINGS_MODEL_ID
export EMBEDDINGS_VOYAGE_MULTIMODAL
export VOYAGE_ENDPOINT_SUFFIX

# Re-read SHARED_VPC_NAME after sourcing .env so a .env override wins.
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"

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
# PHASE 3b — Verify shared network is applied
# envs/ec2 reads VPC + subnet IDs + Atlas VPCE details from SSM under
# /${SHARED_VPC_NAME}/${AWS_REGION}/. Surface a clean error if the operator
# hasn't applied envs/network yet — terraform itself would also fail with
# ParameterNotFound, but a precheck gives a nicer remediation hint.
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 3b — Verifying shared network is applied (SSM /${SHARED_VPC_NAME}/${AWS_REGION}/...)"

SHARED_SSM_PARAMS=(
  "vpc_id"
  "vpc_cidr"
  "public_subnet_ids"
  "private_subnet_ids"
  "network_mode"
)
if [[ "$NETWORK_MODE" == "privatelink" ]]; then
  MODE_SSM_PARAMS=(
    "atlas_pl_vpce_id"
    "atlas_pl_vpce_dns_name"
  )
elif [[ "$NETWORK_MODE" == "peering" ]]; then
  MODE_SSM_PARAMS=(
    "atlas_peering_id"
    "atlas_container_id"
    "atlas_peering_cidr"
  )
else
  # public: the network stack provisions no Atlas plumbing, so no mode params.
  MODE_SSM_PARAMS=()
fi
REQUIRED_SSM_PARAMS=("${SHARED_SSM_PARAMS[@]}" "${MODE_SSM_PARAMS[@]}")
_MISSING=()
for p in "${REQUIRED_SSM_PARAMS[@]}"; do
  aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/${p}" \
    --query "Parameter.Value" --output text >/dev/null 2>&1 \
    || _MISSING+=("$p")
done
if (( ${#_MISSING[@]} > 0 )); then
  err "Shared network not found / wrong mode (missing SSM params: ${_MISSING[*]}). Run ./deploy/scripts/deploy-network.sh with NETWORK_MODE=${NETWORK_MODE} first."
fi
ok "Shared network ready (${#REQUIRED_SSM_PARAMS[@]} SSM params found for mode=${NETWORK_MODE})"

# Cross-check: SSM-recorded network_mode must match this script's NETWORK_MODE.
# Catches the case where envs/network was applied in the other mode (envs/ec2
# would also catch it via the `check` block but a precheck gives a nicer
# remediation hint).
SHARED_NETWORK_MODE=$(aws ssm get-parameter \
  --region "$AWS_REGION" \
  --name "/${SHARED_VPC_NAME}/${AWS_REGION}/network_mode" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")
if [[ "$SHARED_NETWORK_MODE" != "$NETWORK_MODE" ]]; then
  case "$SHARED_NETWORK_MODE" in
    peering)
      DESTROY_PROJECT="./deploy/destroy/destroy-project-with-vpc-peering.sh"
      DESTROY_SHARED="./deploy/destroy/destroy-shared-with-vpc-peering.sh"
      ;;
    *)
      DESTROY_PROJECT="./deploy/destroy/destroy-project-with-privatelink.sh"
      DESTROY_SHARED="./deploy/destroy/destroy-shared-with-privatelink.sh"
      ;;
  esac
  err "NETWORK MODE MISMATCH: shared network reports mode='${SHARED_NETWORK_MODE}' but env says '${NETWORK_MODE}'.
     PrivateLink and VPC peering are mutually exclusive per account. To switch modes run:
       ${DESTROY_PROJECT}
       ${DESTROY_SHARED}
     Then re-run deploy-network.sh with the desired NETWORK_MODE before re-running this script."
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — Generate Terraform config (envs/ec2)
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 4 — Generating Terraform config for envs/ec2..."

cat > "$TF_DIR/backend.hcl" <<EOF
bucket  = "${SHARED_BUCKET}"
key     = "${ENVIRONMENT}/ec2/terraform.tfstate"
region  = "${AWS_REGION}"
encrypt = true
# dynamodb_table omitted — SCP on this account blocks DynamoDB CreateTable.
EOF
ok "backend.hcl written (state key: ${ENVIRONMENT}/ec2/terraform.tfstate)"

# ── Operator/deploy-machine IP for the Atlas IP access list ─────────────────
# Atlas is NEVER opened to 0.0.0.0/0. In privatelink mode the mongodb-atlas
# module scopes the only public-SRV allowlist entry to this /32 ("anywhere it
# was created from"); runtime traffic uses PrivateLink and bypasses the list.
# In peering mode the module uses the VPC CIDR instead and this is ignored.
# shellcheck source=deploy/scripts/_operator-ip.sh
source "$SCRIPT_DIR/_operator-ip.sh"
if [[ "$NETWORK_MODE" == "privatelink" ]]; then
  resolve_operator_ip_cidr "deploy" || err "Could not determine operator IP for the Atlas IP access list (privatelink mode). Atlas must be reachable from the deploy machine without 0.0.0.0/0. Set OPERATOR_IP_CIDR=A.B.C.D/32 in .env (or TF_VAR_my_ip) and re-run."
  ok "Atlas IP access list will be scoped to operator IP ${OPERATOR_IP_CIDR}"
else
  resolve_operator_ip_cidr "deploy" || true
fi

cat > "$TF_DIR/terraform.tfvars" <<EOF
# EC2 mode — generated by deploy.sh
aws_region         = "${AWS_REGION}"
environment        = "${ENVIRONMENT}"
project_name       = "${PROJECT_NAME}"
shared_bucket_name = "${SHARED_BUCKET}"

# Shared network (envs/network) — drives the SSM prefix this env reads from.
# VPC + subnets + Atlas-PL VPCE all come from /${SHARED_VPC_NAME}/${AWS_REGION}/.
shared_vpc_name    = "${SHARED_VPC_NAME}"

# MongoDB Atlas (cluster provisioned by Terraform in this env)
atlas_project_id = "${TF_VAR_atlas_project_id}"
atlas_db_user    = "${ATLAS_DB_USER}"
atlas_db_name    = "${ATLAS_DB_NAME}"
# atlas_db_password / atlas_public_key / atlas_private_key → TF_VAR env vars

# Bedrock KB — Titan used for ingestion (KB requires Bedrock-native embedding)
# kb_iam_role_name omitted on purpose — bedrock-kb module derives a unique
# IAM role name from project_name + environment so parallel deploys do not collide.
embed_model_id   = "amazon.titan-embed-text-v2:0"
# Optional dedicated S3 bucket for KB source docs. Empty = shared bucket.
kb_docs_bucket_name = "${KB_DOCS_BUCKET:-}"

# EC2 — SSM Session Manager for shell access (no SSH key required)
ec2_instance_type = "t3.medium"
ec2_key_pair_name = "${EC2_KEY_PAIR}"

# Voyage AI SageMaker variables intentionally NOT passed here — the SageMaker
# endpoint is provisioned once by envs/shared (deploy-shared.sh) per
# (account, region, environment) and read via SSM by this per-project ec2 stack.
# See local.shared_voyage_endpoint_{name,arn} in envs/ec2/main.tf.

# AgentCore Memory TTL
agentcore_memory_expiry_days = 30
agentcore_runtime_deployment_mode = "${AGENTCORE_RUNTIME_DEPLOYMENT_MODE}"
agentcore_code_artifact_prefix    = "${AGENTCORE_CODE_ARTIFACT_PREFIX}"

# Connectivity mode — must match the mode the shared network was applied in
# (verified by the SSM canary above and by the \`check "network_mode_matches_shared"\`
# block in envs/ec2/main.tf). Switching modes requires destroy + redeploy.
network_mode      = "${NETWORK_MODE}"

# Cluster source — 'byo' skips Terraform cluster creation and uses the
# operator-supplied connection string (byo_* vars passed via TF_VAR env).
cluster_source     = "${ATLAS_CLUSTER_SOURCE}"
allow_public_atlas = ${TF_VAR_allow_public_atlas:-false}

# Operator/deploy-machine public IP — the ONLY public-SRV Atlas IP access list
# entry in privatelink mode (replaces the former 0.0.0.0/0). Auto-detected by
# deploy-project.sh; override via OPERATOR_IP_CIDR / TF_VAR_my_ip in .env.
operator_ip_cidr  = "${OPERATOR_IP_CIDR:-}"
EOF

# NOTE: the `create_agentcore_runtime_vpc_endpoints` decision is intentionally
# NOT made here. It is resolved AFTER `terraform init` (Phase 5a below) because
# the only authoritative "does THIS stack already own the 4 AgentCore VPCEs?"
# signal is `terraform state list`, which requires an initialized backend.
# Deciding pre-init is unsafe: a wiped local `.terraform` makes state list
# return empty, the auto path then sees the endpoints existing in the VPC,
# picks `false`, and the next apply DESTROYS this project's ECR/Logs/S3/Atlas
# endpoints. See docs/status/debugging.md "AgentCore VPCE create/reuse probe
# must run after terraform init".
ok "terraform.tfvars written (network_mode=${NETWORK_MODE})"

# ── Phase 4a — Discover agents + write agents.auto.tfvars.json ────────────────
sep
log "Phase 4a — Discovering agents from config/agents/..."
discover_agents
validate_handoff_consistency "warn"
write_specialist_agents_tfvars

# ── Phase 4b — Build + upload AgentCore direct-code artifact ──────────────────
sep
log "Phase 4b — Building + uploading AgentCore direct-code artifact..."
build_and_upload_code_artifact

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4c — Shared-stack pre-flight check
#
# envs/ec2 reads /<SHARED_VPC_NAME>/<REGION>/voyage_sagemaker_endpoint_name
# (and the rest of the shared-stack SSM keys) at plan time. Failing inside
# `terraform plan` with a generic "ParameterNotFound" wastes a few minutes; a
# pre-flight probe surfaces the missing-prereq case with an actionable message.
# Only voyage_sagemaker_endpoint_name is enforced strictly here because the
# value-vs-"_empty_" sentinel distinction is the one downstream agent IAM
# depends on (sagemaker:InvokeEndpoint scoping).
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 4c — Shared-stack pre-flight check..."
SHARED_VOYAGE_PARAM="/${SHARED_VPC_NAME}/${AWS_REGION}/voyage_sagemaker_endpoint_name"
SHARED_VOYAGE_VAL="$(aws ssm get-parameter \
  --region "$AWS_REGION" \
  --name "$SHARED_VOYAGE_PARAM" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")"

if [[ -z "$SHARED_VOYAGE_VAL" ]]; then
  err "Shared stack has not been applied — SSM parameter $SHARED_VOYAGE_PARAM is missing.
     Run: ./deploy/scripts/deploy-shared.sh --env-file $ENV_FILE
     (or use ./deploy/deploy-full-with-privatelink.sh which does this for you.)"
fi

if [[ "$EMBEDDINGS_PROVIDER" == "voyage" ]]; then
  if [[ "$SHARED_VOYAGE_VAL" == "_empty_" ]]; then
    err "EMBEDDINGS_PROVIDER=voyage but the shared stack provisioned no SageMaker endpoint
     ($SHARED_VOYAGE_PARAM is the '_empty_' sentinel — meaning VOYAGE_MODEL_PACKAGE_ARN
     was unset when deploy-shared.sh last ran).
     Fix: export VOYAGE_MODEL_PACKAGE_ARN in .env and re-run deploy-shared.sh."
  fi
  ok "Shared Voyage endpoint: $SHARED_VOYAGE_VAL"
else
  ok "Shared stack present (voyage endpoint: ${SHARED_VOYAGE_VAL/#_empty_/<not provisioned, EMBEDDINGS_PROVIDER=titan>})"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4d — Pre-apply: build + push the mongodb-mcp runtime image
#
# The mongodb-mcp AgentCore Runtime uses container deployment mode (it's an
# Express/MCP-SDK server, not the direct-code Strands shape) and AgentCore
# refuses to bring it READY if `:latest` doesn't exist in ECR. So we apply
# JUST the ECR repo first, push the image, and then let the full apply
# create the runtime against an existing image.
#
# Skipped when --skip-docker is set.
# ══════════════════════════════════════════════════════════════════════════════
sep
cd "$TF_DIR"
deploy_diag_terraform_context "ec2 terraform init" "$TF_DIR" "$TF_DIR/backend.hcl" "$TF_DIR/.tfplan"
log "Phase 5 — terraform init..."
deploy_diag_checkpoint "terraform init start: terraform init -input=false -reconfigure -backend-config=${TF_DIR}/backend.hcl"
terraform init -input=false -reconfigure -backend-config="$TF_DIR/backend.hcl"
ok "init complete"

# ── Phase 5a — Resolve create_agentcore_runtime_vpc_endpoints (POST-INIT) ─────
# AgentCore runtime VPCEs (ECR API/DKR, CloudWatch Logs, S3 gateway) are
# VPC-scoped singletons OWNED BY THIS stack. This decision runs after
# `terraform init` so `terraform state list` reflects the real remote state and
# reliably reports whether this stack already owns them.
#
# Fail-closed contract: any ambiguity (state list errored, backend unreadable)
# keeps create=true so a transient read failure can NEVER plan a destroy of
# live endpoints. `false` (reuse external singletons) is chosen ONLY when state
# was readable AND confirms this stack owns none of the four.
sep
log "Phase 5a — Resolving create_agentcore_runtime_vpc_endpoints (post-init)..."
CREATE_AGENTCORE_VPCE="${TF_VAR_create_agentcore_runtime_vpc_endpoints:-auto}"
# public mode: envs/ec2/main.tf forces agentcore_vpce_create AND _lookup both
# false, so this value is inert — Terraform ignores it. Skip the slow SSM +
# `terraform state list` (S3 backend) + describe-vpc-endpoints probes entirely.
# ponytail: false is the cheap honest answer; the result is discarded anyway.
if [[ "$NETWORK_MODE" == "public" ]]; then
  CREATE_AGENTCORE_VPCE="false"
  log "network_mode=public — AgentCore VPCEs neither created nor looked up; skipping resolution probes"
else
  SHARED_VPC_ID=$(aws ssm get-parameter --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id" \
    --query Parameter.Value --output text 2>/dev/null || echo "")
  if [[ "$CREATE_AGENTCORE_VPCE" == "true" || "$CREATE_AGENTCORE_VPCE" == "false" ]]; then
    log "Using explicit TF_VAR_create_agentcore_runtime_vpc_endpoints=${CREATE_AGENTCORE_VPCE}"
  elif [[ -n "$SHARED_VPC_ID" && "$SHARED_VPC_ID" != "None" ]]; then
    CREATE_AGENTCORE_VPCE="true"
    # Capture `terraform state list` separately from the parse so a non-zero exit
    # (uninitialized / locked / transient backend error) is detected. On failure
    # we keep create=true rather than mis-reading "empty output" as "this stack
    # owns nothing" — the exact bug that destroyed live endpoints after a local
    # .terraform wipe.
    TF_STATE_LIST_OK=true
    if ! TF_STATE_LIST_OUT="$(terraform -chdir="$TF_DIR" state list 2>/dev/null)"; then
      TF_STATE_LIST_OK=false
      TF_STATE_LIST_OUT=""
      warn "terraform state list failed after init — forcing create_agentcore_runtime_vpc_endpoints=true (fail-closed: never destroy live endpoints on an ambiguous read)"
    fi
    MANAGED_AGENTCORE_VPCE_COUNT=$(printf '%s\n' "$TF_STATE_LIST_OUT" | python3 -c 'import sys
managed = [line.strip() for line in sys.stdin if line.strip().startswith("aws_vpc_endpoint.agentcore_runtime_")]
print(len(managed))' 2>/dev/null || echo "0")
    EXISTING_VPCE_COUNT=$(aws ec2 describe-vpc-endpoints --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=${SHARED_VPC_ID}" \
      --query "length(VpcEndpoints[?ServiceName=='com.amazonaws.${AWS_REGION}.ecr.api' || ServiceName=='com.amazonaws.${AWS_REGION}.ecr.dkr' || ServiceName=='com.amazonaws.${AWS_REGION}.logs'])" \
      --output text 2>/dev/null || echo "0")
    EXISTING_S3_VPCE_COUNT=$(aws ec2 describe-vpc-endpoints --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=${SHARED_VPC_ID}" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.s3" \
      --query "length(VpcEndpoints)" \
      --output text 2>/dev/null || echo "0")
    if [[ "${MANAGED_AGENTCORE_VPCE_COUNT:-0}" -ge 4 ]]; then
      CREATE_AGENTCORE_VPCE="true"
      log "Shared VPC ${SHARED_VPC_ID} has AgentCore VPCEs in this Terraform state — keeping ownership"
    elif [[ "${MANAGED_AGENTCORE_VPCE_COUNT:-0}" -gt 0 ]]; then
      err "Terraform state has only ${MANAGED_AGENTCORE_VPCE_COUNT}/4 AgentCore VPCE resources. Resolve partial state or rerun with TF_VAR_create_agentcore_runtime_vpc_endpoints=false after confirming ECR/Logs/S3 endpoints already exist."
    elif [[ "$TF_STATE_LIST_OK" == "true" && "${EXISTING_VPCE_COUNT:-0}" -ge 3 && "${EXISTING_S3_VPCE_COUNT:-0}" -ge 1 ]]; then
      # Reuse ONLY when state was readable and confirms this stack owns none of
      # them — i.e. they are genuinely externally-owned shared-VPC singletons.
      CREATE_AGENTCORE_VPCE="false"
      log "Shared VPC ${SHARED_VPC_ID} already has externally-owned AgentCore ECR/Logs/S3 VPCEs — reusing"
    fi
  else
    CREATE_AGENTCORE_VPCE="true"
  fi
fi
echo "create_agentcore_runtime_vpc_endpoints = ${CREATE_AGENTCORE_VPCE}" >> "$TF_DIR/terraform.tfvars"
ok "create_agentcore_runtime_vpc_endpoints=${CREATE_AGENTCORE_VPCE} appended to terraform.tfvars"

# ── Phase 5b — Resolve kb_docs_bucket_create (POST-INIT) ──────────────────────
# Decide whether Terraform creates/owns the dedicated KB bucket (KB_DOCS_BUCKET)
# or references an already-existing, externally-owned one. Runs after
# `terraform init` so `terraform state list` reflects the real remote state.
#
# Fail-closed contract: any ambiguity (state unreadable) keeps create=true.
# create=false is destructive-adjacent — if this stack already manages the
# bucket, flipping to false would plan to DESTROY/unmanage it. So we choose
# false (reuse) ONLY when state was readable, confirms this stack does NOT manage
# the bucket, AND the bucket already exists in AWS. create=true on an existing
# unmanaged bucket merely fails non-destructively (BucketAlreadyExists), which is
# the safer default under uncertainty.
sep
log "Phase 5b — Resolving kb_docs_bucket_create (post-init)..."
KB_BUCKET_CREATE="${TF_VAR_kb_docs_bucket_create:-auto}"
if [[ -z "${KB_DOCS_BUCKET:-}" ]]; then
  KB_BUCKET_CREATE="true"
  log "No dedicated KB bucket configured (KB_DOCS_BUCKET empty) — KB docs live in the shared bucket; kb_docs_bucket_create=true"
elif [[ "$KB_BUCKET_CREATE" == "true" || "$KB_BUCKET_CREATE" == "false" ]]; then
  log "Using explicit TF_VAR_kb_docs_bucket_create=${KB_BUCKET_CREATE}"
else
  KB_BUCKET_CREATE="true"
  KB_TF_STATE_OK=true
  if ! KB_TF_STATE_OUT="$(terraform -chdir="$TF_DIR" state list 2>/dev/null)"; then
    KB_TF_STATE_OK=false
    KB_TF_STATE_OUT=""
    warn "terraform state list failed after init — forcing kb_docs_bucket_create=true (fail-closed: never unmanage/destroy a managed KB bucket on an ambiguous read)"
  fi
  if printf '%s\n' "$KB_TF_STATE_OUT" | grep -q '^module\.bedrock_kb\.aws_s3_bucket\.kb_docs\['; then
    KB_BUCKET_CREATE="true"
    log "KB bucket ${KB_DOCS_BUCKET} is already in this Terraform state — keeping ownership (create=true)"
  elif [[ "$KB_TF_STATE_OK" == "true" ]] && aws s3api head-bucket --bucket "${KB_DOCS_BUCKET}" --region "$AWS_REGION" >/dev/null 2>&1; then
    KB_BUCKET_CREATE="false"
    log "KB bucket ${KB_DOCS_BUCKET} already exists and is NOT managed by this stack — reusing it (no create, no sample-doc upload)"
  else
    log "KB bucket ${KB_DOCS_BUCKET} not found (or read ambiguous) — Terraform will create it (create=true)"
  fi
fi
echo "kb_docs_bucket_create = ${KB_BUCKET_CREATE}" >> "$TF_DIR/terraform.tfvars"
ok "kb_docs_bucket_create=${KB_BUCKET_CREATE} appended to terraform.tfvars"

if [[ "$SKIP_DOCKER" != "true" ]]; then
  sep
  log "Phase 4d — Ensuring mongodb-mcp runtime ECR repo, then push image..."
  MCP_RUNTIME_REPO_NAME="${PROJECT_NAME}-mongodb-mcp-${ENVIRONMENT}"
  MCP_RUNTIME_REPO="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${MCP_RUNTIME_REPO_NAME}"

  if ! aws ecr describe-repositories \
    --region "$AWS_REGION" \
    --repository-names "$MCP_RUNTIME_REPO_NAME" >/dev/null 2>&1; then
    log "  creating ECR repo → $MCP_RUNTIME_REPO_NAME"
    aws ecr create-repository \
      --region "$AWS_REGION" \
      --repository-name "$MCP_RUNTIME_REPO_NAME" \
      --image-tag-mutability MUTABLE \
      --image-scanning-configuration scanOnPush=true >/dev/null
  fi

  # Do not use `terraform -target` here. Targeted plans break when unrelated
  # resources have moved addresses, and they can hide drift in the rest of the
  # stack. If this is a first deploy, import the repo so the following normal
  # full plan owns it and can manage the lifecycle policy idempotently.
  if ! terraform state list 2>/dev/null | awk '$0 == "aws_ecr_repository.mongodb_mcp_runtime" { found = 1 } END { exit !found }'; then
    log "  importing ECR repo into Terraform state → aws_ecr_repository.mongodb_mcp_runtime"
    deploy_diag_checkpoint "terraform import start: terraform import -input=false aws_ecr_repository.mongodb_mcp_runtime ${MCP_RUNTIME_REPO_NAME}"
    terraform import -input=false aws_ecr_repository.mongodb_mcp_runtime "$MCP_RUNTIME_REPO_NAME" >/dev/null
  fi

  ECR_REGISTRY=$(echo "$MCP_RUNTIME_REPO" | cut -d'/' -f1)
  log "  ECR login → $ECR_REGISTRY"
  source "$SCRIPT_DIR/_docker-build.sh"
  ecr_login_with_retry "$AWS_REGION" "$ECR_REGISTRY" >/dev/null \
    || err "ECR login failed after retries (transient DNS/network did not clear)"
  log "  building mongodb-mcp-runtime image (linux/arm64)..."
  docker_build_push_image linux/arm64 \
    "$REPO_ROOT/mcp-runtimes/mongodb-mcp/Dockerfile" \
    "$REPO_ROOT/mcp-runtimes/mongodb-mcp" \
    "${MCP_RUNTIME_REPO}:latest" >/dev/null
  ok "mongodb-mcp-runtime pushed: ${MCP_RUNTIME_REPO}:latest"

  # Phase 4d.5 — force-sync the AgentCore runtime + gateway target. Required
  # because the TF-managed `container_uri` of `<repo>:latest` is a constant
  # string — `terraform plan` would otherwise see no diff and AgentCore would
  # keep serving the previous image version. See docs/status/debugging.md
  # "AgentCore Runtime image push does not auto-trigger a runtime version bump"
  # and "AgentCore Gateway target caches tool schemas …".
  #
  # First-deploy safety: when the runtime/gateway don't exist yet,
  # force_mcp_runtime_image_sync no-ops and the apply below creates them with
  # the freshly-pushed image.
  if ! declare -F force_mcp_runtime_image_sync >/dev/null 2>&1; then
    # Source the helpers if the caller didn't (deploy-project.sh sources later
    # in normal flow, but Phase 4d runs before the source on first-deploy).
    source "$SCRIPT_DIR/_agents-common.sh"
  fi
  _MCP_RUNTIME_ID_PRE=$(tfo -raw mongodb_mcp_runtime_id 2>/dev/null || echo "")
  _GATEWAY_ID_PRE=$(tfo -raw agentcore_gateway_id 2>/dev/null || echo "")
  force_mcp_runtime_image_sync \
    "$_MCP_RUNTIME_ID_PRE" \
    "$MCP_RUNTIME_REPO_NAME" \
    "latest" \
    "$_GATEWAY_ID_PRE" \
    "mongodb-mcp"
  unset _GATEWAY_ID_PRE

  # Capture the pushed image digest so the next `terraform plan` propagates it
  # as a trigger on module.agentcore_gateway.null_resource.mcp_server_gateway_target.
  # Belt-and-suspenders for any future apply that does not go through
  # `deploy-project.sh` (e.g. operator-driven targeted plans).
  TF_VAR_mongodb_mcp_image_digest=$(aws ecr describe-images \
    --region "$AWS_REGION" \
    --repository-name "$MCP_RUNTIME_REPO_NAME" \
    --image-ids imageTag=latest \
    --query 'imageDetails[0].imageDigest' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$TF_VAR_mongodb_mcp_image_digest" && "$TF_VAR_mongodb_mcp_image_digest" != "None" ]]; then
    export TF_VAR_mongodb_mcp_image_digest
    log "  exporting TF_VAR_mongodb_mcp_image_digest=${TF_VAR_mongodb_mcp_image_digest:0:19}…"
  else
    unset TF_VAR_mongodb_mcp_image_digest
  fi
fi

# MCP ECR repo name + pre-apply runtime id (for R.0 first-deploy Gateway refresh).
# Must be set even when --skip-docker: Phase 4d only runs inside the docker block.
MCP_RUNTIME_REPO_NAME="${PROJECT_NAME}-mongodb-mcp-${ENVIRONMENT}"
_MCP_RUNTIME_ID_PRE=$(tfo -raw mongodb_mcp_runtime_id 2>/dev/null || echo "")

# ── Pre-apply: adopt an orphaned Atlas vector search index ───────────────────
# A prior apply can create the vector index (POST to the Atlas Admin API
# succeeds, the index reaches READY) but die before persisting the resource to
# Terraform state. The next run then re-POSTs the same index name and Atlas
# rejects it with HTTP 409 ATLAS_SEARCH_DUPLICATE_INDEX. This is especially
# likely on a BYO cluster, which persists across deploys. If the index already
# exists in Atlas but not in our state, import it so the plan adopts it instead
# of recreating a duplicate. Best-effort and idempotent (managed + BYO): any
# failure here is non-fatal — the plan/apply below surfaces the real error.
if ! terraform state list 2>/dev/null | grep -qx 'module.bedrock_kb.mongodbatlas_search_index.vector'; then
  _VEC_CLUSTER="${MONGODB_BYO_CLUSTER_NAME:-${PROJECT_NAME}-${ENVIRONMENT}}"
  _VEC_COLL="troubleshooting_docs"     # modules/bedrock-kb default atlas_collection
  _VEC_NAME="troubleshooting-vector-index"  # modules/bedrock-kb default atlas_vector_index
  if [[ -n "${MONGODB_ATLAS_PUBLIC_KEY:-}" && -n "${MONGODB_ATLAS_PRIVATE_KEY:-}" && -n "${TF_VAR_atlas_project_id:-}" ]]; then
    _VEC_ID=$(curl -sS --user "${MONGODB_ATLAS_PUBLIC_KEY}:${MONGODB_ATLAS_PRIVATE_KEY}" --digest \
      -H "Accept: application/vnd.atlas.2024-05-30+json" \
      "https://cloud.mongodb.com/api/atlas/v2/groups/${TF_VAR_atlas_project_id}/clusters/${_VEC_CLUSTER}/search/indexes/${ATLAS_DB_NAME}/${_VEC_COLL}" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in (d if isinstance(d,list) else []):
    if it.get("name")==sys.argv[1]:
        print(it.get("indexID",""))
        break
' "$_VEC_NAME" 2>/dev/null || echo "")
    if [[ -n "$_VEC_ID" ]]; then
      log "Adopting pre-existing Atlas vector index '${_VEC_NAME}' (${_VEC_ID}) into Terraform state…"
      deploy_diag_checkpoint "terraform import start: module.bedrock_kb.mongodbatlas_search_index.vector ${TF_VAR_atlas_project_id}--${_VEC_CLUSTER}--${_VEC_ID}"
      if terraform import -input=false \
        'module.bedrock_kb.mongodbatlas_search_index.vector' \
        "${TF_VAR_atlas_project_id}--${_VEC_CLUSTER}--${_VEC_ID}" >/dev/null 2>&1; then
        ok "Imported existing vector index — plan will adopt it, not recreate"
      else
        warn "terraform import of vector index failed; if apply hits HTTP 409 ATLAS_SEARCH_DUPLICATE_INDEX, import it manually:"
        warn "  terraform import 'module.bedrock_kb.mongodbatlas_search_index.vector' '${TF_VAR_atlas_project_id}--${_VEC_CLUSTER}--${_VEC_ID}'"
      fi
    fi
  fi
  unset _VEC_CLUSTER _VEC_COLL _VEC_NAME _VEC_ID
fi

sep
log "Running terraform plan..."
deploy_diag_checkpoint "terraform plan start: terraform plan -input=false -out=${TF_DIR}/.tfplan"
terraform plan -input=false -out="$TF_DIR/.tfplan"
ok "plan complete"

sep
log "NOTE: First apply creates Atlas M10 (~5-10 min), AgentCore resources, and EC2."

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

# ── Outputs ──────────────────────────────────────────────────────────────────
load_tf_outputs() {
  EC2_IP=$(tfo -raw ec2_public_ip 2>/dev/null || echo "")
  EC2_API=$(tfo -raw ec2_api_url 2>/dev/null || echo "")
  EC2_UI=$(tfo -raw ec2_ui_url 2>/dev/null || echo "")
  EC2_SSM=$(tfo -raw ec2_ssm_command 2>/dev/null || echo "")
  EC2_INSTANCE_ID=$(tfo -raw ec2_instance_id 2>/dev/null || echo "")
  ATLAS_MONGO_HOST=$(tfo -raw atlas_mongo_host 2>/dev/null || echo "")
  ATLAS_CONNECTION_STRING=$(tfo -raw atlas_connection_string 2>/dev/null || echo "")
  COGNITO_POOL_ID=$(tfo -raw cognito_user_pool_id 2>/dev/null || echo "")
  COGNITO_CLIENT_ID=$(tfo -raw cognito_app_client_id 2>/dev/null || echo "")
  COGNITO_JWKS=$(tfo -raw cognito_jwks_uri 2>/dev/null || echo "")
  VOYAGE_ENDPOINT=$(tfo -raw voyage_endpoint_name 2>/dev/null || echo "")
  if [[ "$EMBEDDINGS_PROVIDER" == "titan" ]]; then
    VOYAGE_ENDPOINT=""
  fi
  ECR_API_REPO=$(tfo -raw ecr_api_repository_url 2>/dev/null || echo "")
  ECR_UI_REPO=$(tfo -raw ecr_ui_repository_url 2>/dev/null || echo "")
  ECR_RUNTIME_REPO=$(tfo -raw ecr_agent_runtime_repository_url 2>/dev/null || echo "")
  ECR_MCP_RUNTIME_REPO=$(tfo -raw ecr_mongodb_mcp_runtime_repository_url 2>/dev/null || echo "")
  MONGODB_MCP_RUNTIME_ARN=$(tfo -raw mongodb_mcp_runtime_arn 2>/dev/null || echo "")
  MONGODB_MCP_RUNTIME_ENDPOINT=$(tfo -raw mongodb_mcp_runtime_endpoint 2>/dev/null || echo "")
  AGENTCORE_RUNTIME_DEPLOYMENT_MODE=$(tfo -raw agentcore_runtime_deployment_mode 2>/dev/null || echo "$AGENTCORE_RUNTIME_DEPLOYMENT_MODE")
  AGENTCORE_CODE_ARTIFACT_PREFIX=$(tfo -raw agentcore_code_artifact_prefix 2>/dev/null || echo "$AGENTCORE_CODE_ARTIFACT_PREFIX")
  AGENTCORE_MEMORY_STORE_ID=$(tfo -raw agentcore_memory_id 2>/dev/null || echo "")
  AGENTCORE_GATEWAY_URL=$(tfo -raw agentcore_gateway_url 2>/dev/null || echo "")
  AGENTCORE_GATEWAY_ID=$(tfo -raw agentcore_gateway_id 2>/dev/null || echo "")
  AGENTCORE_ORCHESTRATOR_ARN=$(tfo -raw acr_orchestrator_arn 2>/dev/null || echo "")
  AGENTCORE_ORCHESTRATOR_ID=$(tfo -raw acr_orchestrator_id 2>/dev/null || echo "")
  # Load specialist ARNs + IDs from the for_each map outputs.
  # The list of specialist IDs comes from discover_agents (config/agents/*.agent.md),
  # so no agent IDs are hardcoded here.
  load_specialist_outputs_from_tf
  ATLAS_PRIVATELINK_ENDPOINT_ID=$(tfo -raw atlas_privatelink_endpoint_id 2>/dev/null || echo "")
  CW_API_LOG_GROUP=$(tfo -raw cloudwatch_api_log_group 2>/dev/null || echo "/${PROJECT_NAME}/${ENVIRONMENT}/api")
  CW_UI_LOG_GROUP=$(tfo -raw cloudwatch_ui_log_group 2>/dev/null || echo "/${PROJECT_NAME}/${ENVIRONMENT}/ui")
}

load_tf_outputs

# Runtime outputs are file-backed by create-runtime scripts and can be empty
# immediately after apply in some edge cases. Refresh outputs once if needed.
if [[ -z "$AGENTCORE_ORCHESTRATOR_ARN" ]] || \
   ! python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d else 1)" \
     "$(tfo -json acr_specialist_arns 2>/dev/null || echo '{}')" 2>/dev/null; then
  warn "AgentCore runtime outputs incomplete after apply; running refresh-only apply to rehydrate outputs..."
  terraform apply -refresh-only -auto-approve -input=false >/dev/null 2>&1 || true
  load_tf_outputs
fi

# ── R.0 First-deploy Gateway target refresh ──────────────────────────────────
# Prevents the long-documented "second deploy fixed it" race:
#   1. First deploy: force_mcp_runtime_image_sync (Phase 4d.5) skipped because
#      the runtime didn't exist yet.
#   2. terraform apply creates the runtime + Gateway target concurrently.
#   3. The Gateway target's tools/list runs against a still-cold runtime and
#      caches an empty/stale schema.
#   4. Until the NEXT deploy runs force_mcp_runtime_image_sync against the
#      now-warm runtime, MCP tool calls return 0 results.
#
# Detect first deploy via `_MCP_RUNTIME_ID_PRE` (captured before apply at
# Phase 4d.5) being empty AND the post-apply ARN now populated. If true,
# poll the runtime to READY and force the Gateway target to recreate so
# tools/list runs against the warm runtime.
MONGODB_MCP_RUNTIME_ID_POST="${MONGODB_MCP_RUNTIME_ARN##*/}"
GATEWAY_ID_POST="$(tfo -raw agentcore_gateway_id 2>/dev/null || echo "")"
if [[ -z "${_MCP_RUNTIME_ID_PRE:-}" && -n "$MONGODB_MCP_RUNTIME_ID_POST" && -n "$GATEWAY_ID_POST" ]]; then
  if ! declare -F force_mcp_runtime_image_sync >/dev/null 2>&1; then
    source "$SCRIPT_DIR/_agents-common.sh"
  fi
  log "[mcp-bootstrap] first-deploy detected — refreshing Gateway target against warm runtime…"

  # Poll the mongodb-mcp runtime until status=READY (max 5 min).
  RUNTIME_READY_BUDGET_S=300
  RUNTIME_READY_STARTED=$SECONDS
  RUNTIME_STATUS=""
  while (( SECONDS - RUNTIME_READY_STARTED < RUNTIME_READY_BUDGET_S )); do
    RUNTIME_STATUS="$(aws bedrock-agentcore-control get-agent-runtime \
      --region "$AWS_REGION" \
      --agent-runtime-id "$MONGODB_MCP_RUNTIME_ID_POST" \
      --query 'status' --output text 2>/dev/null || echo '')"
    if [[ "$RUNTIME_STATUS" == "READY" ]]; then
      ok "[mcp-bootstrap] mongodb-mcp runtime READY"
      break
    fi
    log "  runtime status: ${RUNTIME_STATUS:-?} ($(( SECONDS - RUNTIME_READY_STARTED ))s elapsed)"
    sleep 10
  done
  if [[ "$RUNTIME_STATUS" != "READY" ]]; then
    warn "[mcp-bootstrap] mongodb-mcp runtime did not reach READY in ${RUNTIME_READY_BUDGET_S}s (last: ${RUNTIME_STATUS:-?}) — Gateway target refresh may run against a cold runtime"
  fi

  # Force the Gateway target to be recreated so its tools/list cache is rebuilt
  # against the warm runtime. The helper deletes the target + removes the
  # null_resource from TF state; the targeted apply below recreates it.
  if force_mcp_runtime_image_sync \
       "$MONGODB_MCP_RUNTIME_ID_POST" \
       "$MCP_RUNTIME_REPO_NAME" \
       "latest" \
       "$GATEWAY_ID_POST" \
       "mongodb-mcp"; then
    log "[mcp-bootstrap] running targeted terraform apply to recreate Gateway target…"
    if terraform apply -auto-approve -input=false \
         -target='module.agentcore_gateway.null_resource.mcp_server_gateway_target[0]' \
         2>&1 | tee /tmp/_mcp-bootstrap-tf.out >/dev/null; then
      ok "[mcp-bootstrap] first-deploy Gateway target refresh complete — tool schemas cached against warm runtime"
    else
      warn "[mcp-bootstrap] targeted terraform apply did not succeed; tools/list may still be empty (see /tmp/_mcp-bootstrap-tf.out)"
    fi
    # Refresh outputs in case the targeted apply changed any values.
    load_tf_outputs
  else
    warn "[mcp-bootstrap] force_mcp_runtime_image_sync returned non-zero on first-deploy refresh"
  fi
  unset RUNTIME_READY_BUDGET_S RUNTIME_READY_STARTED RUNTIME_STATUS
fi
unset MONGODB_MCP_RUNTIME_ID_POST GATEWAY_ID_POST _MCP_RUNTIME_ID_PRE

[[ -n "$EC2_IP" ]]        || err "EC2 instance IP not in outputs. Check terraform apply logs."
[[ -n "$ECR_API_REPO" ]]  || err "ECR API repo URL not in outputs."
[[ -n "$ATLAS_MONGO_HOST" ]] || err "Atlas host not in outputs."
[[ -n "$AGENTCORE_ORCHESTRATOR_ARN" ]] || err "AGENTCORE_ORCHESTRATOR_ARN output is empty after apply/refresh."
[[ -n "$AGENTCORE_ORCHESTRATOR_ID" ]] || err "AGENTCORE_ORCHESTRATOR_ID output is empty after apply/refresh."
[[ -n "$MONGODB_MCP_RUNTIME_ARN" ]] || err "MongoDB MCP runtime ARN output is empty after apply/refresh."
[[ -n "$MONGODB_MCP_RUNTIME_ENDPOINT" ]] || err "MongoDB MCP runtime endpoint output is empty after apply/refresh."
# Validate each discovered specialist has a runtime ARN in the map outputs.
# Guard the iteration: with an orchestrator-only roster SPECIALIST_IDS is an
# empty array and "${SPECIALIST_IDS[@]:-}" would expand to a single empty-string
# element under `set -u`, falsely failing on specialist ''. Only iterate when
# at least one specialist was discovered, and skip any empty id defensively.
if [[ ${#SPECIALIST_IDS[@]} -gt 0 ]]; then
  for _spec_id in "${SPECIALIST_IDS[@]}"; do
    [[ -n "$_spec_id" ]] || continue
    [[ -n "$(specialist_runtime_arn "$_spec_id")" ]] \
      || err "AgentCore runtime ARN for specialist '${_spec_id}' is empty after apply/refresh."
  done
  unset _spec_id
fi

if [[ "$EMBEDDINGS_PROVIDER" == "voyage" ]]; then
  [[ -n "$VOYAGE_ENDPOINT" ]] || err "EMBEDDINGS_PROVIDER=voyage but Terraform output voyage_endpoint_name is empty."

  # Polling wait (replaces the legacy single-shot describe-endpoint check).
  # First-deploy: the endpoint may still be Creating when we land here; the
  # helper retries every 30s up to 900s.
  log "Verifying Voyage endpoint InService (polling)..."
  if ! wait_voyage_endpoint_inservice "$VOYAGE_ENDPOINT"; then
    err "Voyage endpoint '$VOYAGE_ENDPOINT' did not reach InService within 900s.
       Refusing to continue because EMBEDDINGS_PROVIDER=voyage must not silently fall back or write a stale manifest."
  fi
  ok "Voyage endpoint verified InService: $VOYAGE_ENDPOINT"
fi

# Re-read KB ID post-apply (now sourced directly from terraform output —
# the legacy JSON state file at $KB_STATE_FILE is gone since the bedrock-kb
# module migrated to the native aws_bedrockagent_knowledge_base resource).
BEDROCK_KB_ID="$(tfo -raw knowledge_base_id 2>/dev/null || echo "")"

# Build Mongo URI once for both runtime updates and .env.live output.
if [[ -n "$ATLAS_CONNECTION_STRING" ]]; then
  MONGODB_URI="$ATLAS_CONNECTION_STRING"
else
  MONGO_URI_USER="$(urlencode_component "$ATLAS_DB_USER")"
  MONGO_URI_PASSWORD="$(urlencode_component "$TF_VAR_atlas_db_password")"
  MONGODB_URI="mongodb+srv://${MONGO_URI_USER}:${MONGO_URI_PASSWORD}@${ATLAS_MONGO_HOST}/?retryWrites=true&w=majority"
  unset MONGO_URI_USER MONGO_URI_PASSWORD
fi

# Preserve the public-SRV form before Phase 5c rewrites MONGODB_URI to the
# PrivateLink/peering URI. Laptop-side helpers (memory-recall-diagnostic.py,
# scenario tests T1/T3/T9/T10, post-deploy-smoke.py) cannot resolve the
# PrivateLink hostname from outside the VPC and must fall back to the SRV form.
MONGODB_URI_PUBLIC="$MONGODB_URI"

# ── MONGODB_URI sanity: must be non-empty and parsable ───────────────────────
# The legacy code only validated ATLAS_MONGO_HOST. An empty atlas_db_password
# (TF_VAR or merge-conflict) would produce `mongodb+srv://user:@host/...`
# that the Mongo driver rejects with a generic MongoServerSelectionError far
# down the line, obscuring the real cause.
[[ -n "$MONGODB_URI" ]] || err "MONGODB_URI is empty — both atlas_connection_string output and ATLAS_DB_USER/PASSWORD/HOST construction yielded nothing. Check terraform outputs and TF_VAR_atlas_db_password."
if ! [[ "$MONGODB_URI" =~ ^mongodb(\+srv)?://[^:]+:[^@]+@[^/]+/.* ]]; then
  err "MONGODB_URI is malformed (no user:password@host). Did TF_VAR_atlas_db_password leak as empty? Sanitized: $(sanitize_mongo_uri "$MONGODB_URI")"
fi

# ── Atlas cluster IDLE wait (covers the first-deploy race where SRV DNS
#    has not yet propagated when terraform apply returns)
ATLAS_PROJECT_ID_RESOLVED="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
if [[ "$ATLAS_CLUSTER_SOURCE" == "byo" ]]; then
  # BYO: Terraform creates no cluster — the operator's cluster already exists and
  # is running. The synthetic "${PROJECT_NAME}-${ENVIRONMENT}" name doesn't exist
  # in the project, so this poll would spin the full budget then fatally err.
  # Reachability against the REAL SRV URI is still asserted below (Phase 5b).
  # ponytail: the IDLE wait only covers the managed first-deploy DNS race.
  log "Skipping Atlas cluster IDLE wait (BYO cluster '${MONGODB_BYO_CLUSTER_NAME:-operator-managed}' is not Terraform-created; reachability checked at seed gate)"
elif [[ -n "$ATLAS_PROJECT_ID_RESOLVED" && -n "$MONGODB_ATLAS_PUBLIC_KEY" && -n "$MONGODB_ATLAS_PRIVATE_KEY" ]]; then
  CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}"
  log "Waiting for Atlas cluster '$CLUSTER_NAME' to reach IDLE state..."
  CLUSTER_IDLE_BUDGET_S=600
  CLUSTER_IDLE_STARTED=$SECONDS
  CLUSTER_STATE="UNKNOWN"
  while (( SECONDS - CLUSTER_IDLE_STARTED < CLUSTER_IDLE_BUDGET_S )); do
    CLUSTER_RESP="$(curl -sS \
      --user "${MONGODB_ATLAS_PUBLIC_KEY}:${MONGODB_ATLAS_PRIVATE_KEY}" \
      --digest \
      -H "Accept: application/vnd.atlas.2024-08-05+json" \
      "https://cloud.mongodb.com/api/atlas/v2/groups/${ATLAS_PROJECT_ID_RESOLVED}/clusters/${CLUSTER_NAME}" 2>/dev/null || echo '')"
    if [[ -n "$CLUSTER_RESP" ]]; then
      CLUSTER_STATE="$(python3 -c 'import json,sys
try:
  d=json.loads(sys.stdin.read() or "{}")
  print(d.get("stateName", "UNKNOWN"))
except Exception:
  print("UNKNOWN")' <<<"$CLUSTER_RESP" 2>/dev/null || echo "UNKNOWN")"
    fi
    if [[ "$CLUSTER_STATE" == "IDLE" ]]; then
      ok "Atlas cluster IDLE"
      break
    fi
    log "  cluster state: ${CLUSTER_STATE} ($(( SECONDS - CLUSTER_IDLE_STARTED ))s elapsed)"
    sleep 15
  done
  if [[ "$CLUSTER_STATE" != "IDLE" ]]; then
    err "Atlas cluster '$CLUSTER_NAME' did not reach IDLE within ${CLUSTER_IDLE_BUDGET_S}s (last state: ${CLUSTER_STATE})"
  fi
else
  log "Skipping Atlas cluster IDLE wait (Atlas project id or API keys missing)"
fi
unset ATLAS_PROJECT_ID_RESOLVED CLUSTER_RESP CLUSTER_STATE CLUSTER_IDLE_BUDGET_S CLUSTER_IDLE_STARTED

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5b — First-time MongoDB seeding (idempotent)
# Seed demo collections only when core collections are missing/empty.
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 5b — Asserting Atlas reachability before seed gate..."

# REPLACES the legacy probe at deploy-project.sh:899-924 that swallowed all
# errors via `2>/dev/null || echo "yes"`. Now we cleanly separate:
#   - Mongo unreachable → fatal abort with sanitized URI + diagnostic envelope
#   - Mongo reachable but collections empty → SEED_NEEDED=yes
#   - Mongo reachable and collections populated → SEED_NEEDED=no
assert_mongo_reachable "$MONGODB_URI" "$ATLAS_DB_NAME" 300 \
  || err "Mongo reachability assertion failed before Phase 5b seed gate (see diagnostic envelope above)"

log "Checking MongoDB seed state..."
SEED_NEEDED="$(MONGODB_URI="$MONGODB_URI" MONGODB_DB="$ATLAS_DB_NAME" bun -e '
const { MongoClient } = await import(process.env.MONGO_PROBE_DRIVER_SPEC || "mongodb"); // spec from _transient-errors.sh; bare import floats to bson@7.3.0 which crashes under Bun 1.3.13 (see mongo-probe-bun-bson-failure-report.md)
const uri = process.env.MONGODB_URI;
const dbName = process.env.MONGODB_DB;
if (!dbName) { console.error("MONGODB_DB env not set"); process.exit(1); }
const client = new MongoClient(uri, { appName: "deploy-seed-check" });
try {
  await client.connect();
  const db = client.db(dbName);
  const required = ["customers", "products", "orders", "troubleshooting_docs"];
  let seeded = true;
  for (const coll of required) {
    const exists = (await db.listCollections({ name: coll }, { nameOnly: true }).toArray()).length > 0;
    if (!exists) { seeded = false; break; }
    const count = await db.collection(coll).countDocuments();
    if (count === 0) { seeded = false; break; }
  }
  process.stdout.write(seeded ? "no" : "yes");
} finally {
  try { await client.close(); } catch (_) {}
}
')"

if [[ "$SEED_NEEDED" != "yes" && "$SEED_NEEDED" != "no" ]]; then
  err "SEED_NEEDED probe returned unexpected output (this should be unreachable now that connectivity is asserted): '${SEED_NEEDED}'"
fi

if [[ "$SEED_NEEDED" == "yes" ]]; then
  log "Atlas appears unseeded — running first-time seed scripts..."
  (
    cd "$REPO_ROOT"
    MONGODB_URI="$MONGODB_URI" MONGODB_DB="$ATLAS_DB_NAME" bun db-seeding/seed-all.ts
  )
  ok "MongoDB seed complete (seed-all)"
else
  ok "MongoDB already seeded — skipping first-time seed step"
fi

log "Reconciling MongoDB indexes (safe to re-run)..."
(
  cd "$REPO_ROOT"
  MONGODB_URI="$MONGODB_URI" \
    MONGODB_DB="$ATLAS_DB_NAME" \
    WAIT_FOR_ATLAS_SEARCH_INDEXES=1 \
    bun db-seeding/seed-indexes.ts
)
ok "MongoDB indexes verified (seed-indexes)"

# ── Embedding seed (gap-fill semantics; REWIRE auto-detected) ────────────────
# This is the FIX for the long-standing silent gap where production deploys
# never embedded `products` / `troubleshooting_docs`. The helper:
#   - filters seeder-owned rows only (KB chunks are never touched)
#   - auto-stamps embeddingModel on legacy rows
#   - auto-detects REWIRE on provider/dim drift (SSM + in-Mongo fingerprint)
#   - waits for the Voyage SageMaker endpoint when EMBEDDINGS_PROVIDER=voyage
#   - exits non-zero on incomplete results (no more warn-only)
log "Generating embeddings for products + troubleshooting_docs (provider=${EMBEDDINGS_PROVIDER})..."
run_embedding_seed "$ATLAS_DB_NAME" "$MONGODB_URI" \
  || err "Embedding seed failed — refusing to continue (see [embed-seed] envelope above)"
ok "Embedding seed complete"

# ── Centralized preflight checks: post-apply (see docs/deployment-preflight-checks.md) ──
export MONGODB_URI MONGODB_URI_PUBLIC
export MONGODB_DB="$ATLAS_DB_NAME"
# shellcheck source=deploy/scripts/_preflight-checks.sh
source "$SCRIPT_DIR/_preflight-checks.sh"
preflight_validate project-post-apply

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5c — API MongoDB URI normalization
#
# privatelink mode: compute Atlas's awsPrivateLink direct URI (multi-host,
#   tlsAllowInvalidHostnames=true) so the EC2 API avoids SRV DNS edge-cases.
# peering mode: compute the cluster's connectionStrings.private direct
#   multi-host URI. Do not use connectionStrings.privateSrv; SRV/TXT discovery
#   adds cold-path latency. Peering hostnames are in the cluster's TLS SAN list,
#   so NO tlsAllowInvalidHostnames is needed.
#
# Terraform seeds the mongodb-mcp runtime URI at apply time; Phase 6b
# update_mcp_runtime_mongodb_env re-syncs it to this normalized URI.
# ══════════════════════════════════════════════════════════════════════════════
sep
if [[ "$NETWORK_MODE" == "privatelink" ]]; then
  if [[ -z "$ATLAS_PRIVATELINK_ENDPOINT_ID" ]]; then
    err "Missing Atlas PrivateLink endpoint ID for deterministic deploy (privatelink mode)"
  fi
  log "Phase 5c — Computing Atlas awsPrivateLink direct URI for the EC2 API..."
  if API_PRIVATE_URI=$(ATLAS_PROJECT_ID="$TF_VAR_atlas_project_id" \
    CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}" \
    VPCE_ID="$ATLAS_PRIVATELINK_ENDPOINT_ID" \
    BASE_MONGODB_URI="$MONGODB_URI" \
    MONGODB_ATLAS_PUBLIC_KEY="${MONGODB_ATLAS_PUBLIC_KEY:-}" \
    MONGODB_ATLAS_PRIVATE_KEY="${MONGODB_ATLAS_PRIVATE_KEY:-}" \
    python3 - <<'PY'
import json, os, subprocess, urllib.parse
project = os.environ["ATLAS_PROJECT_ID"]
cluster = os.environ["CLUSTER_NAME"]
vpce_id = os.environ["VPCE_ID"]
base_uri = os.environ["BASE_MONGODB_URI"]
public_key = os.environ.get("MONGODB_ATLAS_PUBLIC_KEY", "")
private_key = os.environ.get("MONGODB_ATLAS_PRIVATE_KEY", "")
if not public_key or not private_key:
    raise SystemExit("missing Atlas API keys")
parsed = urllib.parse.urlsplit(base_uri)
user = urllib.parse.quote(urllib.parse.unquote(parsed.username or ""))
pwd = urllib.parse.quote(urllib.parse.unquote(parsed.password or ""))
resp = subprocess.check_output([
    "curl", "-s",
    "--user", f"{public_key}:{private_key}",
    "--digest",
    "-H", "Accept: application/vnd.atlas.2023-01-01+json",
    f"https://cloud.mongodb.com/api/atlas/v2/groups/{project}/clusters/{cluster}",
], text=True)
data = json.loads(resp)
pl_map = ((data.get("connectionStrings") or {}).get("awsPrivateLink") or {})
pl_conn = pl_map.get(vpce_id, "")
if not pl_conn:
    raise SystemExit(f"no awsPrivateLink connection string for endpoint {vpce_id}")
no_scheme = pl_conn.replace("mongodb://", "", 1)
# Atlas's awsPrivateLink direct connection serves a TLS cert whose SAN does
# NOT include the per-region privatelink hostname (pl-X-us-east-1.<id>.mongodb.net),
# so default hostname verification fails with "Hostname/IP does not match
# certificate's altnames". Per Atlas's official PrivateLink docs, callers
# using the direct multi-host privatelink URI must set tlsAllowInvalidHostnames=true.
# CA + chain + expiry verification remain enforced; only the hostname check is
# skipped — acceptable here because the connection traverses an AWS PrivateLink
# (private network, MitM would require an attacker inside our VPC).
print(f"mongodb://{user}:{pwd}@{no_scheme}&retryWrites=true&w=majority&tlsAllowInvalidHostnames=true")
PY
  ); then
    MONGODB_URI="$API_PRIVATE_URI"
    ok "API MongoDB URI normalized to awsPrivateLink direct connection string"
  else
    err "Could not compute Atlas awsPrivateLink URI for the API"
  fi
elif [[ "$NETWORK_MODE" == "public" ]]; then
  # ── public mode ──────────────────────────────────────────────────────────
  # No private URI to compute — the runtime + API use the BYO public SRV URI
  # as-is. MONGODB_URI already holds it (from the atlas_connection_string output).
  log "Phase 5c — public mode: using BYO public SRV URI (no private normalization)"
  ok "API MongoDB URI left as public SRV connection string"
else
  # ── peering mode ───────────────────────────────────────────────────────────
  log "Phase 5c — Computing Atlas peering URI for the EC2 API..."
  if API_PRIVATE_URI=$(ATLAS_PROJECT_ID="$TF_VAR_atlas_project_id" \
    CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}" \
    BASE_MONGODB_URI="$MONGODB_URI" \
    MONGODB_ATLAS_PUBLIC_KEY="${MONGODB_ATLAS_PUBLIC_KEY:-}" \
    MONGODB_ATLAS_PRIVATE_KEY="${MONGODB_ATLAS_PRIVATE_KEY:-}" \
    python3 - <<'PY'
import json, os, subprocess, urllib.parse
project = os.environ["ATLAS_PROJECT_ID"]
cluster = os.environ["CLUSTER_NAME"]
base_uri = os.environ["BASE_MONGODB_URI"]
public_key = os.environ.get("MONGODB_ATLAS_PUBLIC_KEY", "")
private_key = os.environ.get("MONGODB_ATLAS_PRIVATE_KEY", "")
if not public_key or not private_key:
    raise SystemExit("missing Atlas API keys")
parsed = urllib.parse.urlsplit(base_uri)
user = urllib.parse.quote(urllib.parse.unquote(parsed.username or ""))
pwd = urllib.parse.quote(urllib.parse.unquote(parsed.password or ""))
resp = subprocess.check_output([
    "curl", "-s",
    "--user", f"{public_key}:{private_key}",
    "--digest",
    "-H", "Accept: application/vnd.atlas.2023-01-01+json",
    f"https://cloud.mongodb.com/api/atlas/v2/groups/{project}/clusters/{cluster}",
], text=True)
data = json.loads(resp)
conn = (data.get("connectionStrings") or {})
# Require multi-host non-SRV form to match the faster PrivateLink direct URI
# shape and avoid SRV/TXT DNS lookups on cold runtime paths.
priv_multi = conn.get("private") or ""
if priv_multi:
    # mongodb://<authority>[/?...]
    no_scheme = priv_multi.replace("mongodb://", "", 1)
    sep_char = "&" if "?" in no_scheme else "/?"
    # Peering hostnames (*.<id>-pri.mongodb.net) ARE in the cert SAN list — no
    # tlsAllowInvalidHostnames needed (unlike PrivateLink).
    print(f"mongodb://{user}:{pwd}@{no_scheme}{sep_char}retryWrites=true&w=majority")
else:
    raise SystemExit("Atlas cluster has no connectionStrings.private multi-host URI — peering not active yet or Atlas has not populated the private direct URI")
PY
  ); then
    MONGODB_URI="$API_PRIVATE_URI"
    # Sanity check — peering URIs MUST use the private DNS token (-pri).
    # Atlas may emit either legacy (*-pri.mongodb.net) or project-scoped
    # (*-pri.<shard-id>.mongodb.net) hostnames once Private DNS for Peering is on.
    if ! echo "$MONGODB_URI" | grep -qE '\-pri\.'; then
      err "Computed peering URI does not contain '-pri.' (private peering host) — would route over the public SRV. Aborting to preserve privacy parity."
    fi
    ok "API MongoDB URI normalized to peering direct multi-host connection string"
  else
    err "Could not compute Atlas peering direct multi-host URI for the API. Verify the peering connection is ACTIVE and that Atlas has populated connectionStrings.private."
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5d — Cognito test user seeding (idempotent)
# Creates deterministic test users for auth validation, matching seeded orders.
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$COGNITO_SEED_USERS" == "true" ]]; then
  sep
  log "Phase 5d — Seeding Cognito test users..."

  [[ -n "$COGNITO_POOL_ID" ]] || err "cognito_user_pool_id output is empty."
  [[ -n "$COGNITO_CLIENT_ID" ]] || err "cognito_app_client_id output is empty."

  seed_cognito_user() {
    local email="$1"
    local name="$2"
    if aws cognito-idp admin-get-user \
      --region "$AWS_REGION" \
      --user-pool-id "$COGNITO_POOL_ID" \
      --username "$email" >/dev/null 2>&1; then
      :
    else
      aws cognito-idp admin-create-user \
        --region "$AWS_REGION" \
        --user-pool-id "$COGNITO_POOL_ID" \
        --username "$email" \
        --user-attributes "Name=email,Value=${email}" "Name=email_verified,Value=true" "Name=name,Value=${name}" \
        --message-action SUPPRESS >/dev/null \
        || err "Failed to create Cognito user ${email}"
    fi

    aws cognito-idp admin-set-user-password \
      --region "$AWS_REGION" \
      --user-pool-id "$COGNITO_POOL_ID" \
      --username "$email" \
      --password "$COGNITO_TEST_PASSWORD" \
      --permanent >/dev/null \
      || err "Failed setting deterministic password for Cognito user ${email}"
  }

  IFS=',' read -r -a COGNITO_TEST_USERS <<<"$COGNITO_TEST_USERS_CSV"
  for email in "${COGNITO_TEST_USERS[@]}"; do
    e_trimmed="$(echo "$email" | xargs)"
    [[ -n "$e_trimmed" ]] || continue
    case "$e_trimmed" in
      alex@example.com)  seed_cognito_user "$e_trimmed" "Alex Rivera" ;;
      blake@example.com) seed_cognito_user "$e_trimmed" "Blake Chen" ;;
      casey@example.com) seed_cognito_user "$e_trimmed" "Casey Morgan" ;;
      *)                 seed_cognito_user "$e_trimmed" "Demo User" ;;
    esac
  done
  ok "Cognito users ready: ${COGNITO_TEST_USERS_CSV}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — Build + push Docker images (API + UI = amd64; agent-runtime = arm64)
# ══════════════════════════════════════════════════════════════════════════════
sep
if [[ "$SKIP_DOCKER" == "true" ]]; then
  warn "Phase 6 — Skipping Docker build/push (--skip-docker)"
else
  log "Phase 6 — Building and pushing Docker images to ECR..."
  # docker-build-push.sh signature:
  #   <api_repo> <ui_repo> <aws_region> [agent_runtime_repo] [mongodb_mcp_runtime_repo]
  # mongodb-mcp runtime image is rebuilt here so any code changes between Phase 4d
  # and Phase 6 (rare in normal runs) land before the runtime updates in Phase 7.
  if [[ "$AGENTCORE_RUNTIME_DEPLOYMENT_MODE" == "container" ]]; then
    "$SCRIPT_DIR/docker-build-push.sh" "$ECR_API_REPO" "$ECR_UI_REPO" "$AWS_REGION" "$ECR_RUNTIME_REPO" "$ECR_MCP_RUNTIME_REPO"
  else
    "$SCRIPT_DIR/docker-build-push.sh" "$ECR_API_REPO" "$ECR_UI_REPO" "$AWS_REGION" "" "$ECR_MCP_RUNTIME_REPO"
  fi
  ok "Images pushed to ECR"
fi

ECR_API_IMAGE="${ECR_API_REPO}:latest"
ECR_UI_IMAGE="${ECR_UI_REPO}:latest"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6b — Update AgentCore runtimes with dynamic env vars
# Terraform creates static env vars; now inject dynamic vars (MongoDB URI, KB ID,
# Gateway URL, Memory ID). Orchestrator additionally gets specialist runtime ARNs.
# ══════════════════════════════════════════════════════════════════════════════
if [[ -n "$AGENTCORE_ORCHESTRATOR_ID" ]]; then
  sep
  log "Phase 6b — Updating AgentCore Runtime environment variables..."

  if [[ -z "${AGENTCORE_GATEWAY_URL:-}" ]]; then
    err "AGENTCORE_GATEWAY_URL is empty. Provision the AgentCore Gateway first (terraform apply)."
  fi
  # Agent runtimes must use Gateway for MCP traffic. The MongoDB MCP runtime
  # ARN/endpoint are infrastructure wiring for the Gateway target only and are
  # intentionally not injected into application runtimes.

  # Strict-mode embeddings: only export EMBEDDING_MODEL_ID for titan stacks.
  # `_agents-common.sh::build_dynamic_env_base` reads EMBEDDING_MODEL_ID via
  # `os.environ.get(..., '')` and the heredoc's `if v` filter drops empty
  # values, so voyage stacks ship AgentCore runtimes without any Bedrock
  # fallback model id present in the runtime env.
  if [[ "$EMBEDDINGS_PROVIDER" == "titan" ]]; then
    export EMBEDDING_MODEL_ID="${EMBEDDING_MODEL_ID:-amazon.titan-embed-text-v2:0}"
  else
    unset EMBEDDING_MODEL_ID
  fi

  export AWS_REGION MONGODB_URI ATLAS_DB_NAME BEDROCK_KB_ID \
         AGENTCORE_MEMORY_STORE_ID AGENTCORE_GATEWAY_URL \
         VOYAGE_ENDPOINT EMBEDDINGS_PROVIDER \
         AGENTCORE_RUNTIME_DEPLOYMENT_MODE SHARED_BUCKET AGENTCORE_CODE_ARTIFACT_PREFIX \
         ECR_RUNTIME_REPO

  build_dynamic_env_base
  update_runtime_env_dynamic

  if [[ -n "${MONGODB_MCP_RUNTIME_ARN:-}" ]]; then
    update_mcp_runtime_mongodb_env "${MONGODB_MCP_RUNTIME_ARN##*/}" "$MONGODB_URI" "$ATLAS_DB_NAME"
  fi

  log "Phase 6c — Verifying runtime environment variables..."
  verify_runtime_env_dynamic
  ok "Runtime env verification passed"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 7 — Write .env.docker (Docker --env-file) + .env.live (bash-source)
#           + copy both to EC2 via SSM. systemd unit files on EC2 reference
#           /opt/multiagent/.env.docker (modules/ec2/user_data.sh); .env.live
#           is the bash-source-safe sibling for laptop dev + SSM debugging.
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 7 — Writing .env.docker + .env.live and copying to EC2 via SSM..."
ensure_agent_config_refresh_token

if [[ -n "$VOYAGE_ENDPOINT" ]]; then
  # Best-effort: derive the model package id from VOYAGE_MODEL_PACKAGE_ARN
  # so the .env.live banner doesn't lie about which Voyage variant is live.
  # Example ARN tail: model-package/voyage-3-5-lite-9e7d9de9...
  VOYAGE_MODEL_LABEL="unknown"
  VOYAGE_MODEL_TAIL="${VOYAGE_MODEL_PACKAGE_ARN##*/}"
  if [[ "$VOYAGE_MODEL_TAIL" =~ ^(.+)-[0-9a-f]{8,}$ ]]; then
    VOYAGE_MODEL_LABEL="${BASH_REMATCH[1]}"
  fi
  EMBEDDING_LINE="Voyage AI ${VOYAGE_MODEL_LABEL} (${VOYAGE_ENDPOINT})"
else
  EMBEDDING_LINE="Bedrock Titan (amazon.titan-embed-text-v2:0)"
fi

# Strict-mode embeddings (api/src/lib/embed-query.ts):
# In voyage stacks, EMBEDDING_MODEL_ID must NOT be present in the env files —
# its mere presence used to enable a silent Bedrock fallback when Voyage
# stuttered, which produced `embeddingModel: amazon.titan-embed-text-v2:0`
# rows in `chat_messages` / `agent_memory_facts`. The runtime now refuses to
# fall back, but we strip the env var here as defense in depth so a
# misconfigured runtime can never even attempt Bedrock.
if [[ "$EMBEDDINGS_PROVIDER" == "titan" ]]; then
  EMBEDDING_MODEL_ID_LINE="EMBEDDING_MODEL_ID=amazon.titan-embed-text-v2:0"
else
  EMBEDDING_MODEL_ID_LINE="# EMBEDDING_MODEL_ID intentionally omitted — strict ${EMBEDDINGS_PROVIDER} mode (no Bedrock fallback)"
fi

# Shared writer for `.env.docker` (Docker --env-file, canonical) + `.env.live`
# (bash-source-safe variant). Both files go to $REPO_ROOT and are pushed to
# /opt/multiagent/ on EC2 by sync_env_live_to_ec2 below.
# shellcheck source=deploy/scripts/_env-live.sh
source "$SCRIPT_DIR/_env-live.sh"
write_env_live_files "deploy-project.sh"
ok ".env.docker + .env.live written"

wait_for_instance_status_ok "$EC2_INSTANCE_ID"
wait_for_ssm_online "$EC2_INSTANCE_ID"

# Wait for cloud-init/bootstrap completion marker.
BOOTSTRAP_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: check bootstrap marker" \
  '["test -f /opt/multiagent/.bootstrap-done && echo yes || echo no"]' \
  24) || err "Could not send bootstrap-check command via SSM"

wait_for_ssm_command_success "$BOOTSTRAP_CMD_ID" "$EC2_INSTANCE_ID" 36 \
  || err "Bootstrap check command failed on EC2"

BOOTSTRAP_OUT=$(aws ssm get-command-invocation \
  --region "$AWS_REGION" \
  --command-id "$BOOTSTRAP_CMD_ID" \
  --instance-id "$EC2_INSTANCE_ID" \
  --query "StandardOutputContent" --output text 2>/dev/null || echo "no")
if [[ "$BOOTSTRAP_OUT" != *"yes"* ]]; then
  err "EC2 bootstrap marker not found at /opt/multiagent/.bootstrap-done"
fi
ok "EC2 bootstrap marker detected"

# ── CloudWatch Agent readiness ────────────────────────────────────────────────
# The amazon-cloudwatch-agent service must be active and a log stream must be
# created in /<project>/<env>/api within 60 s of API restart, otherwise journald
# logs are never shipped to CloudWatch. We probe both before continuing.
log "Verifying amazon-cloudwatch-agent is active on EC2..."
CWA_STATUS_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: cw-agent status" \
  '["systemctl is-active amazon-cloudwatch-agent || true"]' \
  12) || warn "Failed to send cw-agent status command via SSM"

if [[ -n "$CWA_STATUS_CMD_ID" ]]; then
  wait_for_ssm_command_success "$CWA_STATUS_CMD_ID" "$EC2_INSTANCE_ID" 12 || true
  CWA_STATUS_OUT=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$CWA_STATUS_CMD_ID" \
    --instance-id "$EC2_INSTANCE_ID" \
    --query "StandardOutputContent" --output text 2>/dev/null || echo "unknown")
  CWA_STATUS_OUT="$(echo "$CWA_STATUS_OUT" | tr -d '[:space:]')"
  if [[ "$CWA_STATUS_OUT" == "active" ]]; then
    ok "amazon-cloudwatch-agent is active"
  else
    warn "amazon-cloudwatch-agent reported '${CWA_STATUS_OUT:-unknown}' (continuing; CloudWatch shipping may be delayed)"
  fi
fi

# ── Centralized preflight checks: pre-env-sync (see docs/deployment-preflight-checks.md) ──
export MONGODB_URI MONGODB_MCP_RUNTIME_ARN AGENTCORE_GATEWAY_URL
export MONGODB_MCP_RUNTIME_ID="${MONGODB_MCP_RUNTIME_ARN##*/}"
# shellcheck source=deploy/scripts/_preflight-checks.sh
source "$SCRIPT_DIR/_preflight-checks.sh"
preflight_validate project-pre-env-sync

# Copy via SSM Session Manager — no SSH key required.
log "Copying .env.docker + .env.live to EC2 ($EC2_INSTANCE_ID) via SSM..."
sync_env_live_to_ec2 "$EC2_INSTANCE_ID" \
  || err "env-file sync to EC2 failed"
ok ".env.docker + .env.live synced to /opt/multiagent/ on $EC2_INSTANCE_ID"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 8 — Restart services on EC2 + ECR docker login
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 8 — Pulling images + restarting services on EC2..."

# Interface endpoints use private DNS for ECR/Logs. If the endpoint security
# group drifts and no longer allows a consumer SG, calls resolve privately and
# then time out. Repair that ingress here as a deploy-time guardrail; Terraform's
# null_resource authorizer is idempotent but cannot detect manually removed SG
# rules after its state has already recorded success.
EC2_VPC_ID="$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$EC2_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].VpcId' \
  --output text)"
EC2_SECURITY_GROUP_IDS="$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$EC2_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' \
  --output text)"
MONGODB_MCP_RUNTIME_ID="${MONGODB_MCP_RUNTIME_ARN##*/}"
MONGODB_MCP_RUNTIME_SECURITY_GROUP_IDS="$(aws bedrock-agentcore-control get-agent-runtime \
  --region "$AWS_REGION" \
  --agent-runtime-id "$MONGODB_MCP_RUNTIME_ID" \
  --query 'networkConfiguration.networkModeConfig.securityGroups[]' \
  --output text 2>/dev/null || true)"
ENDPOINT_CONSUMER_SECURITY_GROUP_IDS="$(printf "%s\n%s\n" \
  "$EC2_SECURITY_GROUP_IDS" \
  "$MONGODB_MCP_RUNTIME_SECURITY_GROUP_IDS" | tr '\t' '\n' | sort -u)"
AWS_ENDPOINT_SECURITY_GROUP_IDS="$(aws ec2 describe-vpc-endpoints \
  --region "$AWS_REGION" \
  --filters \
    "Name=vpc-id,Values=${EC2_VPC_ID}" \
    "Name=service-name,Values=com.amazonaws.${AWS_REGION}.ecr.api,com.amazonaws.${AWS_REGION}.ecr.dkr,com.amazonaws.${AWS_REGION}.logs" \
  --query 'VpcEndpoints[].Groups[].GroupId' \
  --output text | tr '\t' '\n' | sort -u)"
if [[ -n "$AWS_ENDPOINT_SECURITY_GROUP_IDS" && "$AWS_ENDPOINT_SECURITY_GROUP_IDS" != "None" ]]; then
  for endpoint_sg_id in $AWS_ENDPOINT_SECURITY_GROUP_IDS; do
    for source_sg_id in $ENDPOINT_CONSUMER_SECURITY_GROUP_IDS; do
      [[ -n "$source_sg_id" && "$source_sg_id" != "None" ]] || continue
      OUT=$(aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$endpoint_sg_id" \
        --protocol tcp \
        --port 443 \
        --source-group "$source_sg_id" 2>&1) || {
        if [[ "$OUT" != *"InvalidPermission.Duplicate"* ]]; then
          echo "$OUT" >&2
          err "Failed to allow consumer SG $source_sg_id to reach AWS endpoint SG $endpoint_sg_id"
        fi
      }
    done
  done
  ok "ECR/Logs VPC endpoint ingress allows EC2 host and MongoDB MCP runtime"
fi

# Single SSM command: ECR login, pull latest images, restart API + UI containers.
# --skip-docker only skips local build/push; a replaced EC2 host still needs
# ECR auth and image pulls from the already-published tags.
ECR_REGISTRY=$(echo "$ECR_API_REPO" | cut -d'/' -f1)
# Retry the remote ECR login + image pulls (the network-facing steps) so a
# transient DNS resolver / network blip on the EC2 host does not abort the
# restart. The `ok` flag gates the restart so an exhausted retry budget still
# fails the SSM command instead of restarting against a stale/missing image.
RESTART_CMD="ok=0; for i in 1 2 3 4; do aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY} \
  && docker pull ${ECR_API_IMAGE} \
  && docker pull ${ECR_UI_IMAGE} \
  && ok=1 && break; echo ecr-login-pull attempt \$i failed, retrying in 10s; sleep 10; done; \
  [ \$ok -eq 1 ] && systemctl daemon-reload && systemctl restart multiagent-api multiagent-ui"

RESTART_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: pull images + restart services" \
  "[\"${RESTART_CMD//\"/\\\"}\"]" \
  12) || err "Failed to send restart command via SSM"
wait_for_ssm_command_success "$RESTART_CMD_ID" "$EC2_INSTANCE_ID" 36 \
  || err "EC2 service restart command failed"
ok "Restart command completed"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 9 — Health check + summary
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Waiting for API health check..."
HEALTH_OK="no"
API_HEALTH_MAX_ATTEMPTS=120
for i in $(seq 1 "$API_HEALTH_MAX_ATTEMPTS"); do
  if curl -sf --max-time 10 "http://${EC2_IP}:3000/health" > /dev/null 2>&1; then
    ok "API is healthy"
    HEALTH_OK="yes"
    break
  fi
  log "  Waiting ($i/${API_HEALTH_MAX_ATTEMPTS})..."
  sleep 5
done
if [[ "$HEALTH_OK" != "yes" ]]; then
  warn "Public /health probe timed out; verifying API health from inside EC2 via SSM..."
  HEALTH_SSM_CMD_ID=$(send_ssm_command_retry \
    "$EC2_INSTANCE_ID" \
    "multiagent: api health local probe" \
    '["curl -sf --max-time 10 http://127.0.0.1:3000/health >/dev/null && echo ok || echo fail"]' \
    12) || err "Failed to send local API health check via SSM"
  wait_for_ssm_command_success "$HEALTH_SSM_CMD_ID" "$EC2_INSTANCE_ID" 24 \
    || err "Local API health SSM command failed"
  HEALTH_SSM_OUT=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$HEALTH_SSM_CMD_ID" \
    --instance-id "$EC2_INSTANCE_ID" \
    --query "StandardOutputContent" --output text 2>/dev/null || echo "fail")
  [[ "$HEALTH_SSM_OUT" == *"ok"* ]] || err "API health check did not pass in time"
  ok "API is healthy (verified via EC2 local probe)"
fi

# ── CloudWatch Logs streams probe ────────────────────────────────────────────
# EC2 ships /var/log/multiagent-api.log via amazon-cloudwatch-agent (file tail).
# Nudge the agent after API restart so PutLogEvents creates the {instance_id} stream.
if [[ -n "${CW_API_LOG_GROUP:-}" ]]; then
  log "Nudging CloudWatch agent after API restart..."
  CW_NUDGE_CMD_ID=$(send_ssm_command_retry \
    "$EC2_INSTANCE_ID" \
    "multiagent: nudge cw-agent log shipping" \
    '["curl -sf --max-time 10 http://127.0.0.1:3000/health >/dev/null 2>&1 || true; systemctl restart amazon-cloudwatch-agent; sleep 3"]' \
    12) || warn "Failed to send CloudWatch agent nudge via SSM"
  if [[ -n "${CW_NUDGE_CMD_ID:-}" ]]; then
    wait_for_ssm_command_success "$CW_NUDGE_CMD_ID" "$EC2_INSTANCE_ID" 12 || true
  fi

  log "Probing CloudWatch log streams in ${CW_API_LOG_GROUP}..."
  CW_STREAMS_OK="no"
  for i in $(seq 1 24); do
    CW_STREAM_NAME=$(aws logs describe-log-streams \
      --region "$AWS_REGION" \
      --log-group-name "$CW_API_LOG_GROUP" \
      --order-by LastEventTime \
      --descending \
      --max-items 1 \
      --query 'logStreams[0].logStreamName' --output text 2>/dev/null || echo "")
    CW_STREAM_NAME="${CW_STREAM_NAME%%$'\n'*}"
    if [[ -n "$CW_STREAM_NAME" && "$CW_STREAM_NAME" != "None" && "$CW_STREAM_NAME" != "null" ]]; then
      CW_STREAMS_OK="yes"
      break
    fi
    sleep 5
  done
  if [[ "$CW_STREAMS_OK" == "yes" ]]; then
    ok "CloudWatch agent is shipping API logs (${CW_API_LOG_GROUP}, stream=${CW_STREAM_NAME})"
  else
    warn "No log streams found in ${CW_API_LOG_GROUP} after 120s — check /var/log/multiagent-api.log and systemctl status amazon-cloudwatch-agent on EC2."
  fi
fi

sep
# Obtain SMOKE_ID_TOKEN BEFORE Phase 9a2 so the /health probe can be
# authenticated. With a valid JWT the API populates the `mcpServer` key (real
# MCP transport status). Without it, /health returns mcpServer omitted which
# is the source of the original "deploy succeeded but Mongo not connected" gap.
log "Phase 9a1 — Acquiring Cognito JWT for authenticated smoke probes..."
SMOKE_ID_TOKEN=$(aws cognito-idp initiate-auth \
  --region "$AWS_REGION" \
  --client-id "$COGNITO_CLIENT_ID" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=${COGNITO_SMOKE_USER_EMAIL},PASSWORD=${COGNITO_TEST_PASSWORD}" \
  --query "AuthenticationResult.IdToken" \
  --output text 2>/dev/null || echo "")
[[ -n "$SMOKE_ID_TOKEN" && "$SMOKE_ID_TOKEN" != "None" ]] || err "Could not obtain Cognito IdToken for smoke user ${COGNITO_SMOKE_USER_EMAIL}"

sep
log "Phase 9a2 — Authenticated /health dependency smoke (mongodb + agentcore + mcpServer must report 'connected')..."
HEALTH_PAYLOAD=$(curl -sf --max-time 10 \
  -H "Authorization: Bearer $SMOKE_ID_TOKEN" \
  "http://${EC2_IP}:3000/health" 2>/dev/null || echo "")
if [[ -n "$HEALTH_PAYLOAD" ]]; then
  python3 - "$HEALTH_PAYLOAD" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
deps = payload.get("dependencies", {})
required = {
    # Atlas: must be connected (we just seeded data there).
    "mongodb": "connected",
    # AgentCore Memory Store: probe must classify "Actor not found"
    # for the synthetic health-probe actor as `connected` — the API
    # round-trip succeeded, IAM is fine, the memory store exists.
    # If this regresses to `unreachable`, somebody dropped the
    # `ResourceNotFoundException` + `/actor/i` carve-out in
    # api/src/lib/health-status.ts.
    "agentcore": "connected",
    # MCP transport (Gateway URL, IAM, Gateway target schema cache). Phase 9a2
    # is now AUTHENTICATED so this key is populated. Escalated from warn to
    # err — the original deploy regression (`mongoQueries == 0` in Phase 9b)
    # would have been caught here if /health were authenticated.
    "mcpServer": "connected",
}
mismatches = []
for key, want in required.items():
    got = deps.get(key)
    if got != want:
        mismatches.append(f"  {key}: want={want}  got={got}")
if mismatches:
    raise SystemExit(
        "Phase 9a2 failed — /health reported wrong dependency status.\n"
        "Full /health payload:\n"
        + json.dumps(payload, indent=2)
        + "\nMismatches:\n" + "\n".join(mismatches)
    )
print("  /health dependencies all 'connected' as expected (mongodb, agentcore, mcpServer)")
PY
  ok "Authenticated /health dependency smoke passed"
else
  err "/health probe returned no body — refusing to continue"
fi

sep
log "Phase 9a3 — Direct MCP tool probe (/health/deep mongodb_query via Gateway)..."
# This catches end-to-end MCP path failures (Gateway target wiring, MCP runtime
# MONGODB_URI, Atlas connectivity from inside the MCP runtime) BEFORE the
# LLM-dependent Phase 9b smoke. mcpProbe must equal "connected" — anything
# else (unreachable / timeout) fails the deploy with a precise diagnosis.
#
# Bounded retry: Gateway IAM propagation can take 60-90s after a new target.
# 3 attempts × 30s between tries. If all 3 attempts fail, we make one extra
# attempt AFTER trying to self-heal a FAILED gateway target in-place (see the
# `self_heal_failed_gateway_target` helper in _agents-common.sh). The self-heal
# step exists because Terraform's `null_resource.mcp_server_gateway_target`
# only re-runs its delete+recreate logic when its triggers change (image
# digest, endpoint, name) — so a target that turned FAILED during this apply
# stays FAILED until the next apply unless we recover it here.
HEALTH_DEEP_RETRY_MAX=3
HEALTH_DEEP_RETRY_DELAY=30
HEALTH_DEEP_PAYLOAD=""
HEALTH_DEEP_HTTP_CODE=""
HEALTH_DEEP_PROBE=""
HEALTH_DEEP_LAST_ERROR=""
HEALTH_DEEP_ATTEMPT=0
HEALTH_DEEP_HEAL_TRIED="no"

# Local helper — runs ONE /health/deep probe and updates the shared vars
# (HEALTH_DEEP_HTTP_CODE / HEALTH_DEEP_PAYLOAD / HEALTH_DEEP_PROBE /
# HEALTH_DEEP_LAST_ERROR). 404 is fatal here (stale API image). Returns 0 if
# mcpProbe came back "connected", non-zero otherwise. Bumps
# HEALTH_DEEP_ATTEMPT so the post-loop diagnostic line counts every probe
# (bounded retry + post-heal re-probe) consistently.
_phase_9a3_probe_once() {
  HEALTH_DEEP_ATTEMPT=$(( HEALTH_DEEP_ATTEMPT + 1 ))
  local raw
  raw=$(curl -s --max-time 15 -o /tmp/health-deep.body -w "%{http_code}" \
    -H "Authorization: Bearer $SMOKE_ID_TOKEN" \
    "http://${EC2_IP}:3000/health/deep" 2>/dev/null || echo "000")
  HEALTH_DEEP_HTTP_CODE="$raw"
  HEALTH_DEEP_PAYLOAD="$(cat /tmp/health-deep.body 2>/dev/null || true)"
  if [[ "$HEALTH_DEEP_HTTP_CODE" == "404" ]]; then
    err "/health/deep returned 404 — running API image is missing this route (stale container or --skip-docker). Rebuild and redeploy: ./deploy/deploy-api.sh"
  fi
  if [[ -z "$HEALTH_DEEP_PAYLOAD" ]]; then
    HEALTH_DEEP_PROBE=""
    HEALTH_DEEP_LAST_ERROR="empty response body (http=${HEALTH_DEEP_HTTP_CODE})"
    return 1
  fi
  HEALTH_DEEP_PROBE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('mcpProbe',''))" "$HEALTH_DEEP_PAYLOAD" 2>/dev/null || echo "")
  HEALTH_DEEP_LAST_ERROR="http=${HEALTH_DEEP_HTTP_CODE} mcpProbe=${HEALTH_DEEP_PROBE:-<unparseable>}"
  [[ "$HEALTH_DEEP_PROBE" == "connected" ]]
}

while (( HEALTH_DEEP_ATTEMPT < HEALTH_DEEP_RETRY_MAX )); do
  if _phase_9a3_probe_once; then
    break
  fi
  if (( HEALTH_DEEP_ATTEMPT < HEALTH_DEEP_RETRY_MAX )); then
    log "  attempt ${HEALTH_DEEP_ATTEMPT}/${HEALTH_DEEP_RETRY_MAX} failed (${HEALTH_DEEP_LAST_ERROR}); retrying in ${HEALTH_DEEP_RETRY_DELAY}s (Gateway IAM propagation typically takes 60-90s)..."
    sleep "$HEALTH_DEEP_RETRY_DELAY"
  fi
done

if [[ -z "$HEALTH_DEEP_PAYLOAD" ]]; then
  err "/health/deep probe returned no body after ${HEALTH_DEEP_RETRY_MAX} attempts — refusing to continue"
fi

# Self-heal attempt: bounded retry exhausted and mcpProbe is still not
# "connected". If the gateway target is stuck in FAILED, recreate it in-place
# and probe once more. See `self_heal_failed_gateway_target` for return codes.
if [[ "$HEALTH_DEEP_PROBE" != "connected" ]]; then
  HEALTH_DEEP_HEAL_TRIED="yes"
  log "Phase 9a3 — bounded retry exhausted; attempting in-place gateway target self-heal..."
  if [[ -z "${AGENTCORE_GATEWAY_ID:-}" ]]; then
    warn "AGENTCORE_GATEWAY_ID unset (load_tf_outputs miss) — skipping self-heal"
  elif [[ -z "${MONGODB_MCP_RUNTIME_ENDPOINT:-}" ]]; then
    warn "MONGODB_MCP_RUNTIME_ENDPOINT unset — skipping self-heal"
  else
    HEAL_RC=0
    self_heal_failed_gateway_target \
      "$AGENTCORE_GATEWAY_ID" \
      "mongodb-mcp" \
      "$MONGODB_MCP_RUNTIME_ENDPOINT" \
      || HEAL_RC=$?
    case "$HEAL_RC" in
      0)
        log "Phase 9a3 — gateway target healed; re-probing /health/deep once..."
        _phase_9a3_probe_once || true
        ;;
      2)
        log "Phase 9a3 — gateway target is healthy; probe failure is from a different cause (skipping re-probe)"
        ;;
      3)
        log "Phase 9a3 — gateway target is mid-flight (CREATING/UPDATING); waiting 30s + one more probe..."
        sleep 30
        _phase_9a3_probe_once || true
        ;;
      *)
        warn "Phase 9a3 — self-heal did not recover the gateway target (rc=${HEAL_RC}); falling through to fatal diagnostic"
        ;;
    esac
    unset HEAL_RC
  fi
fi
unset -f _phase_9a3_probe_once

python3 - "$HEALTH_DEEP_PAYLOAD" "$HEALTH_DEEP_ATTEMPT" "$HEALTH_DEEP_RETRY_MAX" "$HEALTH_DEEP_HEAL_TRIED" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
attempts = sys.argv[2]
retry_max = sys.argv[3]
heal_tried = sys.argv[4] == "yes"
probe = payload.get("mcpProbe")
if probe != "connected":
    heal_note = (
        "  The deploy already attempted an in-place self-heal of the gateway target\n"
        "  (delete + recreate); that did not fix it, so the remaining causes are:\n"
    ) if heal_tried else (
        "  Self-heal was NOT attempted (AGENTCORE_GATEWAY_ID or MCP_RUNTIME_ENDPOINT\n"
        "  missing from Terraform outputs). The likely causes are:\n"
    )
    raise SystemExit(
        f"Phase 9a3 failed — /health/deep MCP probe did not return 'connected' after {attempts} attempts (bounded retry budget {retry_max}{', + self-heal' if heal_tried else ''}).\n"
        "Diagnosis: the API can reach the AgentCore Gateway but the gateway-routed\n"
        "  mongodb_query tool did not succeed.\n"
        + heal_note +
        "    1. mongodb-mcp runtime's MONGODB_URI wrong / env wiped by partial Phase 6b\n"
        "       → ./deploy/deploy-agents.sh --auto-approve\n"
        "    2. mongodb-mcp runtime cannot actually reach Atlas (PrivateLink / SG misconfig)\n"
        "       → check runtime CloudWatch logs at /multiagent/${ENVIRONMENT:-dev}/mcp\n"
        "    3. Gateway role IAM trust still propagating beyond the retry+heal budget\n"
        "       → wait 60s and re-run deploy-project.sh\n"
        "Full payload:\n" + json.dumps(payload, indent=2)
    )
print(f"  /health/deep mcpProbe=connected latencyMs={payload.get('latencyMs')} gatewayUrl={payload.get('gatewayUrl')} attempts={attempts}/{retry_max}")
PY
ok "Direct MCP tool probe passed"

sep
log "Phase 9b — Deterministic backend smoke validation..."
SMOKE_SESSION_ID="deploy-smoke-$(date +%s)"
EC2_API_URL="http://${EC2_IP}:3000"
BACKEND_SMOKE_SCRIPT="${SCRIPT_DIR}/backend-smoke.py"

python3 "$BACKEND_SMOKE_SCRIPT" \
  --api-url "$EC2_API_URL" \
  --session-id "$SMOKE_SESSION_ID" \
  --id-token "$SMOKE_ID_TOKEN" \
  --check-session-user
ok "Backend smoke validation passed"

sep
ok "EC2 deployment complete!"
echo ""
echo "  API        : ${EC2_API}"
echo "  UI         : ${EC2_UI}"
echo "  EC2 IP     : ${EC2_IP}"
echo "  Shell      : ${EC2_SSM}"
echo ""
echo "  Atlas      : ${ATLAS_MONGO_HOST}"
echo "  Bedrock KB : ${BEDROCK_KB_ID:-not yet provisioned}"
echo "  Embedding  : ${VOYAGE_ENDPOINT:-Titan amazon.titan-embed-text-v2:0}"
echo "  AgentCore  : memory=${AGENTCORE_MEMORY_STORE_ID:-?}"
echo "               gateway=${AGENTCORE_GATEWAY_URL:-?}"
echo "  Tools/MCP  : MongoDB tools via AgentCore Gateway ${AGENTCORE_GATEWAY_URL:-?}"
echo "               Gateway target runtime ${MONGODB_MCP_RUNTIME_ARN:-?}"
echo "  Auth       : Cognito JWKS required (no bypass)"
echo "               Cognito users=${COGNITO_TEST_USERS_CSV}"
echo "               Password=${COGNITO_TEST_PASSWORD}"
echo ""
echo "  Logs       : aws ssm start-session --target ${EC2_INSTANCE_ID} --region ${AWS_REGION}"
echo "               then: journalctl -u multiagent-api -f"
echo ""
echo "  For local dev: ./deploy/scripts/deploy-local.sh"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 10 — Write resource manifest
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 10 — Writing resource manifest..."
MANIFEST_FILE="$REPO_ROOT/deploy-manifest.json"

export _MANIFEST_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
export _M_ACCOUNT="$ACCOUNT_ID"  _M_REGION="$AWS_REGION"   _M_ENV="$ENVIRONMENT"
export _M_BUCKET="$SHARED_BUCKET" _M_KB="$BEDROCK_KB_ID"
export _M_EC2_IP="$EC2_IP"        _M_EC2_ID="$EC2_INSTANCE_ID"
export _M_EC2_API="$EC2_API"      _M_EC2_UI="$EC2_UI"
export _M_COGNITO_POOL="$COGNITO_POOL_ID" _M_COGNITO_CLIENT="$COGNITO_CLIENT_ID"
# Titan stacks must not advertise a Voyage endpoint in the manifest — the shared
# stack may still provision SageMaker, but post-deploy smoke treats a non-empty
# voyage_sagemaker_endpoint as "Voyage is active".
if [[ "$EMBEDDINGS_PROVIDER" == "titan" ]]; then
  export _M_VOYAGE=""
else
  export _M_VOYAGE="$VOYAGE_ENDPOINT"
fi
export _M_EMBEDDINGS_PROVIDER="$EMBEDDINGS_PROVIDER"
export _M_EMBEDDINGS_MODEL="$EMBEDDINGS_MODEL_ID"
export _M_EMBEDDINGS_VOYAGE_MULTIMODAL="$EMBEDDINGS_VOYAGE_MULTIMODAL"
export _M_ECR_API="$ECR_API_REPO"  _M_ECR_UI="$ECR_UI_REPO"
export _M_AC_MEM="$AGENTCORE_MEMORY_STORE_ID" _M_AC_GW="$AGENTCORE_GATEWAY_URL" _M_MCP_RUNTIME_ARN="$MONGODB_MCP_RUNTIME_ARN" _M_MCP_RUNTIME_ENDPOINT="$MONGODB_MCP_RUNTIME_ENDPOINT"
export _M_ATLAS_PROJ="$TF_VAR_atlas_project_id" _M_ATLAS_HOST="$ATLAS_MONGO_HOST"
export _M_TOOL_MODE="hybrid"
export _M_KB_SECRET_NAME="${PROJECT_NAME}-bedrock-kb-creds-${ENVIRONMENT}"
# Capture how this deploy authenticated so post-deploy smoke / audit tooling
# can detect a stale manifest (deploy ran under a different principal than
# the current sts:GetCallerIdentity). validate_aws_auth populates the
# AWS_AUTH_* exports earlier in Phase 1.
export _M_AUTH_MODE="${AWS_AUTH_MODE:-${AUTH_MODE:-iam}}"
export _M_AUTH_CALLER_ARN="${AWS_AUTH_CALLER_ARN:-$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo unknown)}"
# Connectivity mode + KB connectivity for post-deploy smoke / dashboards.
export _M_NETWORK_MODE="$NETWORK_MODE"
export _M_ATLAS_PEERING_CIDR="${ATLAS_PEERING_CIDR:-}"
export _M_ATLAS_PEERING_CONN_ID="$(tfo -raw atlas_peering_connection_id 2>/dev/null || echo "")"
export _M_KB_CONNECTIVITY_MODE="$(tfo -raw kb_connectivity_mode 2>/dev/null || echo "")"

python3 - <<'PYEOF' > "$MANIFEST_FILE"
import json, os
def v(k): return os.environ.get(k, "")
manifest = {
  "generated_at":  v("_MANIFEST_TS"),
  "mode":          "ec2",
  "script":        "deploy.sh",
  "aws_account":   v("_M_ACCOUNT"),
  "aws_region":    v("_M_REGION"),
  "environment":   v("_M_ENV"),
  "network": {
    "mode":                     v("_M_NETWORK_MODE"),
    "atlas_peering_cidr":       v("_M_ATLAS_PEERING_CIDR"),
    "atlas_peering_conn_id":    v("_M_ATLAS_PEERING_CONN_ID"),
    "kb_connectivity_mode":     v("_M_KB_CONNECTIVITY_MODE"),
  },
  "auth": {
    "mode":        v("_M_AUTH_MODE"),
    "caller_arn":  v("_M_AUTH_CALLER_ARN"),
  },
  "resources": {
    "s3_state_bucket":            v("_M_BUCKET"),
    "bedrock_kb_id":              v("_M_KB"),
    "secrets_manager_secret":     v("_M_KB_SECRET_NAME"),
    "ec2_instance_id":            v("_M_EC2_ID"),
    "ec2_public_ip":              v("_M_EC2_IP"),
    "ec2_api_url":                v("_M_EC2_API"),
    "ec2_ui_url":                 v("_M_EC2_UI"),
    "cognito_user_pool_id":       v("_M_COGNITO_POOL"),
    "cognito_client_id":          v("_M_COGNITO_CLIENT"),
    "voyage_sagemaker_endpoint":  v("_M_VOYAGE"),
    "embeddings_provider":        v("_M_EMBEDDINGS_PROVIDER"),
    "embeddings_model":           v("_M_EMBEDDINGS_MODEL"),
    "embeddings_voyage_multimodal":     v("_M_EMBEDDINGS_VOYAGE_MULTIMODAL") == "true",
    "ecr_api_repo":               v("_M_ECR_API"),
    "ecr_ui_repo":                v("_M_ECR_UI"),
    "agentcore_memory_id":        v("_M_AC_MEM"),
    "agentcore_gateway_url":      v("_M_AC_GW"),
    "agentcore_gateway_target":   "reserved for non-Mongo Gateway-hosted tools",
    "mongodb_mcp_runtime_arn":    v("_M_MCP_RUNTIME_ARN"),
    "mongodb_mcp_runtime_endpoint": v("_M_MCP_RUNTIME_ENDPOINT"),
    "atlas_project_id":           v("_M_ATLAS_PROJ"),
    "atlas_srv_host":             v("_M_ATLAS_HOST"),
    "tool_hosting_mode":          v("_M_TOOL_MODE"),
    "mcp_server":                 "MongoDB MCP direct AgentCore Runtime; other tools via AgentCore Gateway",
  }
}
print(json.dumps(manifest, indent=2))
PYEOF
ok "Resource manifest written: $MANIFEST_FILE"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 11 — Full post-deploy smoke (all agents, LTM, CloudWatch join, …)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_SMOKE" == "true" ]]; then
  warn "Phase 11 — Skipping full post-deploy smoke (--skip-smoke)"
else
  sep
  log "Phase 11 — Full post-deploy smoke (e2e-smoke/post-deploy-smoke.py)..."
  log "  NOTE: ~5–8 min — all four agents, LTM recall, Terraform/manifest parity, CloudWatch trace join."
  POST_DEPLOY_SMOKE="$REPO_ROOT/e2e-smoke/post-deploy-smoke.py"
  [[ -f "$POST_DEPLOY_SMOKE" ]] || err "post-deploy smoke script not found: $POST_DEPLOY_SMOKE"

  E2E_USER="${COGNITO_SMOKE_USER_EMAIL}" \
  E2E_PASS="${COGNITO_TEST_PASSWORD}" \
  DEPLOY_MANIFEST_PATH="$MANIFEST_FILE" \
  python3 "$POST_DEPLOY_SMOKE"
  ok "Full post-deploy smoke passed"
fi
sep
