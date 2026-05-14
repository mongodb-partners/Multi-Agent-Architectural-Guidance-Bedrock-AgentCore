#!/usr/bin/env bash
# deploy.sh — EC2 deployment (envs/ec2 terraform)
#
# Usage:
#   ./deploy/scripts/deploy.sh [--auto-approve] [--skip-docker] [--env-file <path>]
#
# What it does:
#   Phase 1  — Validate prerequisites (aws, terraform, bun)
#   Phase 2  — Source env.sh, verify AWS + Atlas credentials
#   Phase 3  — Bootstrap shared S3 bucket (once)
#   Phase 4  — Generate backend.hcl + terraform.tfvars for envs/ec2
#   Phase 5  — terraform apply (envs/ec2):
#                VPC + Atlas M10 + PrivateLink + EC2 + ECR + Cognito + Bedrock KB
#                + AgentCore Memory + AgentCore Gateway (no Lambda target yet)
#                (+ Voyage AI if ARN set)
#   Phase 6  — Build + push Docker images to ECR (unless --skip-docker)
#   Phase 7  — Write .env.live + copy to EC2 via SSM
#   Phase 8  — Pull images + restart multiagent-api, multiagent-ui, mongodb-mcp on EC2
#   Phase 9  — Health check, summary, manifest
#
# Embedding: Bedrock Titan by default. Voyage AI SageMaker only when
#            VOYAGE_MODEL_PACKAGE_ARN is set in env.sh.
#
# Tools:     MongoDB MCP runs as a systemd service on the EC2 instance
#            (`mongodb-mcp.service`, bound to 127.0.0.1:8080) and the API talks
#            to it over loopback. Lambda + AgentCore Gateway are DEFERRED —
#            see Docs/adr/0001-mcp-on-ec2-not-lambda.md.
#
# Shell:     SSM Session Manager (no SSH keypair by default).
#
# For local dev (no EC2, direct tools), use: ./deploy/scripts/deploy-local.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_ROOT="$REPO_ROOT/deploy/terraform"
TF_DIR="$TF_ROOT/envs/ec2"
BOOTSTRAP_DIR="$TF_ROOT/bootstrap"
KB_STATE_FILE="$TF_ROOT/modules/bedrock-kb/.kb-state.json"

ENV_FILE="$REPO_ROOT/env.sh"
AUTO_APPROVE=false
SKIP_DOCKER=false
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
ATLAS_DB_USER="${ATLAS_DB_USER:-bedrock_agent}"
ATLAS_DB_NAME="${ATLAS_DB_NAME:-bedrock_agents}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
COGNITO_SEED_USERS="${COGNITO_SEED_USERS:-true}"
COGNITO_REQUIRE_AUTH="${COGNITO_REQUIRE_AUTH:-true}"
COGNITO_TEST_USERS_CSV="${COGNITO_TEST_USERS_CSV:-alex@example.com,blake@example.com,casey@example.com}"
COGNITO_TEST_PASSWORD="${COGNITO_TEST_PASSWORD:-DemoUser#2026}"
COGNITO_SMOKE_USER_EMAIL="${COGNITO_SMOKE_USER_EMAIL:-alex@example.com}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve) AUTO_APPROVE=true ;;
    --skip-docker)  SKIP_DOCKER=true ;;
    --env-file)     ENV_FILE="$2"; shift ;;
    *) echo "  [ec2] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { echo "  [ec2] $*"; }
ok()   { echo "  [ec2] ✓ $*"; }
err()  { echo "  [ec2] ✗ $*" >&2; exit 1; }
warn() { echo "  [ec2] ⚠ $*"; }
sep()  { echo "────────────────────────────────────────────────"; }

wait_for_instance_status_ok() {
  local instance_id="$1"
  log "Waiting for EC2 instance checks to pass: $instance_id"
  aws ec2 wait instance-status-ok \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    || err "EC2 status checks did not pass in time for $instance_id"
  ok "EC2 status checks passed"
}

wait_for_ssm_online() {
  local instance_id="$1"
  local max_attempts=36
  log "Waiting for SSM registration (up to 6 min)..."
  for i in $(seq 1 "$max_attempts"); do
    local status
    status=$(aws ssm describe-instance-information \
      --region "$AWS_REGION" \
      --query "InstanceInformationList[?InstanceId=='${instance_id}'].PingStatus | [0]" \
      --output text 2>/dev/null || echo "None")
    if [[ "$status" == "Online" ]]; then
      ok "SSM agent is online"
      return 0
    fi
    log "  Waiting for SSM ($i/$max_attempts)..."
    sleep 10
  done
  err "SSM agent did not become online for $instance_id"
}

send_ssm_command_retry() {
  local instance_id="$1"
  local comment="$2"
  local commands_json="$3"
  local max_attempts="${4:-15}"

  local cmd_id=""
  for i in $(seq 1 "$max_attempts"); do
    cmd_id=$(aws ssm send-command \
      --region "$AWS_REGION" \
      --instance-ids "$instance_id" \
      --document-name "AWS-RunShellScript" \
      --comment "$comment" \
      --parameters "commands=${commands_json}" \
      --query "Command.CommandId" \
      --output text 2>/dev/null || true)
    if [[ -n "$cmd_id" && "$cmd_id" != "None" ]]; then
      echo "$cmd_id"
      return 0
    fi
    sleep 10
  done
  return 1
}

wait_for_ssm_command_success() {
  local command_id="$1"
  local instance_id="$2"
  local max_attempts="${3:-30}"

  for i in $(seq 1 "$max_attempts"); do
    local status
    status=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query "Status" --output text 2>/dev/null || echo "Pending")
    case "$status" in
      Success) return 0 ;;
      Failed|Cancelled|TimedOut)
        aws ssm get-command-invocation \
          --region "$AWS_REGION" \
          --command-id "$command_id" \
          --instance-id "$instance_id" \
          --query "{Status:Status,StdOut:StandardOutputContent,StdErr:StandardErrorContent}" \
          --output json 2>/dev/null || true
        return 1
        ;;
    esac
    sleep 5
  done
  return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Prerequisites
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 1 — Checking prerequisites..."
for cmd in aws terraform bun python3; do
  command -v "$cmd" &>/dev/null || err "'$cmd' not found in PATH"
done
if [[ "${AGENTCORE_RUNTIME_DEPLOYMENT_MODE:-code}" == "code" ]]; then
  command -v zip &>/dev/null || err "'zip' not found in PATH (required for AgentCore code artifacts)"
fi
ok "All prerequisites found"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Load credentials
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 2 — Loading credentials from $ENV_FILE..."
[[ -f "$ENV_FILE" ]] || err "env file not found: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

export TF_VAR_atlas_db_password="${TF_VAR_atlas_db_password:-${TF_VAR_mongodb_password:-}}"
[[ -n "${TF_VAR_atlas_db_password:-}" ]] || err "Atlas DB password not set. Set TF_VAR_mongodb_password in env.sh"

export TF_VAR_atlas_project_id="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
[[ -n "${TF_VAR_atlas_project_id:-}" ]] || err "Atlas Project ID not set. Set TF_VAR_mongodb_atlas_project_id in env.sh"

export TF_VAR_atlas_public_key="${MONGODB_ATLAS_PUBLIC_KEY:-}"
export TF_VAR_atlas_private_key="${MONGODB_ATLAS_PRIVATE_KEY:-}"
[[ -n "${TF_VAR_atlas_public_key:-}" ]]  || err "MONGODB_ATLAS_PUBLIC_KEY not set in env.sh"
[[ -n "${TF_VAR_atlas_private_key:-}" ]] || err "MONGODB_ATLAS_PRIVATE_KEY not set in env.sh"

[[ -n "${AWS_ACCESS_KEY_ID:-}" ]] || err "AWS_ACCESS_KEY_ID not set. Re-authenticate and update env.sh"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "AWS credentials invalid or expired. Re-authenticate and update env.sh"
ok "AWS account: $ACCOUNT_ID"
ok "Atlas project: $TF_VAR_atlas_project_id"

