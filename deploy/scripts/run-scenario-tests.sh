#!/usr/bin/env bash
# run-scenario-tests.sh — T1–T12 scenario matrix for embedding/MCP hardening.
# Usage: source .env && bash deploy/scripts/run-scenario-tests.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

export PATH="${HOME}/.bun/bin:${PATH}"

_pass=0
_fail=0
_skip=0

result() {
  local id="$1" status="$2" detail="${3:-}"
  if [[ "$status" == "PASS" ]]; then
    echo "  ✓ ${id}: PASS ${detail}"
    _pass=$(( _pass + 1 ))
  elif [[ "$status" == "SKIP" ]]; then
    echo "  ⊘ ${id}: SKIP ${detail}"
    _skip=$(( _skip + 1 ))
  else
    echo "  ✗ ${id}: FAIL ${detail}"
    _fail=$(( _fail + 1 ))
  fi
}

# Safe .env.live readers (avoid sourcing — URIs contain &)
_ev() { awk -F= -v k="$1" '$1==k {sub(/^[^=]+=/,""); print; exit}' .env.live 2>/dev/null || true; }

MONGODB_URI="$(_ev MONGODB_URI)"
MONGODB_URI_PUBLIC="$(_ev MONGODB_URI_PUBLIC)"
MONGODB_DB="$(_ev MONGODB_DB)"
EMBEDDINGS_PROVIDER="${EMBEDDINGS_PROVIDER:-$(_ev EMBEDDINGS_PROVIDER)}"
EMBEDDING_DIMENSIONS="${EMBEDDING_DIMENSIONS:-$(_ev VOYAGE_OUTPUT_DIM)}"
[[ -n "$EMBEDDING_DIMENSIONS" ]] || EMBEDDING_DIMENSIONS=1024
VOYAGE_SAGEMAKER_ENDPOINT="$(_ev VOYAGE_SAGEMAKER_ENDPOINT)"
BEDROCK_KB_ID="$(_ev BEDROCK_KB_ID)"
KB_DATA_SOURCE_ID="${KB_DATA_SOURCE_ID:-$(_ev KB_DATA_SOURCE_ID)}"
AGENTCORE_GATEWAY_URL="$(_ev AGENTCORE_GATEWAY_URL)"
STREAMLIT_API_URL="$(_ev STREAMLIT_API_URL)"
COGNITO_CLIENT_ID="$(_ev STREAMLIT_COGNITO_CLIENT_ID)"
EC2_IP="${EC2_IP:-$(echo "$STREAMLIT_API_URL" | sed -E 's|http://([^:/]+).*|\1|')}"
NETWORK_MODE="${NETWORK_MODE:-privatelink}"
ATLAS_PRIVATELINK_ENDPOINT_ID="${ATLAS_PRIVATELINK_ENDPOINT_ID:-}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

echo "════════════════════════════════════════════════════════════════"
echo "  Scenario tests T1–T12 (repo: ${REPO_ROOT})"
echo "  EC2=${EC2_IP} DB=${MONGODB_DB} PROVIDER=${EMBEDDINGS_PROVIDER}"
echo "════════════════════════════════════════════════════════════════"

# ── T1: assert_mongo_reachable happy-path (public SRV) + network path warn ──
echo ""
echo "── T1: mongo-connect happy-path ──"
set +e
T1_OUT=$(NETWORK_MODE=privatelink bash -c "source deploy/scripts/_mongo-connect.sh && assert_mongo_reachable '${MONGODB_URI_PUBLIC}' '${MONGODB_DB}' 30" 2>&1)
T1_RC=$?
set -e
if [[ $T1_RC -eq 0 ]]; then
  if echo "$T1_OUT" | grep -q "NETWORK_MODE=privatelink but MONGODB_URI is mongodb+srv"; then
    result T1 PASS "(reachable + PL/+srv mismatch warned as expected)"
  else
    result T1 PASS "(reachable)"
  fi
else
  result T1 FAIL "rc=${T1_RC} $(echo "$T1_OUT" | tail -3 | tr '\n' ' ')"
fi

# ── T2: failure envelopes ──
echo ""
echo "── T2: mongo-connect failure modes ──"
set +e
bash -c 'source deploy/scripts/_mongo-connect.sh && assert_mongo_reachable "" "db" 5' >/dev/null 2>&1
T2A=$?
bash -c 'source deploy/scripts/_mongo-connect.sh && assert_mongo_reachable "mongodb://u:p@host:27017/" "" 5' >/dev/null 2>&1
T2B=$?
T2C_OUT=$(NETWORK_MODE=peering bash -c 'source deploy/scripts/_mongo-connect.sh && assert_mongo_reachable "mongodb://u:p@unreachable.invalid:27017/?ssl=true" "db" 12' 2>&1)
T2C=$?
set -e
if [[ $T2A -eq 1 && $T2B -eq 1 && $T2C -eq 2 && "$T2C_OUT" == *"mongo connectivity failure"* ]]; then
  result T2 PASS "(empty uri=1 empty db=1 unreachable=2 + envelope)"
