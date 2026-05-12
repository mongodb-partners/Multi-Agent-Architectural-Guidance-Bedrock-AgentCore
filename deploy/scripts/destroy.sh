#!/usr/bin/env bash
# destroy.sh — Tear down a Terraform environment (network, local, or ec2)
#
# Usage:
#   ./deploy/scripts/destroy.sh --mode local   [--auto-approve] [--env-file <path>]
#   ./deploy/scripts/destroy.sh --mode ec2     [--auto-approve] [--env-file <path>]
#   ./deploy/scripts/destroy.sh --mode network [--auto-approve] [--env-file <path>]
#   ./deploy/scripts/destroy.sh --mode ec2     --with-bootstrap   # also deletes shared S3
#
# What it does:
#   1. Sources env.sh (or --env-file) for AWS + Atlas creds
#   2. Writes backend.hcl + terraform.tfvars for the chosen env
#   3. terraform init -backend-config=backend.hcl
#   4. terraform destroy (the chosen env's state)
#   5. With --with-bootstrap: also empties + destroys the shared state S3 bucket
#      WARNING: this deletes all Terraform state — make sure no other env uses it
#
# State keys:
#   envs/local   :  <env>/terraform.tfstate
#   envs/ec2     :  <env>/ec2/terraform.tfstate
#   envs/network :  <SHARED_VPC_NAME>/<region>/network/terraform.tfstate
#
# All three share the same S3 bucket but use distinct state keys, so destroying
# one does NOT affect the others. IMPORTANT: do not destroy the network env
# while any per-project ec2 env in the same region is still deployed —
# the per-project env reads its VPC + subnet IDs from SSM published by network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_ROOT="$REPO_ROOT/deploy/terraform"
BOOTSTRAP_DIR="$TF_ROOT/bootstrap"
KB_STATE_FILE="$TF_ROOT/modules/bedrock-kb/.kb-state.json"
REPORTS_DIR="$REPO_ROOT/destroy-reports"

ENV_FILE="$REPO_ROOT/env.sh"
MODE=""
AUTO_APPROVE=false
WITH_BOOTSTRAP=false
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
# DB user + DB name follow the same project+env convention as env.sh so a
# stale ATLAS_DB_USER / ATLAS_DB_NAME from a prior shell does not clobber the
# tfvars file. Mongo identifiers can't contain "-", so underscore-normalize.
_PROJECT_SLUG="${PROJECT_NAME//-/_}"
ATLAS_DB_USER="${ATLAS_DB_USER:-${_PROJECT_SLUG}_${ENVIRONMENT}_user}"
ATLAS_DB_NAME="${ATLAS_DB_NAME:-${_PROJECT_SLUG}_${ENVIRONMENT}}"
unset _PROJECT_SLUG
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"

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

[[ "$MODE" == "local" || "$MODE" == "ec2" || "$MODE" == "network" ]] \
  || { echo "✗ --mode is required and must be 'local', 'ec2', or 'network'" >&2; exit 1; }

TF_DIR="$TF_ROOT/envs/$MODE"
[[ -d "$TF_DIR" ]] || { echo "✗ env dir not found: $TF_DIR" >&2; exit 1; }

# STATE_KEY is computed *after* env.sh is sourced (see below) so that any
# AWS_REGION / ENVIRONMENT / SHARED_VPC_NAME override in env.sh wins over the
# pre-source defaults declared at the top of this file.

log()  { echo "  [destroy:$MODE] $*"; }
ok()   { echo "  [destroy:$MODE] ✓ $*"; }
err()  { echo "  [destroy:$MODE] ✗ $*" >&2; exit 1; }
warn() { echo "  [destroy:$MODE] ⚠ $*"; }
sep()  { echo "────────────────────────────────────────────────"; }

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
[[ -n "${TF_VAR_atlas_db_password:-}" ]] || err "Atlas DB password not set in env.sh"

export TF_VAR_atlas_project_id="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
[[ -n "${TF_VAR_atlas_project_id:-}" ]] || err "Atlas Project ID not set in env.sh"

export TF_VAR_atlas_public_key="${MONGODB_ATLAS_PUBLIC_KEY:-}"
export TF_VAR_atlas_private_key="${MONGODB_ATLAS_PRIVATE_KEY:-}"

[[ -n "${AWS_ACCESS_KEY_ID:-}" ]] || err "AWS_ACCESS_KEY_ID not set"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "AWS credentials invalid or expired"
ok "AWS account: $ACCOUNT_ID"

SHARED_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-${ACCOUNT_ID}"

# Re-default SHARED_VPC_NAME after sourcing env.sh so a missing env.sh entry
# falls back to the canonical value, and recompute STATE_KEY from post-source
# variables so an env.sh override of ENVIRONMENT / AWS_REGION / SHARED_VPC_NAME
# is honored.
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"
case "$MODE" in
  local)   STATE_KEY="${ENVIRONMENT}/terraform.tfstate" ;;
  ec2)     STATE_KEY="${ENVIRONMENT}/ec2/terraform.tfstate" ;;
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
    warn "  • Lambda (mongodb-mcp) + AgentCore Memory + AgentCore Gateway"
    warn "  • Per-cluster Route 53 private zone (atlas-cluster-dns)"
    warn "  • Bedrock Knowledge Base + Voyage SageMaker (if deployed)"
    warn "  • CloudWatch log groups"
    warn "  (Shared VPC + Atlas PrivateLink VPCE are NOT touched — they live in envs/network)"
    ;;
  network)
    warn "  • Shared VPC + public/private subnets + IGW + RT"
    warn "  • Atlas Interface VPCE + Atlas-side endpoint binding"
    warn "  • Atlas-PL security group"
    warn "  • SSM params under /${SHARED_VPC_NAME}/${AWS_REGION}/"
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
EOF
    ;;
  network)
    cat > "$TF_DIR/terraform.tfvars" <<EOF
