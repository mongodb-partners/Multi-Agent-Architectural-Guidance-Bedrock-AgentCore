#!/usr/bin/env bash
# create-runtime.sh — idempotent AgentCore Runtime + DEFAULT endpoint provisioner
set -euo pipefail

: "${AWS_REGION:?required}"
: "${RUNTIME_NAME:?required}"
: "${DEPLOYMENT_MODE:=container}"
: "${ROLE_ARN:?required}"
: "${NETWORK_MODE:?required}"
: "${IDLE_TIMEOUT:?required}"
: "${STATE_FILE:?required}"
# ENV_JSON and RESOURCE_TAGS are optional
ENV_JSON="${ENV_JSON:-{}}"
RESOURCE_TAGS="${RESOURCE_TAGS:-}"
CODE_BUCKET="${CODE_BUCKET:-}"
CODE_PREFIX="${CODE_PREFIX:-}"
CODE_VERSION="${CODE_VERSION:-}"
CODE_RUNTIME="${CODE_RUNTIME:-NODE_22}"
CODE_ENTRYPOINT="${CODE_ENTRYPOINT:-[\"agent-runtime-code.js\"]}"

if [[ "$DEPLOYMENT_MODE" == "container" ]]; then
  : "${CONTAINER_URI:?required when DEPLOYMENT_MODE=container}"
elif [[ "$DEPLOYMENT_MODE" == "code" ]]; then
  : "${CODE_BUCKET:?required when DEPLOYMENT_MODE=code}"
  : "${CODE_PREFIX:?required when DEPLOYMENT_MODE=code}"
else
  log "ERROR: DEPLOYMENT_MODE must be container or code (got: $DEPLOYMENT_MODE)" >&2
  exit 1
fi

log() { echo "[agentcore-runtime] $*"; }

# ── Build network configuration ───────────────────────────────────────────────
if [[ "$NETWORK_MODE" == "PUBLIC" ]]; then
  NETWORK_CFG='{"networkMode":"PUBLIC"}'
else
  # VPC mode requires subnet/SG passed via ENV_JSON extras — not implemented for POC
  log "ERROR: VPC network mode not implemented in this script. Use PUBLIC for POC." >&2
  exit 1
fi

