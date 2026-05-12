#!/usr/bin/env bash
# create-gateway.sh — idempotent AgentCore Gateway + Lambda target provisioner
set -euo pipefail

: "${AWS_REGION:?required}"
: "${GATEWAY_NAME:?required}"
: "${GATEWAY_ROLE_ARN:?required}"
: "${TARGET_NAME:?required}"
: "${JWT_ISSUER:?required}"
: "${JWT_AUDIENCE:?required}"
: "${STATE_FILE:?required}"
# LAMBDA_ARN is optional — when empty, the Gateway is created without any target
# (useful when the Lambda is SCP-blocked; targets can be registered later).
LAMBDA_ARN="${LAMBDA_ARN:-}"

log() { echo "[agentcore-gateway] $*"; }

# ── Gateway — create or reuse ────────────────────────────────────────────────
EXISTING_GW=$(aws bedrock-agentcore-control list-gateways \
  --region "$AWS_REGION" \
  --query "items[?name=='${GATEWAY_NAME}'].{id:gatewayId,arn:gatewayArn,url:gatewayUrl} | [0]" \
  --output json 2>/dev/null || echo "null")

if [[ "$EXISTING_GW" != "null" && "$EXISTING_GW" != "" ]]; then
  GATEWAY_ID=$(echo "$EXISTING_GW" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id') or '')")
  GATEWAY_ARN=$(echo "$EXISTING_GW" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('arn') or '')")
  GATEWAY_URL=$(echo "$EXISTING_GW" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('url') or '')")
  log "reusing gateway: $GATEWAY_ID"
else
  log "creating gateway: $GATEWAY_NAME"
  AUTH_CFG=$(python3 -c "
import json
print(json.dumps({'customJWTAuthorizer': {'discoveryUrl': '${JWT_ISSUER}/.well-known/openid-configuration', 'allowedAudience': ['${JWT_AUDIENCE}']}}))
")
  TAG_ARG=()
  if [[ -n "${RESOURCE_TAGS:-}" ]]; then
    TAG_ARG=(--tags "$RESOURCE_TAGS")
  fi
  RESULT=$(aws bedrock-agentcore-control create-gateway \
    --region "$AWS_REGION" \
    --name "$GATEWAY_NAME" \
    --role-arn "$GATEWAY_ROLE_ARN" \
    --protocol-type MCP \
    --authorizer-type CUSTOM_JWT \
    --authorizer-configuration "$AUTH_CFG" \
    "${TAG_ARG[@]}" \
    --output json)

  GATEWAY_ID=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('gatewayId') or d.get('id') or '')")
  GATEWAY_ARN=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('gatewayArn') or d.get('arn') or '')")
  GATEWAY_URL=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('gatewayUrl') or d.get('url') or '')")
  log "created gateway: $GATEWAY_ID"
fi

if [[ -z "$GATEWAY_ID" ]]; then
  log "ERROR: gateway ID missing from response" >&2
  exit 1
fi

# ── IAM propagation wait — trust policy needs ~15s to reach AgentCore service ──
# Without this sleep, CreateGatewayTarget fails with:
#   "Gateway service is not authorized to perform AssumeRole on Gateway role"
# This is an AWS eventual-consistency behaviour, not a bug in the role definition.
if [[ -n "$LAMBDA_ARN" ]]; then
  log "waiting 15s for IAM trust policy to propagate before registering target..."
  sleep 15
fi

# ── Target — MongoDB MCP Lambda (only if LAMBDA_ARN is set) ──────────────────
if [[ -z "$LAMBDA_ARN" ]]; then
  log "LAMBDA_ARN empty — creating Gateway WITHOUT a tool target."
  log "Register a target later with: aws bedrock-agentcore-control create-gateway-target ..."
  TARGET_ID=""
else
EXISTING_TG=$(aws bedrock-agentcore-control list-gateway-targets \
  --region "$AWS_REGION" \
  --gateway-identifier "$GATEWAY_ID" \
  --query "items[?name=='${TARGET_NAME}'].targetId | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "$EXISTING_TG" != "None" && -n "$EXISTING_TG" ]]; then
  log "reusing target: $EXISTING_TG"
  TARGET_ID="$EXISTING_TG"
else
  log "creating target: $TARGET_NAME → $LAMBDA_ARN"
  TARGET_CFG=$(python3 -c "
import json
print(json.dumps({
  'mcp': {
    'lambda': {
      'lambdaArn': '${LAMBDA_ARN}',
      'toolSchema': {
        'inlinePayload': [
          {'name': 'mongodb_query',         'description': 'Find documents matching a BSON filter.',             'inputSchema': {'type': 'object', 'properties': {'collection': {'type':'string'}, 'filter': {'type':'object'}, 'limit': {'type':'integer'}},     'required': ['collection']}},
          {'name': 'mongodb_vector_search', 'description': 'Run an Atlas \$vectorSearch aggregation.',            'inputSchema': {'type': 'object', 'properties': {'collection': {'type':'string'}, 'index': {'type':'string'}, 'queryVector': {'type':'array', 'items': {'type':'number'}}, 'limit': {'type':'integer'}}, 'required': ['collection','index','queryVector']}},
          {'name': 'mongodb_aggregate',     'description': 'Run an arbitrary MongoDB aggregation pipeline.',     'inputSchema': {'type': 'object', 'properties': {'collection': {'type':'string'}, 'pipeline': {'type':'array'}},  'required': ['collection','pipeline']}}
        ]
      }
    }
  }
}))
")
  TARGET_RESULT=$(aws bedrock-agentcore-control create-gateway-target \
    --region "$AWS_REGION" \
    --gateway-identifier "$GATEWAY_ID" \
    --name "$TARGET_NAME" \
    --target-configuration "$TARGET_CFG" \
    --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' \
    --output json)
  TARGET_ID=$(echo "$TARGET_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('targetId') or '')")
  log "created target: $TARGET_ID"
fi
fi  # end: if LAMBDA_ARN empty

# ── Fetch gateway URL if not returned yet (some API versions populate later) ──
if [[ -z "$GATEWAY_URL" ]]; then
  GATEWAY_URL=$(aws bedrock-agentcore-control get-gateway \
    --region "$AWS_REGION" \
    --gateway-identifier "$GATEWAY_ID" \
    --query 'gatewayUrl' --output text 2>/dev/null || echo "")
fi

python3 -c "
import json
with open('$STATE_FILE','w') as f:
  json.dump({
    'gateway_id':  '$GATEWAY_ID',
    'gateway_arn': '$GATEWAY_ARN',
    'mcp_url':     '$GATEWAY_URL',
    'target_id':   '$TARGET_ID',
    'name':        '$GATEWAY_NAME'
  }, f, indent=2)
"
log "state written: $STATE_FILE"
log "gateway MCP URL: $GATEWAY_URL"