aws_region       = "${AWS_REGION}"
environment      = "${ENVIRONMENT}"
project_name     = "${PROJECT_NAME}"
shared_vpc_name  = "${SHARED_VPC_NAME}"
vpc_cidr         = "${VPC_CIDR}"
atlas_project_id = "${TF_VAR_atlas_project_id}"
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

declare -A RESIDUES

if aws s3api head-bucket --bucket "$SHARED_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
  if [[ "$WITH_BOOTSTRAP" == "true" ]]; then
    RESIDUES["s3_state_bucket"]="RESIDUE — bucket still exists after --with-bootstrap"
  else
    RESIDUES["s3_state_bucket"]="INTENTIONAL — kept (other env may use it; pass --with-bootstrap to delete)"
  fi
else
  RESIDUES["s3_state_bucket"]="DELETED"
  ok "S3 bucket $SHARED_BUCKET: gone"
fi

# Bedrock KB (managed by local + ec2 envs — skip in network mode)
if [[ "$MODE" != "network" ]]; then
  _KB_ID=""
  [[ -f "$KB_STATE_FILE" ]] && _KB_ID=$(python3 -c "import json; print(json.load(open('$KB_STATE_FILE')).get('knowledge_base_id',''))" 2>/dev/null || true)
  if [[ -n "$_KB_ID" ]]; then
    if aws bedrock-agent get-knowledge-base --knowledge-base-id "$_KB_ID" --region "$AWS_REGION" 2>/dev/null | grep -q knowledgeBase; then
      RESIDUES["bedrock_kb"]="EXISTS — KB $_KB_ID"
    else
      RESIDUES["bedrock_kb"]="DELETED (id: $_KB_ID)"
    fi
  else
    RESIDUES["bedrock_kb"]="UNKNOWN — KB ID not found in state file"
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
    RESIDUES["ec2_instances"]="RESIDUE — instances: $_EC2_IDS"
  else
    RESIDUES["ec2_instances"]="DELETED"
  fi
fi

# SageMaker endpoints (only relevant for ec2 mode)
if [[ "$MODE" == "ec2" ]]; then
  _SM_ENDPOINTS=$(aws sagemaker list-endpoints --region "$AWS_REGION" \
    --name-contains "${PROJECT_NAME}" --query "Endpoints[].EndpointName" --output text 2>/dev/null || echo "")
  if [[ -n "$_SM_ENDPOINTS" && "$_SM_ENDPOINTS" != "None" ]]; then
    RESIDUES["sagemaker_endpoints"]="RESIDUE — endpoints: $_SM_ENDPOINTS"
  else
    RESIDUES["sagemaker_endpoints"]="DELETED"
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
    RESIDUES["shared_vpc"]="RESIDUE — VPC ${_VPC_IDS} (Name=${_VPC_TAG_NAME}) still exists"
  else
    RESIDUES["shared_vpc"]="DELETED"
  fi

  _SSM_LEFTOVER=$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "/${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id" \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")
  if [[ -n "$_SSM_LEFTOVER" ]]; then
    RESIDUES["shared_ssm_params"]="RESIDUE — /${SHARED_VPC_NAME}/${AWS_REGION}/vpc_id still present"
  else
    RESIDUES["shared_ssm_params"]="DELETED"
  fi
  warn "  Atlas endpoint service is intentionally NOT destroyed (shared resource;"
  warn "  see modules/atlas-privatelink/scripts/discover-or-create-pl.sh)."
fi

# Lambda MCP (only ec2 mode)
if [[ "$MODE" == "ec2" ]]; then
  _LAMBDA_NAME="${PROJECT_NAME}-mongodb-mcp-${ENVIRONMENT}"
  if aws lambda get-function --function-name "$_LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    RESIDUES["lambda_mcp"]="RESIDUE — $_LAMBDA_NAME still exists"
  else
    RESIDUES["lambda_mcp"]="DELETED"
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
  RESIDUES["legacy_orphans"]="RESIDUE — failed to delete: ${_LEGACY_FAILED[*]}; deleted: ${_LEGACY_DELETED[*]:-none}"
elif [[ ${#_LEGACY_DELETED[@]} -gt 0 ]]; then
  RESIDUES["legacy_orphans"]="DELETED — cleaned up legacy orphans: ${_LEGACY_DELETED[*]}"
else
  RESIDUES["legacy_orphans"]="DELETED"
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
export _DR_RES_S3="${RESIDUES[s3_state_bucket]:-N/A}"
export _DR_RES_KB="${RESIDUES[bedrock_kb]:-N/A (network mode)}"
export _DR_RES_EC2="${RESIDUES[ec2_instances]:-N/A (not ec2 mode)}"
export _DR_RES_SAGE="${RESIDUES[sagemaker_endpoints]:-N/A (not ec2 mode)}"
export _DR_RES_LAMBDA="${RESIDUES[lambda_mcp]:-N/A (not ec2 mode)}"
export _DR_RES_LEGACY="${RESIDUES[legacy_orphans]:-N/A}"
export _DR_RES_SHARED_VPC="${RESIDUES[shared_vpc]:-N/A (not network mode)}"
export _DR_RES_SHARED_SSM="${RESIDUES[shared_ssm_params]:-N/A (not network mode)}"
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
     "_DR_RES_SHARED_VPC","_DR_RES_SHARED_SSM"])
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
