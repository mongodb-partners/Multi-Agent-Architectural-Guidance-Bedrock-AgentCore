#!/usr/bin/env bash
# deploy-agents.sh — agent-only redeploy (no infra changes).
#
# Usage:
#   ./deploy/deploy-agents.sh [--auto-approve] [--allow-destroy] [--force]
#                             [--env-file <path>] [--skip-smoke]
#
# What it does:
#   Phase 1  — Validate prerequisites (aws, terraform, bun, python3, zip)
#   Phase 2  — Source .env, verify AWS credentials
#   Phase 3  — Discover agents from config/agents/*.agent.md
#              Validate orchestrator handoff consistency
#   Phase 4  — Write agents.auto.tfvars.json; guard against running before deploy.sh
#   Phase 5  — Build + upload code artifact (bun → JS → zip → S3)
#   Phase 6  — terraform init + targeted apply (acr_specialists + acr_orchestrator)
#              Destroy-safety check: require explicit confirmation when agents are removed
#   Phase 7  — Load terraform outputs (specialist ARNs/IDs, orchestrator ID, etc.)
#   Phase 8  — Inject dynamic env vars into all runtimes; verify them
#   Phase 9  — Refresh API agent config cache (no API restart)
#   Phase 10 — Agent smoke test (optional, requires EC2 API reachable)
#   Phase 11 — Write deploy-manifest.agents.json
#
# What it does NOT do:
#   × Build or push API/UI Docker images
#   × Restart multiagent-api / multiagent-ui on EC2
#   × Write or push .env.live
#   × Seed MongoDB or Cognito
#   × Touch network / bootstrap / Atlas / KB infrastructure
#
# Prerequisites:
#   deploy.sh must have been run at least once (backend.hcl + prior tf state required).
#
# Flags:
#   --auto-approve   Pass -auto-approve to terraform apply (still prompts when destroys detected)
#   --allow-destroy  Skip the extra confirmation when specialists are being deleted
#   --force          Skip orchestrator handoff-consistency check (use with care)
#   --skip-smoke     Skip the Phase 9 agent smoke test
#   --env-file PATH  Path to env file (default: repo-root/.env)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_SH="$REPO_ROOT/deploy/scripts/_agents-common.sh"
TF_ROOT="$REPO_ROOT/deploy/terraform"
TF_DIR="$TF_ROOT/envs/ec2"
ENV_FILE="$REPO_ROOT/.env"
AUTO_APPROVE=false
ALLOW_DESTROY=false
FORCE=false
SKIP_SMOKE=false
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve)  AUTO_APPROVE=true ;;
    --allow-destroy) ALLOW_DESTROY=true ;;
    --force)         FORCE=true ;;
    --skip-smoke)    SKIP_SMOKE=true ;;
    --env-file)      ENV_FILE="$2"; shift ;;
    *) echo "  [agents] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo "  [agents] $*"; }
ok()   { echo "  [agents] ✓ $*"; }
err()  { echo "  [agents] ✗ $*" >&2; exit 1; }
warn() { echo "  [agents] ⚠ $*"; }
sep()  { echo "────────────────────────────────────────────────"; }

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Prerequisites
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 1 — Checking prerequisites..."
for cmd in aws terraform bun python3 zip curl; do
  command -v "$cmd" &>/dev/null || err "'$cmd' not found in PATH"
done
[[ -f "$COMMON_SH" ]] || err "Shared helper not found: $COMMON_SH — run from the repo root."

# Source the shared helper (provides discover_agents, write_specialist_agents_tfvars, etc.)
# shellcheck source=deploy/scripts/_agents-common.sh
source "$COMMON_SH"
# shellcheck source=deploy/scripts/_voyage-config.sh
source "$REPO_ROOT/deploy/scripts/_voyage-config.sh"
ok "All prerequisites found"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Load credentials
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 2 — Loading credentials from $ENV_FILE..."
[[ -f "$ENV_FILE" ]] || err "env file not found: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