# ── Build environment variables JSON for AWS CLI ──────────────────────────────
# ENV_JSON shape: {"KEY": "VALUE", ...}
# AWS CLI shape:  {"KEY": {"value": "VALUE"}, ...}
ENV_CLI_JSON=$(echo "$ENV_JSON" | python3 -c "
import json,sys
text = sys.stdin.read().strip()
if not text:
  text = '{}'
try:
  raw = json.loads(text)
except json.JSONDecodeError:
  # Some shells/providers may append stray output; keep the first JSON object.
  raw, _ = json.JSONDecoder().raw_decode(text)
if not isinstance(raw, dict):
  raise SystemExit('ENV_JSON must decode to an object')
print(json.dumps({k: str(v) for k, v in raw.items()}))
")

# ── Runtime — create or reuse ─────────────────────────────────────────────────
if [[ "$DEPLOYMENT_MODE" == "container" ]]; then
  ARTIFACT_JSON=$(python3 -c "
import json, os
print(json.dumps({'containerConfiguration': {'containerUri': os.environ['CONTAINER_URI']}}))
")
else
  ARTIFACT_JSON=$(python3 -c "
import json, os
entry = json.loads(os.environ.get('CODE_ENTRYPOINT', '[\"agent-runtime-code.js\"]'))
if not isinstance(entry, list) or not entry:
  raise SystemExit('CODE_ENTRYPOINT must be a non-empty JSON array')
s3 = {'bucket': os.environ['CODE_BUCKET'], 'prefix': os.environ['CODE_PREFIX']}
ver = os.environ.get('CODE_VERSION', '').strip()
if ver:
  s3['versionId'] = ver
artifact = {
  'codeConfiguration': {
    'code': {'s3': s3},
    'runtime': os.environ.get('CODE_RUNTIME', 'NODE_22'),
    'entryPoint': entry
  }
}
print(json.dumps(artifact))
")
fi

EXISTING=$(aws bedrock-agentcore-control list-agent-runtimes \
  --region "$AWS_REGION" \
  --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].{id:agentRuntimeId,arn:agentRuntimeArn,status:status} | [0]" \
  --output json 2>/dev/null || echo "null")

if [[ "$EXISTING" != "null" && -n "$EXISTING" && "$EXISTING" != "{}" ]]; then
  RUNTIME_ID=$(echo "$EXISTING"  | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")
  RUNTIME_ARN=$(echo "$EXISTING" | python3 -c "import json,sys; print(json.load(sys.stdin).get('arn',''))")
  log "reusing runtime: $RUNTIME_ID"
else
  log "creating runtime: $RUNTIME_NAME (network: $NETWORK_MODE)"

  TAG_ARG=()
  if [[ -n "$RESOURCE_TAGS" ]]; then
    TAG_ARG=(--tags "$RESOURCE_TAGS")
  fi

  RESULT=""
  for i in $(seq 1 10); do
    set +e
    RESULT=$(aws bedrock-agentcore-control create-agent-runtime \
      --region "$AWS_REGION" \
      --agent-runtime-name "$RUNTIME_NAME" \
      --agent-runtime-artifact "$ARTIFACT_JSON" \
      --role-arn "$ROLE_ARN" \
      --network-configuration "$NETWORK_CFG" \
      --lifecycle-configuration "{\"idleRuntimeSessionTimeout\":${IDLE_TIMEOUT}}" \
      --environment-variables "$ENV_CLI_JSON" \
      "${TAG_ARG[@]}" \
      --output json 2>&1)
    rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
      break
    fi

    if [[ "$RESULT" == *"Role validation failed"* ]]; then
      log "IAM role propagation in progress ($i/10), waiting 15s..."
      sleep 15
      continue
    fi

    log "ERROR: create-agent-runtime failed: $RESULT" >&2
    exit $rc
  done

  if [[ -z "$RESULT" || "$RESULT" != *"agentRuntime"* ]]; then
    log "ERROR: create-agent-runtime did not return success payload: $RESULT" >&2
    exit 1
  fi

  RUNTIME_ID=$(echo "$RESULT"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agentRuntimeId') or d.get('id') or '')")
  RUNTIME_ARN=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agentRuntimeArn') or d.get('arn') or '')")
  log "created runtime: $RUNTIME_ID — waiting for READY..."

  # Poll until READY (create is async — can take 3-8 min on first deploy)
  for i in $(seq 1 40); do
    STATUS=$(aws bedrock-agentcore-control get-agent-runtime \
      --region "$AWS_REGION" \
      --agent-runtime-id "$RUNTIME_ID" \
      --query 'status' --output text 2>/dev/null || echo "UNKNOWN")
    log "  status ($i/40): $STATUS"
    [[ "$STATUS" == "READY" ]] && break
    [[ "$STATUS" == "CREATE_FAILED" || "$STATUS" == "FAILED" ]] && {
      log "ERROR: runtime creation failed (status: $STATUS)" >&2
      exit 1
    }
    sleep 15
  done
fi

if [[ -z "$RUNTIME_ID" ]]; then
  log "ERROR: runtime ID missing from response" >&2
  exit 1
fi

# ── DEFAULT endpoint — create or reuse ───────────────────────────────────────
EXISTING_EP=$(aws bedrock-agentcore-control list-agent-runtime-endpoints \
  --region "$AWS_REGION" \
  --agent-runtime-id "$RUNTIME_ID" \
  --query "runtimeEndpoints[?name=='DEFAULT'].{id:id,status:status} | [0]" \
  --output json 2>/dev/null || echo "null")

if [[ "$EXISTING_EP" != "null" && -n "$EXISTING_EP" && "$EXISTING_EP" != "{}" ]]; then
  ENDPOINT_ID=$(echo "$EXISTING_EP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")
  log "reusing endpoint: $ENDPOINT_ID"
else
  log "creating DEFAULT endpoint for runtime: $RUNTIME_ID"
  EP_RESULT=$(aws bedrock-agentcore-control create-agent-runtime-endpoint \
    --region "$AWS_REGION" \
    --agent-runtime-id "$RUNTIME_ID" \
    --name "DEFAULT" \
    --output json)
  ENDPOINT_ID=$(echo "$EP_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('agentRuntimeEndpointId') or d.get('id') or '')")
  log "created endpoint: $ENDPOINT_ID"
fi

# ── Write state file ──────────────────────────────────────────────────────────
python3 -c "
import json
with open('$STATE_FILE','w') as f:
  json.dump({
    'runtime_id':   '$RUNTIME_ID',
    'runtime_arn':  '$RUNTIME_ARN',
    'endpoint_id':  '$ENDPOINT_ID',
    'name':         '$RUNTIME_NAME'
  }, f, indent=2)
"
log "state written: $STATE_FILE"
log "runtime ARN: $RUNTIME_ARN"
