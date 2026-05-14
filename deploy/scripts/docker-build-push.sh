#!/usr/bin/env bash
# docker-build-push.sh — Build API + UI + agent-runtime + mongodb-mcp-runtime
# Docker images and push to ECR.
#
# Usage:
#   ./deploy/scripts/docker-build-push.sh \
#       <api_repo_url> <ui_repo_url> <aws_region> \
#       [agent_runtime_repo_url] [mongodb_mcp_runtime_repo_url]
#
# Called by deploy.sh (Phase 6) after ECR repos are created by Terraform.
# Images are tagged with both :latest and :sha-<git-short-sha>.
# Both AgentCore Runtime images (agent-runtime + mongodb-mcp-runtime) are
# linux/arm64, as required by AgentCore Runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

API_REPO="${1:?Usage: $0 <api_repo_url> <ui_repo_url> <aws_region> [agent_runtime_repo_url] [mongodb_mcp_runtime_repo_url]}"
UI_REPO="${2:?}"
AWS_REGION="${3:-us-east-1}"
AGENT_RUNTIME_REPO="${4:-}"
MONGODB_MCP_RUNTIME_REPO="${5:-}"

log()  { echo "  [docker] $*"; }
ok()   { echo "  [docker] ✓ $*"; }
err()  { echo "  [docker] ✗ $*" >&2; exit 1; }

# Verify prerequisites up-front. With `set -euo pipefail`, missing binaries
# inside a pipeline (e.g. `aws ecr get-login-password | docker login`) cause
# a SIGPIPE on the upstream and a confusing BrokenPipeError instead of a
# clear error. Fail here with an explicit message.
command -v docker &>/dev/null || err "'docker' not found in PATH"
docker info &>/dev/null      || err "'docker' is installed but the daemon is not reachable — start Docker Desktop / dockerd"
command -v aws &>/dev/null    || err "'aws' (AWS CLI) not found in PATH"
command -v git &>/dev/null    || err "'git' not found in PATH"

# Use an isolated DOCKER_CONFIG so a stale / broken `credsStore` in the
# user's global ~/.docker/config.json (e.g. `desktop` left behind after
# uninstalling Docker Desktop) cannot break `docker login` against ECR.
# We copy the user's existing config (including `contexts/` so colima /
# desktop-linux contexts keep working) into a temp dir, then strip
# `credsStore` + `credHelpers` so docker falls back to plaintext storage
# inside the temp dir. The temp dir is wiped on exit, so the short-lived
# ECR token never persists.
DOCKER_CONFIG_DIR=$(mktemp -d -t docker-build-push-XXXXXX)
trap 'rm -rf "$DOCKER_CONFIG_DIR"' EXIT
if [[ -d "$HOME/.docker" ]]; then
  cp -R "$HOME/.docker/." "$DOCKER_CONFIG_DIR/"
  if [[ -f "$DOCKER_CONFIG_DIR/config.json" ]]; then
    python3 -c "
import json, sys
p = '$DOCKER_CONFIG_DIR/config.json'
c = json.load(open(p))
c.pop('credsStore', None)
c.pop('credHelpers', None)
json.dump(c, open(p, 'w'), indent='\t')
"
  else
    echo '{}' > "$DOCKER_CONFIG_DIR/config.json"
  fi
else
  echo '{}' > "$DOCKER_CONFIG_DIR/config.json"
fi
export DOCKER_CONFIG="$DOCKER_CONFIG_DIR"

GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
API_TAG="sha-${GIT_SHA}"
UI_TAG="sha-${GIT_SHA}"
RUNTIME_TAG="sha-${GIT_SHA}"

ECR_REGISTRY=$(echo "$API_REPO" | cut -d'/' -f1)

