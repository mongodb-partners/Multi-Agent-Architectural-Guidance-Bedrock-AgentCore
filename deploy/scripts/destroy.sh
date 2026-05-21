#!/usr/bin/env bash
# destroy.sh — Tear down a Terraform environment (network, shared, local, or ec2)
#
# Usage:
#   ./deploy/scripts/destroy.sh --mode local   [--auto-approve] [--env-file <path>]
#   ./deploy/scripts/destroy.sh --mode ec2     [--auto-approve] [--env-file <path>]
#   ./deploy/scripts/destroy.sh --mode shared  [--auto-approve] [--env-file <path>]
#   ./deploy/scripts/destroy.sh --mode network [--auto-approve] [--env-file <path>]
#   ./deploy/scripts/destroy.sh --mode ec2     --with-bootstrap   # also deletes shared S3
#
# What it does:
#   1. Sources .env (or --env-file) for AWS + Atlas creds
#   2. Writes backend.hcl + terraform.tfvars for the chosen env
#   3. terraform init -backend-config=backend.hcl
#   4. terraform destroy (the chosen env's state)
#   5. With --with-bootstrap: also empties + destroys the shared state S3 bucket
#      WARNING: this deletes all Terraform state — make sure no other env uses it
#
# State keys:
#   envs/local   :  <env>/terraform.tfstate
#   envs/ec2     :  <env>/ec2/terraform.tfstate
#   envs/shared  :  <SHARED_VPC_NAME>/<region>/<env>/shared/terraform.tfstate
#   envs/network :  <SHARED_VPC_NAME>/<region>/network/terraform.tfstate
#
# All four share the same S3 bucket but use distinct state keys, so destroying
# one does NOT affect the others. IMPORTANT ordering:
#   ec2 → shared → network
# Destroy the per-project ec2 envs first (they read SSM published by both
# shared and network). Then destroy shared (account/region singleton). Then
# network last.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_ROOT="$REPO_ROOT/deploy/terraform"
BOOTSTRAP_DIR="$TF_ROOT/bootstrap"
REPORTS_DIR="$REPO_ROOT/destroy-reports"

ENV_FILE="$REPO_ROOT/.env"
MODE=""
AUTO_APPROVE=false
WITH_BOOTSTRAP=false
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
# DB user + DB name follow the same project+env convention as .env so a
# stale ATLAS_DB_USER / ATLAS_DB_NAME from a prior shell does not clobber the
# tfvars file. Mongo identifiers can't contain "-", so underscore-normalize.
_PROJECT_SLUG="${PROJECT_NAME//-/_}"
ATLAS_DB_USER="${ATLAS_DB_USER:-${_PROJECT_SLUG}_${ENVIRONMENT}_user}"
ATLAS_DB_NAME="${ATLAS_DB_NAME:-${_PROJECT_SLUG}_${ENVIRONMENT}}"
unset _PROJECT_SLUG
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
NETWORK_MODE="${NETWORK_MODE:-privatelink}"
ATLAS_PEERING_CIDR="${ATLAS_PEERING_CIDR:-192.168.248.0/21}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)           MODE="$2"; shift ;;
    --auto-approve)   AUTO_APPROVE=true ;;
    --with-bootstrap) WITH_BOOTSTRAP=true ;;
    --env-file)       ENV_FILE="$2"; shift ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

[[ "$MODE" == "local" || "$MODE" == "ec2" || "$MODE" == "shared" || "$MODE" == "network" ]] \
  || { echo "✗ --mode is required and must be 'local', 'ec2', 'shared', or 'network'" >&2; exit 1; }

TF_DIR="$TF_ROOT/envs/$MODE"
[[ -d "$TF_DIR" ]] || { echo "✗ env dir not found: $TF_DIR" >&2; exit 1; }

# STATE_KEY is computed *after* .env is sourced (see below) so that any
# AWS_REGION / ENVIRONMENT / SHARED_VPC_NAME override in .env wins over the
# pre-source defaults declared at the top of this file.

log()  { echo "  [destroy:$MODE] $*"; }
ok()   { echo "  [destroy:$MODE] ✓ $*"; }
err()  { echo "  [destroy:$MODE] ✗ $*" >&2; exit 1; }
warn() { echo "  [destroy:$MODE] ⚠ $*"; }
sep()  { echo "────────────────────────────────────────────────"; }

