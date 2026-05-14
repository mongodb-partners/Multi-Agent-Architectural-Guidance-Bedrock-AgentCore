#!/usr/bin/env bash
# docker-build-push.sh — Build API + UI + agent-runtime Docker images and push to ECR.
#
# Usage:
#   ./deploy/scripts/docker-build-push.sh <api_repo_url> <ui_repo_url> <aws_region> [agent_runtime_repo_url]
#
# Called by deploy.sh (Phase 5.5) after ECR repos are created by Terraform.
# Images are tagged with both :latest and :sha-<git-short-sha>.
# agent-runtime image is linux/arm64 (required by AgentCore Runtime).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

API_REPO="${1:?Usage: $0 <api_repo_url> <ui_repo_url> <aws_region> [agent_runtime_repo_url]}"
UI_REPO="${2:?}"
AWS_REGION="${3:-us-east-1}"
AGENT_RUNTIME_REPO="${4:-}"

log()  { echo "  [docker] $*"; }
ok()   { echo "  [docker] ✓ $*"; }
err()  { echo "  [docker] ✗ $*" >&2; exit 1; }

GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
API_TAG="sha-${GIT_SHA}"
UI_TAG="sha-${GIT_SHA}"
RUNTIME_TAG="sha-${GIT_SHA}"

ECR_REGISTRY=$(echo "$API_REPO" | cut -d'/' -f1)

log "Git SHA  : $GIT_SHA"
log "API repo : $API_REPO"
log "UI repo  : $UI_REPO"
[[ -n "$AGENT_RUNTIME_REPO" ]] && log "Runtime  : $AGENT_RUNTIME_REPO (linux/arm64)"
log "Registry : $ECR_REGISTRY"
echo ""

# ── ECR login ─────────────────────────────────────────────────────────────────
log "Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
ok "ECR login successful"

# ── Build API image ───────────────────────────────────────────────────────────
log "Building API image (context: repo root, Dockerfile: api/Dockerfile)..."
docker build \
  --platform linux/amd64 \
  -f "$REPO_ROOT/api/Dockerfile" \
  -t "$API_REPO:$API_TAG" \
  -t "$API_REPO:latest" \
  "$REPO_ROOT"
ok "API image built: $API_REPO:$API_TAG"

# ── Build UI image ────────────────────────────────────────────────────────────
log "Building UI image (context: ui/, Dockerfile: ui/Dockerfile)..."
docker build \
  --platform linux/amd64 \
  -f "$REPO_ROOT/ui/Dockerfile" \
  -t "$UI_REPO:$UI_TAG" \
  -t "$UI_REPO:latest" \
  "$REPO_ROOT/ui"
ok "UI image built: $UI_REPO:$UI_TAG"

# ── Push images ───────────────────────────────────────────────────────────────
log "Pushing API image..."
docker push "$API_REPO:$API_TAG"
docker push "$API_REPO:latest"
ok "API pushed: $API_REPO:$API_TAG"

log "Pushing UI image..."
docker push "$UI_REPO:$UI_TAG"
docker push "$UI_REPO:latest"
ok "UI pushed: $UI_REPO:$UI_TAG"

# ── Build + push agent-runtime image (ARM64 — required by AgentCore Runtime) ──
if [[ -n "$AGENT_RUNTIME_REPO" ]]; then
  log "Building agent-runtime image (linux/arm64, Dockerfile: api/Dockerfile.agentcore)..."
  docker buildx build \
    --platform linux/arm64 \
    -f "$REPO_ROOT/api/Dockerfile.agentcore" \
    -t "$AGENT_RUNTIME_REPO:$RUNTIME_TAG" \
    -t "$AGENT_RUNTIME_REPO:latest" \
    --push \
    "$REPO_ROOT"
  ok "agent-runtime pushed: $AGENT_RUNTIME_REPO:$RUNTIME_TAG"
fi

echo ""
ok "Done. Images available in ECR:"
echo "  API     : $API_REPO:latest  ($API_TAG)"
echo "  UI      : $UI_REPO:latest  ($UI_TAG)"
if [[ -n "$AGENT_RUNTIME_REPO" ]]; then
  echo "  Runtime : $AGENT_RUNTIME_REPO:latest  ($RUNTIME_TAG)"
fi