else
  result T2 FAIL "rcs=${T2A}/${T2B}/${T2C}"
fi

# ── T3–T7: preflight checks (live AWS + Mongo) ──
source deploy/scripts/_preflight-checks.sh
export MONGODB_URI_PUBLIC MONGODB_DB EMBEDDINGS_PROVIDER EMBEDDING_DIMENSIONS
export VOYAGE_SAGEMAKER_ENDPOINT BEDROCK_KB_ID NETWORK_MODE ATLAS_PRIVATELINK_ENDPOINT_ID
export MONGODB_URI AGENTCORE_GATEWAY_URL PROJECT_NAME ENVIRONMENT AWS_REGION SHARED_VPC_NAME

_run_pf() {
  local id="$1" fn="$2"
  PREFLIGHT_FAILED_IDS=()
  PREFLIGHT_PASSED_IDS=()
  PREFLIGHT_SKIPPED_IDS=()
  "$fn" >/dev/null 2>&1 || true
  local obs
  if _pf_in_array "$fn" "${PREFLIGHT_PASSED_IDS[@]}"; then
    result "$id" PASS "($fn)"
  elif _pf_in_array "$fn" "${PREFLIGHT_FAILED_IDS[@]}"; then
    obs="$(_pf_get PREFLIGHT_FAIL_OBSERVED "$fn")"
    result "$id" FAIL "${obs}"
  elif _pf_in_array "$fn" "${PREFLIGHT_SKIPPED_IDS[@]}"; then
    obs="$(_pf_get PREFLIGHT_SKIP_REASON "$fn")"
    result "$id" SKIP "${obs}"
  else
    result "$id" FAIL "($fn: no pass/fail recorded)"
  fi
}

echo ""
echo "── T3: pf_check_documents_have_embeddings ──"
_run_pf T3 pf_check_documents_have_embeddings

echo ""
echo "── T4: pf_check_embedding_dim_consistency ──"
_run_pf T4 pf_check_embedding_dim_consistency

echo ""
echo "── T5: pf_check_mcp_runtime_env_complete ──"
# Needs runtime ARNs from .env.live
export AGENTCORE_ORCHESTRATOR_ARN="$(_ev AGENTCORE_ORCHESTRATOR_ARN)"
export AGENTCORE_ORDER_MANAGEMENT_ARN="$(_ev AGENTCORE_ORDER_MANAGEMENT_ARN)"
export AGENTCORE_PRODUCT_RECOMMENDATION_ARN="$(_ev AGENTCORE_PRODUCT_RECOMMENDATION_ARN)"
export AGENTCORE_TROUBLESHOOTING_ARN="$(_ev AGENTCORE_TROUBLESHOOTING_ARN)"
MONGODB_MCP_RUNTIME_ARN=$(cd deploy/terraform/envs/ec2 && terraform output -raw mongodb_mcp_runtime_arn 2>/dev/null || true)
MONGODB_MCP_RUNTIME_ID=$(cd deploy/terraform/envs/ec2 && terraform output -raw mongodb_mcp_runtime_id 2>/dev/null || true)
export MONGODB_MCP_RUNTIME_ARN MONGODB_MCP_RUNTIME_ID
_run_pf T5 pf_check_mcp_runtime_env_complete

echo ""
echo "── T6: pf_check_privatelink_endpoint_available ──"
if [[ "$NETWORK_MODE" == "privatelink" ]]; then
  ATLAS_PRIVATELINK_ENDPOINT_ID="${ATLAS_PRIVATELINK_ENDPOINT_ID:-$(cd deploy/terraform/envs/ec2 && terraform output -raw atlas_privatelink_endpoint_id 2>/dev/null || true)}"
  export ATLAS_PRIVATELINK_ENDPOINT_ID
  _run_pf T6 pf_check_privatelink_endpoint_available
else
  result T6 SKIP "(NETWORK_MODE=${NETWORK_MODE})"
fi

echo ""
echo "── T7: pf_check_kb_ingestion_complete ──"
if [[ -n "$BEDROCK_KB_ID" ]]; then
  KB_DATA_SOURCE_ID="${KB_DATA_SOURCE_ID:-$(cd deploy/terraform/envs/ec2 && terraform output -raw kb_data_source_id 2>/dev/null || true)}"
  export KB_DATA_SOURCE_ID
  _run_pf T7 pf_check_kb_ingestion_complete