DEPLOY_DIAG_LABEL="agents"
# shellcheck source=deploy/scripts/_deploy-diagnostics.sh
source "$SCRIPT_DIR/scripts/_deploy-diagnostics.sh"
deploy_diag_install_error_trap

# shellcheck source=deploy/scripts/_aws-auth.sh
source "$SCRIPT_DIR/scripts/_aws-auth.sh"
validate_aws_auth || err "AWS auth validation failed (see above)"
ACCOUNT_ID="$AWS_AUTH_ACCOUNT_ID"

# ── Centralized preflight checks (see docs/deployment-preflight-checks.md) ──
# shellcheck source=deploy/scripts/_preflight-checks.sh
source "$SCRIPT_DIR/scripts/_preflight-checks.sh"
preflight_validate agents
deploy_diag_after_preflight "agents" "$ENV_FILE"

ok "AWS account: $ACCOUNT_ID"

SHARED_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-${ACCOUNT_ID}"
GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
AGENTCORE_RUNTIME_DEPLOYMENT_MODE="${AGENTCORE_RUNTIME_DEPLOYMENT_MODE:-code}"
AGENTCORE_CODE_ARTIFACT_PREFIX="artifacts/agentcore-runtime/${GIT_SHA}/deployment_package.zip"

# EMBEDDINGS_PROVIDER is required (used by update_runtime_env_dynamic → base env)
EMBEDDINGS_PROVIDER="${EMBEDDINGS_PROVIDER:-}"
case "$EMBEDDINGS_PROVIDER" in
  voyage|titan) ;;
  "") err "EMBEDDINGS_PROVIDER is not set. Set 'voyage' or 'titan' in .env." ;;
  *)  err "EMBEDDINGS_PROVIDER='$EMBEDDINGS_PROVIDER' is not recognised. Use 'voyage' or 'titan'." ;;
esac
export EMBEDDINGS_PROVIDER

VOYAGE_ENDPOINT="${VOYAGE_ENDPOINT:-$(terraform -chdir="$TF_DIR" output -raw voyage_endpoint_name 2>/dev/null || true)}"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Discover agents + validate handoff consistency
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 3 — Discovering agents from config/agents/..."
discover_agents   # sets AGENTS_JSON, ORCHESTRATOR_ID, SPECIALIST_IDS[], SPECIALIST_IDS_JSON

if [[ "$FORCE" == "true" ]]; then
  validate_handoff_consistency "warn"
else
  validate_handoff_consistency "fail"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — Write tfvars; guard against missing prior state
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 4 — Preparing Terraform config..."

# Refuse to run if no prior state exists — the operator must bootstrap with deploy.sh first.
if [[ ! -f "$TF_DIR/backend.hcl" ]]; then
  err "backend.hcl not found at $TF_DIR — run deploy.sh first to initialise the Terraform state."
fi
if [[ ! -f "$REPO_ROOT/deploy-manifest.json" ]]; then
  err "deploy-manifest.json not found — run deploy.sh first to bootstrap the full stack."
fi

write_specialist_agents_tfvars   # writes agents.auto.tfvars.json

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — Build + upload code artifact
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 5 — Building + uploading AgentCore code artifact..."
build_and_upload_code_artifact

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — terraform init + targeted apply
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 6 — terraform init..."
cd "$TF_DIR"
deploy_diag_terraform_context "agents terraform init" "$TF_DIR" "$TF_DIR/backend.hcl" "$TF_DIR/.tfplan-agents"
deploy_diag_checkpoint "terraform init start: terraform init -input=false -reconfigure -backend-config=${TF_DIR}/backend.hcl -no-color"
terraform init -input=false -reconfigure -backend-config="$TF_DIR/backend.hcl" -no-color
ok "init complete"

log "Phase 6 — terraform plan (targeting agent runtime modules)..."
AGENT_TF_TARGETS=(
  -target=module.acr_specialists
  -target=module.acr_orchestrator
)
deploy_diag_checkpoint "terraform plan start: terraform plan -input=false ${AGENT_TF_TARGETS[*]} -out=${TF_DIR}/.tfplan-agents"
terraform plan -input=false "${AGENT_TF_TARGETS[@]}" -out="$TF_DIR/.tfplan-agents"
ok "plan complete"

