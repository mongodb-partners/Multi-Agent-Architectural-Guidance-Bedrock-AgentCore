#!/usr/bin/env bash
# deploy-api.sh — API-only redeploy for the EC2 stack.
#
# Usage:
#   ./deploy/deploy-api.sh [--skip-docker] [--skip-smoke] [--env-file <path>]
#
# What it does:
#   Phase 1 — Validate prerequisites
#   Phase 2 — Source .env and read Terraform outputs
#   Phase 3 — Discover current config/agents roster
#   Phase 4 — Build + push only the API Docker image
#   Phase 5 — Regenerate .env.live and sync it to EC2
#   Phase 6 — Pull latest API image and restart only multiagent-api
#   Phase 7 — API health + deterministic backend smoke
#
# What it does NOT do:
#   x Terraform apply
#   x Build/push UI or AgentCore runtime images
#   x Restart Streamlit UI
#   x Create/delete AgentCore runtimes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_SH="$REPO_ROOT/deploy/scripts/_agents-common.sh"
TF_DIR="$REPO_ROOT/deploy/terraform/envs/ec2"
ENV_FILE="$REPO_ROOT/.env"
SKIP_DOCKER=false
SKIP_SMOKE=false
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-docker) SKIP_DOCKER=true ;;
    --skip-smoke)  SKIP_SMOKE=true ;;
    --env-file)    ENV_FILE="$2"; shift ;;
    *) echo "  [api] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo "  [api] $*"; }
ok()   { echo "  [api] ✓ $*"; }
err()  { echo "  [api] ✗ $*" >&2; exit 1; }
warn() { echo "  [api] ⚠ $*"; }
sep()  { echo "────────────────────────────────────────────────"; }

send_ssm_command_retry() {
  local instance_id="$1"
  local comment="$2"
  local commands_json="$3"
  local max_attempts="${4:-15}"
  local cmd_id=""

  for _i in $(seq 1 "$max_attempts"); do
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
  local status

  for _i in $(seq 1 "$max_attempts"); do
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

tf_raw() {
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true
}

sep
log "Phase 1 — Checking prerequisites..."
for cmd in aws terraform python3 git curl bun; do
  command -v "$cmd" &>/dev/null || err "'$cmd' not found in PATH"
done
if [[ "$SKIP_DOCKER" != "true" ]]; then
  command -v docker &>/dev/null || err "'docker' not found in PATH (pass --skip-docker to only restart)"
  docker info &>/dev/null || err "Docker daemon is not reachable — start Docker Desktop / dockerd, or pass --skip-docker"
fi
[[ -f "$COMMON_SH" ]] || err "Shared helper not found: $COMMON_SH"
[[ -f "$TF_DIR/backend.hcl" ]] || err "backend.hcl not found at $TF_DIR — run deploy.sh first"
[[ -f "$REPO_ROOT/deploy-manifest.json" ]] || err "deploy-manifest.json not found — run deploy.sh first"
# shellcheck source=deploy/scripts/_agents-common.sh
source "$COMMON_SH"
# shellcheck source=deploy/scripts/_voyage-config.sh
source "$REPO_ROOT/deploy/scripts/_voyage-config.sh"
ok "All prerequisites found"

sep
log "Phase 2 — Loading credentials and Terraform outputs..."
[[ -f "$ENV_FILE" ]] || err "env file not found: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

DEPLOY_DIAG_LABEL="api"
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
preflight_validate api
deploy_diag_after_preflight "api" "$ENV_FILE"

ok "AWS account: $ACCOUNT_ID"

deploy_diag_terraform_context "api terraform output init" "$TF_DIR" "$TF_DIR/backend.hcl" ""
deploy_diag_checkpoint "terraform init start: terraform -chdir=${TF_DIR} init -input=false -reconfigure -backend-config=${TF_DIR}/backend.hcl -no-color"
terraform -chdir="$TF_DIR" init -input=false -reconfigure -backend-config="$TF_DIR/backend.hcl" -no-color >/dev/null
deploy_diag_checkpoint "terraform outputs start: reading EC2/API/ECR/Cognito/AgentCore outputs from ${TF_DIR}"

EC2_IP="$(tf_raw ec2_public_ip)"
EC2_INSTANCE_ID="$(tf_raw ec2_instance_id)"
EC2_API_URL="$(tf_raw ec2_api_url)"
ECR_API_REPO="$(tf_raw ecr_api_repository_url)"
ATLAS_DB_NAME="${ATLAS_DB_NAME:-${PROJECT_NAME//-/_}_${ENVIRONMENT}}"
ATLAS_CONNECTION_STRING="$(tf_raw atlas_connection_string)"
COGNITO_POOL_ID="$(tf_raw cognito_user_pool_id)"
COGNITO_CLIENT_ID="$(tf_raw cognito_app_client_id)"
COGNITO_JWKS="$(tf_raw cognito_jwks_uri)"
BEDROCK_KB_ID="$(tf_raw knowledge_base_id)"
ATLAS_MONGO_HOST="$(tf_raw atlas_mongo_host)"
ATLAS_PRIVATELINK_ENDPOINT_ID="$(tf_raw atlas_privatelink_endpoint_id)"
# Connectivity mode — read from terraform output (set by envs/ec2). Falls back
# to env var, then 'privatelink' for pre-NETWORK_MODE deploys.
NETWORK_MODE="$(tf_raw network_mode)"
NETWORK_MODE="${NETWORK_MODE:-${NETWORK_MODE_ENV:-${NETWORK_MODE:-privatelink}}}"
case "$NETWORK_MODE" in
  privatelink|peering|public) ;;
  *) err "Invalid network_mode='${NETWORK_MODE}' from terraform output" ;;