else
  result T7 SKIP "(no BEDROCK_KB_ID)"
fi

# ── T8: /health/deep authenticated ──
echo ""
echo "── T8: /health/deep via EC2 API ──"
COGNITO_SMOKE_USER_EMAIL="${COGNITO_SMOKE_USER_EMAIL:-alex@example.com}"
COGNITO_TEST_PASSWORD="${COGNITO_TEST_PASSWORD:-DemoUser#2026}"
COGNITO_CLIENT_ID="${COGNITO_CLIENT_ID:-$(cd deploy/terraform/envs/ec2 && terraform output -raw cognito_app_client_id 2>/dev/null || true)}"
if [[ -z "$COGNITO_CLIENT_ID" || -z "$EC2_IP" ]]; then
  result T8 SKIP "(missing cognito client or EC2 IP)"
else
  SMOKE_ID_TOKEN=$(aws cognito-idp initiate-auth \
    --region "$AWS_REGION" \
    --client-id "$COGNITO_CLIENT_ID" \
    --auth-flow USER_PASSWORD_AUTH \
    --auth-parameters "USERNAME=${COGNITO_SMOKE_USER_EMAIL},PASSWORD=${COGNITO_TEST_PASSWORD}" \
    --query "AuthenticationResult.IdToken" --output text 2>/dev/null || echo "")
  if [[ -z "$SMOKE_ID_TOKEN" || "$SMOKE_ID_TOKEN" == "None" ]]; then
    result T8 FAIL "(cognito auth failed)"
  else
    T8_CODE=$(curl -s --max-time 20 -o /tmp/t8.body -w "%{http_code}" -H "Authorization: Bearer $SMOKE_ID_TOKEN" "http://${EC2_IP}:3000/health/deep" 2>/dev/null || echo "000")
    if [[ "$T8_CODE" == "404" ]]; then
      result T8 FAIL "(http=404 /health/deep route missing — rebuild API: ./deploy/deploy-api.sh)"
    else
      DEEP="$(cat /tmp/t8.body 2>/dev/null || true)"
      MCP_PROBE=$(python3 -c "import json,sys; d=json.loads(sys.argv[1] or '{}'); print(d.get('mcpProbe',''))" "$DEEP" 2>/dev/null || echo "")
      if [[ "$MCP_PROBE" == "connected" ]]; then
        result T8 PASS "(mcpProbe=connected http=${T8_CODE})"
      else
        result T8 FAIL "(http=${T8_CODE} mcpProbe=${MCP_PROBE:-empty} payload=$(echo "$DEEP" | head -c 200))"
      fi
    fi
  fi
fi

# ── T9: run_embedding_seed idempotent ──
echo ""
echo "── T9: run_embedding_seed (idempotent) ──"
if [[ ! -f deploy/scripts/_seed-embeddings.sh ]]; then
  result T9 SKIP "(helper missing)"
else
  source deploy/scripts/_mongo-connect.sh
  source deploy/scripts/_seed-embeddings.sh
  set +e
  T9_OUT=$(run_embedding_seed "$MONGODB_DB" "$MONGODB_URI_PUBLIC" 2>&1)
  T9_RC=$?
  set -e
  if [[ $T9_RC -eq 0 ]]; then
    result T9 PASS "(seed completed)"
  else
    result T9 FAIL "rc=${T9_RC} $(echo "$T9_OUT" | tail -5 | tr '\n' ' ')"
  fi
fi

# ── T10: re-check embeddings after seed ──
echo ""
echo "── T10: corpus embeddings after seed ──"
_run_pf T10 pf_check_documents_have_embeddings

# ── T11: post-deploy-smoke.py ──
echo ""
echo "── T11: post-deploy-smoke.py ──"
# T11 runs in isolation (no prior chat traffic), so the LTM-embedding window
# check (which requires fresh agent_memory_facts within the last hour) cannot
# pass. Set SKIP_LTM_CHECK=1 to scope the test to the deploy-time invariants
# (Mongo reachability, KB connectivity, runtime env wiring, corpus embeddings).
set +e
T11_OUT=$(source .env 2>/dev/null; SKIP_LTM_CHECK=1 python3 e2e-smoke/post-deploy-smoke.py 2>&1)
T11_RC=$?
set -e
if [[ $T11_RC -eq 0 ]]; then
  result T11 PASS ""
else
  result T11 FAIL "rc=${T11_RC} $(echo "$T11_OUT" | grep -E 'FAIL|ERROR|✗' | tail -5 | tr '\n' ' ')"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Summary: ${_pass} passed, ${_fail} failed, ${_skip} skipped"
echo "════════════════════════════════════════════════════════════════"
[[ $_fail -eq 0 ]]
