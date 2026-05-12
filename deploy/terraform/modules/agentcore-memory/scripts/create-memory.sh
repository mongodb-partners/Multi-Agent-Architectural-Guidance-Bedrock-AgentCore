#!/usr/bin/env bash
# create-memory.sh — idempotent AgentCore Memory Store provisioner
set -euo pipefail

: "${AWS_REGION:?required}"
: "${MEMORY_NAME:?required}"
: "${EVENT_EXPIRY_DAYS:?required}"
: "${STATE_FILE:?required}"

# Reuse existing memory if name already exists (idempotent re-apply)
EXISTING=$(aws bedrock-agentcore-control list-memories \
  --region "$AWS_REGION" \
  --query "memories[?name=='${MEMORY_NAME}'].{id:id,arn:arn} | [0]" \
  --output json 2>/dev/null || echo "null")

if [[ "$EXISTING" != "null" && "$EXISTING" != "" ]]; then
  MEMORY_ID=$(echo "$EXISTING" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id') or '')")
  MEMORY_ARN=$(echo "$EXISTING" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('arn') or '')")
  echo "[agentcore-memory] reusing existing: $MEMORY_ID"
else
  echo "[agentcore-memory] creating: $MEMORY_NAME (event expiry ${EVENT_EXPIRY_DAYS}d)"
  # Build optional --tags argument from RESOURCE_TAGS="K=V,K=V". Empty = no tags.
  TAG_ARG=()
  if [[ -n "${RESOURCE_TAGS:-}" ]]; then
    TAG_ARG=(--tags "$RESOURCE_TAGS")
  fi
  RESULT=$(aws bedrock-agentcore-control create-memory \
    --region "$AWS_REGION" \
    --name "$MEMORY_NAME" \
    --event-expiry-duration "$EVENT_EXPIRY_DAYS" \
    "${TAG_ARG[@]}" \
    --output json)
  MEMORY_ID=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); m=d.get('memory',d); print(m.get('id') or m.get('memoryId') or '')")
  MEMORY_ARN=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); m=d.get('memory',d); print(m.get('arn') or m.get('memoryArn') or '')")
  echo "[agentcore-memory] created: $MEMORY_ID"
fi

if [[ -z "$MEMORY_ID" ]]; then
  echo "[agentcore-memory] ERROR: memory ID missing from response" >&2
  exit 1
fi

python3 -c "
import json
with open('$STATE_FILE','w') as f:
  json.dump({'memory_id': '$MEMORY_ID', 'memory_arn': '$MEMORY_ARN', 'name': '$MEMORY_NAME'}, f, indent=2)
"
echo "[agentcore-memory] state written: $STATE_FILE"