# ── Atlas API key validation ─────────────────────────────────────────────────
log "Verifying Atlas API key access..."
_ATLAS_HTTP=$(curl -s -o /tmp/.atlas_check.json -w "%{http_code}" \
  --user "${MONGODB_ATLAS_PUBLIC_KEY}:${MONGODB_ATLAS_PRIVATE_KEY}" \
  --digest \
  -H "Accept: application/vnd.atlas.2023-01-01+json" \
  "https://cloud.mongodb.com/api/atlas/v2/groups/${TF_VAR_atlas_project_id}" \
  2>/dev/null) || _ATLAS_HTTP="000"
case "$_ATLAS_HTTP" in
  200)
    _ATLAS_NAME=$(python3 -c "import json; d=json.load(open('/tmp/.atlas_check.json')); print(d.get('name','?'))" 2>/dev/null || echo "?")
    ok "Atlas API keys valid — project: ${_ATLAS_NAME}" ;;
  401) err "Atlas API keys invalid (HTTP 401). Check MONGODB_ATLAS_PUBLIC_KEY / MONGODB_ATLAS_PRIVATE_KEY in env.sh" ;;
  403) err "Atlas API keys valid but forbidden (HTTP 403). Verify the key has Project Owner role." ;;
  404) err "Atlas project not found (HTTP 404). Check TF_VAR_mongodb_atlas_project_id in env.sh" ;;
  000) warn "Atlas API unreachable (curl failed) — check network. Proceeding." ;;
  *)   warn "Atlas API returned HTTP $_ATLAS_HTTP — unexpected. Proceeding cautiously." ;;
esac
rm -f /tmp/.atlas_check.json

SHARED_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-${ACCOUNT_ID}"
VOYAGE_ARN="${VOYAGE_MODEL_PACKAGE_ARN:-}"
EC2_KEY_PAIR="${EC2_KEY_PAIR:-}"
AGENTCORE_RUNTIME_DEPLOYMENT_MODE="${AGENTCORE_RUNTIME_DEPLOYMENT_MODE:-code}"
GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
AGENTCORE_CODE_ARTIFACT_PREFIX="artifacts/agentcore-runtime/${GIT_SHA}/deployment_package.zip"

if [[ -z "$VOYAGE_ARN" ]]; then
  warn "VOYAGE_MODEL_PACKAGE_ARN not set — SageMaker endpoint will not be deployed."
  warn "API will fall back to Titan embeddings. Set it in env.sh after Marketplace approval."
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Bootstrap (idempotent)
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 3 — Checking bootstrap state..."
if aws s3api head-bucket --bucket "$SHARED_BUCKET" 2>/dev/null; then
  ok "Shared bucket exists — skipping bootstrap"
else
  log "Bucket not found — running bootstrap (one-time)..."
  cd "$BOOTSTRAP_DIR"
  terraform init -input=false -no-color
  terraform apply -input=false -auto-approve \
    -var="account_id=$ACCOUNT_ID" \
    -var="aws_region=$AWS_REGION" \
    -var="environment=$ENVIRONMENT" \
    -var="project_name=$PROJECT_NAME"
  ok "Bootstrap complete"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — Generate Terraform config (envs/ec2)
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 4 — Generating Terraform config for envs/ec2..."

cat > "$TF_DIR/backend.hcl" <<EOF
bucket  = "${SHARED_BUCKET}"
key     = "${ENVIRONMENT}/ec2/terraform.tfstate"
region  = "${AWS_REGION}"
encrypt = true
# dynamodb_table omitted — SCP on this account blocks DynamoDB CreateTable.
EOF
ok "backend.hcl written (state key: ${ENVIRONMENT}/ec2/terraform.tfstate)"

cat > "$TF_DIR/terraform.tfvars" <<EOF
# EC2 mode — generated by deploy.sh
aws_region         = "${AWS_REGION}"
environment        = "${ENVIRONMENT}"
project_name       = "${PROJECT_NAME}"
shared_bucket_name = "${SHARED_BUCKET}"
vpc_cidr           = "${VPC_CIDR}"

# MongoDB Atlas (cluster provisioned by Terraform in this env)
atlas_project_id = "${TF_VAR_atlas_project_id}"
atlas_db_user    = "${ATLAS_DB_USER}"
atlas_db_name    = "${ATLAS_DB_NAME}"
# atlas_db_password / atlas_public_key / atlas_private_key → TF_VAR env vars

# Bedrock KB — Titan used for ingestion (KB requires Bedrock-native embedding)
embed_model_id   = "amazon.titan-embed-text-v2:0"
kb_iam_role_name = "bedrock-kb-ts-role"

# EC2 — SSM Session Manager for shell access (no SSH key required)
ec2_instance_type = "t3.medium"
ec2_key_pair_name = "${EC2_KEY_PAIR}"

# Voyage AI SageMaker (embeds queries on EC2; leave empty to skip endpoint deploy)
voyage_model_package_arn = "${VOYAGE_ARN}"
voyage_instance_type     = "ml.m5.xlarge"

# AgentCore Memory TTL
agentcore_memory_expiry_days = 30
agentcore_runtime_deployment_mode = "${AGENTCORE_RUNTIME_DEPLOYMENT_MODE}"
agentcore_code_artifact_prefix    = "${AGENTCORE_CODE_ARTIFACT_PREFIX}"
EOF
ok "terraform.tfvars written"

# Build + upload AgentCore direct-code artifact before apply so runtimes can be created.
if [[ "$AGENTCORE_RUNTIME_DEPLOYMENT_MODE" == "code" ]]; then
  sep
  log "Phase 4b — Building AgentCore direct-code artifact (TS -> JS) and uploading to S3..."
  (cd "$REPO_ROOT/api" && bun run build:agentcore-code)
  ARTIFACT_ZIP="$REPO_ROOT/api/dist/agentcore-deployment.zip"
  ARTIFACT_STAGE_DIR="$REPO_ROOT/api/dist/agentcore-package"
  rm -f "$ARTIFACT_ZIP"
  rm -rf "$ARTIFACT_STAGE_DIR"
  mkdir -p "$ARTIFACT_STAGE_DIR/config"
  cp "$REPO_ROOT/api/dist/agent-runtime-code.js" "$ARTIFACT_STAGE_DIR/agent-runtime-code.js"
  cp -R "$REPO_ROOT/config/." "$ARTIFACT_STAGE_DIR/config/"
  (cd "$ARTIFACT_STAGE_DIR" && zip -r "../agentcore-deployment.zip" . >/dev/null)
  aws s3 cp "$ARTIFACT_ZIP" "s3://${SHARED_BUCKET}/${AGENTCORE_CODE_ARTIFACT_PREFIX}" --region "$AWS_REGION" >/dev/null
  ok "Uploaded AgentCore code artifact: s3://${SHARED_BUCKET}/${AGENTCORE_CODE_ARTIFACT_PREFIX}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — terraform apply (envs/ec2)
# ══════════════════════════════════════════════════════════════════════════════
sep
cd "$TF_DIR"
log "Phase 5 — terraform init..."
terraform init -input=false -reconfigure -backend-config="$TF_DIR/backend.hcl"
ok "init complete"

log "Running terraform plan..."
terraform plan -input=false -out="$TF_DIR/.tfplan"
ok "plan complete"

sep
log "NOTE: First apply creates Atlas M10 (~5-10 min), AgentCore resources, and EC2."

if [[ "$AUTO_APPROVE" == "true" ]]; then
  log "Applying..."
  terraform apply -input=false "$TF_DIR/.tfplan"
else
  echo ""
  read -r -p "  Apply? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Cancelled."; exit 0; }
  terraform apply -input=false "$TF_DIR/.tfplan"
fi
ok "Terraform apply complete"