# ── Destroy-safety check ──────────────────────────────────────────────────────
# Parse the plan JSON for any acr_specialists resource marked for deletion.
if command -v python3 &>/dev/null; then
  PLANNED_DESTROYS=$(terraform show -json "$TF_DIR/.tfplan-agents" 2>/dev/null | python3 -c "
import json, sys
try:
    plan = json.load(sys.stdin)
except Exception:
    sys.exit(0)
destroyed = []
for change in (plan.get('resource_changes') or []):
    actions = change.get('change', {}).get('actions', [])
    addr    = change.get('address', '')
    if 'delete' in actions and 'acr_specialists' in addr:
        destroyed.append(addr)
if destroyed:
    print('\n'.join(destroyed))
" 2>/dev/null || true)

  if [[ -n "$PLANNED_DESTROYS" ]]; then
    warn "The plan will DESTROY the following specialist runtime(s):"
    echo "$PLANNED_DESTROYS" | while IFS= read -r addr; do
      warn "  $addr"
    done
    if [[ "$ALLOW_DESTROY" != "true" ]]; then
      echo ""
      echo "  This is a destructive, irreversible operation."
      echo "  Type 'yes, destroy' to confirm, or Ctrl-C to cancel:"
      read -r CONFIRM_DESTROY
      [[ "$CONFIRM_DESTROY" == "yes, destroy" ]] || err "Cancelled — no runtimes were destroyed."
    else
      warn "--allow-destroy set — skipping destroy confirmation"
    fi
  fi
fi

sep
if [[ "$AUTO_APPROVE" == "true" ]]; then
  log "Applying (--auto-approve)..."
  apply_with_retry "$TF_DIR/.tfplan-agents" "${AGENT_TF_TARGETS[@]}"
else
  echo ""
  read -r -p "  Apply agent runtime changes? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Cancelled."; exit 0; }
  apply_with_retry "$TF_DIR/.tfplan-agents" "${AGENT_TF_TARGETS[@]}"
fi
ok "Terraform apply complete"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 7 — Load terraform outputs
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 7 — Loading terraform outputs..."

# Read scalar outputs (these exist even after the for_each refactor via legacy named outputs).
AGENTCORE_ORCHESTRATOR_ID=$(terraform output -raw acr_orchestrator_id 2>/dev/null || echo "")
AGENTCORE_ORCHESTRATOR_ARN=$(terraform output -raw acr_orchestrator_arn 2>/dev/null || echo "")
AGENTCORE_MEMORY_STORE_ID=$(terraform output -raw agentcore_memory_id 2>/dev/null || echo "")
AGENTCORE_GATEWAY_URL=$(terraform output -raw agentcore_gateway_url 2>/dev/null || echo "")
MONGODB_MCP_RUNTIME_ARN=$(terraform output -raw mongodb_mcp_runtime_arn 2>/dev/null || echo "")
ECR_RUNTIME_REPO=$(terraform output -raw ecr_agent_runtime_repository_url 2>/dev/null || echo "")
BEDROCK_KB_ID=$(terraform output -raw knowledge_base_id 2>/dev/null || echo "")

# Read map outputs for specialists.
load_specialist_outputs_from_tf

# Re-read from deploy-manifest.json for Atlas + EC2 values not in tf outputs above.
ATLAS_DB_NAME=$(python3 -c "import json; m=json.load(open('$REPO_ROOT/deploy-manifest.json')); print(m.get('resources',{}).get('atlas_db_name',''))" 2>/dev/null || echo "")
if [[ -z "$ATLAS_DB_NAME" ]]; then
  # Fallback: derive from project+env convention
  _P="${PROJECT_NAME//-/_}"
  ATLAS_DB_NAME="${_P}_${ENVIRONMENT}"
  unset _P
fi

