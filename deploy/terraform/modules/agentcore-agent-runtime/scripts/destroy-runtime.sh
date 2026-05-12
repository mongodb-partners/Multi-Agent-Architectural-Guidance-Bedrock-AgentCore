#!/usr/bin/env bash
# destroy-runtime.sh — delete AgentCore Runtime (endpoint first, then runtime)
set -euo pipefail

: "${AWS_REGION:?required}"
: "${STATE_FILE:?required}"

log() { echo "[agentcore-runtime] $*"; }

if [[ ! -f "$STATE_FILE" ]]; then
  log "no state file — nothing to delete"
  exit 0
fi

RUNTIME_ID=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('runtime_id',''))" 2>/dev/null || echo "")
ENDPOINT_ID=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('endpoint_id',''))" 2>/dev/null || echo "")

if [[ -z "$RUNTIME_ID" ]]; then
  log "no runtime_id in state — skipping"
  rm -f "$STATE_FILE"
  exit 0
fi

# Delete endpoint first
if [[ -n "$ENDPOINT_ID" ]]; then
  log "deleting endpoint: $ENDPOINT_ID"
  aws bedrock-agentcore-control delete-agent-runtime-endpoint \
    --region "$AWS_REGION" \
    --agent-runtime-id "$RUNTIME_ID" \
    --agent-runtime-endpoint-id "$ENDPOINT_ID" 2>&1 || log "endpoint delete failed (may already be gone)"
fi

log "deleting runtime: $RUNTIME_ID"
aws bedrock-agentcore-control delete-agent-runtime \
  --region "$AWS_REGION" \
  --agent-runtime-id "$RUNTIME_ID" 2>&1 || log "runtime delete failed (may already be gone)"

rm -f "$STATE_FILE"
log "cleaned up"