# ── Outputs ──────────────────────────────────────────────────────────────────
load_tf_outputs() {
  EC2_IP=$(terraform output -raw ec2_public_ip 2>/dev/null || echo "")
  EC2_API=$(terraform output -raw ec2_api_url 2>/dev/null || echo "")
  EC2_UI=$(terraform output -raw ec2_ui_url 2>/dev/null || echo "")
  EC2_SSM=$(terraform output -raw ec2_ssm_command 2>/dev/null || echo "")
  EC2_INSTANCE_ID=$(terraform output -raw ec2_instance_id 2>/dev/null || echo "")
  ATLAS_MONGO_HOST=$(terraform output -raw atlas_mongo_host 2>/dev/null || echo "")
  ATLAS_CONNECTION_STRING=$(terraform output -raw atlas_connection_string 2>/dev/null || echo "")
  COGNITO_POOL_ID=$(terraform output -raw cognito_user_pool_id 2>/dev/null || echo "")
  COGNITO_CLIENT_ID=$(terraform output -raw cognito_app_client_id 2>/dev/null || echo "")
  COGNITO_JWKS=$(terraform output -raw cognito_jwks_uri 2>/dev/null || echo "")
  VOYAGE_ENDPOINT=$(terraform output -raw voyage_endpoint_name 2>/dev/null || echo "")
  ECR_API_REPO=$(terraform output -raw ecr_api_repository_url 2>/dev/null || echo "")
  ECR_UI_REPO=$(terraform output -raw ecr_ui_repository_url 2>/dev/null || echo "")
  ECR_RUNTIME_REPO=$(terraform output -raw ecr_agent_runtime_repository_url 2>/dev/null || echo "")
  AGENTCORE_RUNTIME_DEPLOYMENT_MODE=$(terraform output -raw agentcore_runtime_deployment_mode 2>/dev/null || echo "$AGENTCORE_RUNTIME_DEPLOYMENT_MODE")
  AGENTCORE_CODE_ARTIFACT_PREFIX=$(terraform output -raw agentcore_code_artifact_prefix 2>/dev/null || echo "$AGENTCORE_CODE_ARTIFACT_PREFIX")
  AGENTCORE_MEMORY_STORE_ID=$(terraform output -raw agentcore_memory_id 2>/dev/null || echo "")
  AGENTCORE_GATEWAY_URL=$(terraform output -raw agentcore_gateway_url 2>/dev/null || echo "")
  AGENTCORE_ORCHESTRATOR_ARN=$(terraform output -raw acr_orchestrator_arn 2>/dev/null || echo "")
  AGENTCORE_ORCHESTRATOR_ID=$(terraform output -raw acr_orchestrator_id 2>/dev/null || echo "")
  AGENTCORE_TROUBLESHOOTING_ARN=$(terraform output -raw acr_troubleshooting_arn 2>/dev/null || echo "")
  AGENTCORE_TROUBLESHOOTING_ID=$(terraform output -raw acr_troubleshooting_id 2>/dev/null || echo "")
  AGENTCORE_ORDER_MANAGEMENT_ARN=$(terraform output -raw acr_order_management_arn 2>/dev/null || echo "")
  AGENTCORE_ORDER_MANAGEMENT_ID=$(terraform output -raw acr_order_management_id 2>/dev/null || echo "")
  AGENTCORE_PRODUCT_RECOMMENDATION_ARN=$(terraform output -raw acr_product_recommendation_arn 2>/dev/null || echo "")
  AGENTCORE_PRODUCT_RECOMMENDATION_ID=$(terraform output -raw acr_product_recommendation_id 2>/dev/null || echo "")
  LAMBDA_MCP_ARN=$(terraform output -raw lambda_mcp_arn 2>/dev/null || echo "")
  LAMBDA_MCP_FUNCTION_NAME=$(terraform output -raw lambda_mcp_function_name 2>/dev/null || echo "")
  if [[ -z "$LAMBDA_MCP_FUNCTION_NAME" && -n "$LAMBDA_MCP_ARN" ]]; then
    LAMBDA_MCP_FUNCTION_NAME="${LAMBDA_MCP_ARN##*:function:}"
  fi
  ATLAS_PRIVATELINK_ENDPOINT_ID=$(terraform output -raw atlas_privatelink_endpoint_id 2>/dev/null || echo "")
  CW_API_LOG_GROUP=$(terraform output -raw cloudwatch_api_log_group 2>/dev/null || echo "/multiagent/${ENVIRONMENT}/api")
}

load_tf_outputs

# Runtime outputs are file-backed by create-runtime scripts and can be empty
# immediately after apply in some edge cases. Refresh outputs once if needed.
if [[ -z "$AGENTCORE_ORCHESTRATOR_ARN" || -z "$AGENTCORE_ORDER_MANAGEMENT_ARN" || -z "$AGENTCORE_TROUBLESHOOTING_ARN" || -z "$AGENTCORE_PRODUCT_RECOMMENDATION_ARN" ]]; then
  warn "AgentCore runtime outputs incomplete after apply; running refresh-only apply to rehydrate outputs..."
  terraform apply -refresh-only -auto-approve -input=false >/dev/null 2>&1 || true
  load_tf_outputs
fi

# If module-local runtime state files are missing on this machine, Terraform
# outputs can still be empty even when runtimes exist in AWS. Recover by name.
if [[ -z "$AGENTCORE_ORCHESTRATOR_ARN" || -z "$AGENTCORE_ORDER_MANAGEMENT_ARN" || -z "$AGENTCORE_TROUBLESHOOTING_ARN" || -z "$AGENTCORE_PRODUCT_RECOMMENDATION_ARN" || -z "$AGENTCORE_ORCHESTRATOR_ID" || -z "$AGENTCORE_ORDER_MANAGEMENT_ID" || -z "$AGENTCORE_TROUBLESHOOTING_ID" || -z "$AGENTCORE_PRODUCT_RECOMMENDATION_ID" ]]; then
  warn "AgentCore runtime outputs still incomplete; resolving runtime IDs/ARNs via AWS API..."

  lookup_runtime_field() {
    local runtime_name="$1"
    local field="$2"
    local value
    value=$(aws bedrock-agentcore-control list-agent-runtimes \
      --region "$AWS_REGION" \
      --query "agentRuntimes[?agentRuntimeName=='${runtime_name}'] | [0].${field}" \
      --output text 2>/dev/null || true)
    if [[ -z "$value" || "$value" == "None" ]]; then
      echo ""
    else
      echo "$value"
    fi
  }

  ORCH_RUNTIME_NAME="${PROJECT_NAME//-/_}_orchestrator_${ENVIRONMENT}"
  TROUBLE_RUNTIME_NAME="${PROJECT_NAME//-/_}_troubleshooting_${ENVIRONMENT}"
  ORDER_RUNTIME_NAME="${PROJECT_NAME//-/_}_order_management_${ENVIRONMENT}"
  PRODUCT_RUNTIME_NAME="${PROJECT_NAME//-/_}_product_recommendation_${ENVIRONMENT}"

  [[ -n "$AGENTCORE_ORCHESTRATOR_ID" ]] || AGENTCORE_ORCHESTRATOR_ID=$(lookup_runtime_field "$ORCH_RUNTIME_NAME" "agentRuntimeId")
  [[ -n "$AGENTCORE_ORCHESTRATOR_ARN" ]] || AGENTCORE_ORCHESTRATOR_ARN=$(lookup_runtime_field "$ORCH_RUNTIME_NAME" "agentRuntimeArn")
  [[ -n "$AGENTCORE_TROUBLESHOOTING_ID" ]] || AGENTCORE_TROUBLESHOOTING_ID=$(lookup_runtime_field "$TROUBLE_RUNTIME_NAME" "agentRuntimeId")
  [[ -n "$AGENTCORE_TROUBLESHOOTING_ARN" ]] || AGENTCORE_TROUBLESHOOTING_ARN=$(lookup_runtime_field "$TROUBLE_RUNTIME_NAME" "agentRuntimeArn")
  [[ -n "$AGENTCORE_ORDER_MANAGEMENT_ID" ]] || AGENTCORE_ORDER_MANAGEMENT_ID=$(lookup_runtime_field "$ORDER_RUNTIME_NAME" "agentRuntimeId")
  [[ -n "$AGENTCORE_ORDER_MANAGEMENT_ARN" ]] || AGENTCORE_ORDER_MANAGEMENT_ARN=$(lookup_runtime_field "$ORDER_RUNTIME_NAME" "agentRuntimeArn")
  [[ -n "$AGENTCORE_PRODUCT_RECOMMENDATION_ID" ]] || AGENTCORE_PRODUCT_RECOMMENDATION_ID=$(lookup_runtime_field "$PRODUCT_RUNTIME_NAME" "agentRuntimeId")
  [[ -n "$AGENTCORE_PRODUCT_RECOMMENDATION_ARN" ]] || AGENTCORE_PRODUCT_RECOMMENDATION_ARN=$(lookup_runtime_field "$PRODUCT_RUNTIME_NAME" "agentRuntimeArn")

  [[ -n "${AGENTCORE_RUNTIME_ID:-}" ]] || AGENTCORE_RUNTIME_ID="$AGENTCORE_ORCHESTRATOR_ID"
  [[ -n "${AGENTCORE_RUNTIME_ARN:-}" ]] || AGENTCORE_RUNTIME_ARN="$AGENTCORE_ORCHESTRATOR_ARN"