esac
ok "Network mode: ${NETWORK_MODE}"
VOYAGE_ENDPOINT="$(tf_raw voyage_endpoint_name)"
AGENTCORE_MEMORY_STORE_ID="$(tf_raw agentcore_memory_id)"
AGENTCORE_GATEWAY_URL="$(tf_raw agentcore_gateway_url)"
AGENTCORE_ORCHESTRATOR_ARN="$(tf_raw acr_orchestrator_arn)"
MONGODB_MCP_RUNTIME_ARN="$(tf_raw mongodb_mcp_runtime_arn)"
CW_API_LOG_GROUP="$(tf_raw cloudwatch_api_log_group)"
CW_UI_LOG_GROUP="$(tf_raw cloudwatch_ui_log_group)"
export TF_VAR_atlas_project_id="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
export TF_VAR_atlas_db_password="${TF_VAR_atlas_db_password:-${TF_VAR_mongodb_password:-}}"
if [[ -n "$ATLAS_CONNECTION_STRING" ]]; then
  MONGODB_URI="$ATLAS_CONNECTION_STRING"
else
  MONGODB_URI="mongodb+srv://${ATLAS_DB_USER}:${TF_VAR_atlas_db_password}@${ATLAS_MONGO_HOST}/?retryWrites=true&w=majority"
fi
SEED_MONGODB_URI="$MONGODB_URI"
EMBEDDINGS_PROVIDER="${EMBEDDINGS_PROVIDER:-}"

[[ -n "$EC2_IP" && -n "$EC2_INSTANCE_ID" ]] || err "EC2 outputs missing; run deploy.sh first"
[[ -n "$ECR_API_REPO" ]] || err "ECR API repo output missing"
[[ -n "$AGENTCORE_GATEWAY_URL" ]] || err "AgentCore Gateway URL output missing; AGENTCORE_GATEWAY_URL is required and localhost fallback is disabled"
[[ -n "$MONGODB_URI" ]] || err "MONGODB_URI unavailable (.env or terraform output atlas_connection_string)"
[[ -n "$TF_VAR_atlas_project_id" ]] || err "Atlas project id missing (TF_VAR_mongodb_atlas_project_id / TF_VAR_atlas_project_id)"
[[ -n "${MONGODB_ATLAS_PUBLIC_KEY:-}" && -n "${MONGODB_ATLAS_PRIVATE_KEY:-}" ]] \
  || err "MongoDB Atlas API keys missing; required to compute the API private URI"