# shellcheck source=deploy/scripts/_sg-cleanup.sh
source "$SCRIPT_DIR/_sg-cleanup.sh"

# ══════════════════════════════════════════════════════════════════════════════
# Prerequisites
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Checking prerequisites..."
for cmd in terraform aws python3; do
  command -v "$cmd" &>/dev/null || err "'$cmd' not found in PATH"
done

# ══════════════════════════════════════════════════════════════════════════════
# Load credentials
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Loading credentials from $ENV_FILE..."
[[ -f "$ENV_FILE" ]] || err "env file not found: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

export TF_VAR_atlas_db_password="${TF_VAR_atlas_db_password:-${TF_VAR_mongodb_password:-}}"
[[ -n "${TF_VAR_atlas_db_password:-}" ]] || err "Atlas DB password not set in .env"

export TF_VAR_atlas_project_id="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
[[ -n "${TF_VAR_atlas_project_id:-}" ]] || err "Atlas Project ID not set in .env"

export TF_VAR_atlas_public_key="${MONGODB_ATLAS_PUBLIC_KEY:-}"
export TF_VAR_atlas_private_key="${MONGODB_ATLAS_PRIVATE_KEY:-}"

# shellcheck source=deploy/scripts/_aws-auth.sh
source "$SCRIPT_DIR/_aws-auth.sh"
validate_aws_auth || err "AWS auth validation failed (see above)"
ACCOUNT_ID="$AWS_AUTH_ACCOUNT_ID"
ok "AWS account: $ACCOUNT_ID"

SHARED_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-${ACCOUNT_ID}"

# Re-default SHARED_VPC_NAME after sourcing .env so a missing .env entry
# falls back to the canonical value, and recompute STATE_KEY from post-source
# variables so a .env override of ENVIRONMENT / AWS_REGION / SHARED_VPC_NAME
# is honored. Same for NETWORK_MODE (drives tfvars + SSM cleanup branches).
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
NETWORK_MODE="${NETWORK_MODE:-privatelink}"
ATLAS_PEERING_CIDR="${ATLAS_PEERING_CIDR:-192.168.248.0/21}"
case "$NETWORK_MODE" in
  privatelink|peering) ;;
  *) err "Invalid NETWORK_MODE='${NETWORK_MODE}' — must be 'privatelink' or 'peering'" ;;
esac
[[ "$MODE" == "ec2" || "$MODE" == "network" ]] && ok "Network mode: ${NETWORK_MODE}"
case "$MODE" in
  local)   STATE_KEY="${ENVIRONMENT}/terraform.tfstate" ;;
  ec2)     STATE_KEY="${ENVIRONMENT}/ec2/terraform.tfstate" ;;
  shared)  STATE_KEY="${SHARED_VPC_NAME}/${AWS_REGION}/${ENVIRONMENT}/shared/terraform.tfstate" ;;
  network) STATE_KEY="${SHARED_VPC_NAME}/${AWS_REGION}/network/terraform.tfstate" ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# Safety confirmation
