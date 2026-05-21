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
  privatelink|peering) ;;
  *) err "Invalid network_mode='${NETWORK_MODE}' from terraform output" ;;
esac
ok "Network mode: ${NETWORK_MODE}"
VOYAGE_ENDPOINT="$(tf_raw voyage_endpoint_name)"
AGENTCORE_MEMORY_STORE_ID="$(tf_raw agentcore_memory_id)"
AGENTCORE_GATEWAY_URL="$(tf_raw agentcore_gateway_url)"
AGENTCORE_ORCHESTRATOR_ARN="$(tf_raw acr_orchestrator_arn)"
MONGODB_MCP_RUNTIME_ARN="$(tf_raw mongodb_mcp_runtime_arn)"
MONGODB_MCP_RUNTIME_ENDPOINT="$(tf_raw mongodb_mcp_runtime_endpoint)"
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
VOYAGE_REQUEST_FORMAT="${VOYAGE_REQUEST_FORMAT:-multimodal}"

[[ -n "$EC2_IP" && -n "$EC2_INSTANCE_ID" ]] || err "EC2 outputs missing; run deploy.sh first"
[[ -n "$ECR_API_REPO" ]] || err "ECR API repo output missing"
[[ -n "$MONGODB_URI" ]] || err "MONGODB_URI unavailable (.env or terraform output atlas_connection_string)"
[[ -n "$TF_VAR_atlas_project_id" ]] || err "Atlas project id missing (TF_VAR_mongodb_atlas_project_id / TF_VAR_atlas_project_id)"
[[ -n "${MONGODB_ATLAS_PUBLIC_KEY:-}" && -n "${MONGODB_ATLAS_PRIVATE_KEY:-}" ]] \
  || err "MongoDB Atlas API keys missing; required to compute the API private URI"
case "$EMBEDDINGS_PROVIDER" in
  voyage|titan) ;;
  "") err "EMBEDDINGS_PROVIDER is not set. Set 'voyage' or 'titan' in .env." ;;
  *)  err "EMBEDDINGS_PROVIDER='$EMBEDDINGS_PROVIDER' is not recognised. Use 'voyage' or 'titan'." ;;
esac

# ── Atlas private MONGODB_URI computation — mode-aware ───────────────────────
# privatelink: Atlas awsPrivateLink direct multi-host URI with
#   tlsAllowInvalidHostnames=true.
# peering: cluster's connectionStrings.privateSrv (when Atlas Private DNS for
#   Peering is on) else connectionStrings.private (multi-host non-SRV). NO
#   tlsAllowInvalidHostnames — peering hostnames ARE in the cert SAN.
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
priv_srv = conn.get("privateSrv") or ""
priv_multi = conn.get("private") or ""
if priv_srv:
    host = priv_srv.replace("mongodb+srv://", "", 1)
    print(f"mongodb+srv://{user}:{pwd}@{host}/?retryWrites=true&w=majority")
elif priv_multi:
    no_scheme = priv_multi.replace("mongodb://", "", 1)
    sep_char = "&" if "?" in no_scheme else "/?"
    print(f"mongodb://{user}:{pwd}@{no_scheme}{sep_char}retryWrites=true&w=majority")
else:
    raise SystemExit("Atlas cluster has neither connectionStrings.privateSrv nor connectionStrings.private — peering not active yet?")
PY
  ); then
    MONGODB_URI="$API_PRIVATE_URI"
    if ! echo "$MONGODB_URI" | grep -qE '\-pri\.'; then
      err "Computed peering URI does not contain '-pri.' (private peering host) — would route over the public SRV. Aborting to preserve privacy parity."
    fi
    ok "API MongoDB URI normalized to peering connection string"
  else
    err "Could not compute Atlas peering URI for the API. Verify the peering connection is ACTIVE."
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
    EMBEDDING_DIMENSIONS="${EMBEDDING_DIMENSIONS:-1024}" \
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
  trap 'rm -rf "$DOCKER_CONFIG_DIR"' EXIT
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

  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null
  docker buildx build \
    --platform linux/amd64 \
    -f "$REPO_ROOT/api/Dockerfile" \
    -t "$ECR_API_REPO:$API_TAG" \
    -t "$ECR_API_REPO:latest" \
    --push \
    "$REPO_ROOT"
  ok "API image pushed: $ECR_API_REPO:$API_TAG"
fi

sep
log "Phase 5 — Writing .env.live and copying to EC2 via SSM..."
ensure_agent_config_refresh_token
cat > "$REPO_ROOT/.env.live" <<EOF
# EC2 mode — generated by deploy-api.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# NOTE: plain KEY=VALUE only — no export, no quotes, no declare -x
ORCHESTRATOR_MODE=runtime
AGENT_CONFIG_REFRESH_TOKEN=${AGENT_CONFIG_REFRESH_TOKEN}

MONGODB_URI=${MONGODB_URI}
# Public SRV URI for off-VPC tooling (harness cleanup, ad-hoc \`mongosh\`,
# memory-recall-diagnostic.py scenarios C/F which delete chat_messages rows
# the API session-list cannot reach). The API container itself MUST keep
# using MONGODB_URI (PrivateLink) for security + no public egress.
MONGODB_URI_PUBLIC=${SEED_MONGODB_URI}
MONGODB_DB=${ATLAS_DB_NAME}
BEDROCK_KB_ID=${BEDROCK_KB_ID}
AWS_REGION=${AWS_REGION}