case "$EMBEDDINGS_PROVIDER" in
  voyage|titan) ;;
  "") err "EMBEDDINGS_PROVIDER is not set. Set 'voyage' or 'titan' in .env." ;;
  *)  err "EMBEDDINGS_PROVIDER='$EMBEDDINGS_PROVIDER' is not recognised. Use 'voyage' or 'titan'." ;;
esac
if [[ "$EMBEDDINGS_PROVIDER" == "titan" ]]; then
  VOYAGE_ENDPOINT=""
fi

# ── Atlas private MONGODB_URI computation — mode-aware ───────────────────────
# privatelink: Atlas awsPrivateLink direct multi-host URI with
#   tlsAllowInvalidHostnames=true.
# peering: cluster's connectionStrings.private direct multi-host URI only. NO
#   SRV/TXT lookup and NO tlsAllowInvalidHostnames — peering hostnames ARE in
#   the cert SAN.
if [[ "$NETWORK_MODE" == "privatelink" ]]; then
  [[ -n "$ATLAS_PRIVATELINK_ENDPOINT_ID" ]] \
    || err "Missing Atlas PrivateLink endpoint ID for deterministic API deploy (privatelink mode)"
  log "Computing Atlas awsPrivateLink direct URI for the EC2 API..."
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
print(f"mongodb://{user}:{pwd}@{no_scheme}&retryWrites=true&w=majority&tlsAllowInvalidHostnames=true")
PY
  ); then
    MONGODB_URI="$API_PRIVATE_URI"
    ok "API MongoDB URI normalized to awsPrivateLink direct connection string"
  else
    err "Could not compute Atlas awsPrivateLink URI for the API"
  fi
elif [[ "$NETWORK_MODE" == "public" ]]; then
  # ── public mode (BYO) ──────────────────────────────────────────────────────
  # No private URI to compute — the API uses the BYO public SRV URI as-is.
  # MONGODB_URI already holds it (atlas_connection_string output or constructed
  # from host above). Mirrors deploy-project.sh Phase 5c public branch.
  log "Public mode: using BYO public SRV URI for the EC2 API (no private normalization)"
  ok "API MongoDB URI left as public SRV connection string"
else
  # ── peering mode ───────────────────────────────────────────────────────────
  log "Computing Atlas peering URI for the EC2 API..."
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
priv_multi = conn.get("private") or ""
if priv_multi:
    no_scheme = priv_multi.replace("mongodb://", "", 1)
    sep_char = "&" if "?" in no_scheme else "/?"
    print(f"mongodb://{user}:{pwd}@{no_scheme}{sep_char}retryWrites=true&w=majority")
else:
    raise SystemExit("Atlas cluster has no connectionStrings.private multi-host URI — peering not active yet or Atlas has not populated the private direct URI")
PY
  ); then
    MONGODB_URI="$API_PRIVATE_URI"
    if ! echo "$MONGODB_URI" | grep -qE '\-pri\.'; then
      err "Computed peering URI does not contain '-pri.' (private peering host) — would route over the public SRV. Aborting to preserve privacy parity."
    fi
    ok "API MongoDB URI normalized to peering direct multi-host connection string"
  else
    err "Could not compute Atlas peering direct multi-host URI for the API. Verify the peering connection is ACTIVE and that Atlas has populated connectionStrings.private."
  fi
fi
ok "Terraform outputs loaded"

sep
log "Phase 2b — Reconciling MongoDB indexes..."
(
  cd "$REPO_ROOT"
  MONGODB_URI="$SEED_MONGODB_URI" \
    MONGODB_DB="$ATLAS_DB_NAME" \
    WAIT_FOR_ATLAS_SEARCH_INDEXES=1 \
    bun db-seeding/seed-indexes.ts
)
ok "MongoDB indexes verified (seed-indexes)"

sep
log "Phase 3 — Discovering agents from config/agents/..."
discover_agents
pushd "$TF_DIR" >/dev/null
load_specialist_outputs_from_tf
popd >/dev/null
python3 - "$SPECIALIST_IDS_JSON" "${SPECIALIST_RUNTIME_ARNS_JSON:-}" <<'PY'
import json, sys
ids = json.loads(sys.argv[1] or "[]")
arns = json.loads(sys.argv[2] or "{}")
missing = [agent_id for agent_id in ids if not arns.get(agent_id)]
if missing:
    raise SystemExit("missing specialist runtime ARN outputs for: " + ", ".join(missing))