# Agent-only deploys must reuse the canonical Docker env file generated by a
# full/API deploy. Do not fall back to `.env.live`: it is bash-source-safe and
# may contain quotes that must never be copied into AgentCore Runtime env vars.
MONGODB_URI=""
if [[ -f "$REPO_ROOT/.env.docker" ]]; then
  while IFS='=' read -r key value; do
    if [[ "$key" == "MONGODB_URI" ]]; then
      MONGODB_URI="$value"
      break
    fi
  done < "$REPO_ROOT/.env.docker"
fi
if [[ -z "$MONGODB_URI" ]]; then
  err "Could not read MONGODB_URI from .env.docker. Refusing to update runtime env vars because update-agent-runtime replaces the whole environment map. Run a full/API deploy to regenerate .env.docker, then rerun deploy-agents.sh."
fi
if [[ "$MONGODB_URI" == \"* || "$MONGODB_URI" == \'* ]]; then
  err "MONGODB_URI in .env.docker appears quoted; .env.docker must be raw Docker --env-file format. Regenerate it with deploy-project.sh/deploy-api.sh."
fi

[[ -n "$AGENTCORE_ORCHESTRATOR_ID" ]] || err "acr_orchestrator_id output is empty — run deploy.sh first."
[[ -n "$AGENTCORE_GATEWAY_URL" ]] || err "agentcore_gateway_url output is empty."

ok "Orchestrator: ${AGENTCORE_ORCHESTRATOR_ID}"
for spec_id in "${SPECIALIST_IDS[@]:-}"; do
  ok "Specialist ${spec_id}: $(specialist_runtime_id "$spec_id")"
done

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 8 — Inject dynamic env vars + verify
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 8 — Updating AgentCore Runtime environment variables..."

if [[ -z "${AGENTCORE_GATEWAY_URL:-}" ]]; then
  err "AGENTCORE_GATEWAY_URL is empty. Provision the AgentCore Gateway first (deploy.sh)."
fi

# Strict-mode embeddings: only export EMBEDDING_MODEL_ID for titan stacks.
# Voyage stacks ship AgentCore runtimes without a Bedrock fallback model id,
# matching the API container's `.env.live` (deploy-project.sh / deploy-api.sh).
if [[ "$EMBEDDINGS_PROVIDER" == "titan" ]]; then
  export EMBEDDING_MODEL_ID="${EMBEDDING_MODEL_ID:-amazon.titan-embed-text-v2:0}"
else
  unset EMBEDDING_MODEL_ID
fi

# Export everything build_dynamic_env_base / update_runtime_env_dynamic need.
export AWS_REGION MONGODB_URI ATLAS_DB_NAME BEDROCK_KB_ID \
       AGENTCORE_MEMORY_STORE_ID AGENTCORE_GATEWAY_URL \
       VOYAGE_ENDPOINT EMBEDDINGS_PROVIDER \
       AGENTCORE_RUNTIME_DEPLOYMENT_MODE SHARED_BUCKET AGENTCORE_CODE_ARTIFACT_PREFIX \
       ECR_RUNTIME_REPO

build_dynamic_env_base   # sets DYNAMIC_ENV_BASE
update_runtime_env_dynamic

if [[ -n "${MONGODB_MCP_RUNTIME_ARN:-}" ]]; then
  update_mcp_runtime_mongodb_env "${MONGODB_MCP_RUNTIME_ARN##*/}" "$MONGODB_URI" "$ATLAS_DB_NAME"
fi

sep
log "Phase 8b — Verifying runtime environment variables..."
verify_runtime_env_dynamic
ok "All runtime env verifications passed"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 9 — Refresh API agent config cache
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 9 — Refreshing API agent config cache..."

EC2_API_URL=$(python3 -c "import json; m=json.load(open('$REPO_ROOT/deploy-manifest.json')); print(m.get('resources',{}).get('ec2_api_url',''))" 2>/dev/null || echo "")
COGNITO_CLIENT_ID=$(python3 -c "import json; m=json.load(open('$REPO_ROOT/deploy-manifest.json')); print(m.get('resources',{}).get('cognito_client_id',''))" 2>/dev/null || echo "")
COGNITO_POOL_ID=$(python3 -c "import json; m=json.load(open('$REPO_ROOT/deploy-manifest.json')); print(m.get('resources',{}).get('cognito_user_pool_id',''))" 2>/dev/null || echo "")
COGNITO_SMOKE_USER_EMAIL="${COGNITO_SMOKE_USER_EMAIL:-alex@example.com}"
COGNITO_TEST_PASSWORD="${COGNITO_TEST_PASSWORD:-DemoUser#2026}"

[[ -n "$EC2_API_URL" ]] || err "EC2 API URL not found in deploy-manifest.json — run deploy.sh first"
[[ -n "$COGNITO_CLIENT_ID" ]] || err "Cognito client ID not found in deploy-manifest.json — run deploy.sh first"

SMOKE_ID_TOKEN=$(aws cognito-idp initiate-auth \
  --region "$AWS_REGION" \
  --client-id "$COGNITO_CLIENT_ID" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=${COGNITO_SMOKE_USER_EMAIL},PASSWORD=${COGNITO_TEST_PASSWORD}" \
  --query "AuthenticationResult.IdToken" \
  --output text 2>/dev/null || echo "")
[[ -n "$SMOKE_ID_TOKEN" && "$SMOKE_ID_TOKEN" != "None" ]] \
  || err "Could not obtain Cognito token for ${COGNITO_SMOKE_USER_EMAIL}"

ensure_agent_config_refresh_token
REFRESH_PAYLOAD_FILE=$(mktemp -t agent-config-refresh.XXXXXX.json)
REFRESH_RESPONSE_FILE=$(mktemp -t agent-config-refresh-response.XXXXXX.json)
trap 'rm -f "$REFRESH_PAYLOAD_FILE" "$REFRESH_RESPONSE_FILE"; _pf_release_lock_on_exit' EXIT

REPO_ROOT="$REPO_ROOT" SPECIALIST_RUNTIME_ARNS_JSON="${SPECIALIST_RUNTIME_ARNS_JSON:-}" \
  python3 - <<'PYEOF' > "$REFRESH_PAYLOAD_FILE"
import json, os, pathlib

root = pathlib.Path(os.environ["REPO_ROOT"]) / "config"
files = {}
include_roots = ["agents", "skills"]
for name in include_roots:
    base = root / name
    if not base.exists():
        continue
    for path in sorted(p for p in base.rglob("*") if p.is_file()):
        rel = path.relative_to(root).as_posix()
        files[rel] = path.read_text(encoding="utf-8")

for name in ["http-tools.json", "environment.yaml", "demo-prompts.yaml"]:
    path = root / name
    if path.exists() and path.is_file():
        files[name] = path.read_text(encoding="utf-8")

print(json.dumps({
    "files": files,
    "specialistArns": json.loads(os.environ.get("SPECIALIST_RUNTIME_ARNS_JSON") or "{}"),
}))
PYEOF

REFRESH_STATUS=$(curl -sS \
  -o "$REFRESH_RESPONSE_FILE" \
  -w "%{http_code}" \
  -X POST "${EC2_API_URL%/}/internal/agents/refresh" \
  -H "Authorization: Bearer ${SMOKE_ID_TOKEN}" \
  -H "X-Agent-Config-Refresh-Token: ${AGENT_CONFIG_REFRESH_TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary "@${REFRESH_PAYLOAD_FILE}" || echo "000")

if [[ "$REFRESH_STATUS" != "200" ]]; then
  python3 - "$REFRESH_RESPONSE_FILE" <<'PYEOF' 2>/dev/null || true
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.exists():
    print(p.read_text(encoding="utf-8", errors="replace"))
PYEOF
  err "API agent config refresh failed with HTTP ${REFRESH_STATUS}. If this is the first run after adding the endpoint, run ./deploy/deploy-api.sh once to bootstrap it."
fi
ok "API agent config cache refreshed"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 10 — Agent smoke test (optional)
# ══════════════════════════════════════════════════════════════════════════════
sep
if [[ "$SKIP_SMOKE" == "true" ]]; then
  warn "Phase 10 — Skipping smoke test (--skip-smoke)"
else
  log "Phase 10 — Agent smoke test..."
  SMOKE_SESSION_ID="agents-smoke-$(date +%s)"
  python3 "$REPO_ROOT/deploy/scripts/backend-smoke.py" \
    --api-url "$EC2_API_URL" \
    --session-id "$SMOKE_SESSION_ID" \
    --id-token "$SMOKE_ID_TOKEN" \
    --check-session-user
  ok "Agent smoke test passed"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 11 — Write deploy-manifest.agents.json
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 11 — Writing deploy-manifest.agents.json..."

MANIFEST_AGENTS_FILE="$REPO_ROOT/deploy-manifest.agents.json"

_SPEC_ENV_ARGS=()
for spec_id in "${SPECIALIST_IDS[@]:-}"; do
  upper_id="$(printf '%s' "$spec_id" | tr '[:lower:]-' '[:upper:]_')"
  _SPEC_ENV_ARGS+=("SPEC_ARN_${upper_id}=$(specialist_runtime_arn "$spec_id")")
done

env AGENTS_JSON="$AGENTS_JSON" \
    ENVIRONMENT="$ENVIRONMENT" \
    GIT_SHA="$GIT_SHA" \
    AGENTCORE_ORCHESTRATOR_ARN="$AGENTCORE_ORCHESTRATOR_ARN" \
    AGENTCORE_ORCHESTRATOR_ID="$AGENTCORE_ORCHESTRATOR_ID" \
    SHARED_BUCKET="$SHARED_BUCKET" \
    AGENTCORE_CODE_ARTIFACT_PREFIX="$AGENTCORE_CODE_ARTIFACT_PREFIX" \
    "${_SPEC_ENV_ARGS[@]}" \
  python3 - <<'PYEOF' > "$MANIFEST_AGENTS_FILE"
import json, os
from datetime import datetime, timezone

agents_json = json.loads(os.environ.get('AGENTS_JSON', '{}'))

specialists_out = {}
for s in agents_json.get('specialists', []):
    sid = s['id']
    arn_key = f"SPEC_ARN_{sid.upper().replace('-', '_')}"
    specialists_out[sid] = os.environ.get(arn_key, '')

manifest = {
    'generated_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'script': 'deploy-agents.sh',
    'mode': 'agent-only',
    'environment': os.environ.get('ENVIRONMENT', ''),
    'git_sha': os.environ.get('GIT_SHA', ''),
    'orchestrator': {
        'id': agents_json.get('orchestrator', {}).get('id', ''),
        'runtime_arn': os.environ.get('AGENTCORE_ORCHESTRATOR_ARN', ''),
        'runtime_id': os.environ.get('AGENTCORE_ORCHESTRATOR_ID', ''),
    },
    'specialists': specialists_out,
    'artifact_s3': f"s3://{os.environ.get('SHARED_BUCKET','')}/{os.environ.get('AGENTCORE_CODE_ARTIFACT_PREFIX','')}",
}
print(json.dumps(manifest, indent=2))
PYEOF

ok "Manifest written: $MANIFEST_AGENTS_FILE"

sep
ok "Agent-only deploy complete!"
echo ""
echo "  Orchestrator : ${AGENTCORE_ORCHESTRATOR_ARN}"
for spec_id in "${SPECIALIST_IDS[@]:-}"; do
  echo "  Specialist   : ${spec_id} → $(specialist_runtime_arn "$spec_id")"
done
echo "  Artifact     : s3://${SHARED_BUCKET}/${AGENTCORE_CODE_ARTIFACT_PREFIX}"
echo ""
echo "  Changes are live for new sessions immediately."
echo "  Warm sessions will pick up changes within idle_runtime_session_timeout (default 15 min)."
echo ""
echo "  To deploy infra changes too: ./deploy/deploy-full-with-privatelink.sh"