# ══════════════════════════════════════════════════════════════════════════════
sep
warn "This will DESTROY envs/$MODE resources in account $ACCOUNT_ID:"
case "$MODE" in
  local)
    warn "  • MongoDB Atlas M10 cluster + DB user"
    warn "  • Bedrock Knowledge Base + IAM policies + Secrets Manager secret"
    warn "  • CloudWatch log groups"
    warn "  • S3 objects under s3://$SHARED_BUCKET/kb-docs/"
    ;;
  ec2)
    warn "  • Atlas M10 cluster + DB user"
    warn "  • EC2 instance + Elastic IP + ECR repos + Cognito pool"
    warn "  • mongodb-mcp AgentCore Runtime + AgentCore Memory + AgentCore Gateway"
    warn "  • Per-cluster Route 53 private zone (atlas-privatelink-dns)"
    warn "  • Bedrock Knowledge Base (Voyage SageMaker now lives in envs/shared)"
    warn "  • CloudWatch GenAI Observability (Transaction Search + AgentCore log delivery)"
    warn "  (Shared VPC + Atlas PrivateLink VPCE live in envs/network — not touched.)"
    warn "  (Shared SageMaker + log groups + dashboards live in envs/shared — not touched.)"
    ;;
  shared)
    warn "  • Voyage SageMaker endpoint + endpoint config + model + IAM exec role"
    warn "  • CloudWatch log groups: API / UI / MCP / AgentCore / OTel / OTel-Atlas"
    warn "  • Bedrock invocation logging + audit log group (account-scoped singleton)"
    warn "  • Fleet / mongo / cost dashboards + 7 fleet alarms + audit metric filter"
    warn "  • Atlas dashboard + 2 alarms (if enable_atlas_metrics=true)"
    warn "  • Logs-Insights saved query library"
    warn "  • SSM params under /${SHARED_VPC_NAME}/${AWS_REGION}/ (voyage_*, cw_*, bedrock_*)"
    warn ""
    warn "  ⚠ DO NOT proceed if any per-project envs/ec2 deployment in"
    warn "  ⚠ account+region+environment ${AWS_REGION}/${ENVIRONMENT} is still applied —"
    warn "  ⚠ those envs read SSM values published here, and the ADOT collector"
    warn "  ⚠ will lose its CloudWatch log destinations."
    ;;
  network)
    warn "  • Shared VPC + public/private subnets + IGW + RT"
    if [[ "$NETWORK_MODE" == "privatelink" ]]; then
      warn "  • Atlas Interface VPCE + Atlas-side endpoint binding"
      warn "  • Atlas-PL security group"
    else
      warn "  • AWS-side VPC peering accepter + route entries (main + public RT)"
      warn "  • Atlas-side mongodbatlas_network_peering"
      warn "  • Atlas project IP access list peering entries"
      warn "  • (Atlas network container is intentionally KEPT — shared across deployments)"
    fi
    warn "  • SSM params under /${SHARED_VPC_NAME}/${AWS_REGION}/ (network_mode + ${NETWORK_MODE} keys)"
    warn ""
    warn "  ⚠ DO NOT proceed if any per-project envs/ec2 deployment in"
    warn "  ⚠ region ${AWS_REGION} is still applied — those envs read SSM"
    warn "  ⚠ values published here, and will fail to plan after destroy."
    ;;
esac
if [[ "$WITH_BOOTSTRAP" == "true" ]]; then
  warn "  • Shared S3 bucket: $SHARED_BUCKET  ← DELETES ALL TERRAFORM STATE"
fi
warn "  • Legacy orphans (if present): bedrock-kb-atlas-creds, bedrock-kb-ts-role,"
warn "    ts-bedrock-kb-creator, ts-aoss-index-creator, troubleshooting-kb"
echo ""

if [[ "$AUTO_APPROVE" == "false" ]]; then
  read -r -p "  Type 'yes' to confirm destroy: " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { log "Cancelled."; exit 0; }
fi

# ══════════════════════════════════════════════════════════════════════════════
# Write backend.hcl + terraform.tfvars
# ══════════════════════════════════════════════════════════════════════════════
sep
cat > "$TF_DIR/backend.hcl" <<EOF
bucket  = "${SHARED_BUCKET}"
key     = "${STATE_KEY}"
region  = "${AWS_REGION}"
encrypt = true
EOF

# Minimal tfvars — only required vars (defaults cover the rest)
case "$MODE" in
  local)
    cat > "$TF_DIR/terraform.tfvars" <<EOF
aws_region         = "${AWS_REGION}"
environment        = "${ENVIRONMENT}"
project_name       = "${PROJECT_NAME}"
shared_bucket_name = "${SHARED_BUCKET}"
atlas_project_id   = "${TF_VAR_atlas_project_id}"
atlas_db_user      = "${ATLAS_DB_USER}"
atlas_db_name      = "${ATLAS_DB_NAME}"
EOF
    ;;
  ec2)
    cat > "$TF_DIR/terraform.tfvars" <<EOF
aws_region         = "${AWS_REGION}"
environment        = "${ENVIRONMENT}"
project_name       = "${PROJECT_NAME}"
shared_bucket_name = "${SHARED_BUCKET}"
shared_vpc_name    = "${SHARED_VPC_NAME}"
atlas_project_id   = "${TF_VAR_atlas_project_id}"
atlas_db_user      = "${ATLAS_DB_USER}"
atlas_db_name      = "${ATLAS_DB_NAME}"
network_mode       = "${NETWORK_MODE}"
EOF
    ;;
  shared)
    cat > "$TF_DIR/terraform.tfvars" <<EOF
