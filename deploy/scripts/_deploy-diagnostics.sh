#!/usr/bin/env bash
# _deploy-diagnostics.sh — non-secret deploy breadcrumbs for AWS/Terraform handoffs.
#
# Sourced by deploy scripts after .env has been loaded. These helpers print
# enough context to debug "preflight passed but Terraform did not start" without
# exposing credentials, Atlas keys, or Terraform variable values.

_deploy_diag_prefix() {
  local label="${DEPLOY_DIAG_LABEL:-deploy}"
  printf '  [%s:diag]' "$label"
}

deploy_diag_log() {
  printf '%s %s\n' "$(_deploy_diag_prefix)" "$*"
}

deploy_diag_checkpoint() {
  deploy_diag_log "$*"
}

_deploy_diag_redact_command() {
  local text="${1:-unknown}"
  local name value
  for name in \
    AWS_SECRET_ACCESS_KEY \
    AWS_SESSION_TOKEN \
    MONGODB_ATLAS_PUBLIC_KEY \
    MONGODB_ATLAS_PRIVATE_KEY \
    TF_VAR_atlas_db_password \
    TF_VAR_mongodb_password \
    COGNITO_TEST_PASSWORD; do
    value="${!name:-}"
    if [[ -n "$value" ]]; then
      text="${text//$value/<redacted:${name}>}"
    fi
  done
  printf '%s' "$text"
}

deploy_diag_on_error() {
  local rc="${1:-1}"
  local command="${2:-unknown}"
  local line="${3:-unknown}"
  if (( rc == 0 )); then return 0; fi
  deploy_diag_log "ERROR rc=${rc} line=${line} cwd=$(pwd) command=$(_deploy_diag_redact_command "$command")"
}

deploy_diag_install_error_trap() {
  set -E
  trap 'deploy_diag_on_error "$?" "$BASH_COMMAND" "$LINENO"' ERR
}

_deploy_diag_present() {
  local value="${1:-}"
  [[ -n "$value" ]] && printf 'set' || printf 'unset'
}

_deploy_diag_access_key_summary() {
  local key="${AWS_ACCESS_KEY_ID:-}"
  if [[ -z "$key" ]]; then
    printf 'unset'
    return 0
  fi
  local tail="$key"
  if (( ${#key} > 4 )); then
    tail="${key: -4}"
  fi
  printf 'set(ending:%s)' "$tail"
}

deploy_diag_after_preflight() {
  local profile="${1:-unknown}"
  local env_file="${2:-${ENV_FILE:-unknown}}"
  deploy_diag_log "preflight profile '${profile}' completed; entering deploy handoff at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  deploy_diag_auth_context "$env_file"
}

deploy_diag_auth_context() {
  local env_file="${1:-${ENV_FILE:-unknown}}"
  local auth_mode="${AWS_AUTH_MODE:-${AUTH_MODE:-iam}}"
  local caller_arn="${AWS_AUTH_CALLER_ARN:-}"
  local account_id="${AWS_AUTH_ACCOUNT_ID:-}"

  deploy_diag_log "env_file=${env_file} cwd=$(pwd) pid=$$"
  deploy_diag_log "auth_mode=${auth_mode} region=${AWS_REGION:-unset} profile=${AWS_PROFILE:-unset} access_key=$(_deploy_diag_access_key_summary) session_token=$(_deploy_diag_present "${AWS_SESSION_TOKEN:-}") credential_expiration=${AWS_CREDENTIAL_EXPIRATION:-unset}"

  if [[ -z "$caller_arn" || -z "$account_id" ]]; then
    local identity
    identity="$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>&1 || true)"
    if [[ "$identity" == *$'\t'* || "$identity" == *"arn:"* ]]; then
      account_id="$(printf '%s' "$identity" | awk '{print $1}')"
      caller_arn="$(printf '%s' "$identity" | awk '{print $2}')"
    else
      deploy_diag_log "sts_identity_probe=failed (${identity})"
    fi
  fi

  if [[ -n "$caller_arn" || -n "$account_id" ]]; then
    deploy_diag_log "sts_identity account=${account_id:-unknown} arn=${caller_arn:-unknown}"
  fi
}

deploy_diag_terraform_context() {
  local phase="${1:-terraform}"
  local tf_dir="${2:-${PWD}}"
  local backend_file="${3:-}"
  local plan_file="${4:-}"
  local terraform_path terraform_version
  terraform_path="$(command -v terraform 2>/dev/null || echo "not found")"
  terraform_version="$(terraform version 2>/dev/null | awk 'NR == 1 {print; exit}' || true)"

  deploy_diag_log "${phase}: cwd=$(pwd) tf_dir=${tf_dir}"
  deploy_diag_log "${phase}: terraform=${terraform_path} ${terraform_version:-version-unavailable}"
  deploy_diag_log "${phase}: plan_file=${plan_file:-unset} TF_IN_AUTOMATION=${TF_IN_AUTOMATION:-unset} TF_CLI_ARGS=${TF_CLI_ARGS:-unset} TF_PLUGIN_CACHE_DIR=${TF_PLUGIN_CACHE_DIR:-unset}"

  if [[ -n "$backend_file" && -f "$backend_file" ]]; then
    local backend_bucket backend_key backend_region
    backend_bucket="$(awk -F= '$1 ~ /bucket/ {gsub(/[ "]/, "", $2); print $2; exit}' "$backend_file" 2>/dev/null || true)"
    backend_key="$(awk -F= '$1 ~ /key/ {gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", $2); print $2; exit}' "$backend_file" 2>/dev/null || true)"
    backend_region="$(awk -F= '$1 ~ /region/ {gsub(/[ "]/, "", $2); print $2; exit}' "$backend_file" 2>/dev/null || true)"
    deploy_diag_log "${phase}: backend bucket=${backend_bucket:-unknown} key=${backend_key:-unknown} region=${backend_region:-unknown}"
  elif [[ -n "$backend_file" ]]; then
    deploy_diag_log "${phase}: backend_file missing (${backend_file})"
  fi
}
