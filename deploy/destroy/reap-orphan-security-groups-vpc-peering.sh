#!/usr/bin/env bash
# reap-orphan-security-groups-vpc-peering.sh — Delete security groups left behind
# during a VPC peering project destroy because service-managed AgentCore ENIs
# (interface-type=agentic_ai) still pinned them.
#
# Run this AFTER AWS has released those ENIs (typically ~1 hour after the
# AgentCore runtimes are destroyed). It is safe to run repeatedly: it only
# touches the recorded/discovered project runtime security groups, skips any
# that are still pinned, and prunes the manifest as groups are deleted.
#
# Usage:
#   ./deploy/destroy/reap-orphan-security-groups-vpc-peering.sh [options]
#
# Options:
#   --watch                 Loop until every target SG is deleted (or attempts exhausted).
#   --interval <seconds>    Poll interval in --watch mode (default 300).
#   --max-attempts <n>      Max --watch passes before giving up (default 24 → ~2h at 5m).
#   --env-file <path>       Env file to source (default: repo .env).
#   --region <region>       Override AWS_REGION.
#   -h | --help             Show this help.
#
# Sources of truth for what to delete:
#   1. The manifest written by destroy.sh:  destroy-reports/orphan-security-groups.tsv
#   2. Self-discovery by name in the shared VPC (covers SGs not in the manifest):
#        <PROJECT_NAME>-sg-mcp-runtime-<ENVIRONMENT>
#        <PROJECT_NAME>-sg-agentcore-vpce-<ENVIRONMENT>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
AWS_AUTH_HELPER="$DEPLOY_DIR/scripts/_aws-auth.sh"
REPORTS_DIR="$REPO_ROOT/destroy-reports"
ORPHAN_SG_MANIFEST="$REPORTS_DIR/orphan-security-groups.tsv"

ENV_FILE="$REPO_ROOT/.env"
REGION_OVERRIDE=""
WATCH=false
INTERVAL=300
MAX_ATTEMPTS=24

log()  { echo "  [reap-sg:vpc-peering] $*"; }
ok()   { echo "  [reap-sg:vpc-peering] ✓ $*"; }
err()  { echo "  [reap-sg:vpc-peering] ✗ $*" >&2; exit 1; }
warn() { echo "  [reap-sg:vpc-peering] ⚠ $*"; }
sep()  { echo "------------------------------------------------"; }

