#!/usr/bin/env bash
# deploy-ui.sh — UI-only redeploy for the EC2 stack.
#
# Usage:
#   ./deploy/deploy-ui.sh [--skip-docker] [--skip-smoke] [--env-file <path>]
#
# What it does:
#   Phase 1 — Validate prerequisites
#   Phase 2 — Source .env and read Terraform outputs
#   Phase 3 — Build + push only the UI Docker image
#   Phase 4 — Pull latest UI image and restart only multiagent-ui
#   Phase 5 — UI health check
#
# What it does NOT do:
#   x Terraform apply
#   x Build/push API, AgentCore, or MCP runtime images
#   x Restart multiagent-api
#   x Regenerate .env.live (use deploy-api.sh when Cognito/Atlas/OTel env vars change)
#   x Create/delete AgentCore runtimes
#   x MongoDB index seeding or agent roster discovery

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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
    *) echo "  [ui] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo "  [ui] $*"; }
ok()   { echo "  [ui] ✓ $*"; }
err()  { echo "  [ui] ✗ $*" >&2; exit 1; }
warn() { echo "  [ui] ⚠ $*"; }
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
for cmd in aws terraform git curl; do
  command -v "$cmd" &>/dev/null || err "'$cmd' not found in PATH"
done
if [[ "$SKIP_DOCKER" != "true" ]]; then
  command -v docker &>/dev/null || err "'docker' not found in PATH (pass --skip-docker to only restart)"
  docker info &>/dev/null || err "Docker daemon is not reachable — start Docker Desktop / dockerd, or pass --skip-docker"
fi
[[ -f "$TF_DIR/backend.hcl" ]] || err "backend.hcl not found at $TF_DIR — run deploy.sh first"
[[ -f "$REPO_ROOT/deploy-manifest.json" ]] || err "deploy-manifest.json not found — run deploy.sh first"
ok "All prerequisites found"

sep
log "Phase 2 — Loading credentials and Terraform outputs..."
[[ -f "$ENV_FILE" ]] || err "env file not found: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

DEPLOY_DIAG_LABEL="ui"
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
preflight_validate ui
deploy_diag_after_preflight "ui" "$ENV_FILE"

ok "AWS account: $ACCOUNT_ID"

deploy_diag_terraform_context "ui terraform output init" "$TF_DIR" "$TF_DIR/backend.hcl" ""
deploy_diag_checkpoint "terraform init start: terraform -chdir=${TF_DIR} init -input=false -reconfigure -backend-config=${TF_DIR}/backend.hcl -no-color"
terraform -chdir="$TF_DIR" init -input=false -reconfigure -backend-config="$TF_DIR/backend.hcl" -no-color >/dev/null
deploy_diag_checkpoint "terraform outputs start: reading EC2/UI/ECR outputs from ${TF_DIR}"

EC2_IP="$(tf_raw ec2_public_ip)"
EC2_INSTANCE_ID="$(tf_raw ec2_instance_id)"
EC2_UI_URL="$(tf_raw ec2_ui_url)"
ECR_UI_REPO="$(tf_raw ecr_ui_repository_url)"

[[ -n "$EC2_IP" && -n "$EC2_INSTANCE_ID" ]] || err "EC2 outputs missing; run deploy.sh first"
[[ -n "$ECR_UI_REPO" ]] || err "ECR UI repo output missing"
ok "Terraform outputs loaded"

GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
UI_TAG="sha-${GIT_SHA}"
ECR_REGISTRY="$(echo "$ECR_UI_REPO" | cut -d'/' -f1)"
ECR_UI_IMAGE="${ECR_UI_REPO}:latest"

sep
if [[ "$SKIP_DOCKER" == "true" ]]; then
  warn "Phase 3 — Skipping UI image build/push (--skip-docker)"
else
  log "Phase 3 — Building + pushing UI image only..."
  DOCKER_CONFIG_DIR=$(mktemp -d -t deploy-ui-docker-XXXXXX)
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

  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null
  source "$SCRIPT_DIR/scripts/_docker-build.sh"
  docker_build_push_image linux/amd64 \
    "$REPO_ROOT/ui/Dockerfile" \
    "$REPO_ROOT/ui" \
    "$ECR_UI_REPO:$UI_TAG" \
    "$ECR_UI_REPO:latest"
  ok "UI image pushed: $ECR_UI_REPO:$UI_TAG"
fi

sep
log "Phase 4 — Pulling UI image + restarting multiagent-ui..."
aws ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$EC2_INSTANCE_ID" \
  || err "EC2 status checks did not pass for $EC2_INSTANCE_ID"

if [[ "$SKIP_DOCKER" == "true" ]]; then
  RESTART_CMD="systemctl daemon-reload && systemctl restart multiagent-ui"
else
  RESTART_CMD="aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY} \
    && docker pull ${ECR_UI_IMAGE} \
    && systemctl daemon-reload \
    && systemctl restart multiagent-ui"
fi

RESTART_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: pull ui image + restart ui" \
  "[\"${RESTART_CMD//\"/\\\"}\"]" \
  12) || err "Failed to send UI restart command via SSM"
wait_for_ssm_command_success "$RESTART_CMD_ID" "$EC2_INSTANCE_ID" 36 \
  || err "UI restart command failed on EC2"
ok "multiagent-ui restart completed"

sep
if [[ "$SKIP_SMOKE" == "true" ]]; then
  warn "Phase 5 — Skipping UI health check (--skip-smoke)"
else
  log "Phase 5 — Waiting for UI health check..."
  HEALTH_OK="no"
  for _i in $(seq 1 120); do
    if curl -sf --max-time 10 "http://${EC2_IP}:8501/_stcore/health" >/dev/null 2>&1; then
      HEALTH_OK="yes"
      break
    fi
    sleep 5
  done
  [[ "$HEALTH_OK" == "yes" ]] || err "UI did not become healthy at http://${EC2_IP}:8501/_stcore/health"
  ok "UI is healthy"
fi

cat > "$REPO_ROOT/deploy-manifest.ui.json" <<EOF
{
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "mode": "ui-only",
  "script": "deploy-ui.sh",
  "aws_account": "${ACCOUNT_ID}",
  "aws_region": "${AWS_REGION}",
  "environment": "${ENVIRONMENT}",
  "ui_url": "${EC2_UI_URL:-http://${EC2_IP}:8501}",
  "ecr_ui_repo": "${ECR_UI_REPO}",
  "ui_image_tag": "${UI_TAG}"
}
EOF

sep
ok "UI-only deploy complete!"
echo "  UI     : ${EC2_UI_URL:-http://${EC2_IP}:8501}"
echo "  Image  : ${ECR_UI_REPO}:${UI_TAG}"
