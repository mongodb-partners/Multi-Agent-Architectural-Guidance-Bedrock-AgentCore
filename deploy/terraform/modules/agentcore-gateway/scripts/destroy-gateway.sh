#!/usr/bin/env bash
# destroy-gateway.sh — delete AgentCore Gateway (targets first)
set -euo pipefail

: "${AWS_REGION:?required}"
: "${STATE_FILE:?required}"

log() { echo "[agentcore-gateway] $*"; }

if [[ ! -f "$STATE_FILE" ]]; then
  log "no state file — nothing to delete"
  exit 0
fi

GATEWAY_ID=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('gateway_id',''))" 2>/dev/null || echo "")
TARGET_ID=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('target_id',''))" 2>/dev/null || echo "")

if [[ -z "$GATEWAY_ID" ]]; then
  log "no gateway_id in state — skipping"
  rm -f "$STATE_FILE"
  exit 0
fi

# Delete target first (gateway cannot be deleted with active targets)
if [[ -n "$TARGET_ID" ]]; then
  log "deleting target: $TARGET_ID"
  aws bedrock-agentcore-control delete-gateway-target \
    --region "$AWS_REGION" \
    --gateway-identifier "$GATEWAY_ID" \
    --target-id "$TARGET_ID" 2>&1 || log "target delete failed (may already be gone)"
fi

log "deleting gateway: $GATEWAY_ID"
aws bedrock-agentcore-control delete-gateway \
  --region "$AWS_REGION" \
  --gateway-identifier "$GATEWAY_ID" 2>&1 || log "gateway delete failed (may already be gone)"

rm -f "$STATE_FILE"
log "cleaned up"