aws_region              = "${AWS_REGION}"
environment             = "${ENVIRONMENT}"
project_name            = "${PROJECT_NAME}"
shared_vpc_name         = "${SHARED_VPC_NAME}"
shared_bucket_name      = "${SHARED_BUCKET}"
shared_resource_prefix  = "${SHARED_RESOURCE_PREFIX:-multiagent}"
EOF
    ;;
  network)
    cat > "$TF_DIR/terraform.tfvars" <<EOF
aws_region         = "${AWS_REGION}"
environment        = "${ENVIRONMENT}"
project_name       = "${PROJECT_NAME}"
shared_vpc_name    = "${SHARED_VPC_NAME}"
vpc_cidr           = "${VPC_CIDR}"
atlas_project_id   = "${TF_VAR_atlas_project_id}"
network_mode       = "${NETWORK_MODE}"
atlas_peering_cidr = "${ATLAS_PEERING_CIDR}"
EOF
    ;;
esac
ok "backend.hcl + terraform.tfvars written"

# ══════════════════════════════════════════════════════════════════════════════
# terraform init + destroy
# ══════════════════════════════════════════════════════════════════════════════
sep
cd "$TF_DIR"
log "terraform init..."
terraform init -input=false -reconfigure -backend-config="$TF_DIR/backend.hcl"
ok "init complete"

sep
log "Capturing resources before destroy..."
mkdir -p "$REPORTS_DIR"
TF_STATE_BEFORE="$REPORTS_DIR/.tf-state-before-${MODE}.txt"
terraform state list 2>/dev/null > "$TF_STATE_BEFORE" || echo "(state empty)" > "$TF_STATE_BEFORE"
_RESOURCE_COUNT=$(wc -l < "$TF_STATE_BEFORE" | tr -d ' ')
log "Found $_RESOURCE_COUNT resource(s) in state"

_DESTROY_START="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log "Running terraform destroy..."
if [[ "$MODE" == "ec2" ]]; then
  log "Pre-cleaning external security-group references for project SGs..."
  cleanup_project_security_group_references || true
fi
if [[ "$AUTO_APPROVE" == "true" ]]; then
  terraform destroy -input=false -auto-approve
else
  terraform destroy -input=false
fi
_DESTROY_END="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
ok "envs/$MODE destroyed"

# ══════════════════════════════════════════════════════════════════════════════
# Bootstrap destroy (opt-in, shared across envs)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$WITH_BOOTSTRAP" == "true" ]]; then
  sep
  warn "Destroying bootstrap resources (shared S3 bucket)..."
  warn "Terraform state stored in S3 will be permanently deleted."

  log "Emptying S3 bucket $SHARED_BUCKET..."
  aws s3 rm "s3://$SHARED_BUCKET" --recursive --region "$AWS_REGION" || true
  aws s3api list-object-versions --bucket "$SHARED_BUCKET" --region "$AWS_REGION" \
    --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null \
    | python3 -c "
import json, sys, subprocess, os
bucket = os.environ['B']; region = os.environ['R']
items = json.load(sys.stdin) or []
for item in items:
    subprocess.run(['aws','s3api','delete-object','--bucket',bucket,
                    '--key',item['Key'],'--version-id',item['VersionId'],
                    '--region',region], check=False)
print(f'Deleted {len(items)} object version(s)')
" B="$SHARED_BUCKET" R="$AWS_REGION" || true

  cd "$BOOTSTRAP_DIR"
  terraform init -input=false -no-color
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    terraform destroy -input=false -auto-approve \
      -var="account_id=$ACCOUNT_ID" -var="aws_region=$AWS_REGION" \
      -var="environment=$ENVIRONMENT" -var="project_name=$PROJECT_NAME"
  else
    terraform destroy -input=false \
      -var="account_id=$ACCOUNT_ID" -var="aws_region=$AWS_REGION" \
      -var="environment=$ENVIRONMENT" -var="project_name=$PROJECT_NAME"
  fi
  ok "Bootstrap resources destroyed"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Residue scan
