#!/usr/bin/env bash
# deploy-local.sh — Full local deployment
#
# Usage:
#   ./deploy/scripts/deploy-local.sh [--auto-approve] [--skip-seed] [--env-file <path>]
#
# What it does:
#   Phase 1 — Validate prerequisites (aws, terraform, bun, python3)
#   Phase 2 — Source .env, verify AWS + Atlas credentials
#   Phase 3 — Bootstrap shared S3 bucket + DynamoDB lock table (once)
#   Phase 4 — Generate backend.hcl + terraform.tfvars (local mode: no EC2, no Voyage AI)
#   Phase 5 — terraform apply:
#               • MongoDB Atlas M10 cluster + user + IP allowlist
#               • Bedrock Knowledge Base (Titan embeddings)
#               • Cognito User Pool
#               • Secrets Manager (Atlas creds for KB)
#               • S3 (KB docs + TF state)
#   Phase 6 — Write .env.live (Atlas URI from terraform output, Titan embeddings)
#   Phase 7 — Seed MongoDB (data + Titan embeddings + vector indexes)
#   Phase 8 — Start API (Hono/Bun :3000) and UI (Streamlit :8501) locally
#
# Embedding: Bedrock Titan (EMBEDDING_MODEL_ID) — no SageMaker needed
# EC2:       Not created — app runs on localhost
#
# For EC2 + Voyage AI deployment: ./deploy/deploy-full-with-privatelink.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_ROOT="$REPO_ROOT/deploy/terraform"
TF_DIR="$TF_ROOT/envs/local"
BOOTSTRAP_DIR="$TF_ROOT/bootstrap"
LOG_DIR="$REPO_ROOT/logs"

ENV_FILE="$REPO_ROOT/.env"
AUTO_APPROVE=false
SKIP_SEED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve) AUTO_APPROVE=true ;;
    --skip-seed)    SKIP_SEED=true ;;
    --env-file)     ENV_FILE="$2"; shift ;;
    *) echo "  [local] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo "  [local] $*"; }
ok()   { echo "  [local] ✓ $*"; }
err()  { echo "  [local] ✗ $*" >&2; exit 1; }
sep()  { echo "────────────────────────────────────────────────"; }
warn() { echo "  [local] ⚠ $*"; }

# Shared helpers — used by Phase 7 (seed) and the post-apply preflight gate.
# shellcheck source=deploy/scripts/_mongo-connect.sh
source "$SCRIPT_DIR/_mongo-connect.sh"
# shellcheck source=deploy/scripts/_seed-embeddings.sh
source "$SCRIPT_DIR/_seed-embeddings.sh"

# Wrap `terraform apply` with retry-on-transient-Atlas-API-error. The MongoDB
# Atlas control plane (cloud.mongodb.com) occasionally returns i/o timeouts
# or connection-resets that vanish on the next call. We retry the apply up to
# `max_attempts - 1` times, re-planning between attempts so the saved plan
# stays consistent with the post-partial-apply state. Any non-transient error
# is treated as a hard failure and stops the script immediately.
apply_with_retry() {
  local plan_file="$1"
  local max_attempts=3   # initial + 2 retries
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
    if grep -qE 'cloud\.mongodb\.com.*(i/o timeout|connection reset|connection refused|EOF|TLS handshake timeout)' "$log_file"; then
      warn "Transient Atlas API error detected on attempt ${attempt} — will retry"
      attempt=$((attempt + 1))
      continue
    fi
    rm -f "$log_file"
    err "terraform apply failed with a non-transient error (see output above)"
  done
  rm -f "$log_file"
  err "terraform apply failed after ${max_attempts} attempts — transient Atlas API errors did not clear"
}

mkdir -p "$LOG_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Prerequisites
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 1 — Checking prerequisites..."
for cmd in aws terraform bun python3; do
  command -v "$cmd" &>/dev/null || err "'$cmd' not found in PATH"
done
ok "All prerequisites found"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Load credentials
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 2 — Loading credentials from $ENV_FILE..."
[[ -f "$ENV_FILE" ]] || err "env file not found: $ENV_FILE"
source "$ENV_FILE"