usage() { sed -n '2,26p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)        WATCH=true ;;
    --interval)     [[ $# -ge 2 ]] || err "--interval requires a value"; INTERVAL="$2"; shift ;;
    --max-attempts) [[ $# -ge 2 ]] || err "--max-attempts requires a value"; MAX_ATTEMPTS="$2"; shift ;;
    --env-file)     [[ $# -ge 2 ]] || err "--env-file requires a path"; ENV_FILE="$2"; shift ;;
    --region)       [[ $# -ge 2 ]] || err "--region requires a value"; REGION_OVERRIDE="$2"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) err "Unknown arg: $1" ;;
  esac
  shift
done

[[ -f "$AWS_AUTH_HELPER" ]] || err "_aws-auth.sh not found: $AWS_AUTH_HELPER"
[[ -f "$ENV_FILE" ]]       || err "env file not found: $ENV_FILE"

# shellcheck source=/dev/null
source "$ENV_FILE"

AWS_REGION="${REGION_OVERRIDE:-${AWS_REGION:-us-east-1}}"
export AWS_REGION
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
SHARED_VPC_NAME="${SHARED_VPC_NAME:-shared-network}"

# shellcheck source=/dev/null
source "$AWS_AUTH_HELPER"
validate_aws_auth || err "AWS auth validation failed (see above)"

# ── helpers ───────────────────────────────────────────────────────────────────

# Resolve the shared VPC id by its Name tag (best-effort; used for self-discovery).
lookup_shared_vpc_id() {
  aws ec2 describe-vpcs \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${SHARED_VPC_NAME}" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo ""
}

# Number of service-managed AgentCore ENIs still attached to a security group.
agentic_eni_count() {
  local sg_id="$1"
  aws ec2 describe-network-interfaces \
    --region "$AWS_REGION" \
    --filters "Name=group-id,Values=${sg_id}" "Name=interface-type,Values=agentic_ai" \
    --query "length(NetworkInterfaces)" --output text 2>/dev/null || echo "0"
}

# Does a security group still exist?
sg_exists() {
  local sg_id="$1"
  aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --group-ids "$sg_id" \
    --query "SecurityGroups[0].GroupId" --output text >/dev/null 2>&1
}

# Collect the set of target SG ids: manifest entries (this region) + discovered
# project runtime SGs in the shared VPC. Echoes one sg-id per line, de-duped.
collect_targets() {
  local vpc_id name sg_id
  {
    if [[ -f "$ORPHAN_SG_MANIFEST" ]]; then
      while IFS=$'\t' read -r m_sg m_region _rest; do
        m_sg="${m_sg%\"}"
        m_sg="${m_sg#\"}"
        [[ -n "$m_sg" && "$m_sg" != \#* ]] || continue
        [[ -z "$m_region" || "$m_region" == "$AWS_REGION" ]] && echo "$m_sg"
      done < "$ORPHAN_SG_MANIFEST"
    fi

    vpc_id="$(lookup_shared_vpc_id)"
    for name in \
      "${PROJECT_NAME}-sg-mcp-runtime-${ENVIRONMENT}" \
      "${PROJECT_NAME}-sg-agentcore-vpce-${ENVIRONMENT}"; do
      local filters=("Name=group-name,Values=${name}")
      [[ -n "$vpc_id" && "$vpc_id" != "None" ]] && filters+=("Name=vpc-id,Values=${vpc_id}")
      sg_id="$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "${filters[@]}" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "")"
      [[ -n "$sg_id" && "$sg_id" != "None" ]] && echo "$sg_id"
    done
  } | sort -u | grep -E '^sg-' || true
}

# Drop a deleted/absent sg-id from the manifest (idempotent).
prune_manifest() {
  local sg_id="$1" tmp
  [[ -f "$ORPHAN_SG_MANIFEST" ]] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/orphan-sg.XXXXXX")"
  grep -v -E "^\"?${sg_id}\"?([[:space:]]|$)" "$ORPHAN_SG_MANIFEST" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$ORPHAN_SG_MANIFEST"
  # Remove the manifest entirely once it only has blanks/comments left.
  if ! grep -qE '^"?sg-' "$ORPHAN_SG_MANIFEST" 2>/dev/null; then
    rm -f "$ORPHAN_SG_MANIFEST"
  fi
}

# One pass over all targets. Echoes the number of SGs still pending to stdout
# (last line); human-readable status goes to stderr so callers can capture the count.
reap_pass() {
  local targets pending=0 sg_id count
  targets="$(collect_targets)"

  if [[ -z "$targets" ]]; then
    echo "0"
    return 0
  fi

  while IFS= read -r sg_id; do
    [[ -n "$sg_id" ]] || continue

    if ! sg_exists "$sg_id"; then
      ok "$sg_id already deleted" >&2
      prune_manifest "$sg_id"
      continue
    fi

    count="$(agentic_eni_count "$sg_id")"
    if [[ "$count" != "0" ]]; then
      warn "$sg_id still pinned by $count AgentCore ENI(s); will retry later" >&2
      pending=$((pending + 1))
      continue
    fi

    if aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg_id" >/dev/null 2>&1; then
      ok "Deleted $sg_id" >&2
      prune_manifest "$sg_id"
    else
      warn "delete-security-group failed for $sg_id (still has a dependent object?); will retry later" >&2
      pending=$((pending + 1))
    fi
  done <<< "$targets"

  echo "$pending"
}

# ── run ─────────────────────────────────────────────────────────────────────

sep
log "Region:      $AWS_REGION"
log "Account:     ${AWS_AUTH_ACCOUNT_ID:-unknown}"
log "Project/env: ${PROJECT_NAME} / ${ENVIRONMENT}"
log "Manifest:    $ORPHAN_SG_MANIFEST $( [[ -f "$ORPHAN_SG_MANIFEST" ]] && echo "(present)" || echo "(none — self-discovery only)" )"
sep

if [[ "$WATCH" != "true" ]]; then
  pending="$(reap_pass)"
  sep
  if [[ "$pending" == "0" ]]; then
    ok "All target security groups deleted (or none remaining)."
  else
    warn "$pending security group(s) still pinned/blocked. Re-run later, or use --watch."
    exit 2
  fi
  exit 0
fi

attempt=1
while (( attempt <= MAX_ATTEMPTS )); do
  log "Pass ${attempt}/${MAX_ATTEMPTS}..."
  pending="$(reap_pass)"
  if [[ "$pending" == "0" ]]; then
    sep
    ok "All target security groups deleted."
    exit 0
  fi
  log "$pending security group(s) still pending; sleeping ${INTERVAL}s..."
  sleep "$INTERVAL"
  attempt=$((attempt + 1))
done

sep
warn "Gave up after ${MAX_ATTEMPTS} passes; some security groups are still pinned."
warn "Check for lingering AgentCore ENIs and re-run when they clear."
exit 2