# ══════════════════════════════════════════════════════════════════════════════
sep
log "Scanning for residual AWS resources..."

# Scalar residue variables. We used to use `declare -A RESIDUES` (bash 4 assoc
# array) but macOS ships bash 3.2, which dies with `declare: -A: invalid
# option`. Plain scalars work on every bash and shellcheck-clean.
_RES_s3_state_bucket=""
_RES_bedrock_kb=""
_RES_ec2_instances=""
_RES_sagemaker_endpoints=""
_RES_shared_ssm_params=""
_RES_shared_vpc=""
_RES_atlas_vpc_peering=""
_RES_atlas_peering_ssm=""
_RES_bedrock_invocation_logging=""
_RES_legacy_lambda_mcp=""
_RES_legacy_orphans=""

if aws s3api head-bucket --bucket "$SHARED_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
  if [[ "$WITH_BOOTSTRAP" == "true" ]]; then
    _RES_s3_state_bucket="RESIDUE — bucket still exists after --with-bootstrap"
  else
    _RES_s3_state_bucket="INTENTIONAL — kept (other env may use it; pass --with-bootstrap to delete)"
  fi
else
  _RES_s3_state_bucket="DELETED"
  ok "S3 bucket $SHARED_BUCKET: gone"
fi

# Bedrock KB (managed by local + ec2 envs — skip in network/shared modes).
# Source the KB ID from the project tag — KB module migrated from JSON state
# file to native aws_bedrockagent_knowledge_base, so the state file is gone.
if [[ "$MODE" != "network" && "$MODE" != "shared" ]]; then
  _KB_NAME="${PROJECT_NAME}-troubleshooting-kb-${ENVIRONMENT}"
  _KB_ID=$(aws bedrock-agent list-knowledge-bases --region "$AWS_REGION" \
    --query "knowledgeBaseSummaries[?name=='${_KB_NAME}'].knowledgeBaseId | [0]" \
    --output text 2>/dev/null || echo "None")
  if [[ -n "$_KB_ID" && "$_KB_ID" != "None" ]]; then
    _RES_bedrock_kb="EXISTS — KB $_KB_ID (name: $_KB_NAME)"
  else
    _RES_bedrock_kb="DELETED"
  fi
fi

# EC2 instances tagged with project (only relevant for ec2 mode — network has none)
if [[ "$MODE" == "ec2" ]]; then
  _EC2_IDS=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=${PROJECT_NAME}" "Name=instance-state-name,Values=running,stopped,stopping" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text 2>/dev/null || echo "")
  if [[ -n "$_EC2_IDS" && "$_EC2_IDS" != "None" ]]; then
    _RES_ec2_instances="RESIDUE — instances: $_EC2_IDS"
  else
    _RES_ec2_instances="DELETED"
  fi
fi

# SageMaker endpoints (now owned by envs/shared — endpoint name is
# "<voyage_endpoint_name_suffix>-<environment>", no project_name prefix).
if [[ "$MODE" == "shared" ]]; then
  _SM_ENDPOINTS=$(aws sagemaker list-endpoints --region "$AWS_REGION" \
    --name-contains "${ENVIRONMENT}" --query "Endpoints[?ends_with(EndpointName, \`-${ENVIRONMENT}\`)].EndpointName" --output text 2>/dev/null || echo "")
  if [[ -n "$_SM_ENDPOINTS" && "$_SM_ENDPOINTS" != "None" ]]; then
    _RES_sagemaker_endpoints="RESIDUE — endpoints: $_SM_ENDPOINTS"
  else
    _RES_sagemaker_endpoints="DELETED"
  fi
fi

