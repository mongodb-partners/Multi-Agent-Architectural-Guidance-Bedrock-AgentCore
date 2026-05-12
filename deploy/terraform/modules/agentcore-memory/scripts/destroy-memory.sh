#!/usr/bin/env bash
# destroy-memory.sh — delete AgentCore Memory Store from state file
set -euo pipefail

: "${AWS_REGION:?required}"
: "${STATE_FILE:?required}"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "[agentcore-memory] no state file — nothing to delete"
  exit 0
fi

MEMORY_ID=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('memory_id',''))" 2>/dev/null || echo "")

if [[ -z "$MEMORY_ID" ]]; then
  echo "[agentcore-memory] no memory_id in state file — skipping"
  rm -f "$STATE_FILE"
  exit 0
fi

echo "[agentcore-memory] deleting: $MEMORY_ID"
aws bedrock-agentcore-control delete-memory \
  --region "$AWS_REGION" \
  --memory-id "$MEMORY_ID" 2>&1 || echo "[agentcore-memory] delete failed (may already be gone)"

rm -f "$STATE_FILE"
echo "[agentcore-memory] cleaned up"