log "Git SHA  : $GIT_SHA"
log "API repo : $API_REPO"
log "UI repo  : $UI_REPO"
[[ -n "$AGENT_RUNTIME_REPO" ]] && log "Runtime  : $AGENT_RUNTIME_REPO (linux/arm64)"
[[ -n "$MONGODB_MCP_RUNTIME_REPO" ]] && log "MCP rt   : $MONGODB_MCP_RUNTIME_REPO (linux/arm64)"
log "Registry : $ECR_REGISTRY"
echo ""

# ── ECR login ─────────────────────────────────────────────────────────────────
log "Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
ok "ECR login successful"

# ── Build + push API image ────────────────────────────────────────────────────
# buildx with --push is the only path that reliably cross-builds linux/amd64
# from an Apple Silicon host (the legacy `docker build --platform` produces an
# image colima/dockerd refuses to load with "does not provide the specified
# platform"). On amd64 hosts it still works the same.
log "Building + pushing API image (linux/amd64, context: repo root, Dockerfile: api/Dockerfile)..."
docker buildx build \
  --platform linux/amd64 \
  -f "$REPO_ROOT/api/Dockerfile" \
  -t "$API_REPO:$API_TAG" \
  -t "$API_REPO:latest" \
  --push \
  "$REPO_ROOT"
ok "API pushed: $API_REPO:$API_TAG"

# ── Build + push UI image ─────────────────────────────────────────────────────
log "Building + pushing UI image (linux/amd64, context: ui/, Dockerfile: ui/Dockerfile)..."
docker buildx build \
  --platform linux/amd64 \
  -f "$REPO_ROOT/ui/Dockerfile" \
  -t "$UI_REPO:$UI_TAG" \
  -t "$UI_REPO:latest" \
  --push \
  "$REPO_ROOT/ui"
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

# ── Build + push mongodb-mcp-runtime image (ARM64 — AgentCore Runtime contract) ──
# Hosts the Streamable-HTTP MCP server defined under mcp-runtimes/mongodb-mcp/
# and consumed by the AgentCore Gateway as an `mcpServer` target. Build context
# is the runtime directory itself; tool implementations live in
# `mcp-runtimes/mongodb-mcp/src/vendor/` (canonical home after CLIENT_REVIEW
# Phase 7e — the legacy `lambda/mongodb-mcp/` host has been deleted).
if [[ -n "$MONGODB_MCP_RUNTIME_REPO" ]]; then
  log "Building mongodb-mcp-runtime image (linux/arm64, Dockerfile: mcp-runtimes/mongodb-mcp/Dockerfile)..."
  docker buildx build \
    --platform linux/arm64 \
    -f "$REPO_ROOT/mcp-runtimes/mongodb-mcp/Dockerfile" \
    -t "$MONGODB_MCP_RUNTIME_REPO:$RUNTIME_TAG" \
    -t "$MONGODB_MCP_RUNTIME_REPO:latest" \
    --push \
    "$REPO_ROOT/mcp-runtimes/mongodb-mcp"
  ok "mongodb-mcp-runtime pushed: $MONGODB_MCP_RUNTIME_REPO:$RUNTIME_TAG"
fi

echo ""
ok "Done. Images available in ECR:"
echo "  API     : $API_REPO:latest  ($API_TAG)"
echo "  UI      : $UI_REPO:latest  ($UI_TAG)"
# If no agent-runtime repo was passed, the `[[ -n "$X" ]] && echo ...` form
# would return non-zero — and since this is the last command in the script,
# under `set -e` the script's overall exit code becomes non-zero, silently
# killing the parent `deploy.sh`. Use an explicit `if` so the script always
# exits 0 on success.
if [[ -n "$AGENT_RUNTIME_REPO" ]]; then
  echo "  Runtime : $AGENT_RUNTIME_REPO:latest  ($RUNTIME_TAG)"
fi
if [[ -n "$MONGODB_MCP_RUNTIME_REPO" ]]; then
  echo "  MCP rt  : $MONGODB_MCP_RUNTIME_REPO:latest  ($RUNTIME_TAG)"
fi