# Shared mode — verify SSM canary keys + dashboards actually went away
if [[ "$MODE" == "shared" ]]; then
  _SHARED_CANARY=$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/cw_api_log_group" \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")
  if [[ -n "$_SHARED_CANARY" ]]; then
    _RES_shared_ssm_params="RESIDUE — /${SHARED_VPC_NAME}/${AWS_REGION}/cw_api_log_group still present"
  else
    _RES_shared_ssm_params="DELETED"
  fi

  # Bedrock invocation logging configuration is account-scoped (one per
  # account). Check whether the model invocation logging is still configured.
  _BEDROCK_LOG_CFG=$(aws bedrock get-model-invocation-logging-configuration \
    --region "$AWS_REGION" \
    --query "loggingConfig.cloudWatchConfig.logGroupName" --output text 2>/dev/null || echo "None")
  if [[ -n "$_BEDROCK_LOG_CFG" && "$_BEDROCK_LOG_CFG" != "None" ]]; then
    _RES_bedrock_invocation_logging="RESIDUE — model invocation logging still configured ($_BEDROCK_LOG_CFG); run aws bedrock delete-model-invocation-logging-configuration"
  else
    _RES_bedrock_invocation_logging="DELETED"
  fi
fi

# Network mode — verify VPC + Atlas-PL VPCE + SSM params actually went away
if [[ "$MODE" == "network" ]]; then
  _VPC_TAG_NAME="${SHARED_VPC_NAME}-vpc-${ENVIRONMENT}"
  _VPC_IDS=$(aws ec2 describe-vpcs \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${_VPC_TAG_NAME}" \
    --query "Vpcs[].VpcId" --output text 2>/dev/null || echo "")
  if [[ -n "$_VPC_IDS" && "$_VPC_IDS" != "None" ]]; then
    _RES_shared_vpc="RESIDUE — VPC ${_VPC_IDS} (Name=${_VPC_TAG_NAME}) still exists"
  else
    _RES_shared_vpc="DELETED"
  fi

  _SSM_LEFTOVER=$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id" \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")
  if [[ -n "$_SSM_LEFTOVER" ]]; then
    _RES_shared_ssm_params="RESIDUE — /${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id still present"
  else
    _RES_shared_ssm_params="DELETED"
  fi

  if [[ "$NETWORK_MODE" == "privatelink" ]]; then
    warn "  Atlas endpoint service is intentionally NOT destroyed (shared resource;"
    warn "  see modules/atlas-privatelink/scripts/discover-or-create-pl.sh)."
  else
    # Peering-side residue: VPC peering connection, peering SSM keys, container.
    _PEERING_LEFTOVER=$(aws ec2 describe-vpc-peering-connections \
      --region "$AWS_REGION" \
      --filters "Name=tag:Project,Values=${SHARED_VPC_NAME}" "Name=status-code,Values=active,pending-acceptance,provisioning" \
      --query "VpcPeeringConnections[].VpcPeeringConnectionId" --output text 2>/dev/null || echo "")
    if [[ -n "$_PEERING_LEFTOVER" && "$_PEERING_LEFTOVER" != "None" ]]; then
      _RES_atlas_vpc_peering="RESIDUE — VPC peering connection(s) still active: ${_PEERING_LEFTOVER}"
    else
      _RES_atlas_vpc_peering="DELETED"
    fi

    _PEERING_SSM_LEFTOVER=$(aws ssm get-parameter \
      --region "$AWS_REGION" \
      --name "/${SHARED_VPC_NAME}/${AWS_REGION}/atlas_peering_id" \
      --query "Parameter.Value" --output text 2>/dev/null || echo "")
    if [[ -n "$_PEERING_SSM_LEFTOVER" ]]; then
      _RES_atlas_peering_ssm="RESIDUE — /${SHARED_VPC_NAME}/${AWS_REGION}/atlas_peering_id still present"
    else
      _RES_atlas_peering_ssm="DELETED"
    fi

    warn "  Atlas network container is intentionally NOT destroyed (shared resource;"
    warn "  see modules/atlas-vpc-peering/scripts/discover-or-create-container.sh)."
    warn "  Verify in Atlas console → Network Access → Peering if you need to free the CIDR block."
  fi
fi

# Legacy Lambda MCP residue check (only ec2 mode). The lambda-mcp host has
# been deleted in CLIENT_REVIEW Phase 7e and replaced by the mongodb-mcp
# AgentCore Runtime; this probe stays in place to flag any function that
# survives an old terraform state from before the cutover.
if [[ "$MODE" == "ec2" ]]; then
  _LEGACY_LAMBDA_NAME="${PROJECT_NAME}-mongodb-mcp-${ENVIRONMENT}"
  if aws lambda get-function --function-name "$_LEGACY_LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    _RES_legacy_lambda_mcp="RESIDUE — $_LEGACY_LAMBDA_NAME still exists (pre-Phase-7e leftover; delete manually)"
  else
    _RES_legacy_lambda_mcp="DELETED"
  fi
