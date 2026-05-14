#!/usr/bin/env bash
# =============================================================================
# probe-resources.sh — combined local + EC2 permission smoke test
#
# For every resource defined in deploy/terraform/envs/local and envs/ec2,
# this script attempts to CREATE it (exact terraform name), VALIDATE it, and
# DELETE it — then prints an access matrix showing what this AWS account can
# and cannot do.
#
# Usage:
#   source env.sh
#   bash deploy/scripts/probe-resources.sh               # fast probes (~5 min)
#   bash deploy/scripts/probe-resources.sh --with-ec2    # + full VPC+EC2 CRUD (~5 min)
#   bash deploy/scripts/probe-resources.sh --with-cluster # + Atlas M10 CRUD (~20 min)
#   bash deploy/scripts/probe-resources.sh --with-bedrock-kb # + Bedrock KB (needs cluster)
#   bash deploy/scripts/probe-resources.sh --with-sagemaker  # + SageMaker endpoint config
#   bash deploy/scripts/probe-resources.sh --all         # everything
#
# Probe types:
#   CRUD      — create → validate → delete (full lifecycle)
#   api-only  — read-only reachability check (no resource created)
#   skipped   — requires a flag to enable
# =============================================================================
set -uo pipefail   # no -e — keep going on per-probe failures

# ─── Colours ────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'
hdr() { printf "\n${BOLD}── %s ──${NC}\n" "$*"; }
ok()  { printf "  ${G}✓${NC} %s\n" "$*"; }
no()  { printf "  ${R}✗${NC} %s\n" "$*"; }
inf() { printf "  ${B}·${NC} %s\n" "$*"; }
wrn() { printf "  ${Y}⚠${NC} %s\n" "$*"; }

# ─── Result tracking ─────────────────────────────────────────────────────────
declare -a RESULTS=()
rec() { RESULTS+=("$1|$2|$3|$4"); }  # name | create | validate | delete

# ─── Flags ───────────────────────────────────────────────────────────────────
WITH_EC2=false; WITH_CLUSTER=false; WITH_KB=false; WITH_SAGEMAKER=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-ec2)        WITH_EC2=true ;;
    --with-cluster)    WITH_CLUSTER=true ;;
    --with-bedrock-kb) WITH_KB=true; WITH_CLUSTER=true ;;
    --with-sagemaker)  WITH_SAGEMAKER=true ;;
    --all)             WITH_EC2=true; WITH_CLUSTER=true; WITH_KB=true; WITH_SAGEMAKER=true ;;
    -h|--help)         sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown: $1" >&2; exit 1 ;;
  esac; shift
done

# ─── Load env ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
[[ -f "$REPO_ROOT/env.sh" ]] && source "$REPO_ROOT/env.sh"

for v in AWS_REGION PROJECT_NAME ENVIRONMENT ATLAS_DB_USER ATLAS_DB_NAME \
          TF_VAR_atlas_project_id TF_VAR_atlas_db_password \
          MONGODB_ATLAS_PUBLIC_KEY MONGODB_ATLAS_PRIVATE_KEY; do
  [[ -z "${!v:-}" ]] && { echo "ERROR: $v not set — source env.sh first" >&2; exit 1; }
done

# ─── Pre-flight ──────────────────────────────────────────────────────────────
hdr "Pre-flight"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || { echo "ERROR: AWS STS failed — source env.sh"; exit 1; }
ok "AWS STS — account=$ACCOUNT_ID region=$AWS_REGION"

ATLAS_HTTP=$(curl -s -o /tmp/.atlas.json -w "%{http_code}" \
  --user "${MONGODB_ATLAS_PUBLIC_KEY}:${MONGODB_ATLAS_PRIVATE_KEY}" --digest \
  -H "Accept: application/vnd.atlas.2024-05-30+json" \
  "https://cloud.mongodb.com/api/atlas/v2/groups/${TF_VAR_atlas_project_id}")
[[ "$ATLAS_HTTP" == "200" ]] && ok "Atlas API — project $TF_VAR_atlas_project_id" \
  || { no "Atlas API HTTP $ATLAS_HTTP"; exit 1; }

# ─── Terraform-generated names (exact match) ─────────────────────────────────
# Every account/region-global resource is prefixed with project_name AND
# environment so multiple deployments in one AWS account cannot collide.
SHARED_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-${ACCOUNT_ID}"
KB_ROLE_NAME="${PROJECT_NAME}-bedrock-kb-${ENVIRONMENT}-role"
EC2_ROLE_NAME="${PROJECT_NAME}-ec2-role-${ENVIRONMENT}"
EC2_PROFILE_NAME="${PROJECT_NAME}-ec2-profile-${ENVIRONMENT}"
SM_ROLE_NAME="${PROJECT_NAME}-sagemaker-voyage-exec-${ENVIRONMENT}"
GW_ROLE_NAME="${PROJECT_NAME}-agentcore-gw-${ENVIRONMENT}"
SECRET_NAME="${PROJECT_NAME}-bedrock-kb-creds-${ENVIRONMENT}"
KB_NAME="${PROJECT_NAME}-troubleshooting-kb-${ENVIRONMENT}"
CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}"
ECR_API="${PROJECT_NAME}-api-${ENVIRONMENT}"
ECR_UI="${PROJECT_NAME}-ui-${ENVIRONMENT}"
COGNITO_POOL="${PROJECT_NAME}-users-${ENVIRONMENT}"
VPC_NAME="${PROJECT_NAME}-vpc-${ENVIRONMENT}"
LG_PREFIX="/${PROJECT_NAME}/${ENVIRONMENT}"
SM_ENDPOINT="${PROJECT_NAME}-voyage-3-${ENVIRONMENT}"
MEMORY_NAME="${PROJECT_NAME//-/_}_memory_${ENVIRONMENT}"
GATEWAY_NAME="${PROJECT_NAME//-/_}_gw_${ENVIRONMENT}"

inf "names: bucket=$SHARED_BUCKET cluster=$CLUSTER_NAME"

# ─── Atlas API helper ─────────────────────────────────────────────────────────
atlas_api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-s -o /tmp/.atlas_resp.json -w "%{http_code}"
    --user "${MONGODB_ATLAS_PUBLIC_KEY}:${MONGODB_ATLAS_PRIVATE_KEY}" --digest
    -H "Accept: application/vnd.atlas.2024-05-30+json" -X "$method"
    "https://cloud.mongodb.com/api/atlas/v2${path}")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/vnd.atlas.2024-05-30+json" -d "$body")
  curl "${args[@]}"
}

# ─── IAM role helper ─────────────────────────────────────────────────────────
# crud_iam_role <name> <trust-json> <rec-label>
crud_iam_role() {
  local role="$1" trust="$2" label="$3"
  local C="-" V="-" D="-"
  if aws iam create-role --role-name "$role" --assume-role-policy-document "$trust" >/dev/null 2>&1; then
    ok "create $role"; C="✓"
  elif aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    inf "$role exists"; C="(exists)"
  else
    no "create $role — $(aws iam create-role --role-name "$role" --assume-role-policy-document "$trust" 2>&1 | tail -1)"; C="✗"
  fi
  if [[ "$C" != "✗" ]] && aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    ok "validate $role"; V="✓"
    if [[ "$C" == "✓" ]]; then
      for P in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null); do
        aws iam delete-role-policy --role-name "$role" --policy-name "$P" >/dev/null 2>&1 || true
      done
      for A in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
        aws iam detach-role-policy --role-name "$role" --policy-arn "$A" >/dev/null 2>&1 || true
      done
      aws iam delete-role --role-name "$role" >/dev/null 2>&1 && { ok "delete $role"; D="✓"; } || { no "delete $role"; D="✗"; }
    else
      D="(kept)"
    fi
  fi
  rec "$label" "$C" "$V" "$D"
}

# Trust policies
EC2_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
BEDROCK_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
SM_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"sagemaker.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
AGENTCORE_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock-agentcore.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# =============================================================================
# 1. Bedrock — InvokeModel (Titan embed + Claude Sonnet)
# =============================================================================
hdr "Bedrock — InvokeModel"