# ── Required variables — ALL must be set in .env, no silent defaults ──────
# AWS auth is checked separately below because there are three valid modes
# (static IAM user keys, STS env vars with AWS_SESSION_TOKEN, or AWS_PROFILE),
# and a single hard list cannot express the "one of these credential blocks
# must be present" rule.
_REQUIRED_VARS=(
  AWS_REGION
  ENVIRONMENT
  PROJECT_NAME
  ATLAS_DB_USER
  ATLAS_DB_NAME
  MONGODB_ATLAS_PUBLIC_KEY
  MONGODB_ATLAS_PRIVATE_KEY
  TF_VAR_atlas_project_id
  TF_VAR_atlas_db_password
)
_missing=()
for _v in "${_REQUIRED_VARS[@]}"; do
  [[ -n "${!_v:-}" ]] || _missing+=("$_v")
done
if [[ ${#_missing[@]} -gt 0 ]]; then
  err "The following required variables are not set in .env — add them before running:
$(printf '    %s\n' "${_missing[@]}")"
fi

# AWS credentials — delegated to the shared AUTH_MODE-aware validator.
# Mode is controlled by AUTH_MODE in .env (defaults to "iam" for backward compat).
DEPLOY_DIAG_LABEL="local"
# shellcheck source=deploy/scripts/_deploy-diagnostics.sh
source "$SCRIPT_DIR/_deploy-diagnostics.sh"
deploy_diag_install_error_trap

# shellcheck source=deploy/scripts/_aws-auth.sh
source "$SCRIPT_DIR/_aws-auth.sh"
validate_aws_auth || err "AWS auth validation failed (see above)"
deploy_diag_checkpoint "aws auth validated; deploy-local has no centralized preflight profile"
deploy_diag_auth_context "$ENV_FILE"
ok "All required variables present (region=$AWS_REGION, env=$ENVIRONMENT, project=$PROJECT_NAME)"
ACCOUNT_ID="$AWS_AUTH_ACCOUNT_ID"
ok "AWS account: $ACCOUNT_ID"
ok "Atlas project: $TF_VAR_atlas_project_id"

# ── Atlas API key validation ────────────────────────────────────────────────
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
# PHASE 4 — Generate Terraform config (local mode)
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 4 — Generating Terraform config (local mode: Atlas + Bedrock KB + Cognito)..."

cat > "$TF_DIR/backend.hcl" <<EOF
bucket  = "${SHARED_BUCKET}"
key     = "${ENVIRONMENT}/terraform.tfstate"
region  = "${AWS_REGION}"
encrypt = true
# dynamodb_table omitted — SCP on this AWS account blocks DynamoDB CreateTable.
# Single-user POC: no distributed locking needed.
EOF
ok "backend.hcl written"

# KB ID is now a native terraform output (aws_bedrockagent_knowledge_base.this.id);
# read it from the existing state if any, otherwise it will be populated post-apply.
BEDROCK_KB_ID="$(cd "$TF_DIR" && terraform output -raw knowledge_base_id 2>/dev/null || echo "")"
[[ -n "$BEDROCK_KB_ID" ]] && log "Existing KB found: $BEDROCK_KB_ID" || log "KB will be created on apply"

cat > "$TF_DIR/terraform.tfvars" <<EOF
# Local mode — generated by deploy-local.sh
# Scope: Atlas (public endpoint) + Bedrock KB + CloudWatch.
# No VPC, no EC2, no Cognito, no Lambda/AgentCore, no Voyage — those live in envs/ec2.
aws_region         = "${AWS_REGION}"
environment        = "${ENVIRONMENT}"
project_name       = "${PROJECT_NAME}"
shared_bucket_name = "${SHARED_BUCKET}"

# MongoDB Atlas (cluster provisioned by Terraform)
atlas_project_id = "${TF_VAR_atlas_project_id}"
atlas_db_user    = "${ATLAS_DB_USER}"
atlas_db_name    = "${ATLAS_DB_NAME}"
# atlas_db_password → TF_VAR_atlas_db_password (sensitive)
# atlas_public_key  → TF_VAR_atlas_public_key  (sensitive)
# atlas_private_key → TF_VAR_atlas_private_key (sensitive)

# Bedrock KB — Titan embeddings
# kb_iam_role_name is intentionally left to the bedrock-kb module default
# (`${var.project_name}-bedrock-kb-${var.environment}-role`) so the role name
# is unique per (project, env) and multiple deployments can share an account.
embed_model_id   = "amazon.titan-embed-text-v2:0"
EOF
ok "terraform.tfvars written (local mode — Atlas + Bedrock KB + CloudWatch)"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — Terraform apply (Atlas + Bedrock KB + Cognito + Secrets + S3)
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 5 — terraform init..."
cd "$TF_DIR"
deploy_diag_terraform_context "local terraform init" "$TF_DIR" "$TF_DIR/backend.hcl" "$TF_DIR/.tfplan"
deploy_diag_checkpoint "terraform init start: terraform init -input=false -reconfigure -backend-config=${TF_DIR}/backend.hcl"
terraform init -input=false -reconfigure -backend-config="$TF_DIR/backend.hcl"
ok "init complete"

log "Running terraform plan..."
deploy_diag_checkpoint "terraform plan start: terraform plan -input=false -out=${TF_DIR}/.tfplan"
terraform plan -input=false -out="$TF_DIR/.tfplan"
ok "plan complete"

sep
log "NOTE: MongoDB Atlas M10 cluster creation takes ~5-10 minutes on first apply."

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

# Read outputs — hard-fail if any required output is missing
ATLAS_MONGO_HOST=$(terraform output -raw atlas_mongo_host 2>/dev/null || echo "")
CW_API_LOG_GROUP=$(terraform output -raw cloudwatch_api_log_group 2>/dev/null || echo "")
[[ -n "$ATLAS_MONGO_HOST" ]] || err "atlas_mongo_host not in terraform outputs — apply may have failed"
[[ -n "$CW_API_LOG_GROUP" ]] || err "cloudwatch_api_log_group not in terraform outputs — check envs/local/outputs.tf"

# Re-read KB ID now that apply has run (native terraform output)
BEDROCK_KB_ID="$(terraform output -raw knowledge_base_id 2>/dev/null || echo "")"
[[ -n "$BEDROCK_KB_ID" ]] && ok "Bedrock KB: $BEDROCK_KB_ID" || warn "KB ID not found — terraform output knowledge_base_id is empty"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — Write .env.live
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 6 — Writing .env.live (local mode: Titan embeddings, AgentCore Gateway)..."

MONGODB_URI="mongodb+srv://${ATLAS_DB_USER}:${TF_VAR_atlas_db_password}@${ATLAS_MONGO_HOST}/?retryWrites=true&w=majority"

cat > "$REPO_ROOT/.env.live" <<EOF
# Local mode — generated by deploy-local.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Embedding: Bedrock Titan Embed v2 (no SageMaker needed)
# Tools:     AgentCore Gateway (set AGENTCORE_GATEWAY_URL before running the API)
export ORCHESTRATOR_MODE=swarm

# MongoDB Atlas (provisioned by Terraform)
export MONGODB_URI="${MONGODB_URI}"
export MONGODB_DB="${ATLAS_DB_NAME}"
export MONGODB_ALLOW_WRITE=true

# Bedrock
export BEDROCK_KB_ID="${BEDROCK_KB_ID}"
export AWS_REGION="${AWS_REGION}"

# Embedding: Titan (local mode — VOYAGE_SAGEMAKER_ENDPOINT intentionally not
# set). Strict mode requires EMBEDDINGS_PROVIDER to be set explicitly — empty
# values now throw at API boot. See `api/src/lib/assert-embeddings-provider.ts`.
export EMBEDDINGS_PROVIDER="titan"
export EMBEDDING_MODEL_ID="amazon.titan-embed-text-v2:0"

# Tool hosting: production-style — every Mongo tool call is served by the
# AgentCore Gateway. Provision it via terraform first and export
# AGENTCORE_GATEWAY_URL + AGENTCORE_ORCHESTRATOR_ARN before starting the API.
export AGENTCORE_GATEWAY_URL=""
export MCP_SERVER_URL=""

# CloudWatch (log group created by Terraform; app may or may not stream here locally)
export CLOUDWATCH_LOG_GROUP="${CW_API_LOG_GROUP}"

# Cognito — JWKS auth is required (api/src/lib/jwt-verify.ts assertJwksAuthConfigured()).
# Provision the dev Cognito pool and export AUTH_JWKS_URI / AUTH_ISSUER before running the API.
export AUTH_JWKS_URI=""
export AUTH_ISSUER=""

# CORS + local URLs
export CORS_ORIGINS="http://localhost:8501,http://127.0.0.1:8501"
export STREAMLIT_API_URL="http://127.0.0.1:3000/"
export PORT=3000
export RATE_LIMIT_PER_MIN=60
EOF
ok ".env.live written"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 7 — Seed MongoDB (data + Titan embeddings + vector indexes)
# ══════════════════════════════════════════════════════════════════════════════
sep
if [[ "$SKIP_SEED" == "true" ]]; then
  warn "Phase 7 — Seeding skipped (--skip-seed)"
else
  log "Phase 7 — Seeding MongoDB Atlas..."

  cd "$REPO_ROOT"
  export MONGODB_URI="$MONGODB_URI"
  export MONGODB_DB="$ATLAS_DB_NAME"
  export AWS_REGION="$AWS_REGION"
  export PATH="$HOME/.bun/bin:$PATH"

  # deploy-local.sh defaults to the Bedrock Titan provider — the laptop path
  # does NOT provision the Voyage SageMaker endpoint. Operators who want
  # voyage on the local path must run deploy-shared.sh first.
  export EMBEDDINGS_PROVIDER="${EMBEDDINGS_PROVIDER:-titan}"
  export EMBEDDING_MODEL_ID="${EMBEDDING_MODEL_ID:-amazon.titan-embed-text-v2:0}"
  # Embedding dim is a code constant (VOYAGE_EMBEDDING_DIMS) — no env override.

  log "Seeding collections (customers, products, orders, troubleshooting, indexes)..."
  bun db-seeding/seed-all.ts \
    || err "seed-all failed — re-run: bun db-seeding/seed-all.ts"
  ok "Collections seeded"

  log "Reconciling vector + BM25 indexes..."
  WAIT_FOR_ATLAS_SEARCH_INDEXES=1 bun db-seeding/seed-indexes.ts \
    || err "seed-indexes failed"
  ok "Indexes reconciled"

  log "Generating embeddings (provider=${EMBEDDINGS_PROVIDER})..."
  run_embedding_seed "$ATLAS_DB_NAME" "$MONGODB_URI" \
    || err "Embedding seed failed — see [embed-seed] envelope above"
  ok "Embeddings generated"

  # Post-apply preflight gate: same embedding + index + KB checks as production,
  # minus the AgentCore-runtime-specific ones (no runtime, no Gateway here).
  # shellcheck source=deploy/scripts/_preflight-checks.sh
  source "$SCRIPT_DIR/_preflight-checks.sh"
  preflight_validate local-post-apply \
    || err "local-post-apply preflight failed — see envelope above"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 8 — Start API + UI locally
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 8 — Starting API and UI locally..."

# Kill any existing processes
lsof -ti:3000 | xargs kill -9 2>/dev/null || true
lsof -ti:8501 | xargs kill -9 2>/dev/null || true
sleep 1

# Load env — deploy-local.sh writes .env.live in `export KEY="value"` form
# (bash-source-safe), so direct `source` works here. The EC2 path uses a
# separate Docker-format file (.env.docker) — see deploy/scripts/_env-live.sh.
source "$REPO_ROOT/.env.live"
export PATH="$HOME/.bun/bin:$PATH"

# Install API deps
log "Installing API dependencies..."
cd "$REPO_ROOT/api" && bun install --silent

# Local mode always runs tools in-process — no MCP sidecar, no AgentCore Gateway.
# Gateway-routed tools live in the ec2 env (deploy-project.sh).

# Start API
log "Starting API (Hono/Bun :3000)..."
nohup bun run dev > "$LOG_DIR/api.log" 2>&1 &
echo $! > "$LOG_DIR/api.pid"
ok "API started (PID $(cat $LOG_DIR/api.pid)) — logs: logs/api.log"

sleep 2

# Start UI
log "Starting UI (Streamlit :8501)..."
cd "$REPO_ROOT"
VENV_STREAMLIT="${HOME}/.venvs/multiagent-ui/bin/streamlit"
if [[ -x "$VENV_STREAMLIT" ]]; then
  STREAMLIT_BIN="$VENV_STREAMLIT"
else
  STREAMLIT_BIN="$(command -v streamlit 2>/dev/null || python3 -m streamlit)"
fi
nohup $STREAMLIT_BIN run ui/app.py --server.headless true --server.port 8501 \
  > "$LOG_DIR/ui.log" 2>&1 &
echo $! > "$LOG_DIR/ui.pid"
ok "UI started (PID $(cat $LOG_DIR/ui.pid)) — logs: logs/ui.log"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 9 — E2E Verification (Playwright troubleshooting spec)
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 9 — Running E2E verification (troubleshooting.spec.ts)..."
log "Waiting 10s for services to be fully ready..."
sleep 10

E2E_DIR="$REPO_ROOT/e2e"
cd "$E2E_DIR"

# Install e2e deps if needed
bun install --silent 2>/dev/null || true

# Ensure Playwright browsers are installed
bunx playwright install chromium --with-deps 2>/dev/null || true

log "Running troubleshooting spec..."
if bunx playwright test troubleshooting.spec.ts --reporter=list 2>&1 | tee "$LOG_DIR/e2e.log"; then
  ok "All E2E tests passed"
else
  E2E_EXIT=$?
  warn "Some E2E tests failed (exit code $E2E_EXIT) — check logs/e2e.log for details"
  echo ""
  echo "  Failed tests summary:"
  grep -E "FAILED|✗|×" "$LOG_DIR/e2e.log" | head -10 || true
fi

sep
ok "Local deployment complete!"
echo ""
echo "  API : http://localhost:3000"
echo "  UI  : http://localhost:8501"
echo ""
echo "  Atlas cluster : ${ATLAS_MONGO_HOST}"
echo "  Bedrock KB    : ${BEDROCK_KB_ID}"
echo "  Embedding     : Titan (amazon.titan-embed-text-v2:0)"
echo "  Tool hosting  : direct (in-process)"
echo ""
echo "  Logs  : tail -f logs/api.log"
echo "  Stop  : kill \$(cat logs/api.pid) \$(cat logs/ui.pid)"
echo ""
echo "  For EC2 + Voyage AI: ./deploy/deploy-full-with-privatelink.sh"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 10 — Write resource manifest JSON
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 10 — Writing resource manifest..."
MANIFEST_FILE="$REPO_ROOT/deploy-manifest.json"

export _MANIFEST_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
export _M_ACCOUNT="$ACCOUNT_ID"  _M_REGION="$AWS_REGION"   _M_ENV="$ENVIRONMENT"
export _M_BUCKET="$SHARED_BUCKET" _M_KB="$BEDROCK_KB_ID"
export _M_ATLAS_PROJ="$TF_VAR_atlas_project_id" _M_ATLAS_HOST="${ATLAS_MONGO_HOST:-}"
export _M_KB_SECRET_NAME="${PROJECT_NAME}-bedrock-kb-creds-${ENVIRONMENT}"
export _M_API_PID="$(cat $LOG_DIR/api.pid 2>/dev/null || echo '')"
export _M_UI_PID="$(cat $LOG_DIR/ui.pid 2>/dev/null || echo '')"

python3 - <<'PYEOF' > "$MANIFEST_FILE"
import json, os
def v(k): return os.environ.get(k, "")
manifest = {
  "generated_at":  v("_MANIFEST_TS"),
  "mode":          "local",
  "script":        "deploy-local.sh",
  "aws_account":   v("_M_ACCOUNT"),
  "aws_region":    v("_M_REGION"),
  "environment":   v("_M_ENV"),
  "resources": {
    "s3_state_bucket":        v("_M_BUCKET"),
    "bedrock_kb_id":          v("_M_KB"),
    "secrets_manager_secret": v("_M_KB_SECRET_NAME"),
    "embedding_model":        "amazon.titan-embed-text-v2:0",
    "atlas_project_id":       v("_M_ATLAS_PROJ"),
    "atlas_cluster_host":     v("_M_ATLAS_HOST"),
    "tool_hosting_mode":      "direct",
  },
  "local_processes": {
    "api_pid":  v("_M_API_PID"),
    "ui_pid":   v("_M_UI_PID"),
    "api_url":  "http://localhost:3000",
    "ui_url":   "http://localhost:8501",
  }
}
print(json.dumps(manifest, indent=2))
PYEOF
ok "Resource manifest written: $MANIFEST_FILE"
sep