fi

# Legacy orphans from pre-rename runs of setup-troubleshooting-infra.sh.
# Terraform's project+env-derived resources can't see these (different
# names), so they would otherwise sit indefinitely. The legacy names
# below are no longer created by any current code path; if they exist
# in this account they're guaranteed orphans, so we delete them inline.
_LEGACY_DELETED=()
_LEGACY_FAILED=()

# Secret: bedrock-kb-atlas-creds (replaced by ${PROJECT_NAME}-bedrock-kb-creds-${ENVIRONMENT})
if aws secretsmanager describe-secret --secret-id "bedrock-kb-atlas-creds" \
   --region "$AWS_REGION" >/dev/null 2>&1; then
  log "Deleting legacy orphan secret: bedrock-kb-atlas-creds"
  if aws secretsmanager delete-secret \
       --secret-id "bedrock-kb-atlas-creds" \
       --force-delete-without-recovery \
       --region "$AWS_REGION" >/dev/null 2>&1; then
    _LEGACY_DELETED+=("secret:bedrock-kb-atlas-creds")
  else
    _LEGACY_FAILED+=("secret:bedrock-kb-atlas-creds")
  fi
fi

# IAM roles: pre-rename hardcoded names. Inline policies / attachments must
# be removed before delete-role, otherwise it errors with DeleteConflict.
_delete_legacy_role() {
  local role="$1"
  aws iam get-role --role-name "$role" >/dev/null 2>&1 || return 1
  log "Deleting legacy orphan IAM role: $role"
  local p
  for p in $(aws iam list-role-policies --role-name "$role" \
               --query 'PolicyNames[]' --output text 2>/dev/null || true); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$p" >/dev/null 2>&1 || true
  done
  for p in $(aws iam list-attached-role-policies --role-name "$role" \
               --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$p" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$role" >/dev/null 2>&1
}

for _legacy_role in bedrock-kb-ts-role ts-bedrock-kb-creator ts-aoss-index-creator; do
  if aws iam get-role --role-name "$_legacy_role" >/dev/null 2>&1; then
    if _delete_legacy_role "$_legacy_role"; then
      _LEGACY_DELETED+=("role:$_legacy_role")
    else
      _LEGACY_FAILED+=("role:$_legacy_role")
    fi
  fi
done

# Bedrock KB: pre-rename hardcoded name `troubleshooting-kb`.
_LEGACY_KB_ID=$(aws bedrock-agent list-knowledge-bases --region "$AWS_REGION" \
  --query "knowledgeBaseSummaries[?name=='troubleshooting-kb'].knowledgeBaseId | [0]" \
  --output text 2>/dev/null || echo "")
if [[ -n "$_LEGACY_KB_ID" && "$_LEGACY_KB_ID" != "None" ]]; then
  log "Deleting legacy orphan Bedrock KB: troubleshooting-kb ($_LEGACY_KB_ID)"
  for _ds_id in $(aws bedrock-agent list-data-sources \
                    --knowledge-base-id "$_LEGACY_KB_ID" \
                    --query 'dataSourceSummaries[].dataSourceId' \
                    --output text 2>/dev/null || true); do
    aws bedrock-agent delete-data-source \
      --knowledge-base-id "$_LEGACY_KB_ID" \
      --data-source-id "$_ds_id" >/dev/null 2>&1 || true
  done
  if aws bedrock-agent delete-knowledge-base \
       --knowledge-base-id "$_LEGACY_KB_ID" >/dev/null 2>&1; then
    _LEGACY_DELETED+=("kb:troubleshooting-kb=$_LEGACY_KB_ID")
  else
    _LEGACY_FAILED+=("kb:troubleshooting-kb=$_LEGACY_KB_ID")
  fi
fi

if [[ ${#_LEGACY_FAILED[@]} -gt 0 ]]; then
  _RES_legacy_orphans="RESIDUE — failed to delete: ${_LEGACY_FAILED[*]}; deleted: ${_LEGACY_DELETED[*]:-none}"
elif [[ ${#_LEGACY_DELETED[@]} -gt 0 ]]; then
  _RES_legacy_orphans="DELETED — cleaned up legacy orphans: ${_LEGACY_DELETED[*]}"
else
  _RES_legacy_orphans="DELETED"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Destroy report
# ══════════════════════════════════════════════════════════════════════════════
sep
REPORT_FILE="$REPORTS_DIR/destroy-${MODE}-$(date +%Y%m%d-%H%M%S).json"

export _DR_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" _DR_MODE="$MODE"
export _DR_START="$_DESTROY_START" _DR_END="$_DESTROY_END"
export _DR_ACCOUNT="$ACCOUNT_ID" _DR_REGION="$AWS_REGION" _DR_ENV="$ENVIRONMENT"
export _DR_BUCKET="$SHARED_BUCKET" _DR_BOOTSTRAP="$WITH_BOOTSTRAP"
export _DR_RES_S3="${_RES_s3_state_bucket:-N/A}"
export _DR_RES_KB="${_RES_bedrock_kb:-N/A (network mode)}"
export _DR_RES_EC2="${_RES_ec2_instances:-N/A (not ec2 mode)}"
export _DR_RES_SAGE="${_RES_sagemaker_endpoints:-N/A (not ec2 mode)}"
export _DR_RES_LAMBDA="${_RES_lambda_mcp:-N/A (not ec2 mode)}"
export _DR_RES_LEGACY="${_RES_legacy_orphans:-N/A}"
export _DR_RES_SHARED_VPC="${_RES_shared_vpc:-N/A (not network mode)}"
export _DR_RES_SHARED_SSM="${_RES_shared_ssm_params:-N/A (not network/shared mode)}"
export _DR_RES_BEDROCK_INV="${_RES_bedrock_invocation_logging:-N/A (not shared mode)}"
export _TF_STATE_BEFORE_FILE="$TF_STATE_BEFORE"

python3 - <<'PYEOF' > "$REPORT_FILE"
import json, os
def v(k): return os.environ.get(k, "")
tf_before = []
try:
    with open(os.environ.get("_TF_STATE_BEFORE_FILE","")) as f:
        tf_before = [l.strip() for l in f if l.strip()]
except Exception:
    pass
has_residues = any("RESIDUE" in v(k) for k in
    ["_DR_RES_S3","_DR_RES_EC2","_DR_RES_SAGE","_DR_RES_LAMBDA","_DR_RES_LEGACY",
     "_DR_RES_SHARED_VPC","_DR_RES_SHARED_SSM","_DR_RES_BEDROCK_INV"])
print(json.dumps({
  "destroy_completed_at": v("_DR_TS"),
  "mode":                 v("_DR_MODE"),
  "destroy_started_at":   v("_DR_START"),
  "destroy_finished_at":  v("_DR_END"),
  "aws_account":          v("_DR_ACCOUNT"),
  "aws_region":           v("_DR_REGION"),
  "environment":          v("_DR_ENV"),
  "with_bootstrap":       v("_DR_BOOTSTRAP") == "true",
  "has_residues":         has_residues,
  "terraform_resources_destroyed": tf_before,
  "residue_scan": {
    "s3_state_bucket":     v("_DR_RES_S3"),
    "bedrock_kb":          v("_DR_RES_KB"),
    "ec2_instances":       v("_DR_RES_EC2"),
    "sagemaker_endpoints": v("_DR_RES_SAGE"),
    "lambda_mcp":          v("_DR_RES_LAMBDA"),
    "shared_vpc":          v("_DR_RES_SHARED_VPC"),
    "shared_ssm_params":   v("_DR_RES_SHARED_SSM"),
    "bedrock_invocation_logging": v("_DR_RES_BEDROCK_INV"),
    "legacy_orphans":      v("_DR_RES_LEGACY"),
  }
}, indent=2))
PYEOF

ok "Destroy report: $REPORT_FILE"
if grep -q '"has_residues": true' "$REPORT_FILE" 2>/dev/null; then
  warn "RESIDUES DETECTED — review $REPORT_FILE and clean up manually"
else
  ok "No residues detected — environment is clean"
fi
sep
ok "Destroy complete!"