PY
ok "Agent roster loaded"

GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
API_TAG="sha-${GIT_SHA}"
ECR_REGISTRY="$(echo "$ECR_API_REPO" | cut -d'/' -f1)"
ECR_API_IMAGE="${ECR_API_REPO}:latest"

sep
if [[ "$SKIP_DOCKER" == "true" ]]; then
  warn "Phase 4 — Skipping API image build/push (--skip-docker)"
else
  log "Phase 4 — Building + pushing API image only..."
  DOCKER_CONFIG_DIR=$(mktemp -d -t deploy-api-docker-XXXXXX)
  trap 'rm -rf "$DOCKER_CONFIG_DIR"; _pf_release_lock_on_exit' EXIT
  if [[ -d "$HOME/.docker" ]]; then
    cp -R "$HOME/.docker/." "$DOCKER_CONFIG_DIR/"
    if [[ -f "$DOCKER_CONFIG_DIR/config.json" ]]; then
      python3 - "$DOCKER_CONFIG_DIR/config.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c.pop("credsStore", None)
c.pop("credHelpers", None)
json.dump(c, open(p, "w"), indent="\t")
PY
    else
      echo '{}' > "$DOCKER_CONFIG_DIR/config.json"
    fi
  else
    echo '{}' > "$DOCKER_CONFIG_DIR/config.json"
  fi
  export DOCKER_CONFIG="$DOCKER_CONFIG_DIR"

  source "$SCRIPT_DIR/scripts/_docker-build.sh"
  ecr_login_with_retry "$AWS_REGION" "$ECR_REGISTRY" \
    || err "ECR login failed after retries (see output above)"
  docker_build_push_image linux/amd64 \
    "$REPO_ROOT/api/Dockerfile" \
    "$REPO_ROOT" \
    "$ECR_API_REPO:$API_TAG" \
    "$ECR_API_REPO:latest"
  ok "API image pushed: $ECR_API_REPO:$API_TAG"
fi

sep
log "Phase 5 — Writing .env.docker + .env.live and copying to EC2 via SSM..."
ensure_agent_config_refresh_token

# Strict-mode embeddings (api/src/lib/embed-query.ts):
# In voyage stacks, EMBEDDING_MODEL_ID must NOT be present in the env files —
# its mere presence used to enable a silent Bedrock fallback. The runtime
# now refuses to fall back, but we strip the env var here as defense in
# depth so a misconfigured runtime can never even attempt Bedrock.
if [[ "$EMBEDDINGS_PROVIDER" == "titan" ]]; then
  EMBEDDING_MODEL_ID_LINE="EMBEDDING_MODEL_ID=amazon.titan-embed-text-v2:0"
  EMBEDDING_LINE="Bedrock Titan (amazon.titan-embed-text-v2:0)"
else
  EMBEDDING_MODEL_ID_LINE="# EMBEDDING_MODEL_ID intentionally omitted — strict ${EMBEDDINGS_PROVIDER} mode (no Bedrock fallback)"
  EMBEDDING_LINE="${EMBEDDINGS_PROVIDER} via SageMaker (${VOYAGE_ENDPOINT:-unknown})"
fi

# Common writer expects MONGODB_URI_PUBLIC; deploy-api.sh tracks the same
# value as SEED_MONGODB_URI for its own seeding paths.
export MONGODB_URI_PUBLIC="${SEED_MONGODB_URI}"
export EMBEDDING_MODEL_ID_LINE EMBEDDING_LINE

# Shared writer for `.env.docker` (Docker --env-file) + `.env.live` (bash).
# See deploy/scripts/_env-live.sh for the full schema + escape rules.
# shellcheck source=deploy/scripts/_env-live.sh
source "$REPO_ROOT/deploy/scripts/_env-live.sh"
write_env_live_files "deploy-api.sh"
ok ".env.docker + .env.live written"

aws ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$EC2_INSTANCE_ID" \
  || err "EC2 status checks did not pass for $EC2_INSTANCE_ID"

sync_env_live_to_ec2 "$EC2_INSTANCE_ID" \
  || err "env-file sync to EC2 failed"