fi

[[ -n "$EC2_IP" ]]        || err "EC2 instance IP not in outputs. Check terraform apply logs."
[[ -n "$ECR_API_REPO" ]]  || err "ECR API repo URL not in outputs."
[[ -n "$ATLAS_MONGO_HOST" ]] || err "Atlas host not in outputs."
[[ -n "$AGENTCORE_ORCHESTRATOR_ARN" ]] || err "AGENTCORE_ORCHESTRATOR_ARN output is empty after apply/refresh."
[[ -n "$AGENTCORE_TROUBLESHOOTING_ARN" ]] || err "Troubleshooting runtime ARN output is empty after apply/refresh."
[[ -n "$AGENTCORE_ORDER_MANAGEMENT_ARN" ]] || err "Order-management runtime ARN output is empty after apply/refresh."
[[ -n "$AGENTCORE_PRODUCT_RECOMMENDATION_ARN" ]] || err "Product-recommendation runtime ARN output is empty after apply/refresh."
[[ -n "$AGENTCORE_ORCHESTRATOR_ID" ]] || err "AGENTCORE_ORCHESTRATOR_ID output is empty after apply/refresh."
[[ -n "$AGENTCORE_TROUBLESHOOTING_ID" ]] || err "Troubleshooting runtime ID output is empty after apply/refresh."
[[ -n "$AGENTCORE_ORDER_MANAGEMENT_ID" ]] || err "Order-management runtime ID output is empty after apply/refresh."
[[ -n "$AGENTCORE_PRODUCT_RECOMMENDATION_ID" ]] || err "Product-recommendation runtime ID output is empty after apply/refresh."
[[ -n "$LAMBDA_MCP_FUNCTION_NAME" ]] || err "lambda_mcp_function_name output is empty after apply/refresh."

# Re-read KB ID post-apply
BEDROCK_KB_ID=""
if [[ -f "$KB_STATE_FILE" ]]; then
  BEDROCK_KB_ID=$(python3 -c "import json; print(json.load(open('$KB_STATE_FILE')).get('knowledge_base_id',''))" 2>/dev/null || echo "")
fi

# Build Mongo URI once for both runtime updates and .env.live output.
if [[ -n "$ATLAS_CONNECTION_STRING" ]]; then
  MONGODB_URI="$ATLAS_CONNECTION_STRING"
else
  MONGODB_URI="mongodb+srv://${ATLAS_DB_USER}:${TF_VAR_atlas_db_password}@${ATLAS_MONGO_HOST}/?retryWrites=true&w=majority"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5b — First-time MongoDB seeding (idempotent)
# Seed demo collections only when core collections are missing/empty.
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 5b — Checking MongoDB seed state..."

SEED_NEEDED=$(MONGODB_URI="$MONGODB_URI" MONGODB_DB="$ATLAS_DB_NAME" \
  bun -e '
    import { MongoClient } from "mongodb";
    const uri = process.env.MONGODB_URI;
    const dbName = process.env.MONGODB_DB || "bedrock_agents";
    const client = new MongoClient(uri, { appName: "deploy-seed-check" });
    await client.connect();
    const db = client.db(dbName);
    const required = ["customers", "products", "orders", "troubleshooting_docs"];
    let seeded = true;
    for (const coll of required) {
      const exists = (await db.listCollections({ name: coll }, { nameOnly: true }).toArray()).length > 0;
      if (!exists) {
        seeded = false;
        break;
      }
      const count = await db.collection(coll).countDocuments();
      if (count === 0) {
        seeded = false;
        break;
      }
    }
    await client.close();
    process.stdout.write(seeded ? "no" : "yes");
  ' 2>/dev/null || echo "yes")

if [[ "$SEED_NEEDED" == "yes" ]]; then
  log "Atlas appears unseeded — running first-time seed scripts..."
  (
    cd "$REPO_ROOT"
    MONGODB_URI="$MONGODB_URI" MONGODB_DB="$ATLAS_DB_NAME" bun db-seeding/seed-all.ts
  )
  ok "MongoDB seed complete (seed-all)"
else
  ok "MongoDB already seeded — skipping first-time seed step"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5c — Lambda MCP MongoDB URI normalization (PrivateLink direct URI)
# Avoid SRV DNS edge-cases in VPC Lambda by using Atlas awsPrivateLink URI.
# ══════════════════════════════════════════════════════════════════════════════
if [[ -n "$LAMBDA_MCP_FUNCTION_NAME" && -n "$ATLAS_PRIVATELINK_ENDPOINT_ID" ]]; then
  sep
  log "Phase 5c — Updating Lambda MCP MongoDB URI to Atlas PrivateLink direct URI..."
  if LAMBDA_PRIVATE_URI=$(ATLAS_PROJECT_ID="$TF_VAR_atlas_project_id" \
    CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}" \
    VPCE_ID="$ATLAS_PRIVATELINK_ENDPOINT_ID" \
    BASE_MONGODB_URI="$MONGODB_URI" \
    MONGODB_ATLAS_PUBLIC_KEY="${MONGODB_ATLAS_PUBLIC_KEY:-}" \
    MONGODB_ATLAS_PRIVATE_KEY="${MONGODB_ATLAS_PRIVATE_KEY:-}" \
    python3 - <<'PY'
import json, os, subprocess, urllib.parse
project = os.environ["ATLAS_PROJECT_ID"]
cluster = os.environ["CLUSTER_NAME"]
vpce_id = os.environ["VPCE_ID"]
base_uri = os.environ["BASE_MONGODB_URI"]
public_key = os.environ.get("MONGODB_ATLAS_PUBLIC_KEY", "")
private_key = os.environ.get("MONGODB_ATLAS_PRIVATE_KEY", "")
if not public_key or not private_key:
    raise SystemExit("missing Atlas API keys")
parsed = urllib.parse.urlsplit(base_uri)
user = urllib.parse.quote(urllib.parse.unquote(parsed.username or ""))
pwd = urllib.parse.quote(urllib.parse.unquote(parsed.password or ""))
resp = subprocess.check_output([
    "curl", "-s",
    "--user", f"{public_key}:{private_key}",
    "--digest",
    "-H", "Accept: application/vnd.atlas.2023-01-01+json",
    f"https://cloud.mongodb.com/api/atlas/v2/groups/{project}/clusters/{cluster}",
], text=True)
data = json.loads(resp)
pl_map = ((data.get("connectionStrings") or {}).get("awsPrivateLink") or {})
pl_conn = pl_map.get(vpce_id, "")
if not pl_conn:
    raise SystemExit(f"no awsPrivateLink connection string for endpoint {vpce_id}")
no_scheme = pl_conn.replace("mongodb://", "", 1)
print(f"mongodb://{user}:{pwd}@{no_scheme}&retryWrites=true&w=majority")
PY
  ); then
    aws lambda update-function-configuration \
      --region "$AWS_REGION" \
      --function-name "$LAMBDA_MCP_FUNCTION_NAME" \
      --environment "{\"Variables\":{\"MONGODB_URI\":\"${LAMBDA_PRIVATE_URI}\",\"MONGODB_DB\":\"${ATLAS_DB_NAME}\"}}" \
      --output json >/dev/null 2>&1 \
      && ok "Lambda MCP MongoDB URI updated to awsPrivateLink direct connection string" \
      || err "Failed to update Lambda MCP MongoDB URI"
    # Keep API and Lambda on the same PrivateLink-safe URI so API-side memory
    # (short-term fallback + long-term facts) can reach Mongo reliably.
    MONGODB_URI="$LAMBDA_PRIVATE_URI"
    ok "API MongoDB URI normalized to awsPrivateLink direct connection string"
  else
    err "Could not compute Atlas awsPrivateLink URI for Lambda MCP"
  fi