echo '{"inputText":"probe","dimensions":1024}' > /tmp/.titan.json
ERR=$(aws bedrock-runtime invoke-model --model-id amazon.titan-embed-text-v2:0 \
  --region "$AWS_REGION" --content-type application/json --accept application/json \
  --body fileb:///tmp/.titan.json /tmp/.titan-out.json 2>&1)
[[ $? -eq 0 ]] && { ok "Titan Embed v2 invoke ok"; rec "bedrock:InvokeModel(titan-embed-v2)" "✓" "✓" "n/a"; } \
  || { no "Titan Embed v2 — $(echo "$ERR" | tail -1)"; rec "bedrock:InvokeModel(titan-embed-v2)" "✗" "-" "n/a"; }

echo '{"anthropic_version":"bedrock-2023-05-31","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' > /tmp/.claude.json
ERR=$(aws bedrock-runtime invoke-model --model-id "anthropic.claude-sonnet-4-20250514-v1:0" \
  --region "$AWS_REGION" --content-type application/json --accept application/json \
  --body fileb:///tmp/.claude.json /tmp/.claude-out.json 2>&1)
[[ $? -eq 0 ]] && { ok "Claude Sonnet invoke ok"; rec "bedrock:InvokeModel(claude-sonnet)" "✓" "✓" "n/a"; } \
  || { no "Claude Sonnet — $(echo "$ERR" | tail -1)"; rec "bedrock:InvokeModel(claude-sonnet)" "✗" "-" "n/a"; }

ERR=$(aws bedrock-agent list-knowledge-bases --region "$AWS_REGION" 2>&1)
[[ $? -eq 0 ]] && { ok "bedrock-agent API reachable"; rec "bedrock:bedrock-agent(api)" "(api-only)" "✓" "n/a"; } \
  || { no "bedrock-agent — $(echo "$ERR" | tail -1)"; rec "bedrock:bedrock-agent(api)" "✗" "-" "n/a"; }

# =============================================================================
# 2. S3 — shared bootstrap bucket + KB doc object
# =============================================================================
hdr "S3 — $SHARED_BUCKET"

BC="-"; BV="-"; BD="-"
PRE_EXISTED=false
if aws s3api head-bucket --bucket "$SHARED_BUCKET" 2>/dev/null; then
  inf "bucket already exists — testing object CRUD only"; PRE_EXISTED=true; BC="(exists)"; BD="(kept)"
else
  LOC_ARG=""; [[ "$AWS_REGION" != "us-east-1" ]] && LOC_ARG="--create-bucket-configuration LocationConstraint=$AWS_REGION"
  if aws s3api create-bucket --bucket "$SHARED_BUCKET" --region "$AWS_REGION" $LOC_ARG >/dev/null 2>&1; then
    ok "create bucket"; BC="✓"
  else
    no "create bucket — $(aws s3api create-bucket --bucket "$SHARED_BUCKET" --region "$AWS_REGION" 2>&1 | tail -1)"; BC="✗"
  fi
fi
if [[ "$BC" != "✗" ]] && aws s3api head-bucket --bucket "$SHARED_BUCKET" 2>/dev/null; then
  BV="✓"
  OBJ="kb-docs/docs/.probe-$$.txt"; echo "probe" > /tmp/.probe.txt
  aws s3api put-object --bucket "$SHARED_BUCKET" --key "$OBJ" --body /tmp/.probe.txt >/dev/null 2>&1 \
    && ok "put-object $OBJ" || no "put-object"
  aws s3api delete-object --bucket "$SHARED_BUCKET" --key "$OBJ" >/dev/null 2>&1 \
    && ok "delete-object $OBJ" || no "delete-object"
fi
if [[ "$PRE_EXISTED" == "false" && "$BC" == "✓" ]]; then
  aws s3 rm "s3://$SHARED_BUCKET" --recursive --quiet 2>/dev/null || true
  aws s3api delete-bucket --bucket "$SHARED_BUCKET" --region "$AWS_REGION" >/dev/null 2>&1 \
    && { ok "delete bucket"; BD="✓"; } || { no "delete bucket"; BD="✗"; }
fi
rec "s3:bucket($SHARED_BUCKET)" "$BC" "$BV" "$BD"

# =============================================================================
# 3. IAM — all roles (both modes)
# =============================================================================
hdr "IAM — roles"

crud_iam_role "$KB_ROLE_NAME"      "$BEDROCK_TRUST" "iam:role($KB_ROLE_NAME)"
crud_iam_role "$EC2_ROLE_NAME"     "$EC2_TRUST"     "iam:role($EC2_ROLE_NAME)"
crud_iam_role "$SM_ROLE_NAME"      "$SM_TRUST"      "iam:role($SM_ROLE_NAME)"
crud_iam_role "$GW_ROLE_NAME"      "$AGENTCORE_TRUST" "iam:role($GW_ROLE_NAME)"

# Instance profile (EC2 mode)
C="-"; V="-"; D="-"
if aws iam create-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" >/dev/null 2>&1; then
  ok "create instance-profile $EC2_PROFILE_NAME"; C="✓"
  aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" >/dev/null 2>&1 && { ok "validate"; V="✓"; }
  aws iam delete-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" >/dev/null 2>&1 \
    && { ok "delete"; D="✓"; } || { no "delete"; D="✗"; }
elif aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" >/dev/null 2>&1; then
  inf "$EC2_PROFILE_NAME exists"; C="(exists)"; V="✓"; D="(kept)"
else
  no "create instance-profile — $(aws iam create-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" 2>&1 | tail -1)"; C="✗"
fi
rec "iam:instance-profile($EC2_PROFILE_NAME)" "$C" "$V" "$D"

# =============================================================================
# 4. Secrets Manager — KB Atlas credentials secret (project+env-scoped name)
# =============================================================================
hdr "Secrets Manager — $SECRET_NAME"

C="-"; V="-"; D="-"
SECRET_VAL='{"connectionString":"mongodb+srv://probe","username":"probe","password":"probe"}'
if aws secretsmanager create-secret --name "$SECRET_NAME" --description "probe" \
     --secret-string "$SECRET_VAL" --region "$AWS_REGION" >/dev/null 2>&1; then
  ok "create secret"; C="✓"
elif aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  inf "secret exists"; C="(exists)"
else
  no "create secret — $(aws secretsmanager create-secret --name "$SECRET_NAME" --description "probe" --secret-string '{}' --region "$AWS_REGION" 2>&1 | tail -1)"; C="✗"
fi
if [[ "$C" != "✗" ]]; then
  aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" >/dev/null 2>&1 \
    && { ok "validate secret"; V="✓"; }
  [[ "$C" == "✓" ]] && {
    aws secretsmanager delete-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" \
      --force-delete-without-recovery >/dev/null 2>&1 \
      && { ok "delete secret"; D="✓"; } || { no "delete secret"; D="✗"; }
  } || D="(kept)"
fi
rec "secretsmanager:$SECRET_NAME" "$C" "$V" "$D"

# =============================================================================
# 5. CloudWatch — 3 log groups (both modes)
# =============================================================================
hdr "CloudWatch — log groups"

for LG in "${LG_PREFIX}/api" "${LG_PREFIX}/mcp" "${LG_PREFIX}/agentcore"; do
  C="-"; V="-"; D="-"
  if aws logs create-log-group --log-group-name "$LG" --region "$AWS_REGION" 2>/dev/null; then
    ok "create $LG"; C="✓"
  elif aws logs describe-log-groups --log-group-name-prefix "$LG" --region "$AWS_REGION" \
       --query "logGroups[?logGroupName=='$LG'].logGroupName" --output text 2>/dev/null | grep -q "$LG"; then
    inf "$LG exists"; C="(exists)"
  else
    no "create $LG"; C="✗"
  fi
  if [[ "$C" != "✗" ]]; then V="✓"
    [[ "$C" == "✓" ]] && {
      aws logs delete-log-group --log-group-name "$LG" --region "$AWS_REGION" 2>/dev/null \
        && { ok "delete $LG"; D="✓"; } || { no "delete $LG"; D="✗"; }
    } || D="(kept)"
  fi
  rec "cloudwatch:log-group($LG)" "$C" "$V" "$D"
done

# =============================================================================
# 6. ECR — api + ui repositories (EC2 mode)
# =============================================================================
hdr "ECR — repositories"

for REPO in "$ECR_API" "$ECR_UI"; do
  C="-"; V="-"; D="-"
  if aws ecr create-repository --repository-name "$REPO" --region "$AWS_REGION" >/dev/null 2>&1; then
    ok "create $REPO"; C="✓"
  elif aws ecr describe-repositories --repository-names "$REPO" --region "$AWS_REGION" >/dev/null 2>&1; then
    inf "$REPO exists"; C="(exists)"
  else
    no "create $REPO — $(aws ecr create-repository --repository-name "$REPO" --region "$AWS_REGION" 2>&1 | tail -1)"; C="✗"
  fi
  if [[ "$C" != "✗" ]]; then
    aws ecr describe-repositories --repository-names "$REPO" --region "$AWS_REGION" >/dev/null 2>&1 \
      && { ok "validate $REPO"; V="✓"; }
    [[ "$C" == "✓" ]] && {
      aws ecr delete-repository --repository-name "$REPO" --region "$AWS_REGION" --force >/dev/null 2>&1 \
        && { ok "delete $REPO"; D="✓"; } || { no "delete $REPO"; D="✗"; }
    } || D="(kept)"
  fi
  rec "ecr:repository($REPO)" "$C" "$V" "$D"
done

# =============================================================================
# 7. Cognito — user pool + app client (EC2 mode)
# =============================================================================
hdr "Cognito — user pool"

C="-"; V="-"; D="-"; _POOL_ID=""
_POOL_ID=$(aws cognito-idp create-user-pool --pool-name "$COGNITO_POOL" --region "$AWS_REGION" \
  --query 'UserPool.Id' --output text 2>/dev/null)
if [[ -n "$_POOL_ID" && "$_POOL_ID" != "None" ]]; then
  ok "create user-pool $_POOL_ID"; C="✓"
  aws cognito-idp describe-user-pool --user-pool-id "$_POOL_ID" --region "$AWS_REGION" >/dev/null 2>&1 \
    && { ok "validate user-pool"; V="✓"; }
  # App client (project+env-prefixed so two deployments don't collide)
  COGNITO_APP_CLIENT_NAME="${PROJECT_NAME}-app-client-${ENVIRONMENT}"
  _CLIENT_ID=$(aws cognito-idp create-user-pool-client --user-pool-id "$_POOL_ID" \
    --client-name "$COGNITO_APP_CLIENT_NAME" --region "$AWS_REGION" \
    --query 'UserPoolClient.ClientId' --output text 2>/dev/null)
  [[ -n "$_CLIENT_ID" ]] && ok "create app-client $_CLIENT_ID" || no "create app-client"
  rec "cognito:app-client($COGNITO_APP_CLIENT_NAME)" "${_CLIENT_ID:+✓}" "${_CLIENT_ID:+✓}" "(deleted with pool)"
  aws cognito-idp delete-user-pool --user-pool-id "$_POOL_ID" --region "$AWS_REGION" >/dev/null 2>&1 \
    && { ok "delete user-pool"; D="✓"; } || { no "delete user-pool"; D="✗"; }
else
  ERR=$(aws cognito-idp create-user-pool --pool-name "$COGNITO_POOL" --region "$AWS_REGION" 2>&1 | tail -1)
  no "create user-pool — $ERR"; C="✗"
  rec "cognito:app-client(${PROJECT_NAME}-app-client-${ENVIRONMENT})" "✗" "-" "-"
fi
rec "cognito:user-pool($COGNITO_POOL)" "$C" "$V" "$D"

# =============================================================================
# 8. (Reserved — the Lambda probe was removed in CLIENT_REVIEW Phase 7e once
#    the mongodb-mcp host moved into an AgentCore Runtime.)
# =============================================================================

# =============================================================================
# 9. SageMaker — Voyage AI (EC2 optional mode)
# =============================================================================
hdr "SageMaker — Voyage AI"

ERR=$(aws sagemaker list-endpoints --region "$AWS_REGION" --max-results 1 2>&1)
[[ $? -eq 0 ]] && { ok "SageMaker API reachable"; rec "sagemaker:API" "(api-only)" "✓" "n/a"; } \
  || { no "SageMaker API — $(echo "$ERR" | tail -1)"; rec "sagemaker:API" "✗" "-" "n/a"; }

if [[ "$WITH_SAGEMAKER" == "true" ]]; then
  C="-"; V="-"; D="-"
  # Endpoint config with a placeholder (will fail if no Marketplace model)
  _VOYAGE_ARN="${VOYAGE_MODEL_PACKAGE_ARN:-}"
  if [[ -z "$_VOYAGE_ARN" ]]; then
    wrn "VOYAGE_MODEL_PACKAGE_ARN not set — endpoint-config will fail (expected)"
    _VOYAGE_ARN="arn:aws:sagemaker:${AWS_REGION}::model-package/placeholder"
  fi
  SM_CFG_NAME="${SM_ENDPOINT}-probe-config"
  ERR=$(aws sagemaker create-endpoint-config --region "$AWS_REGION" \
    --endpoint-config-name "$SM_CFG_NAME" \
    --production-variants "[{\"VariantName\":\"default\",\"ModelName\":\"probe-placeholder\",\"InitialInstanceCount\":1,\"InstanceType\":\"ml.p3.2xlarge\"}]" 2>&1)
  # ValidationException (not ModelNotFound) means we DO have create access but no real model
  if echo "$ERR" | grep -q "Could not find model"; then
    ok "SageMaker endpoint-config create: API access confirmed (model doesn't exist, expected)"; C="✓(api-ok)"; V="n/a"; D="n/a"
  elif [[ $? -eq 0 ]]; then
    ok "create endpoint-config"; C="✓"; V="✓"
    aws sagemaker delete-endpoint-config --endpoint-config-name "$SM_CFG_NAME" --region "$AWS_REGION" >/dev/null 2>&1 \
      && { ok "delete endpoint-config"; D="✓"; } || { no "delete"; D="✗"; }
  else
    no "create endpoint-config — $(echo "$ERR" | tail -1)"; C="✗"
  fi
  rec "sagemaker:endpoint-config($SM_ENDPOINT)" "$C" "$V" "$D"
  rec "sagemaker:endpoint($SM_ENDPOINT)" "skipped" "-" "-"
else
  inf "SageMaker endpoint CRUD skipped — use --with-sagemaker"
  rec "sagemaker:endpoint-config($SM_ENDPOINT)" "skipped" "-" "-"
  rec "sagemaker:endpoint($SM_ENDPOINT)" "skipped" "-" "-"
fi

# =============================================================================
# 10. AgentCore — Memory Store (EC2 mode)
# =============================================================================
hdr "AgentCore — Memory Store ($MEMORY_NAME)"

C="-"; V="-"; D="-"; _MEM_ID=""
MEM_RESULT=$(aws bedrock-agentcore-control create-memory \
  --region "$AWS_REGION" --name "$MEMORY_NAME" --event-expiry-duration 90 \
  --output json 2>&1)
if _MEM_ID=$(echo "$MEM_RESULT" | python3 -c "import json,sys; m=json.load(sys.stdin).get('memory',{}); print(m.get('id') or m.get('memoryId',''))" 2>/dev/null) && [[ -n "$_MEM_ID" ]]; then
  ok "create memory store $_MEM_ID"; C="✓"
elif echo "$MEM_RESULT" | grep -qiE "already exists|ConflictException"; then
  _MEM_ID=$(aws bedrock-agentcore-control list-memories --region "$AWS_REGION" \
    --query "memories[?name=='$MEMORY_NAME'].id | [0]" --output text 2>/dev/null)
  inf "memory store exists: $_MEM_ID"; C="(exists)"
else
  no "create memory store — $(echo "$MEM_RESULT" | tail -2 | head -1)"; C="✗"
fi

if [[ "$C" != "✗" && -n "$_MEM_ID" ]]; then
  _MEM_STATUS=$(aws bedrock-agentcore-control get-memory \
    --region "$AWS_REGION" --memory-identifier "$_MEM_ID" \
    --query 'memory.status' --output text 2>/dev/null)
  [[ -n "$_MEM_STATUS" ]] && { ok "validate memory store (status=$_MEM_STATUS)"; V="✓"; }

  # Write + read a test event
  aws bedrock-agentcore create-event --region "$AWS_REGION" \
    --memory-id "$_MEM_ID" --actor-id "probe-user" \
    --session-id "probe-user::probe-agent" \
    --payload '[{"conversational":{"role":"USER","content":{"text":"probe"}}}]' \
    >/dev/null 2>&1 && ok "write event to memory" || wrn "write event failed (may need ACTIVE status)"

  [[ "$C" == "✓" ]] && {
    aws bedrock-agentcore-control delete-memory \
      --region "$AWS_REGION" --memory-identifier "$_MEM_ID" >/dev/null 2>&1 \
      && { ok "delete memory store"; D="✓"; } || { no "delete memory store"; D="✗"; }
  } || D="(kept)"
fi
rec "agentcore:memory-store($MEMORY_NAME)" "$C" "$V" "$D"

# =============================================================================
# 11. AgentCore — Gateway + Target (EC2 mode)
# =============================================================================
hdr "AgentCore — Gateway ($GATEWAY_NAME)"

C="-"; V="-"; D="-"; _GW_ID=""

# Create the gateway role for this probe
_GW_ROLE_ARN=$(aws iam create-role --role-name "$GW_ROLE_NAME" \
  --assume-role-policy-document "$AGENTCORE_TRUST" \
  --query 'Role.Arn' --output text 2>/dev/null)
_CREATED_GW_ROLE=false
if [[ -n "$_GW_ROLE_ARN" && "$_GW_ROLE_ARN" == arn:* ]]; then
  _CREATED_GW_ROLE=true
else
  _GW_ROLE_ARN=$(aws iam get-role --role-name "$GW_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)
fi

if [[ -z "$_GW_ROLE_ARN" ]]; then
  no "gateway IAM role unavailable — skipping gateway probe"
  rec "agentcore:gateway($GATEWAY_NAME)" "✗(role)" "-" "n/a"
  rec "agentcore:gateway-target(mongodb_mcp)" "skipped" "-" "-"
else
  COGNITO_PLACEHOLDER="us-east-1_placeholder"
  AUTH_CFG=$(python3 -c "
import json
print(json.dumps({'customJWTAuthorizer': {
  'discoveryUrl': 'https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_PLACEHOLDER}/.well-known/openid-configuration',
  'allowedAudience': ['probe']
}}))")
  GW_RESULT=$(aws bedrock-agentcore-control create-gateway \
    --region "$AWS_REGION" --name "$GATEWAY_NAME" \
    --role-arn "$_GW_ROLE_ARN" --protocol-type MCP \
    --authorizer-type CUSTOM_JWT --authorizer-configuration "$AUTH_CFG" \
    --output json 2>&1)
  if _GW_ID=$(echo "$GW_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('gatewayId') or d.get('id',''))" 2>/dev/null) && [[ -n "$_GW_ID" ]]; then
    ok "create gateway $_GW_ID"; C="✓"
    _GW_URL=$(echo "$GW_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('gatewayUrl',''))" 2>/dev/null)
    _GW_STATUS=$(aws bedrock-agentcore-control get-gateway \
      --region "$AWS_REGION" --gateway-identifier "$_GW_ID" \
      --query 'gatewayStatus' --output text 2>/dev/null)
    [[ -n "$_GW_STATUS" ]] && { ok "validate gateway (status=$_GW_STATUS)"; V="✓"; }
    [[ -n "$_GW_URL" ]] && ok "MCP URL: $_GW_URL"

    # Gateway Target
    TGT_RESULT=$(aws bedrock-agentcore-control create-gateway-target \
      --region "$AWS_REGION" --gateway-identifier "$_GW_ID" \
      --name "mongodb_mcp" \
      --target-configuration "{\"mcp\":{\"lambda\":{\"lambdaArn\":\"arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:probe\",\"toolSchema\":{\"inlinePayload\":[]}}}}" \
      --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' \
      --output json 2>&1)
    if _TGT_ID=$(echo "$TGT_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('targetId',''))" 2>/dev/null) && [[ -n "$_TGT_ID" ]]; then
      ok "create gateway target mongodb_mcp ($_TGT_ID)"
      rec "agentcore:gateway-target(mongodb_mcp)" "✓" "✓" "-"
      aws bedrock-agentcore-control delete-gateway-target \
        --region "$AWS_REGION" --gateway-identifier "$_GW_ID" --target-identifier "$_TGT_ID" >/dev/null 2>&1 \
        && { ok "delete gateway target"; RESULTS[${#RESULTS[@]}-1]="${RESULTS[${#RESULTS[@]}-1]%-}✓"; }
    else
      no "create gateway target — $(echo "$TGT_RESULT" | tail -2 | head -1)"
      rec "agentcore:gateway-target(mongodb_mcp)" "✗" "-" "n/a"
    fi

    aws bedrock-agentcore-control delete-gateway \
      --region "$AWS_REGION" --gateway-identifier "$_GW_ID" >/dev/null 2>&1 \
      && { ok "delete gateway"; D="✓"; } || { no "delete gateway"; D="✗"; }
  elif echo "$GW_RESULT" | grep -qiE "already exists|ConflictException"; then
    inf "gateway already exists"; C="(exists)"; V="✓"; D="(kept)"
    rec "agentcore:gateway-target(mongodb_mcp)" "(exists)" "✓" "(kept)"
  else
    no "create gateway — $(echo "$GW_RESULT" | tail -2 | head -1)"; C="✗"
    rec "agentcore:gateway-target(mongodb_mcp)" "skipped" "-" "-"
  fi
  rec "agentcore:gateway($GATEWAY_NAME)" "$C" "$V" "$D"

  [[ "$_CREATED_GW_ROLE" == "true" ]] && \
    aws iam delete-role --role-name "$GW_ROLE_NAME" >/dev/null 2>&1 && inf "cleaned up gateway role"
fi

# =============================================================================
# 12. Route53 — private hosted zone (Atlas PrivateLink)
# =============================================================================
hdr "Route53 — private hosted zone"

C="-"; V="-"; D="-"; _ZONE_ID=""
_ZONE_ID=$(aws route53 create-hosted-zone \
  --name "probe.mongodb.net" \
  --caller-reference "probe-$$" \
  --hosted-zone-config PrivateZone=false,Comment=probe \
  --query 'HostedZone.Id' --output text 2>/dev/null | sed 's|/hostedzone/||')
if [[ -n "$_ZONE_ID" ]]; then
  ok "create hosted-zone $_ZONE_ID"; C="✓"
  aws route53 get-hosted-zone --id "$_ZONE_ID" >/dev/null 2>&1 && { ok "validate"; V="✓"; }
  aws route53 delete-hosted-zone --id "$_ZONE_ID" >/dev/null 2>&1 \
    && { ok "delete hosted-zone"; D="✓"; } || { no "delete"; D="✗"; }
else
  no "create hosted-zone — $(aws route53 create-hosted-zone --name probe.mongodb.net --caller-reference probe-err 2>&1 | tail -1)"; C="✗"
fi
rec "route53:private-hosted-zone(atlas-privatelink)" "$C" "$V" "$D"

# ─── Atlas PrivateLink API ────────────────────────────────────────────────────
HTTP=$(atlas_api GET "/groups/${TF_VAR_atlas_project_id}/privateEndpoint/AWS/endpointService")
[[ "$HTTP" == "200" || "$HTTP" == "404" ]] \
  && { ok "Atlas PrivateLink API reachable"; rec "atlas:privatelink-api" "(api-only)" "✓" "n/a"; } \
  || { no "Atlas PrivateLink API HTTP $HTTP"; rec "atlas:privatelink-api" "✗" "-" "n/a"; }

# =============================================================================
# 13. MongoDB Atlas — IP access list + DB user
# =============================================================================
hdr "MongoDB Atlas — IP access list + DB user"

C="-"; V="-"; D="-"
HTTP=$(atlas_api POST "/groups/${TF_VAR_atlas_project_id}/accessList" '[{"cidrBlock":"0.0.0.0/0","comment":"probe"}]')
case "$HTTP" in
  200|201) ok "create ip-access-list 0.0.0.0/0"; C="✓" ;;
  409)     inf "0.0.0.0/0 already in access list"; C="(exists)" ;;
  *)       no "create ip-access-list HTTP $HTTP"; C="✗" ;;
esac
if [[ "$C" != "✗" ]]; then V="✓"
  [[ "$C" == "✓" ]] && {
    HTTP_D=$(atlas_api DELETE "/groups/${TF_VAR_atlas_project_id}/accessList/0.0.0.0%2F0")
    [[ "$HTTP_D" == "200" || "$HTTP_D" == "204" ]] && { ok "delete ip-access-list"; D="✓"; } || { no "delete HTTP $HTTP_D"; D="✗"; }
  } || D="(kept)"
fi
rec "atlas:ip-access-list(0.0.0.0/0)" "$C" "$V" "$D"

C="-"; V="-"; D="-"
USER_BODY=$(printf '{"databaseName":"admin","username":"%s","password":"%s","roles":[{"databaseName":"%s","roleName":"readWrite"}]}' \
  "${ATLAS_DB_USER}-probe" "$TF_VAR_atlas_db_password" "$ATLAS_DB_NAME")
HTTP=$(atlas_api POST "/groups/${TF_VAR_atlas_project_id}/databaseUsers" "$USER_BODY")
case "$HTTP" in
  200|201) ok "create db-user ${ATLAS_DB_USER}-probe"; C="✓" ;;
  409)     inf "db-user exists"; C="(exists)" ;;
  *)       no "create db-user HTTP $HTTP"; C="✗" ;;
esac
if [[ "$C" != "✗" ]]; then V="✓"
  [[ "$C" == "✓" ]] && {
    HTTP_D=$(atlas_api DELETE "/groups/${TF_VAR_atlas_project_id}/databaseUsers/admin/${ATLAS_DB_USER}-probe")
    [[ "$HTTP_D" == "200" || "$HTTP_D" == "204" ]] && { ok "delete db-user"; D="✓"; } || { no "delete HTTP $HTTP_D"; D="✗"; }
  } || D="(kept)"
fi
rec "atlas:db-user($ATLAS_DB_USER)" "$C" "$V" "$D"

# =============================================================================
# 14. VPC + EC2 — full CRUD (--with-ec2)
# =============================================================================
hdr "VPC / EC2 networking"

if [[ "$WITH_EC2" == "false" ]]; then
  aws ec2 describe-vpcs --region "$AWS_REGION" >/dev/null 2>&1 \
    && { ok "EC2 API reachable"; rec "vpc+ec2:API" "(api-only)" "✓" "n/a"; } \
    || { no "EC2 API"; rec "vpc+ec2:API" "✗" "-" "n/a"; }
  inf "use --with-ec2 for full VPC+EC2 CRUD (~5 min)"
  for R in "vpc:VPC($VPC_NAME)" "vpc:internet-gateway" "vpc:subnet-public(x2)" "vpc:subnet-private(x2)" "vpc:route-table" "ec2:security-group" "ec2:EIP" "ec2:instance($PROJECT_NAME-poc-$ENVIRONMENT)" "ec2:ssm-access"; do
    rec "$R" "skipped" "-" "-"
  done
else
  inf "Creating full VPC stack + t3.medium instance..."
  _VPC_ID=""; _IGW_ID=""; _PUB_SUBNET1=""; _PUB_SUBNET2=""; _PRV_SUBNET1=""; _PRV_SUBNET2=""
  _SG_ID=""; _EIP_ALLOC=""; _INSTANCE_ID=""; _RT_PUB_ID=""

  # VPC
  _VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --region "$AWS_REGION" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=Project,Value=$PROJECT_NAME}]" \
    --query 'Vpc.VpcId' --output text 2>/dev/null)
  [[ "$_VPC_ID" == vpc-* ]] && { ok "create VPC $_VPC_ID"; rec "vpc:VPC($VPC_NAME)" "✓" "✓" "-"; } \
    || { no "create VPC"; rec "vpc:VPC($VPC_NAME)" "✗" "-" "-"; }

  if [[ "$_VPC_ID" == vpc-* ]]; then
    # Internet Gateway
    _IGW_ID=$(aws ec2 create-internet-gateway --region "$AWS_REGION" \
      --query 'InternetGateway.InternetGatewayId' --output text 2>/dev/null)
    [[ "$_IGW_ID" == igw-* ]] && {
      aws ec2 attach-internet-gateway --vpc-id "$_VPC_ID" --internet-gateway-id "$_IGW_ID" \
        --region "$AWS_REGION" >/dev/null 2>&1
      ok "create+attach IGW $_IGW_ID"
      rec "vpc:internet-gateway" "✓" "✓" "-"
    } || { no "create IGW"; rec "vpc:internet-gateway" "✗" "-" "-"; }

    # AZs
    _AZ1=$(aws ec2 describe-availability-zones --region "$AWS_REGION" \
      --query 'AvailabilityZones[0].ZoneName' --output text 2>/dev/null)
    _AZ2=$(aws ec2 describe-availability-zones --region "$AWS_REGION" \
      --query 'AvailabilityZones[1].ZoneName' --output text 2>/dev/null)

    # Public subnets (x2 — matches terraform networking module)
    _PUB_SUBNET1=$(aws ec2 create-subnet --vpc-id "$_VPC_ID" --cidr-block 10.0.1.0/24 \
      --availability-zone "$_AZ1" --region "$AWS_REGION" \
      --query 'Subnet.SubnetId' --output text 2>/dev/null)
    _PUB_SUBNET2=$(aws ec2 create-subnet --vpc-id "$_VPC_ID" --cidr-block 10.0.2.0/24 \
      --availability-zone "$_AZ2" --region "$AWS_REGION" \
      --query 'Subnet.SubnetId' --output text 2>/dev/null)
    [[ "$_PUB_SUBNET1" == subnet-* && "$_PUB_SUBNET2" == subnet-* ]] \
      && { ok "create public subnets $_PUB_SUBNET1 $_PUB_SUBNET2"; rec "vpc:subnet-public(x2)" "✓" "✓" "-"; } \
      || { no "create public subnets"; rec "vpc:subnet-public(x2)" "✗" "-" "-"; }

    # Private subnets (x2)
    _PRV_SUBNET1=$(aws ec2 create-subnet --vpc-id "$_VPC_ID" --cidr-block 10.0.11.0/24 \
      --availability-zone "$_AZ1" --region "$AWS_REGION" \
      --query 'Subnet.SubnetId' --output text 2>/dev/null)
    _PRV_SUBNET2=$(aws ec2 create-subnet --vpc-id "$_VPC_ID" --cidr-block 10.0.12.0/24 \
      --availability-zone "$_AZ2" --region "$AWS_REGION" \
      --query 'Subnet.SubnetId' --output text 2>/dev/null)
    [[ "$_PRV_SUBNET1" == subnet-* && "$_PRV_SUBNET2" == subnet-* ]] \
      && { ok "create private subnets $_PRV_SUBNET1 $_PRV_SUBNET2"; rec "vpc:subnet-private(x2)" "✓" "✓" "-"; } \
      || { no "create private subnets"; rec "vpc:subnet-private(x2)" "✗" "-" "-"; }

    # Public route table + default route + associations
    _RT_PUB_ID=$(aws ec2 create-route-table --vpc-id "$_VPC_ID" --region "$AWS_REGION" \
      --query 'RouteTable.RouteTableId' --output text 2>/dev/null)
    if [[ "$_RT_PUB_ID" == rtb-* && "$_IGW_ID" == igw-* ]]; then
      aws ec2 create-route --route-table-id "$_RT_PUB_ID" --destination-cidr-block 0.0.0.0/0 \
        --gateway-id "$_IGW_ID" --region "$AWS_REGION" >/dev/null 2>&1
      [[ "$_PUB_SUBNET1" == subnet-* ]] && \
        aws ec2 associate-route-table --route-table-id "$_RT_PUB_ID" --subnet-id "$_PUB_SUBNET1" \
          --region "$AWS_REGION" >/dev/null 2>&1
      [[ "$_PUB_SUBNET2" == subnet-* ]] && \
        aws ec2 associate-route-table --route-table-id "$_RT_PUB_ID" --subnet-id "$_PUB_SUBNET2" \
          --region "$AWS_REGION" >/dev/null 2>&1
      ok "create route-table $_RT_PUB_ID + IGW route + associations"
      rec "vpc:route-table" "✓" "✓" "-"
    else
      no "create route-table"; rec "vpc:route-table" "✗" "-" "-"
    fi

    # Security group
    _SG_ID=$(aws ec2 create-security-group \
      --group-name "${PROJECT_NAME}-sg-ec2-${ENVIRONMENT}" \
      --description "probe" --vpc-id "$_VPC_ID" --region "$AWS_REGION" \
      --query 'GroupId' --output text 2>/dev/null)
    if [[ "$_SG_ID" == sg-* ]]; then
      aws ec2 authorize-security-group-ingress --group-id "$_SG_ID" \
        --protocol tcp --port 3000 --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null 2>&1
      aws ec2 authorize-security-group-ingress --group-id "$_SG_ID" \
        --protocol tcp --port 8501 --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null 2>&1
      ok "create security-group $_SG_ID"
      rec "ec2:security-group" "✓" "✓" "-"
    else
      no "create security-group"; rec "ec2:security-group" "✗" "-" "-"
    fi

    # Elastic IP
    _EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --region "$AWS_REGION" \
      --query 'AllocationId' --output text 2>/dev/null)
    [[ "$_EIP_ALLOC" == eipalloc-* ]] \
      && { ok "allocate EIP $_EIP_ALLOC"; rec "ec2:EIP" "✓" "✓" "-"; } \
      || { no "allocate EIP"; rec "ec2:EIP" "✗" "-" "-"; }

    # Create EC2 role + profile BEFORE launching (keep alive through instance test)
    _EC2_RL=$(aws iam create-role --role-name "$EC2_ROLE_NAME" \
      --assume-role-policy-document "$EC2_TRUST" \
      --query 'Role.Arn' --output text 2>/dev/null)
    _CREATED_EC2_ROLE=false
    [[ -n "$_EC2_RL" && "$_EC2_RL" == arn:* ]] && _CREATED_EC2_ROLE=true

    aws iam create-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" >/dev/null 2>&1
    [[ -n "$_EC2_RL" ]] && \
      aws iam add-role-to-instance-profile \
        --instance-profile-name "$EC2_PROFILE_NAME" --role-name "$EC2_ROLE_NAME" >/dev/null 2>&1
    inf "waiting 10s for IAM instance profile propagation..."
    sleep 10

    # AMI lookup + EC2 launch
    _AMI_ID=$(aws ec2 describe-images --owners amazon --region "$AWS_REGION" \
      --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>/dev/null)
    inf "AMI=$_AMI_ID"

    if [[ -n "$_PUB_SUBNET1" && -n "$_SG_ID" && -n "$_AMI_ID" ]]; then
      _INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$_AMI_ID" --instance-type t3.medium \
        --subnet-id "$_PUB_SUBNET1" --security-group-ids "$_SG_ID" \
        --associate-public-ip-address \
        --iam-instance-profile "Name=$EC2_PROFILE_NAME" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-poc-${ENVIRONMENT}},{Key=Project,Value=$PROJECT_NAME}]" \
        --region "$AWS_REGION" \
        --query 'Instances[0].InstanceId' --output text 2>/dev/null)
      if [[ "$_INSTANCE_ID" == i-* ]]; then
        ok "launch t3.medium instance $_INSTANCE_ID"
        [[ "$_EIP_ALLOC" == eipalloc-* ]] && sleep 5 && \
          aws ec2 associate-address --instance-id "$_INSTANCE_ID" \
            --allocation-id "$_EIP_ALLOC" --region "$AWS_REGION" >/dev/null 2>&1 \
            && ok "associate EIP" || wrn "EIP associate (non-fatal)"
        inf "waiting for running state..."
        aws ec2 wait instance-running --instance-ids "$_INSTANCE_ID" --region "$AWS_REGION" 2>/dev/null \
          && ok "instance running"
        # SSM
        sleep 15
        _SSM=$(aws ssm describe-instance-information --region "$AWS_REGION" \
          --filters "Key=InstanceIds,Values=$_INSTANCE_ID" \
          --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
        inf "SSM status: ${_SSM:-not-yet-registered}"
        rec "ec2:instance(${PROJECT_NAME}-poc-${ENVIRONMENT})" "✓" "✓" "-"
        rec "ec2:ssm-access" "(api-only)" "${_SSM:-pending}" "n/a"
      else
        ERR2=$(aws ec2 run-instances --image-id "$_AMI_ID" --instance-type t3.medium \
          --subnet-id "$_PUB_SUBNET1" --security-group-ids "$_SG_ID" \
          --associate-public-ip-address --region "$AWS_REGION" 2>&1 | tail -1)
        no "launch EC2 — $ERR2"
        rec "ec2:instance(${PROJECT_NAME}-poc-${ENVIRONMENT})" "✗" "-" "-"
        rec "ec2:ssm-access" "✗" "-" "n/a"
      fi
    else
      wrn "skipping EC2 launch — subnet/SG not created"
      rec "ec2:instance(${PROJECT_NAME}-poc-${ENVIRONMENT})" "skipped" "-" "-"
      rec "ec2:ssm-access" "skipped" "-" "n/a"
    fi

    # ── Cleanup (reverse order) ───────────────────────────────────────────────
    hdr "EC2 cleanup"
    if [[ "$_INSTANCE_ID" == i-* ]]; then
      aws ec2 terminate-instances --instance-ids "$_INSTANCE_ID" --region "$AWS_REGION" >/dev/null 2>&1 \
        && ok "terminate instance"
      aws ec2 wait instance-terminated --instance-ids "$_INSTANCE_ID" --region "$AWS_REGION" 2>/dev/null \
        && ok "instance terminated"
      for i in "${!RESULTS[@]}"; do
        [[ "${RESULTS[$i]}" == "ec2:instance"* ]] && RESULTS[$i]="${RESULTS[$i]%-}✓"
      done
    fi
    [[ "$_EIP_ALLOC" == eipalloc-* ]] && \
      aws ec2 release-address --allocation-id "$_EIP_ALLOC" --region "$AWS_REGION" >/dev/null 2>&1 \
      && ok "release EIP" && { for i in "${!RESULTS[@]}"; do [[ "${RESULTS[$i]}" == "ec2:EIP"* ]] && RESULTS[$i]="${RESULTS[$i]%-}✓"; done; }
    [[ "$_SG_ID" == sg-* ]] && \
      aws ec2 delete-security-group --group-id "$_SG_ID" --region "$AWS_REGION" >/dev/null 2>&1 \
      && ok "delete SG" && { for i in "${!RESULTS[@]}"; do [[ "${RESULTS[$i]}" == "ec2:security"* ]] && RESULTS[$i]="${RESULTS[$i]%-}✓"; done; }
    [[ -n "$_RT_PUB_ID" ]] && \
      aws ec2 delete-route-table --route-table-id "$_RT_PUB_ID" --region "$AWS_REGION" >/dev/null 2>&1 \
      && ok "delete route-table" && { for i in "${!RESULTS[@]}"; do [[ "${RESULTS[$i]}" == "vpc:route-table"* ]] && RESULTS[$i]="${RESULTS[$i]%-}✓"; done; }
    for SN in "$_PUB_SUBNET1" "$_PUB_SUBNET2" "$_PRV_SUBNET1" "$_PRV_SUBNET2"; do
      [[ "$SN" == subnet-* ]] && aws ec2 delete-subnet --subnet-id "$SN" --region "$AWS_REGION" >/dev/null 2>&1
    done
    ok "deleted subnets"
    for i in "${!RESULTS[@]}"; do [[ "${RESULTS[$i]}" == "vpc:subnet"* ]] && RESULTS[$i]="${RESULTS[$i]%-}✓"; done
    [[ "$_IGW_ID" == igw-* ]] && {
      aws ec2 detach-internet-gateway --internet-gateway-id "$_IGW_ID" \
        --vpc-id "$_VPC_ID" --region "$AWS_REGION" >/dev/null 2>&1
      aws ec2 delete-internet-gateway --internet-gateway-id "$_IGW_ID" \
        --region "$AWS_REGION" >/dev/null 2>&1 && ok "delete IGW" \
        && { for i in "${!RESULTS[@]}"; do [[ "${RESULTS[$i]}" == "vpc:internet"* ]] && RESULTS[$i]="${RESULTS[$i]%-}✓"; done; }
    }
    [[ "$_VPC_ID" == vpc-* ]] && \
      aws ec2 delete-vpc --vpc-id "$_VPC_ID" --region "$AWS_REGION" >/dev/null 2>&1 \
      && ok "delete VPC" && { for i in "${!RESULTS[@]}"; do [[ "${RESULTS[$i]}" == "vpc:VPC"* ]] && RESULTS[$i]="${RESULTS[$i]%-}✓"; done; }
    # Cleanup IAM profile + role (after instance terminated)
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "$EC2_PROFILE_NAME" --role-name "$EC2_ROLE_NAME" >/dev/null 2>&1 || true
    aws iam delete-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" >/dev/null 2>&1 \
      && ok "delete instance profile"
    [[ "$_CREATED_EC2_ROLE" == "true" ]] && \
      aws iam delete-role --role-name "$EC2_ROLE_NAME" >/dev/null 2>&1 && ok "delete EC2 role"
  fi
fi

# =============================================================================
# 15. Atlas M10 cluster + collection + vector index + Bedrock KB (--with-cluster)
# =============================================================================
hdr "Atlas — M10 cluster + KB prerequisites"

if [[ "$WITH_CLUSTER" == "false" ]]; then
  inf "Atlas cluster + KB probes skipped — use --with-cluster (~20 min)"
  for R in "atlas:M10-cluster($CLUSTER_NAME)" "atlas:collection(troubleshooting_docs)" \
           "atlas:search-index(troubleshooting-vector-index)" \
           "bedrock:kb($KB_NAME)" "bedrock:kb-data-source(${KB_NAME}-s3)"; do
    rec "$R" "skipped" "-" "-"
  done
else
  # Cluster
  C="-"; V="-"; D="-"; _CLU_HOST=""
  CLUSTER_BODY=$(python3 -c "
import json; print(json.dumps({
  'name': '${CLUSTER_NAME}', 'clusterType': 'REPLICASET',
  'replicationSpecs': [{'numShards': 1, 'regionConfigs': [{'regionName': 'US_EAST_1',
    'electableSpecs': {'instanceSize': 'M10', 'nodeCount': 3},
    'priority': 7, 'providerName': 'AWS'}]}],
  'mongoDBMajorVersion': '7.0'
}))")
  HTTP=$(atlas_api POST "/groups/${TF_VAR_atlas_project_id}/clusters" "$CLUSTER_BODY")
  case "$HTTP" in
    200|201|202) ok "create cluster $CLUSTER_NAME (provisioning ~10-15 min...)"; C="✓" ;;
    409) inf "cluster exists"; C="(exists)" ;;
    *) no "create cluster HTTP $HTTP — $(cat /tmp/.atlas_resp.json | head -c 120)"; C="✗" ;;
  esac

  if [[ "$C" != "✗" ]]; then
    for i in $(seq 1 40); do
      STATE=$(atlas_api GET "/groups/${TF_VAR_atlas_project_id}/clusters/$CLUSTER_NAME" \
        | python3 -c "import json,sys; print(json.load(open('/tmp/.atlas_resp.json')).get('stateName','?'))" 2>/dev/null)
      _CLU_HOST=$(python3 -c "import json; d=json.load(open('/tmp/.atlas_resp.json')); cs=d.get('connectionStrings',{}); srv=cs.get('standardSrv',''); print(srv.replace('mongodb+srv://',''))" 2>/dev/null)
      inf "  cluster state: $STATE ($i/40)"
      [[ "$STATE" == "IDLE" ]] && { ok "cluster IDLE"; V="✓"; break; }
      sleep 30
    done
    rec "atlas:M10-cluster($CLUSTER_NAME)" "$C" "$V" "-"

    # Atlas collection creation (via bun helper)
    if [[ -f "$REPO_ROOT/db-seeding/ensure-collection.ts" && -n "$_CLU_HOST" ]]; then
      export PATH="$HOME/.bun/bin:$PATH"
      CC="-"; CV="-"; CD="-"
      MONGODB_URI="mongodb+srv://${ATLAS_DB_USER}:${TF_VAR_atlas_db_password}@${_CLU_HOST}/?retryWrites=true&w=majority"
      COLL_OUT=$(MONGODB_URI="$MONGODB_URI" MONGODB_DB="$ATLAS_DB_NAME" MONGODB_COLL="troubleshooting_docs" \
        bun "$REPO_ROOT/db-seeding/ensure-collection.ts" 2>&1)
      if [[ $? -eq 0 ]]; then
        ok "ensure collection: $COLL_OUT"; CC="✓"; CV="✓"; CD="n/a"
      else
        no "ensure collection — $COLL_OUT"; CC="✗"
      fi
      rec "atlas:collection(troubleshooting_docs)" "$CC" "$CV" "$CD"
    else
      wrn "ensure-collection.ts not found or cluster host empty"
      rec "atlas:collection(troubleshooting_docs)" "skipped" "-" "-"
    fi

    # Atlas Vector Search Index (Atlas Admin API)
    if [[ -n "$_CLU_HOST" ]]; then
      IC="-"; IV="-"; ID="-"
      IDX_BODY=$(python3 -c "
import json; print(json.dumps({
  'collectionName': 'troubleshooting_docs', 'database': '${ATLAS_DB_NAME}',
  'name': 'troubleshooting-vector-index', 'type': 'vectorSearch',
  'definition': {'fields': [
    {'type': 'vector', 'path': 'embedding', 'numDimensions': 1024, 'similarity': 'cosine'},
    {'type': 'filter', 'path': 'metadata'}
  ]}
}))")
      HTTP=$(atlas_api POST "/groups/${TF_VAR_atlas_project_id}/clusters/${CLUSTER_NAME}/search/indexes" "$IDX_BODY")
      case "$HTTP" in
        200|201)
          _IDX_ID=$(python3 -c "import json; print(json.load(open('/tmp/.atlas_resp.json')).get('indexID',''))" 2>/dev/null)
          ok "create vector search index (id=$_IDX_ID)"; IC="✓"
          # Wait for queryable
          for i in $(seq 1 12); do
            IDX_STATUS=$(atlas_api GET "/groups/${TF_VAR_atlas_project_id}/clusters/${CLUSTER_NAME}/search/indexes/${_IDX_ID}" \
              | python3 -c "import json; print(json.load(open('/tmp/.atlas_resp.json')).get('status','?'))" 2>/dev/null)
            inf "  index status: $IDX_STATUS ($i/12)"
            [[ "$IDX_STATUS" == "READY" || "$IDX_STATUS" == "STEADY" ]] && { ok "vector index ready"; IV="✓"; break; }
            sleep 10
          done
          HTTP_D=$(atlas_api DELETE "/groups/${TF_VAR_atlas_project_id}/clusters/${CLUSTER_NAME}/search/indexes/${_IDX_ID}")
          [[ "$HTTP_D" == "200" || "$HTTP_D" == "204" ]] && { ok "delete vector index"; ID="✓"; } || { no "delete HTTP $HTTP_D"; ID="✗"; }
          ;;
        409) inf "vector index exists"; IC="(exists)"; IV="✓"; ID="(kept)" ;;
        *) no "create vector index HTTP $HTTP"; IC="✗" ;;
      esac
      rec "atlas:search-index(troubleshooting-vector-index)" "$IC" "$IV" "$ID"
    else
      rec "atlas:search-index(troubleshooting-vector-index)" "skipped" "-" "-"
    fi

    # Bedrock KB create (--with-bedrock-kb)
    if [[ "$WITH_KB" == "false" ]]; then
      inf "Bedrock KB CRUD skipped — use --with-bedrock-kb"
      rec "bedrock:kb($KB_NAME)" "skipped" "-" "-"
      rec "bedrock:kb-data-source(${KB_NAME}-s3)" "skipped" "-" "-"
    else
      KC="-"; KV="-"; KD="-"; _KB_ID=""
      # Need: KB IAM role + secrets + vector index + cluster
      # Recreate KB role + secret for this probe
      _KB_ROLE=$(aws iam create-role --role-name "$KB_ROLE_NAME" \
        --assume-role-policy-document "$BEDROCK_TRUST" --query 'Role.Arn' --output text 2>/dev/null \
        || aws iam get-role --role-name "$KB_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)
      _KB_SECRET_ARN=$(aws secretsmanager create-secret --name "$SECRET_NAME" \
        --secret-string "{\"connectionString\":\"mongodb+srv://${_CLU_HOST}\",\"username\":\"${ATLAS_DB_USER}\",\"password\":\"${TF_VAR_atlas_db_password}\"}" \
        --region "$AWS_REGION" --query 'ARN' --output text 2>/dev/null \
        || aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" \
           --query 'ARN' --output text 2>/dev/null)

      EMBED_ARN="arn:aws:bedrock:${AWS_REGION}::foundation-model/amazon.titan-embed-text-v2:0"
      KB_BODY=$(python3 -c "
import json; print(json.dumps({
  'name': '${KB_NAME}',
  'description': 'probe',
  'roleArn': '${_KB_ROLE}',
  'knowledgeBaseConfiguration': {'type': 'VECTOR', 'vectorKnowledgeBaseConfiguration': {'embeddingModelArn': '${EMBED_ARN}'}},
  'storageConfiguration': {'type': 'MONGO_DB_ATLAS', 'mongoDbAtlasConfiguration': {
    'endpoint': '${_CLU_HOST}',
    'credentialsSecretArn': '${_KB_SECRET_ARN}',
    'databaseName': '${ATLAS_DB_NAME}',
    'collectionName': 'troubleshooting_docs',
    'vectorIndexName': 'troubleshooting-vector-index',
    'fieldMapping': {'vectorField': 'embedding', 'textField': 'body', 'metadataField': 'metadata'}
  }}
}))")
      KB_RESULT=$(aws bedrock-agent create-knowledge-base --region "$AWS_REGION" \
        --cli-input-json "$KB_BODY" --query 'knowledgeBase.knowledgeBaseId' --output text 2>&1)
      if [[ "$KB_RESULT" =~ ^[A-Z0-9]{10} ]]; then
        _KB_ID="$KB_RESULT"; ok "create KB $_KB_ID"; KC="✓"
        for i in $(seq 1 40); do
          KB_STATUS=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "$_KB_ID" \
            --region "$AWS_REGION" --query 'knowledgeBase.status' --output text 2>/dev/null)
          inf "  KB status: $KB_STATUS ($i/40)"
          [[ "$KB_STATUS" == "ACTIVE" ]] && { ok "KB ACTIVE"; KV="✓"; break; }
          [[ "$KB_STATUS" == "FAILED" ]] && { no "KB FAILED"; break; }
          sleep 15
        done
        aws bedrock-agent delete-knowledge-base --knowledge-base-id "$_KB_ID" \
          --region "$AWS_REGION" >/dev/null 2>&1 \
          && { ok "delete KB"; KD="✓"; } || { no "delete KB"; KD="✗"; }
      else
        no "create KB — $KB_RESULT"; KC="✗"
      fi
      rec "bedrock:kb($KB_NAME)" "$KC" "$KV" "$KD"

      # Cleanup KB prereqs
      aws secretsmanager delete-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" \
        --force-delete-without-recovery >/dev/null 2>&1 || true
      aws iam delete-role --role-name "$KB_ROLE_NAME" >/dev/null 2>&1 || true
      rec "bedrock:kb-data-source(${KB_NAME}-s3)" "n/a(within-kb)" "-" "-"
    fi

    # Delete cluster if we created it
    if [[ "$C" == "✓" ]]; then
      HTTP_D=$(atlas_api DELETE "/groups/${TF_VAR_atlas_project_id}/clusters/$CLUSTER_NAME")
      case "$HTTP_D" in
        200|202|204)
          ok "delete cluster (terminating...)"
          for i in "${!RESULTS[@]}"; do [[ "${RESULTS[$i]}" == "atlas:M10-cluster"* ]] && RESULTS[$i]="${RESULTS[$i]%-}✓"; done
          ;;
        *) no "delete cluster HTTP $HTTP_D" ;;
      esac
    fi
  fi
