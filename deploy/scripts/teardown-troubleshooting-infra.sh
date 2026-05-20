#!/usr/bin/env bash
# =============================================================================
# teardown-troubleshooting-infra.sh
#
# Deletes all AWS resources created by setup-troubleshooting-infra.sh.
# Atlas cluster is intentionally NOT touched.
#
# Resources deleted (current names are project+env-derived):
#   - Bedrock Knowledge Base + data source
#   - OpenSearch Serverless collection + security policies (legacy)
#   - S3 KB bucket (from .infra-state.sh)
#   - IAM roles: <project>-bedrock-kb-<env>-role,
#                <project>-bedrock-kb-creator-<env>
#   - Secrets Manager secret: <project>-bedrock-kb-creds-<env>
#   - Local state files: .infra-state.sh, .env.live
#
# Legacy resources also cleaned (best-effort; safe no-op when missing):
#   These are orphans from pre-rename runs of setup-troubleshooting-infra.sh
#   that hardcoded names like `troubleshooting-kb`, `bedrock-kb-atlas-creds`,
#   and `bedrock-kb-ts-role`. Without explicit cleanup they would sit
#   indefinitely in the account because the new module references different
#   names and never sees them. List below stays in sync with the names that
#   were hardcoded BEFORE the project+env rename — do not extend.
#
# Usage:
#   source .env
#   bash deploy/scripts/teardown-troubleshooting-infra.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC}  $*"; }
success() { echo -e "${GREEN}✅${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠️ ${NC}  $*"; }
skip()    { echo -e "   ⤷  skipped (not found)"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_FILE="$REPO_ROOT/.infra-state.sh"

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

# Project+env-derived names — must match setup-troubleshooting-infra.sh.
KB_NAME="${PROJECT_NAME}-troubleshooting-kb-${ENVIRONMENT}"
KB_IAM_ROLE_NAME="${PROJECT_NAME}-bedrock-kb-${ENVIRONMENT}-role"
BEDROCK_HELPER_ROLE="${PROJECT_NAME}-bedrock-kb-creator-${ENVIRONMENT}"
ATLAS_SECRET_NAME="${PROJECT_NAME}-bedrock-kb-creds-${ENVIRONMENT}"

# Legacy names from pre-rename runs of setup-troubleshooting-infra.sh.
# These are account-global; if a customer ran the old script in this account
# they'll still exist. We delete them defensively — a no-op when absent.
LEGACY_KB_NAMES=("troubleshooting-kb")
LEGACY_KB_IAM_ROLES=("bedrock-kb-ts-role" "ts-bedrock-kb-creator" "ts-aoss-index-creator")
LEGACY_ATLAS_SECRETS=("bedrock-kb-atlas-creds")

# Load known resource IDs from state file (best-effort)
BEDROCK_KB_ID="${BEDROCK_KB_ID:-}"
AOSS_COLLECTION_ID="${AOSS_COLLECTION_ID:-}"
KB_BUCKET="${KB_BUCKET:-}"

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$STATE_FILE"
  info "Loaded state from .infra-state.sh"
fi

# Verify AWS credentials
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || { echo -e "${RED}❌${NC}  AWS credentials not set or expired. Source .env first." >&2; exit 1; }
info "AWS account: $AWS_ACCOUNT_ID  region: $AWS_REGION"

echo ""
echo -e "${BOLD}━━━ Resources to be deleted ━━━${NC}"
echo "  Bedrock KB:        ${BEDROCK_KB_ID:-(by name: $KB_NAME)}"
echo "  AOSS collection:   ${AOSS_COLLECTION_ID:-(none)}"
echo "  S3 buckets:        ${KB_BUCKET:-(from .infra-state.sh)}"
echo "  IAM roles:         $KB_IAM_ROLE_NAME, $BEDROCK_HELPER_ROLE"
echo "  Secrets Manager:   $ATLAS_SECRET_NAME"
echo "  Legacy orphans:    KB '${LEGACY_KB_NAMES[*]}', roles '${LEGACY_KB_IAM_ROLES[*]}', secret '${LEGACY_ATLAS_SECRETS[*]}'"
echo "  Local files:       .infra-state.sh, .env.live"
echo ""
echo -e "${YELLOW}Atlas cluster is NOT touched.${NC}"
echo ""
read -r -p "Proceed? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# =============================================================================
# 1 — Bedrock Knowledge Base data source + KB
# =============================================================================
echo -e "\n${BOLD}━━━ Bedrock Knowledge Base ━━━${NC}"

# Need to assume helper role (PassRole) for bedrock-agent operations.
# Helper role name is project+env-derived (see header).
HELPER_ARN="$(aws iam get-role --role-name "$BEDROCK_HELPER_ROLE" \
  --query 'Role.Arn' --output text 2>/dev/null || true)"

if [[ -n "$HELPER_ARN" && "$HELPER_ARN" != "None" ]]; then
  info "Assuming helper role for Bedrock operations..."
  HELPER_CREDS="$(aws sts assume-role \
    --role-arn "$HELPER_ARN" \
    --role-session-name "bedrock-kb-teardown" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text 2>/dev/null || true)"
  if [[ -n "$HELPER_CREDS" ]]; then
    # AUTH_MODE-aware capture: ORIG_KEY may be empty if the caller used AWS_PROFILE.
    ORIG_KEY="${AWS_ACCESS_KEY_ID:-}"
    ORIG_SECRET="${AWS_SECRET_ACCESS_KEY:-}"
    ORIG_TOKEN="${AWS_SESSION_TOKEN:-}"
    ORIG_PROFILE="${AWS_PROFILE:-}"
    export AWS_ACCESS_KEY_ID="$(echo "$HELPER_CREDS" | awk '{print $1}')"
    export AWS_SECRET_ACCESS_KEY="$(echo "$HELPER_CREDS" | awk '{print $2}')"
    export AWS_SESSION_TOKEN="$(echo "$HELPER_CREDS" | awk '{print $3}')"
    info "Assumed helper role"
    USE_HELPER=1
  else
    warn "Could not assume helper role — trying with current credentials"
    USE_HELPER=0
  fi
else
  warn "Helper role not found — trying with current credentials"
  USE_HELPER=0
fi

# Helper: delete a Bedrock KB (and its data sources) by ID.
delete_bedrock_kb() {
  local kb_id="$1"
  [[ -z "$kb_id" || "$kb_id" == "None" ]] && return 0

  local ds_ids
  ds_ids="$(aws bedrock-agent list-data-sources \
    --knowledge-base-id "$kb_id" \
    --query 'dataSourceSummaries[].dataSourceId' \
    --output text 2>/dev/null || true)"
  for ds_id in $ds_ids; do
    info "Deleting data source $ds_id from KB $kb_id..."
    aws bedrock-agent delete-data-source \
      --knowledge-base-id "$kb_id" \
      --data-source-id "$ds_id" > /dev/null 2>&1 && success "Deleted data source $ds_id" || warn "Failed to delete data source $ds_id"
  done

  info "Deleting Bedrock Knowledge Base $kb_id..."
  aws bedrock-agent delete-knowledge-base \
    --knowledge-base-id "$kb_id" > /dev/null 2>&1 && success "Deleted KB $kb_id" || warn "KB $kb_id not found or already deleted"
}

# Resolve current-naming KB ID by name when not supplied via env / state
if [[ -z "$BEDROCK_KB_ID" || "$BEDROCK_KB_ID" == "None" ]]; then
  BEDROCK_KB_ID="$(aws bedrock-agent list-knowledge-bases \
    --query "knowledgeBaseSummaries[?name=='${KB_NAME}'].knowledgeBaseId | [0]" \
    --output text 2>/dev/null || echo "")"
  [[ "$BEDROCK_KB_ID" == "None" ]] && BEDROCK_KB_ID=""
  [[ -n "$BEDROCK_KB_ID" ]] && info "Resolved KB by name '$KB_NAME' → $BEDROCK_KB_ID"
fi

if [[ -n "$BEDROCK_KB_ID" && "$BEDROCK_KB_ID" != "None" ]]; then
  delete_bedrock_kb "$BEDROCK_KB_ID"
else
  skip
fi

# Best-effort: clean up legacy KBs that were created with the pre-rename
# hardcoded name (e.g. `troubleshooting-kb`). If a customer ran the old
# setup-troubleshooting-infra.sh in this account, the new module won't see
# the legacy KB and it would otherwise stay as an orphan.
for legacy_name in "${LEGACY_KB_NAMES[@]}"; do
  [[ "$legacy_name" == "$KB_NAME" ]] && continue # already handled above
  legacy_kb_id="$(aws bedrock-agent list-knowledge-bases \
    --query "knowledgeBaseSummaries[?name=='${legacy_name}'].knowledgeBaseId | [0]" \
    --output text 2>/dev/null || echo "")"
  if [[ -n "$legacy_kb_id" && "$legacy_kb_id" != "None" ]]; then
    warn "Found legacy KB '$legacy_name' ($legacy_kb_id) — cleaning up orphan"
    delete_bedrock_kb "$legacy_kb_id"
  fi
done

# Restore original credentials after Bedrock operations.
# AUTH_MODE-aware: when the caller had no static keys (used AWS_PROFILE),
# unset the helper-role vars so the profile chain re-resolves.
if [[ "${USE_HELPER:-0}" -eq 1 ]]; then
  if [[ -n "${ORIG_KEY:-}" ]]; then
    export AWS_ACCESS_KEY_ID="$ORIG_KEY"
    export AWS_SECRET_ACCESS_KEY="$ORIG_SECRET"
    if [[ -n "${ORIG_TOKEN:-}" ]]; then
      export AWS_SESSION_TOKEN="$ORIG_TOKEN"
    else
      unset AWS_SESSION_TOKEN
    fi
  else
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  fi
  if [[ -n "${ORIG_PROFILE:-}" ]]; then
    export AWS_PROFILE="$ORIG_PROFILE"
  fi
  info "Restored original credentials"
fi

# =============================================================================
# 2 — OpenSearch Serverless
# =============================================================================
echo -e "\n${BOLD}━━━ OpenSearch Serverless ━━━${NC}"

COLLECTION_NAME="troubleshooting-kb"

# Delete data access policy
info "Deleting AOSS data access policy..."
aws opensearchserverless delete-access-policy \
  --type data --name "${COLLECTION_NAME}-access" \
  --region "$AWS_REGION" > /dev/null 2>&1 && success "Deleted data access policy" || skip

# Delete network policy
info "Deleting AOSS network policy..."
aws opensearchserverless delete-security-policy \
  --type network --name "${COLLECTION_NAME}-network" \
  --region "$AWS_REGION" > /dev/null 2>&1 && success "Deleted network policy" || skip

# Delete encryption policy
info "Deleting AOSS encryption policy..."
aws opensearchserverless delete-security-policy \
  --type encryption --name "${COLLECTION_NAME}-enc" \
  --region "$AWS_REGION" > /dev/null 2>&1 && success "Deleted encryption policy" || skip

# Delete collection by ID (direct)
if [[ -n "$AOSS_COLLECTION_ID" && "$AOSS_COLLECTION_ID" != "None" ]]; then
  info "Deleting AOSS collection $AOSS_COLLECTION_ID ($COLLECTION_NAME)..."
  aws opensearchserverless delete-collection \
    --id "$AOSS_COLLECTION_ID" \
    --region "$AWS_REGION" > /dev/null 2>&1 && success "Deleted AOSS collection $AOSS_COLLECTION_ID" || warn "Collection not found or already deleted"
else
  # Try by name lookup
  FOUND_ID="$(aws opensearchserverless list-collections \
    --region "$AWS_REGION" \
    --query "collectionSummaries[?name=='${COLLECTION_NAME}'].id | [0]" \
    --output text 2>/dev/null || true)"
  if [[ -n "$FOUND_ID" && "$FOUND_ID" != "None" ]]; then
    info "Deleting AOSS collection $FOUND_ID..."
    aws opensearchserverless delete-collection \
      --id "$FOUND_ID" \
      --region "$AWS_REGION" > /dev/null 2>&1 && success "Deleted AOSS collection $FOUND_ID" || warn "Failed to delete"
  else
    skip
  fi
fi

# Wait for collection deletion
info "Waiting for AOSS collection deletion to complete..."
for i in $(seq 1 20); do
  REMAINING="$(aws opensearchserverless list-collections \
    --region "$AWS_REGION" \
    --query "collectionSummaries[?name=='${COLLECTION_NAME}'].status | [0]" \
    --output text 2>/dev/null || echo "NONE")"
  if [[ "$REMAINING" == "None" || "$REMAINING" == "NONE" || -z "$REMAINING" ]]; then
    success "AOSS collection gone"; break
  fi
  echo "  ... collection status: $REMAINING ($i/20)"
  sleep 10
done

# =============================================================================
# 3 — S3 buckets
# =============================================================================
echo -e "\n${BOLD}━━━ S3 Buckets ━━━${NC}"

BUCKETS_TO_DELETE=(
  "${KB_BUCKET:-bedrock-ts-kb-496194}"
  "bedrock-ts-kb-496194"
  "bedrock-ts-kb-495006"
  "bedrock-ts-kb-495284"
  "bedrock-ts-kb-495320"
  "bedrock-ts-kb-495385"
)

# Deduplicate (bash 3 compatible)
SEEN_BUCKETS=""
for bucket in "${BUCKETS_TO_DELETE[@]}"; do
  [[ -z "$bucket" ]] && continue
  echo "$SEEN_BUCKETS" | grep -qF "|${bucket}|" && continue
  SEEN_BUCKETS="${SEEN_BUCKETS}|${bucket}|"

  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    info "Emptying and deleting s3://$bucket..."
    aws s3 rm "s3://$bucket" --recursive --quiet 2>/dev/null || true
    aws s3api delete-bucket --bucket "$bucket" --region "$AWS_REGION" 2>/dev/null \
      && success "Deleted s3://$bucket" || warn "Failed to delete s3://$bucket"
  else
    info "s3://$bucket — not found, skipping"
  fi
done

# =============================================================================
# 4 — IAM roles (inline policies must be deleted first)
# =============================================================================
echo -e "\n${BOLD}━━━ IAM Roles ━━━${NC}"

delete_iam_role() {
  local role_name="$1"
  if ! aws iam get-role --role-name "$role_name" > /dev/null 2>&1; then
    info "IAM role $role_name — not found, skipping"
    return
  fi

  info "Deleting inline policies from $role_name..."
  POLICIES="$(aws iam list-role-policies --role-name "$role_name" \
    --query 'PolicyNames[]' --output text 2>/dev/null || true)"
  for policy in $POLICIES; do
    aws iam delete-role-policy --role-name "$role_name" --policy-name "$policy" > /dev/null 2>&1 \
      && info "  Deleted policy: $policy" || warn "  Failed to delete policy: $policy"
  done

  # Detach managed policies
  ATTACHED="$(aws iam list-attached-role-policies --role-name "$role_name" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)"
  for arn in $ATTACHED; do
    aws iam detach-role-policy --role-name "$role_name" --policy-arn "$arn" > /dev/null 2>&1 || true
  done

  aws iam delete-role --role-name "$role_name" > /dev/null 2>&1 \
    && success "Deleted IAM role: $role_name" || warn "Failed to delete IAM role: $role_name"
}

delete_iam_role "$KB_IAM_ROLE_NAME"
delete_iam_role "$BEDROCK_HELPER_ROLE"

# Legacy hardcoded IAM roles from pre-rename runs of the setup script.
# Includes ts-aoss-index-creator (only existed when AOSS was used). Each
# call is a no-op when the role isn't on the account.
for legacy_role in "${LEGACY_KB_IAM_ROLES[@]}"; do
  delete_iam_role "$legacy_role"
done

# =============================================================================
# 5 — Secrets Manager
# =============================================================================
echo -e "\n${BOLD}━━━ Secrets Manager ━━━${NC}"

delete_secret() {
  local secret_id="$1"
  local secret_arn
  secret_arn="$(aws secretsmanager describe-secret \
    --secret-id "$secret_id" \
    --query 'ARN' --output text 2>/dev/null || true)"
  if [[ -n "$secret_arn" && "$secret_arn" != "None" ]]; then
    info "Deleting Secrets Manager secret $secret_id..."
    aws secretsmanager delete-secret \
      --secret-id "$secret_arn" \
      --force-delete-without-recovery > /dev/null 2>&1 \
      && success "Deleted secret: $secret_id" || warn "Failed to delete secret: $secret_id"
  else
    info "Secret $secret_id — not found, skipping"
  fi
}

delete_secret "$ATLAS_SECRET_NAME"

# Legacy hardcoded secrets from pre-rename runs of the setup script.
# The `bedrock-kb-atlas-creds` orphan is the most common case: the new
# module creates a project+env-derived secret, so the old one would
# otherwise sit indefinitely (recovery_window_in_days=0 in the module
# only governs deletion of secrets terraform manages, not orphans it
# never imported).
for legacy_secret in "${LEGACY_ATLAS_SECRETS[@]}"; do
  [[ "$legacy_secret" == "$ATLAS_SECRET_NAME" ]] && continue
  delete_secret "$legacy_secret"
done

# =============================================================================
# 6 — Local state files
# =============================================================================
echo -e "\n${BOLD}━━━ Local state files ━━━${NC}"

for f in "$REPO_ROOT/.infra-state.sh" "$REPO_ROOT/.env.live"; do
  if [[ -f "$f" ]]; then
    rm "$f" && success "Deleted $(basename "$f")"
  else
    info "$(basename "$f") — not found, skipping"
  fi
done

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BOLD}━━━ Teardown complete ━━━${NC}"
echo ""
echo -e "  ${GREEN}Deleted:${NC} Bedrock KB, AOSS collection, S3 buckets, IAM roles, Secrets Manager secret"
echo -e "  ${YELLOW}Kept:${NC}    Atlas cluster (${ATLAS_CLUSTER_NAME:-${PROJECT_NAME}-${ENVIRONMENT}})"
echo ""
echo "Re-run setup-troubleshooting-infra.sh to reprovision everything from scratch."