else
  err "Missing Lambda MCP function name or Atlas PrivateLink endpoint ID for deterministic deploy"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5d — Cognito test user seeding (idempotent)
# Creates deterministic test users for auth validation, matching seeded orders.
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$COGNITO_SEED_USERS" == "true" ]]; then
  sep
  log "Phase 5d — Seeding Cognito test users..."

  [[ -n "$COGNITO_POOL_ID" ]] || err "cognito_user_pool_id output is empty."
  [[ -n "$COGNITO_CLIENT_ID" ]] || err "cognito_app_client_id output is empty."

  seed_cognito_user() {
    local email="$1"
    local name="$2"
    if aws cognito-idp admin-get-user \
      --region "$AWS_REGION" \
      --user-pool-id "$COGNITO_POOL_ID" \
      --username "$email" >/dev/null 2>&1; then
      :
    else
      aws cognito-idp admin-create-user \
        --region "$AWS_REGION" \
        --user-pool-id "$COGNITO_POOL_ID" \
        --username "$email" \
        --user-attributes "Name=email,Value=${email}" "Name=email_verified,Value=true" "Name=name,Value=${name}" \
        --message-action SUPPRESS >/dev/null \
        || err "Failed to create Cognito user ${email}"
    fi

    aws cognito-idp admin-set-user-password \
      --region "$AWS_REGION" \
      --user-pool-id "$COGNITO_POOL_ID" \
      --username "$email" \
      --password "$COGNITO_TEST_PASSWORD" \
      --permanent >/dev/null \
      || err "Failed setting deterministic password for Cognito user ${email}"
  }

  IFS=',' read -r -a COGNITO_TEST_USERS <<<"$COGNITO_TEST_USERS_CSV"
  for email in "${COGNITO_TEST_USERS[@]}"; do
    e_trimmed="$(echo "$email" | xargs)"
    [[ -n "$e_trimmed" ]] || continue
    case "$e_trimmed" in
      alex@example.com)  seed_cognito_user "$e_trimmed" "Alex Rivera" ;;
      blake@example.com) seed_cognito_user "$e_trimmed" "Blake Chen" ;;
      casey@example.com) seed_cognito_user "$e_trimmed" "Casey Morgan" ;;
      *)                 seed_cognito_user "$e_trimmed" "Demo User" ;;
    esac
  done
  ok "Cognito users ready: ${COGNITO_TEST_USERS_CSV}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — Build + push Docker images (API + UI = amd64; agent-runtime = arm64)
# ══════════════════════════════════════════════════════════════════════════════
sep
if [[ "$SKIP_DOCKER" == "true" ]]; then
  warn "Phase 6 — Skipping Docker build/push (--skip-docker)"
else
  log "Phase 6 — Building and pushing Docker images to ECR..."
  if [[ "$AGENTCORE_RUNTIME_DEPLOYMENT_MODE" == "container" ]]; then
    "$SCRIPT_DIR/docker-build-push.sh" "$ECR_API_REPO" "$ECR_UI_REPO" "$AWS_REGION" "$ECR_RUNTIME_REPO"
  else
    "$SCRIPT_DIR/docker-build-push.sh" "$ECR_API_REPO" "$ECR_UI_REPO" "$AWS_REGION"
  fi
  ok "Images pushed to ECR"
fi