fi

# =============================================================================
# Summary matrix
# =============================================================================
hdr "ACCESS MATRIX"
printf "\n  %-58s  %-14s  %-10s  %-10s\n" "RESOURCE (terraform name)" "CREATE" "VALIDATE" "DELETE"
printf "  %-58s  %-14s  %-10s  %-10s\n" \
  "──────────────────────────────────────────────────────────" \
  "──────────────" "──────────" "──────────"

PASS=0; FAIL=0; SKIP=0
for ROW in "${RESULTS[@]}"; do
  IFS='|' read -r name c v d <<<"$ROW"
  if   [[ "$c" == "✓"* ]];       then CC="${G}✓${NC}";             ((PASS++))
  elif [[ "$c" == "✗"* ]];       then CC="${R}✗ ${c#✗}${NC}";      ((FAIL++))
  elif [[ "$c" == "skipped" ]];  then CC="${Y}skipped${NC}";        ((SKIP++))
  elif [[ "$c" == "(api-only)" ]]; then CC="${B}(api-only)${NC}";   ((PASS++))
  elif [[ "$c" == "(exists)" ]];  then CC="${B}(exists)${NC}";      ((PASS++))
  else CC="$c"; fi
  printf "  %-58s  %-24s  %-10s  %-10s\n" "$name" "$(printf "$CC")" "$v" "$d"
done

echo ""
printf "${BOLD}Result: ${G}%d passed${NC}  ${R}%d failed${NC}  ${Y}%d skipped${NC}\n" "$PASS" "$FAIL" "$SKIP"
echo ""
echo "  Flags:"
echo "    --with-ec2          full VPC + 2x public + 2x private subnet + EC2 t3.medium CRUD (~5 min)"
echo "    --with-cluster      Atlas M10 + collection + vector-search-index CRUD (~20 min)"
echo "    --with-bedrock-kb   Bedrock KB + data source (requires --with-cluster)"
echo "    --with-sagemaker    SageMaker endpoint-config CRUD"
echo "    --all               run everything"