EMBEDDINGS_PROVIDER=${EMBEDDINGS_PROVIDER}
VOYAGE_SAGEMAKER_ENDPOINT=${VOYAGE_ENDPOINT}
VOYAGE_OUTPUT_DIM=1024
VOYAGE_REQUEST_FORMAT=${VOYAGE_REQUEST_FORMAT}
EMBEDDING_MODEL_ID=amazon.titan-embed-text-v2:0

AGENTCORE_MEMORY_STORE_ID=${AGENTCORE_MEMORY_STORE_ID}
AGENTCORE_GATEWAY_URL=${AGENTCORE_GATEWAY_URL}
AGENTCORE_ORCHESTRATOR_ARN=${AGENTCORE_ORCHESTRATOR_ARN}
EOF

for _spec_id in "${SPECIALIST_IDS[@]:-}"; do
  _upper_id="$(printf '%s' "$_spec_id" | tr '[:lower:]-' '[:upper:]_')"
  _spec_arn="$(specialist_runtime_arn "$_spec_id")"
  [[ -n "$_spec_arn" ]] && echo "AGENTCORE_${_upper_id}_ARN=${_spec_arn}" >> "$REPO_ROOT/.env.live"
done
unset _spec_id _upper_id _spec_arn

cat >> "$REPO_ROOT/.env.live" <<EOF

MCP_SERVER_URL=${AGENTCORE_GATEWAY_URL}
MONGODB_MCP_RUNTIME_ARN=${MONGODB_MCP_RUNTIME_ARN}
MONGODB_MCP_RUNTIME_ENDPOINT=${MONGODB_MCP_RUNTIME_ENDPOINT}
SHORT_TERM_MEMORY_BACKEND=agentcore
PERSIST_CHAT_SESSIONS=1
MEMORY_TTL_DAYS=30
MEMORY_EXTRACTION_MODEL_ID=us.anthropic.claude-haiku-4-5-20251001-v1:0

# LTM / trace value gating — sourced from .env so flips are deploy-tracked.
#   MEMORY_TRACE_VALUES=1 → facts[], queryText, factCandidates[].text,
#                            factsExtracted[] are emitted raw in trace events.
#                            Default 0 = literal "<redacted>" (safe).
#   TRACE_PROMPT_BODY=1   → prompt.assembled.body (full rendered system prompt
#                            including ## Relevant prior context) is attached.
#   TRACE_REDACT=1        → blanket redactDeep pass over every payload.
# Flip via .env then re-run ./deploy/deploy-api.sh --skip-docker --skip-smoke.
MEMORY_TRACE_VALUES=${MEMORY_TRACE_VALUES:-0}
TRACE_PROMPT_BODY=${TRACE_PROMPT_BODY:-0}
TRACE_REDACT=${TRACE_REDACT:-0}

CLOUDWATCH_LOG_GROUP=${CW_API_LOG_GROUP}
CLOUDWATCH_UI_LOG_GROUP=${CW_UI_LOG_GROUP}

AUTH_JWKS_URI=${COGNITO_JWKS}
AUTH_ISSUER=https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_POOL_ID}
STREAMLIT_COGNITO_POOL_ID=${COGNITO_POOL_ID}
STREAMLIT_COGNITO_CLIENT_ID=${COGNITO_CLIENT_ID}
STREAMLIT_API_URL=http://${EC2_IP}:3000/

OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318}
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_SERVICE_NAME=multiagent-api
OTEL_RESOURCE_ATTRIBUTES=service.namespace=multiagent,deployment.environment=${ENVIRONMENT:-dev},service.version=${GIT_SHA:-unknown}
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=${OTEL_SAMPLE_RATIO:-1.0}
OTEL_PYTHON_LOG_CORRELATION=true
EOF
ok ".env.live written"

aws ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$EC2_INSTANCE_ID" \
  || err "EC2 status checks did not pass for $EC2_INSTANCE_ID"

_ENV_B64=$(base64 < "$REPO_ROOT/.env.live" | tr -d '\n')
ENV_SYNC_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: sync .env.live for api" \
  "[\"echo '${_ENV_B64}' | base64 -d > /opt/multiagent/.env.live && chmod 600 /opt/multiagent/.env.live\"]" \
  12) || err "Failed to send .env.live to EC2 via SSM"
wait_for_ssm_command_success "$ENV_SYNC_CMD_ID" "$EC2_INSTANCE_ID" 24 \
  || err ".env.live sync command failed on EC2"
ok ".env.live synced to /opt/multiagent/.env.live"

sep
log "Phase 6 — Pulling API image + restarting multiagent-api..."
if [[ "$SKIP_DOCKER" == "true" ]]; then
  RESTART_CMD="systemctl daemon-reload && systemctl restart multiagent-api"
else
  RESTART_CMD="aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY} \
    && docker pull ${ECR_API_IMAGE} \
    && systemctl daemon-reload \
    && systemctl restart multiagent-api"
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