ECR_API_IMAGE="${ECR_API_REPO}:latest"
ECR_UI_IMAGE="${ECR_UI_REPO}:latest"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6b — Update AgentCore runtimes with dynamic env vars
# Terraform creates static env vars; now inject dynamic vars (MongoDB URI, KB ID,
# Gateway URL, Memory ID). Orchestrator additionally gets specialist runtime ARNs.
# ══════════════════════════════════════════════════════════════════════════════
if [[ -n "$AGENTCORE_ORCHESTRATOR_ID" ]]; then
  sep
  log "Phase 6b — Updating AgentCore Runtime environment variables..."

  DYNAMIC_ENV_BASE=$(MONGODB_URI="$MONGODB_URI" ATLAS_DB_NAME="$ATLAS_DB_NAME" BEDROCK_KB_ID="$BEDROCK_KB_ID" \
    AGENTCORE_MEMORY_STORE_ID="$AGENTCORE_MEMORY_STORE_ID" AGENTCORE_GATEWAY_URL="$AGENTCORE_GATEWAY_URL" \
    LAMBDA_MCP_FUNCTION_NAME="$LAMBDA_MCP_FUNCTION_NAME" LAMBDA_MCP_ARN="$LAMBDA_MCP_ARN" python3 -c "
import json, os
env = {
  'AWS_REGION':               os.environ['AWS_REGION'],
  'CHAT_MODE':                'live',
  'TOOL_HOSTING_MODE':        'lambda',
  'SHORT_TERM_MEMORY_BACKEND':'agentcore',
  'PERSIST_CHAT_SESSIONS':    '1',
  'MEMORY_TTL_DAYS':          '30',
  'LOG_LEVEL':                'info',
  'MONGODB_URI':              os.environ.get('MONGODB_URI',''),
  'MONGODB_DB':               os.environ.get('ATLAS_DB_NAME','bedrock_agents'),
  'BEDROCK_KB_ID':            os.environ.get('BEDROCK_KB_ID',''),
  'AGENTCORE_MEMORY_STORE_ID':os.environ.get('AGENTCORE_MEMORY_STORE_ID',''),
  'LAMBDA_MCP_FUNCTION_NAME': os.environ.get('LAMBDA_MCP_FUNCTION_NAME',''),
  'LAMBDA_MCP_FUNCTION_ARN':  os.environ.get('LAMBDA_MCP_ARN',''),
  'MCP_SERVER_URL':           '',
  'AGENTCORE_GATEWAY_URL':    os.environ.get('AGENTCORE_GATEWAY_URL',''),
  'EMBEDDING_MODEL_ID':       'amazon.titan-embed-text-v2:0',
}
# AWS CLI env format: {\"KEY\": \"VAL\"}
print(json.dumps({k: str(v) for k,v in env.items() if v}))
")

  DYNAMIC_ENV_ORCHESTRATOR=$(DYNAMIC_ENV_BASE="$DYNAMIC_ENV_BASE" \
    AGENTCORE_TROUBLESHOOTING_ARN="$AGENTCORE_TROUBLESHOOTING_ARN" \
    AGENTCORE_ORDER_MANAGEMENT_ARN="$AGENTCORE_ORDER_MANAGEMENT_ARN" \
    AGENTCORE_PRODUCT_RECOMMENDATION_ARN="$AGENTCORE_PRODUCT_RECOMMENDATION_ARN" \
    python3 -c "
import json, os
base = json.loads(os.environ['DYNAMIC_ENV_BASE'])
base['ORCHESTRATOR_MODE'] = 'runtime'
specialists = {
  'AGENTCORE_RUNTIME_ARN_TROUBLESHOOTING': os.environ.get('AGENTCORE_TROUBLESHOOTING_ARN',''),
  'AGENTCORE_RUNTIME_ARN_ORDER_MANAGEMENT': os.environ.get('AGENTCORE_ORDER_MANAGEMENT_ARN',''),
  'AGENTCORE_RUNTIME_ARN_PRODUCT_RECOMMENDATION': os.environ.get('AGENTCORE_PRODUCT_RECOMMENDATION_ARN',''),
}
for k, v in specialists.items():
  if v:
    base[k] = v
print(json.dumps(base))
")

  ECR_RUNTIME_IMAGE="${ECR_RUNTIME_REPO}:latest"

  update_runtime_env() {
    local runtime_id="$1"
    local env_json="$2"
    local runtime_label="$3"
    local role_arn
    role_arn=$(aws bedrock-agentcore-control get-agent-runtime \
      --region "$AWS_REGION" \
      --agent-runtime-id "$runtime_id" \
      --query "roleArn" --output text 2>/dev/null || echo "")

    if [[ -z "$role_arn" || "$role_arn" == "None" ]]; then
      err "Could not resolve roleArn for ${runtime_label} (${runtime_id})"
    fi

    if [[ "$AGENTCORE_RUNTIME_DEPLOYMENT_MODE" == "container" ]]; then
      aws bedrock-agentcore-control update-agent-runtime \
        --region "$AWS_REGION" \
        --agent-runtime-id "$runtime_id" \
        --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${ECR_RUNTIME_IMAGE}\"}}" \
        --role-arn "$role_arn" \
        --network-configuration '{"networkMode":"PUBLIC"}' \
        --environment-variables "$env_json" \
        --output json > /dev/null 2>&1 \
        && ok "Updated ${runtime_label} runtime env vars" \
        || err "Failed to update ${runtime_label} runtime env vars"
    else
      aws bedrock-agentcore-control update-agent-runtime \
        --region "$AWS_REGION" \
        --agent-runtime-id "$runtime_id" \
        --agent-runtime-artifact "{\"codeConfiguration\":{\"code\":{\"s3\":{\"bucket\":\"${SHARED_BUCKET}\",\"prefix\":\"${AGENTCORE_CODE_ARTIFACT_PREFIX}\"}},\"runtime\":\"NODE_22\",\"entryPoint\":[\"agent-runtime-code.js\"]}}" \
        --role-arn "$role_arn" \
        --network-configuration '{"networkMode":"PUBLIC"}' \
        --environment-variables "$env_json" \
        --output json > /dev/null 2>&1 \
        && ok "Updated ${runtime_label} runtime env vars + code artifact" \
        || err "Failed to update ${runtime_label} runtime env vars/code artifact"
    fi
  }

  verify_runtime_env() {
    local runtime_id="$1"
    local runtime_label="$2"
    local expected_agent_id="$3"
    local must_be_orchestrator="$4"
    local env_json
    local attempt
    for attempt in $(seq 1 12); do
      env_json=$(aws bedrock-agentcore-control get-agent-runtime \
        --region "$AWS_REGION" \
        --agent-runtime-id "$runtime_id" \
        --query "environmentVariables" \
        --output json 2>/dev/null || echo "{}")

      if python3 - <<'PY' "$env_json" "$runtime_label" "$expected_agent_id" "$must_be_orchestrator"
import json, sys
env = json.loads(sys.argv[1] or "{}")
label = sys.argv[2]
expected_agent = sys.argv[3]
is_orch = sys.argv[4] == "yes"

def fail(msg: str) -> None:
    raise SystemExit(f"{label}: {msg}")

if env.get("AGENT_ID") != expected_agent:
    fail(f"AGENT_ID expected {expected_agent}, got {env.get('AGENT_ID')}")
if env.get("TOOL_HOSTING_MODE") != "lambda":
    fail(f"TOOL_HOSTING_MODE expected lambda, got {env.get('TOOL_HOSTING_MODE')}")
if env.get("SHORT_TERM_MEMORY_BACKEND") != "agentcore":
    fail(f"SHORT_TERM_MEMORY_BACKEND expected agentcore, got {env.get('SHORT_TERM_MEMORY_BACKEND')}")
if not env.get("LAMBDA_MCP_FUNCTION_NAME"):
    fail("LAMBDA_MCP_FUNCTION_NAME missing")
if is_orch:
    if env.get("ORCHESTRATOR_MODE") != "runtime":
        fail(f"ORCHESTRATOR_MODE expected runtime, got {env.get('ORCHESTRATOR_MODE')}")
    for k in (
        "AGENTCORE_RUNTIME_ARN_TROUBLESHOOTING",
        "AGENTCORE_RUNTIME_ARN_ORDER_MANAGEMENT",
        "AGENTCORE_RUNTIME_ARN_PRODUCT_RECOMMENDATION",
    ):
        if not env.get(k):
            fail(f"{k} missing")
print("ok")
PY
      then
        return 0
      fi
      sleep 5
    done
    return 1
  }

  # Specialists: base dynamic env + AGENT_ID
  DYNAMIC_ENV_TROUBLESHOOTING=$(DYNAMIC_ENV_BASE="$DYNAMIC_ENV_BASE" python3 -c "
import json, os
env = json.loads(os.environ['DYNAMIC_ENV_BASE'])
env['AGENT_ID'] = 'troubleshooting'
print(json.dumps(env))
")
  DYNAMIC_ENV_ORDER_MANAGEMENT=$(DYNAMIC_ENV_BASE="$DYNAMIC_ENV_BASE" python3 -c "
import json, os
env = json.loads(os.environ['DYNAMIC_ENV_BASE'])
env['AGENT_ID'] = 'order-management'
print(json.dumps(env))
")
  DYNAMIC_ENV_PRODUCT_RECOMMENDATION=$(DYNAMIC_ENV_BASE="$DYNAMIC_ENV_BASE" python3 -c "
import json, os
env = json.loads(os.environ['DYNAMIC_ENV_BASE'])
env['AGENT_ID'] = 'product-recommendation'
print(json.dumps(env))
")

  # Orchestrator: base dynamic env + specialist runtime ARNs
  DYNAMIC_ENV_ORCHESTRATOR=$(DYNAMIC_ENV_ORCHESTRATOR="$DYNAMIC_ENV_ORCHESTRATOR" python3 -c "
import json, os
env = json.loads(os.environ['DYNAMIC_ENV_ORCHESTRATOR'])
env['AGENT_ID'] = 'orchestrator'
print(json.dumps(env))
")

  update_runtime_env "$AGENTCORE_ORCHESTRATOR_ID" "$DYNAMIC_ENV_ORCHESTRATOR" "orchestrator"

  [[ -n "$AGENTCORE_TROUBLESHOOTING_ID" && "$AGENTCORE_TROUBLESHOOTING_ID" != "None" ]] && \
    update_runtime_env "$AGENTCORE_TROUBLESHOOTING_ID" "$DYNAMIC_ENV_TROUBLESHOOTING" "troubleshooting"
  [[ -n "$AGENTCORE_ORDER_MANAGEMENT_ID" && "$AGENTCORE_ORDER_MANAGEMENT_ID" != "None" ]] && \
    update_runtime_env "$AGENTCORE_ORDER_MANAGEMENT_ID" "$DYNAMIC_ENV_ORDER_MANAGEMENT" "order-management"
  [[ -n "$AGENTCORE_PRODUCT_RECOMMENDATION_ID" && "$AGENTCORE_PRODUCT_RECOMMENDATION_ID" != "None" ]] && \
    update_runtime_env "$AGENTCORE_PRODUCT_RECOMMENDATION_ID" "$DYNAMIC_ENV_PRODUCT_RECOMMENDATION" "product-recommendation"

  log "Phase 6c — Verifying runtime environment variables..."
  verify_runtime_env "$AGENTCORE_ORCHESTRATOR_ID" "orchestrator" "orchestrator" "yes" || err "Runtime env verification failed for orchestrator"
  verify_runtime_env "$AGENTCORE_TROUBLESHOOTING_ID" "troubleshooting" "troubleshooting" "no" || err "Runtime env verification failed for troubleshooting"
  verify_runtime_env "$AGENTCORE_ORDER_MANAGEMENT_ID" "order-management" "order-management" "no" || err "Runtime env verification failed for order-management"
  verify_runtime_env "$AGENTCORE_PRODUCT_RECOMMENDATION_ID" "product-recommendation" "product-recommendation" "no" || err "Runtime env verification failed for product-recommendation"
  ok "Runtime env verification passed"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 7 — Write .env.live + copy to EC2 via SSM
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 7 — Writing .env.live and copying to EC2 via SSM..."

# Tool hosting
#
# MongoDB MCP runs as a Lambda function invoked directly by AgentCore runtimes.
TOOL_HOSTING_MODE="lambda"
MCP_SERVER_URL=""

if [[ -n "$VOYAGE_ENDPOINT" ]]; then
  EMBEDDING_LINE="Voyage AI multimodal-3 (${VOYAGE_ENDPOINT})"
else
  EMBEDDING_LINE="Bedrock Titan (amazon.titan-embed-text-v2:0)"
fi

cat > "$REPO_ROOT/.env.live" <<EOF
# EC2 mode — generated by deploy.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Embedding: ${EMBEDDING_LINE}
# Tools:     Direct Lambda MongoDB MCP (no AgentCore Gateway path)
# NOTE: plain KEY=VALUE only — no export, no quotes, no declare -x
CHAT_MODE=live
ORCHESTRATOR_MODE=runtime

# MongoDB Atlas
MONGODB_URI=${MONGODB_URI}
MONGODB_DB=${ATLAS_DB_NAME}

# Bedrock
BEDROCK_KB_ID=${BEDROCK_KB_ID}
AWS_REGION=${AWS_REGION}

# Embedding — Voyage SageMaker when ARN was set at deploy time, Titan otherwise
VOYAGE_SAGEMAKER_ENDPOINT=${VOYAGE_ENDPOINT}
EMBEDDING_MODEL_ID=amazon.titan-embed-text-v2:0

# AgentCore — Memory store, Gateway (Lambda MCP), Agent runtimes (orchestrator + specialists)
AGENTCORE_MEMORY_STORE_ID=${AGENTCORE_MEMORY_STORE_ID}
AGENTCORE_GATEWAY_URL=${AGENTCORE_GATEWAY_URL}
AGENTCORE_ORCHESTRATOR_ARN=${AGENTCORE_ORCHESTRATOR_ARN}

# Tool hosting — AgentCore runtime direct invoke to Lambda MongoDB MCP
TOOL_HOSTING_MODE=${TOOL_HOSTING_MODE}
MCP_SERVER_URL=${MCP_SERVER_URL}
LAMBDA_MCP_FUNCTION_NAME=${LAMBDA_MCP_FUNCTION_NAME}
LAMBDA_MCP_FUNCTION_ARN=${LAMBDA_MCP_ARN}
SHORT_TERM_MEMORY_BACKEND=agentcore
PERSIST_CHAT_SESSIONS=1
MEMORY_TTL_DAYS=30

# CloudWatch
CLOUDWATCH_LOG_GROUP=${CW_API_LOG_GROUP}

# Cognito — JWT auth for the API (toggle via REQUIRE_AUTH)
REQUIRE_AUTH=${COGNITO_REQUIRE_AUTH}
AUTH_JWKS_URI=${COGNITO_JWKS}
AUTH_ISSUER=https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_POOL_ID}
STREAMLIT_COGNITO_POOL_ID=${COGNITO_POOL_ID}
STREAMLIT_COGNITO_CLIENT_ID=${COGNITO_CLIENT_ID}

# EC2 URLs
STREAMLIT_API_URL=http://${EC2_IP}:3000/
EOF
ok ".env.live written"

wait_for_instance_status_ok "$EC2_INSTANCE_ID"
wait_for_ssm_online "$EC2_INSTANCE_ID"

# Wait for cloud-init/bootstrap completion marker.
BOOTSTRAP_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: check bootstrap marker" \
  '["test -f /opt/multiagent/.bootstrap-done && echo yes || echo no"]' \
  24) || err "Could not send bootstrap-check command via SSM"

wait_for_ssm_command_success "$BOOTSTRAP_CMD_ID" "$EC2_INSTANCE_ID" 36 \
  || err "Bootstrap check command failed on EC2"

BOOTSTRAP_OUT=$(aws ssm get-command-invocation \
  --region "$AWS_REGION" \
  --command-id "$BOOTSTRAP_CMD_ID" \
  --instance-id "$EC2_INSTANCE_ID" \
  --query "StandardOutputContent" --output text 2>/dev/null || echo "no")
if [[ "$BOOTSTRAP_OUT" != *"yes"* ]]; then
  err "EC2 bootstrap marker not found at /opt/multiagent/.bootstrap-done"
fi
ok "EC2 bootstrap marker detected"

# Copy via SSM Session Manager — no SSH key required.
log "Copying .env.live to EC2 ($EC2_INSTANCE_ID) via SSM..."
_ENV_B64=$(base64 < "$REPO_ROOT/.env.live" | tr -d '\n')
ENV_SYNC_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: sync .env.live" \
  "[\"echo '${_ENV_B64}' | base64 -d > /opt/multiagent/.env.live && chmod 600 /opt/multiagent/.env.live\"]" \
  12) || err "Failed to send .env.live to EC2 via SSM"

wait_for_ssm_command_success "$ENV_SYNC_CMD_ID" "$EC2_INSTANCE_ID" 24 \
  || err ".env.live sync command failed on EC2"
ok ".env.live synced to /opt/multiagent/.env.live"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 8 — Restart services on EC2 + ECR docker login
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 8 — Pulling images + restarting services on EC2..."

# Single SSM command: ECR login, pull latest images, restart API + UI containers.
# MongoDB MCP is now a Lambda function (no local sidecar to restart).
ECR_REGISTRY=$(echo "$ECR_API_REPO" | cut -d'/' -f1)
RESTART_CMD="aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY} \
  && docker pull ${ECR_API_IMAGE} \
  && docker pull ${ECR_UI_IMAGE} \
  && systemctl daemon-reload \
  && systemctl restart multiagent-api multiagent-ui"

RESTART_CMD_ID=$(send_ssm_command_retry \
  "$EC2_INSTANCE_ID" \
  "multiagent: pull images + restart services" \
  "[\"${RESTART_CMD//\"/\\\"}\"]" \
  12) || err "Failed to send restart command via SSM"
wait_for_ssm_command_success "$RESTART_CMD_ID" "$EC2_INSTANCE_ID" 36 \
  || err "EC2 service restart command failed"
ok "Restart command completed"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 9 — Health check + summary
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Waiting for API health check..."
HEALTH_OK="no"
API_HEALTH_MAX_ATTEMPTS=120
for i in $(seq 1 "$API_HEALTH_MAX_ATTEMPTS"); do
  if curl -sf --max-time 10 "http://${EC2_IP}:3000/health" > /dev/null 2>&1; then
    ok "API is healthy"
    HEALTH_OK="yes"
    break
  fi
  log "  Waiting ($i/${API_HEALTH_MAX_ATTEMPTS})..."
  sleep 5
done
if [[ "$HEALTH_OK" != "yes" ]]; then
  warn "Public /health probe timed out; verifying API health from inside EC2 via SSM..."
  HEALTH_SSM_CMD_ID=$(send_ssm_command_retry \
    "$EC2_INSTANCE_ID" \
    "multiagent: api health local probe" \
    '["curl -sf --max-time 10 http://127.0.0.1:3000/health >/dev/null && echo ok || echo fail"]' \
    12) || err "Failed to send local API health check via SSM"
  wait_for_ssm_command_success "$HEALTH_SSM_CMD_ID" "$EC2_INSTANCE_ID" 24 \
    || err "Local API health SSM command failed"
  HEALTH_SSM_OUT=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$HEALTH_SSM_CMD_ID" \
    --instance-id "$EC2_INSTANCE_ID" \
    --query "StandardOutputContent" --output text 2>/dev/null || echo "fail")
  [[ "$HEALTH_SSM_OUT" == *"ok"* ]] || err "API health check did not pass in time"
  ok "API is healthy (verified via EC2 local probe)"
fi

sep
log "Phase 9b — Deterministic backend smoke validation..."
SMOKE_SESSION_ID="deploy-smoke-$(date +%s)"
EC2_API_URL="http://${EC2_IP}:3000"
SMOKE_ID_TOKEN=""
if [[ "$COGNITO_REQUIRE_AUTH" == "true" ]]; then
  SMOKE_ID_TOKEN=$(aws cognito-idp initiate-auth \
    --region "$AWS_REGION" \
    --client-id "$COGNITO_CLIENT_ID" \
    --auth-flow USER_PASSWORD_AUTH \
    --auth-parameters "USERNAME=${COGNITO_SMOKE_USER_EMAIL},PASSWORD=${COGNITO_TEST_PASSWORD}" \
    --query "AuthenticationResult.IdToken" \
    --output text 2>/dev/null || echo "")
  [[ -n "$SMOKE_ID_TOKEN" && "$SMOKE_ID_TOKEN" != "None" ]] || err "Could not obtain Cognito IdToken for smoke user ${COGNITO_SMOKE_USER_EMAIL}"
fi

python3 - <<'PY' "$EC2_API_URL" "$SMOKE_SESSION_ID" "$SMOKE_ID_TOKEN"
import json, sys, urllib.request
api = sys.argv[1].rstrip("/")
sid = sys.argv[2]
id_token = sys.argv[3]

def post_chat(message: str) -> str:
    headers = {"Content-Type": "application/json"}
    if id_token:
        headers["Authorization"] = f"Bearer {id_token}"
    req = urllib.request.Request(
        f"{api}/chat",
        data=json.dumps({"sessionId": sid, "message": message}).encode(),
        headers=headers,
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read().decode("utf-8", "replace")

first = post_chat("I need to return an item from a delivered order!")
second = post_chat("Order ORD-1003 for alex@example.com. Please start the return.")

def check_sse(body: str) -> tuple[bool, bool, bool]:
    has_token = "event: token" in body
    has_handoff = "event: handoff" in body
    has_done = "event: done" in body
    return has_token, has_handoff, has_done

t1, h1, d1 = check_sse(first)
t2, h2, d2 = check_sse(second)
if not (t1 and d1 and t2 and h2 and d2):
    raise SystemExit("SSE smoke validation failed: missing token/handoff/done events")
if "event: error" in first or "event: error" in second:
    raise SystemExit("SSE smoke validation failed: error event present")

if id_token:
    req = urllib.request.Request(
        f"{api}/sessions/{sid}",
        headers={"Authorization": f"Bearer {id_token}"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        session_doc = json.loads(r.read().decode("utf-8", "replace"))
    if not session_doc.get("userId"):
        raise SystemExit("Auth propagation failed: session.userId missing under Cognito auth")
print("smoke_ok")
PY
ok "Backend smoke validation passed"

sep
ok "EC2 deployment complete!"
echo ""
echo "  API        : ${EC2_API}"
echo "  UI         : ${EC2_UI}"
echo "  EC2 IP     : ${EC2_IP}"
echo "  Shell      : ${EC2_SSM}"
echo ""
echo "  Atlas      : ${ATLAS_MONGO_HOST}"
echo "  Bedrock KB : ${BEDROCK_KB_ID:-'(not yet provisioned)'}"
echo "  Embedding  : ${VOYAGE_ENDPOINT:-'Titan (amazon.titan-embed-text-v2:0)'}"
echo "  AgentCore  : memory=${AGENTCORE_MEMORY_STORE_ID:-?}"
echo "               gateway=${AGENTCORE_GATEWAY_URL:-?}"
echo "  Tools/MCP  : Lambda ${LAMBDA_MCP_ARN:-?} direct invoke (no Gateway)"
echo "  Auth       : REQUIRE_AUTH=${COGNITO_REQUIRE_AUTH}"
echo "               Cognito users=${COGNITO_TEST_USERS_CSV}"
echo "               Password=${COGNITO_TEST_PASSWORD}"
echo ""
echo "  Logs       : aws ssm start-session --target ${EC2_INSTANCE_ID} --region ${AWS_REGION}"
echo "               then: journalctl -u multiagent-api -f"
echo ""
echo "  For local dev: ./deploy/scripts/deploy-local.sh"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 10 — Write resource manifest
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Phase 10 — Writing resource manifest..."
MANIFEST_FILE="$REPO_ROOT/deploy-manifest.json"

export _MANIFEST_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
export _M_ACCOUNT="$ACCOUNT_ID"  _M_REGION="$AWS_REGION"   _M_ENV="$ENVIRONMENT"
export _M_BUCKET="$SHARED_BUCKET" _M_KB="$BEDROCK_KB_ID"
export _M_EC2_IP="$EC2_IP"        _M_EC2_ID="$EC2_INSTANCE_ID"
export _M_EC2_API="$EC2_API"      _M_EC2_UI="$EC2_UI"
export _M_COGNITO_POOL="$COGNITO_POOL_ID" _M_COGNITO_CLIENT="$COGNITO_CLIENT_ID"
export _M_VOYAGE="$VOYAGE_ENDPOINT"
export _M_ECR_API="$ECR_API_REPO"  _M_ECR_UI="$ECR_UI_REPO"
export _M_AC_MEM="$AGENTCORE_MEMORY_STORE_ID" _M_AC_GW="$AGENTCORE_GATEWAY_URL" _M_LAMBDA_ARN="$LAMBDA_MCP_ARN"
export _M_ATLAS_PROJ="$TF_VAR_atlas_project_id" _M_ATLAS_HOST="$ATLAS_MONGO_HOST"
export _M_TOOL_MODE="$TOOL_HOSTING_MODE"

python3 - <<'PYEOF' > "$MANIFEST_FILE"
import json, os
def v(k): return os.environ.get(k, "")
manifest = {
  "generated_at":  v("_MANIFEST_TS"),
  "mode":          "ec2",
  "script":        "deploy.sh",
  "aws_account":   v("_M_ACCOUNT"),
  "aws_region":    v("_M_REGION"),
  "environment":   v("_M_ENV"),
  "resources": {
    "s3_state_bucket":            v("_M_BUCKET"),
    "bedrock_kb_id":              v("_M_KB"),
    "secrets_manager_secret":     "bedrock-kb-atlas-creds",
    "ec2_instance_id":            v("_M_EC2_ID"),
    "ec2_public_ip":              v("_M_EC2_IP"),
    "ec2_api_url":                v("_M_EC2_API"),
    "ec2_ui_url":                 v("_M_EC2_UI"),
    "cognito_user_pool_id":       v("_M_COGNITO_POOL"),
    "cognito_client_id":          v("_M_COGNITO_CLIENT"),
    "voyage_sagemaker_endpoint":  v("_M_VOYAGE"),
    "ecr_api_repo":               v("_M_ECR_API"),
    "ecr_ui_repo":                v("_M_ECR_UI"),
    "agentcore_memory_id":        v("_M_AC_MEM"),
    "agentcore_gateway_url":      v("_M_AC_GW"),
    "agentcore_gateway_target":   "not used in tool path (direct Lambda invoke)",
    "lambda_mcp_function_arn":    v("_M_LAMBDA_ARN"),
    "atlas_project_id":           v("_M_ATLAS_PROJ"),
    "atlas_srv_host":             v("_M_ATLAS_HOST"),
    "tool_hosting_mode":          v("_M_TOOL_MODE"),
    "mcp_server":                 "Lambda: mongodb-mcp invoked directly by AgentCore runtimes",
  }
}
print(json.dumps(manifest, indent=2))
PYEOF
ok "Resource manifest written: $MANIFEST_FILE"
sep