ok ".env.docker + .env.live synced to /opt/multiagent/ on $EC2_INSTANCE_ID"

sep
log "Phase 6 — Pulling API image + restarting multiagent-api..."
if [[ "$SKIP_DOCKER" == "true" ]]; then
  RESTART_CMD="systemctl daemon-reload && systemctl restart multiagent-api"
else
  # Retry the remote ECR login + image pull (network-facing steps) so a
  # transient DNS/network blip on the EC2 host does not abort the restart.
  # The `ok` flag gates the restart so an exhausted retry budget still fails
  # the SSM command rather than restarting against a stale/missing image.
  RESTART_CMD="ok=0; for i in 1 2 3 4; do aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY} \
    && docker pull ${ECR_API_IMAGE} \
    && ok=1 && break; echo ecr-login-pull attempt \$i failed, retrying in 10s; sleep 10; done; \
    [ \$ok -eq 1 ] && systemctl daemon-reload && systemctl restart multiagent-api"
fi

RESTART_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: pull api image + restart api" \
  "[\"${RESTART_CMD//\"/\\\"}\"]" \
  12) || err "Failed to send API restart command via SSM"
wait_for_ssm_command_success "$RESTART_CMD_ID" "$EC2_INSTANCE_ID" 36 \
  || err "API restart command failed on EC2"
ok "multiagent-api restart completed"

sep
log "Phase 7 — Waiting for API health check..."
HEALTH_OK="no"
for _i in $(seq 1 120); do
  if curl -sf --max-time 10 "http://${EC2_IP}:3000/health" >/dev/null 2>&1; then
    HEALTH_OK="yes"
    break
  fi
  sleep 5
done
[[ "$HEALTH_OK" == "yes" ]] || err "API did not become healthy at http://${EC2_IP}:3000/health"
ok "API is healthy"

if [[ "$SKIP_SMOKE" == "true" ]]; then
  warn "Skipping backend smoke (--skip-smoke)"
else
  COGNITO_SMOKE_USER_EMAIL="${COGNITO_SMOKE_USER_EMAIL:-alex@example.com}"
  COGNITO_TEST_PASSWORD="${COGNITO_TEST_PASSWORD:-DemoUser#2026}"
  SMOKE_ID_TOKEN=$(aws cognito-idp initiate-auth \
    --region "$AWS_REGION" \
    --client-id "$COGNITO_CLIENT_ID" \
    --auth-flow USER_PASSWORD_AUTH \
    --auth-parameters "USERNAME=${COGNITO_SMOKE_USER_EMAIL},PASSWORD=${COGNITO_TEST_PASSWORD}" \
    --query "AuthenticationResult.IdToken" \
    --output text 2>/dev/null || echo "")
  [[ -n "$SMOKE_ID_TOKEN" && "$SMOKE_ID_TOKEN" != "None" ]] \
    || err "Could not obtain Cognito IdToken for smoke user ${COGNITO_SMOKE_USER_EMAIL}"
  python3 "$REPO_ROOT/deploy/scripts/backend-smoke.py" \
    --api-url "${EC2_API_URL:-http://${EC2_IP}:3000}" \
    --session-id "api-smoke-$(date +%s)" \
    --id-token "$SMOKE_ID_TOKEN" \
    --check-session-user
  ok "Backend smoke validation passed"
fi

cat > "$REPO_ROOT/deploy-manifest.api.json" <<EOF
{
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "mode": "api-only",
  "script": "deploy-api.sh",
  "aws_account": "${ACCOUNT_ID}",
  "aws_region": "${AWS_REGION}",
  "environment": "${ENVIRONMENT}",
  "api_url": "http://${EC2_IP}:3000",
  "ecr_api_repo": "${ECR_API_REPO}",
  "api_image_tag": "${API_TAG}",
  "specialists": ${SPECIALIST_IDS_JSON}
}
EOF

sep
ok "API-only deploy complete!"
echo "  API    : http://${EC2_IP}:3000"
echo "  Image  : ${ECR_API_REPO}:${API_TAG}"
echo "  Agents : ${SPECIALIST_IDS[*]:-'(none)'}"
