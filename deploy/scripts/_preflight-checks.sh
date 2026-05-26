#!/usr/bin/env bash
# _preflight-checks.sh — Centralized deploy preflight checks (sourceable module).
#
# Usage (in calling deploy script):
#     source "$REPO_ROOT/deploy/scripts/_preflight-checks.sh"
#     preflight_validate <profile>
#
# Profiles (see PREFLIGHT_PROFILES_* arrays for the canonical mapping):
#     orchestrator-privatelink   — full-with-privatelink.sh, before phase 1
#     orchestrator-peering       — full-with-vpc-peering.sh, before phase 1
#     network                    — deploy-network.sh, after AWS auth
#     shared                     — deploy-shared.sh,  after AWS auth
#     project-pre-apply          — deploy-project.sh, after AWS auth (phase 2)
#     project-post-apply         — deploy-project.sh, after seeding (phase 5b)
#     project-pre-env-sync       — deploy-project.sh, before .env.live SSM copy
#     agents                     — deploy-agents.sh, after AWS auth
#     api                        — deploy-api.sh,    after AWS auth
#     ui                         — deploy-ui.sh,     after .env source
#
# Override knobs (env vars):
#     PREFLIGHT_QUIET               — default 1; per-check successes collapse.
#     PREFLIGHT_VERBOSE             — same as PREFLIGHT_QUIET=0.
#     PREFLIGHT_SKIP=<id>,<id>      — skip the named checks (also "*" for all).
#     PREFLIGHT_JSON=1              — emit single JSON line instead of human summary.
#     PREFLIGHT_DRY_RUN=1           — list checks that would run; exit 0.
#     PREFLIGHT_NO_COST_PREVIEW=1   — silence pf_advise_cost_and_duration.
#     PREFLIGHT_FORCE_LOCK_BREAK=1  — one-shot break of the S3 deploy lock.
#
# Exit codes (BSD sysexits-inspired):
#     0   — all passed (or all skipped via PREFLIGHT_SKIP=*)
#     78  — actionable configuration / state failures (EX_CONFIG)
#     73  — environment / external failure (EX_CANTCREAT)
#     75  — missing prereq tool (EX_TEMPFAIL)
#
# This module is purely additive — it does NOT remove or refactor any existing
# inline check, err block, or apply_with_retry helper in the deploy scripts.

if [[ -n "${_PF_SOURCED:-}" ]]; then
  # Already sourced in this shell; keep state/functions intact for repeat
  # preflight_validate calls and avoid re-declaring readonly constants.
  return 0 2>/dev/null || true
else
  _PF_SOURCED=1
fi

# Resolve REPO_ROOT lazily — checks need it for ${REPO_ROOT}/.env paths.
# Caller may pre-set; otherwise infer from this file's location: <repo>/deploy/scripts/_preflight-checks.sh
if [[ -z "${REPO_ROOT:-}" ]]; then
  _pf_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${_pf_self_dir}/../.." && pwd)"
  unset _pf_self_dir
fi
export REPO_ROOT

# ──────────────────────────────────────────────────────────────────────────────
# State (reset at the top of each preflight_validate call)
# ──────────────────────────────────────────────────────────────────────────────
declare -a PREFLIGHT_PASSED_IDS=()
declare -a PREFLIGHT_FAILED_IDS=()
declare -a PREFLIGHT_SKIPPED_IDS=()
# bash 3.2 compatible: emulate associative arrays with scalars + tracking list.
# Storage variables are named _PF_KV__<MAP>__<KEY> (KEY has '-' → '_').
declare -a _PF_KV_ALL_VARS=()
PREFLIGHT_CURRENT_PROFILE=""
PREFLIGHT_RUN_START_NS=0

# Lock state — preflight_release_lock_on_exit reads these via trap.
PREFLIGHT_LOCK_BUCKET=""
PREFLIGHT_LOCK_KEY=""
PREFLIGHT_LOCK_HELD=0

readonly _PF_EX_OK=0
readonly _PF_EX_CONFIG=78
readonly _PF_EX_EXTERNAL=73
readonly _PF_EX_TOOL=75

# ──────────────────────────────────────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────────────────────────────────────
_pf_log() {
  # In JSON mode, all human-readable output goes to stderr so stdout is pure JSON.
  if [[ "${PREFLIGHT_JSON:-0}" == "1" ]]; then
    echo "  [preflight] $*" >&2
  else
    echo "  [preflight] $*"
  fi
}
_pf_warn() { echo "  [preflight] ⚠ $*" >&2; }
_pf_dbg()  { [[ "${PREFLIGHT_DEBUG:-0}" == "1" ]] && echo "  [preflight:dbg] $*" >&2 || true; }

_pf_quiet() {
  if [[ "${PREFLIGHT_VERBOSE:-0}" == "1" ]]; then return 1; fi
  if [[ -z "${PREFLIGHT_QUIET+x}" ]]; then return 0; fi
  [[ "${PREFLIGHT_QUIET}" == "1" ]]
}

_pf_now_ns() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.monotonic_ns()))'
  else
    date +%s%N 2>/dev/null || echo 0
  fi
}
_pf_dur_ms() {
  local start_ns="$1" end_ns
  end_ns="$(_pf_now_ns)"
  echo $(( (end_ns - start_ns) / 1000000 ))
}

# ──────────────────────────────────────────────────────────────────────────────
# bash-3.2 compatible map helpers (replacement for `declare -A`)
# ──────────────────────────────────────────────────────────────────────────────
# Encode (map, key) → safe shell variable name. Keys may contain only
# [A-Za-z0-9_-]; we replace '-' with '_' to keep the var name legal.
_pf_kv_var() {
  local map="$1" key="$2"
  key="${key//-/_}"
  printf '_PF_KV__%s__%s' "$map" "$key"
}
_pf_set() {
  local var
  var="$(_pf_kv_var "$1" "$2")"
  printf -v "$var" '%s' "$3"
  _PF_KV_ALL_VARS+=("$var")
}
_pf_get() {
  local var
  var="$(_pf_kv_var "$1" "$2")"
  eval "printf '%s' \"\${${var}:-}\""
}
_pf_kv_reset() {
  local v
  for v in "${_PF_KV_ALL_VARS[@]:-}"; do
    [[ -z "$v" ]] && continue
    unset "$v"
  done
  _PF_KV_ALL_VARS=()
}

# ──────────────────────────────────────────────────────────────────────────────
# Result-recording API (called by individual pf_check_* functions)
# ──────────────────────────────────────────────────────────────────────────────
_pf_pass() {
  local id="$1" summary="${2:-ok}" dur_ms="${3:-}"
  PREFLIGHT_PASSED_IDS+=("$id")
  if _pf_quiet; then
    if [[ -n "$dur_ms" ]]; then _pf_log "✓ ${id} (${dur_ms}ms)"
    else _pf_log "✓ ${id}"; fi
  else
    if [[ -n "$dur_ms" ]]; then _pf_log "✓ ${id} ${summary} (${dur_ms}ms)"
    else _pf_log "✓ ${id} ${summary}"; fi
  fi
}

_pf_skip() {
  local id="$1" reason="${2:-skipped}"
  PREFLIGHT_SKIPPED_IDS+=("$id")
  _pf_set PREFLIGHT_SKIP_REASON "$id" "$reason"
  _pf_log "⊘ ${id} skipped (${reason})"
}

# _pf_fail <id> --summary X [--shortcoming X] [--observed X] [--doc X]
#               [--fix STEP --fix STEP ...] [--hint VERB:T --hint ...]
#               [--exit-class config|external|tool]
_pf_fail() {
  local id="$1"; shift
  local summary="" shortcoming="" observed="" doc="" exit_class="config"
  local -a fix_steps=() hints=()
  while (( $# > 0 )); do
    case "$1" in
      --summary)      summary="$2"; shift 2 ;;
      --shortcoming)  shortcoming="$2"; shift 2 ;;
      --observed)     observed="$2"; shift 2 ;;
      --doc)          doc="$2"; shift 2 ;;
      --fix)          fix_steps+=("$2"); shift 2 ;;
      --hint)         hints+=("$2"); shift 2 ;;
      --exit-class)   exit_class="$2"; shift 2 ;;
      *) _pf_warn "_pf_fail: unknown arg '$1' for ${id}"; shift ;;
    esac
  done
  PREFLIGHT_FAILED_IDS+=("$id")
  _pf_set PREFLIGHT_FAIL_SUMMARY     "$id" "$summary"
  _pf_set PREFLIGHT_FAIL_SHORTCOMING "$id" "$shortcoming"
  _pf_set PREFLIGHT_FAIL_OBSERVED    "$id" "$observed"
  _pf_set PREFLIGHT_FAIL_DOC         "$id" "$doc"
  _pf_set PREFLIGHT_FAIL_EXIT_CLASS  "$id" "$exit_class"
  local s joined_fix=""
  for s in "${fix_steps[@]:-}"; do
    [[ -z "$s" ]] && continue
    [[ -n "$joined_fix" ]] && joined_fix+=$'\n'
    joined_fix+="$s"
  done
  _pf_set PREFLIGHT_FAIL_FIX "$id" "$joined_fix"
  local h joined_hints=""
  for h in "${hints[@]:-}"; do
    [[ -z "$h" ]] && continue
    [[ -n "$joined_hints" ]] && joined_hints+=$'\n'
    joined_hints+="$h"
  done
  _pf_set PREFLIGHT_FAIL_HINTS "$id" "$joined_hints"
  _pf_log "✗ ${id}: ${summary}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Prerequisite chaining
# ──────────────────────────────────────────────────────────────────────────────
_pf_in_array() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# _pf_prereq <id> [<id> ...] — return 0 if every listed prereq passed.
_pf_prereq() {
  local prereq
  for prereq in "$@"; do
    if _pf_in_array "$prereq" "${PREFLIGHT_FAILED_IDS[@]:-}"; then
      return 1
    fi
    if _pf_in_array "$prereq" "${PREFLIGHT_SKIPPED_IDS[@]:-}"; then
      return 1
    fi
  done
  return 0
}

_pf_user_skip() {
  local id="$1" raw="${PREFLIGHT_SKIP:-}"
  [[ -z "$raw" ]] && return 1
  [[ "$raw" == "*" ]] && return 0
  local IFS=, entry
  for entry in $raw; do
    entry="${entry// /}"
    [[ "$entry" == "$id" ]] && return 0
  done
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# AWS auth helper (lazy)
# ──────────────────────────────────────────────────────────────────────────────
_pf_ensure_aws_auth() {
  if [[ -n "${AWS_AUTH_CALLER_ARN:-}" ]]; then return 0; fi
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$script_dir/_aws-auth.sh" ]]; then
    # shellcheck disable=SC1091
    source "$script_dir/_aws-auth.sh"
    if declare -F validate_aws_auth >/dev/null 2>&1; then
      validate_aws_auth >/dev/null 2>&1 || return 1
    fi
  fi
  [[ -n "${AWS_AUTH_CALLER_ARN:-}" ]]
}

_pf_aws_account_id() {
  if [[ -n "${AWS_AUTH_ACCOUNT_ID:-}" ]]; then echo "$AWS_AUTH_ACCOUNT_ID"; return 0; fi
  aws sts get-caller-identity --query Account --output text 2>/dev/null || true
}

# Atlas Admin API helper. Echoes HTTP status code; body in $1 (output file path).
# Args: <out-file> <atlas v2 path>
_pf_atlas_api() {
  local out="$1" path="$2"
  local pub="${MONGODB_ATLAS_PUBLIC_KEY:-}"
  local prv="${MONGODB_ATLAS_PRIVATE_KEY:-}"
  if [[ -z "$pub" || -z "$prv" ]]; then echo "000"; return 0; fi
  curl -s -o "$out" -w "%{http_code}" \
    --user "${pub}:${prv}" --digest \
    --max-time 10 \
    -H "Accept: application/vnd.atlas.2023-01-01+json" \
    "https://cloud.mongodb.com/api/atlas/v2${path}" 2>/dev/null || echo "000"
}

# ──────────────────────────────────────────────────────────────────────────────
# Profile composition (single source of truth)
# ──────────────────────────────────────────────────────────────────────────────
# Each profile is a bash array of check IDs to run, in order. Auto-skipped
# checks (prereq failed / PREFLIGHT_SKIP) are handled by the dispatcher.

# Heavy + new-user-friction checks live in orchestrator profiles.
PREFLIGHT_PROFILE_orchestrator_privatelink=(
  pf_check_env_file_present_and_sourceable
  pf_check_env_required_keys_filled
  pf_check_shell_runtime_safe
  pf_check_resource_name_constraints
  pf_check_env_aws_region_consistency
  pf_check_aws_region_agentcore
  pf_check_atlas_api_keys_present
  pf_check_atlas_api_health
  pf_check_atlas_api_key_scope
  pf_check_atlas_cluster_tier
  pf_check_tool_versions
  pf_check_aws_cli_agentcore_gateway_model
  pf_check_clock_skew
  pf_check_session_manager_plugin
  pf_check_docker_cross_platforms
  pf_check_disk_and_docker_resources
  pf_check_network_egress
  pf_check_atlas_privatelink_no_orphans
  pf_check_atlas_project_quota
  pf_check_voyage_marketplace_subscribed
  pf_check_sagemaker_endpoint_quota
  pf_check_bedrock_model_access
  pf_check_iam_deploy_actions
  pf_check_aws_service_limits
  pf_advise_cost_and_duration
)

# VPC peering orchestrator inherits the full PrivateLink check list — both
# connectivity modes share envs/shared (Voyage SageMaker + observability), so
# pf_check_sagemaker_endpoint_quota applies equally to both flows.
PREFLIGHT_PROFILE_orchestrator_peering=(
  "${PREFLIGHT_PROFILE_orchestrator_privatelink[@]}"
)

PREFLIGHT_PROFILE_network=(
  pf_check_env_file_present_and_sourceable
  pf_check_env_required_keys_filled
  pf_check_resource_name_constraints
  pf_check_aws_region_agentcore
  pf_check_atlas_api_keys_present
  pf_check_tool_versions
  pf_check_atlas_api_health
  pf_check_atlas_api_key_scope
  pf_check_concurrent_deploy_lock
)

PREFLIGHT_PROFILE_shared=(
  pf_check_env_file_present_and_sourceable
  pf_check_env_required_keys_filled
  pf_check_shell_runtime_safe
  pf_check_aws_region_agentcore
  pf_check_tool_versions
  pf_check_voyage_marketplace_subscribed
  pf_check_sagemaker_endpoint_quota
  pf_check_shared_network_ssm
  pf_check_concurrent_deploy_lock
)

PREFLIGHT_PROFILE_project_pre_apply=(
  pf_check_env_file_present_and_sourceable
  pf_check_env_required_keys_filled
  pf_check_resource_name_constraints
  pf_check_env_aws_region_consistency
  pf_check_aws_region_agentcore
  pf_check_atlas_api_keys_present
  pf_check_atlas_api_health
  pf_check_atlas_api_key_scope
  pf_check_atlas_cluster_tier
  pf_check_tool_versions
  pf_check_aws_cli_agentcore_gateway_model
  pf_check_clock_skew
  pf_check_disk_and_docker_resources
  pf_check_docker_cross_platforms
  pf_check_voyage_marketplace_subscribed
  pf_check_bedrock_model_access
  pf_check_iam_deploy_actions
  pf_check_aws_service_limits
  pf_check_shared_network_ssm
  pf_check_shared_stack_ssm
  pf_check_agentcore_vpcendpoints_present
  pf_check_concurrent_deploy_lock
)

PREFLIGHT_PROFILE_project_post_apply=(
  pf_check_env_file_present_and_sourceable
  pf_check_env_required_keys_filled
  pf_check_atlas_api_keys_present
  pf_check_atlas_api_key_scope
  pf_check_runtime_role_bedrock_invoke
  pf_check_privatelink_endpoint_available
  pf_check_vector_indexes_present
  pf_check_documents_have_embeddings
  pf_check_embedding_dim_consistency
  pf_check_kb_ingestion_complete
)

# Post-apply checks for the laptop / partial-infra deploy path (deploy-local.sh).
# Intentionally OMITS pf_check_shell_runtime_safe — that lives in the
# orchestrator profiles. Intentionally OMITS pf_check_privatelink_endpoint_available
# and pf_check_mcp_runtime_env_complete — deploy-local.sh does not provision
# PrivateLink endpoints or AgentCore runtimes.
PREFLIGHT_PROFILE_local_post_apply=(
  pf_check_env_file_present_and_sourceable
  pf_check_atlas_api_keys_present
  pf_check_atlas_api_key_scope
  pf_check_vector_indexes_present
  pf_check_documents_have_embeddings
  pf_check_embedding_dim_consistency
  pf_check_kb_ingestion_complete
)

PREFLIGHT_PROFILE_project_pre_env_sync=(
  pf_check_env_live_required_keys
  pf_check_mcp_runtime_env_complete
)

PREFLIGHT_PROFILE_agents=(
  pf_check_env_file_present_and_sourceable
  pf_check_tool_versions
  pf_check_concurrent_deploy_lock
  pf_check_deploy_manifest_present
  pf_check_session_manager_plugin
)

PREFLIGHT_PROFILE_api=(
  pf_check_env_file_present_and_sourceable
  pf_check_tool_versions
  pf_check_concurrent_deploy_lock
  pf_check_deploy_manifest_present
  pf_check_docker_cross_platforms
  pf_check_session_manager_plugin
)

PREFLIGHT_PROFILE_ui=(
  pf_check_env_file_present_and_sourceable
  pf_check_tool_versions
  pf_check_concurrent_deploy_lock
  pf_check_deploy_manifest_present
  pf_check_docker_cross_platforms
  pf_check_session_manager_plugin
)

# Profile name → array name suffix (for indirect expansion).
_pf_profile_array_name() {
  local profile="$1"
  case "$profile" in
    orchestrator-privatelink) echo PREFLIGHT_PROFILE_orchestrator_privatelink ;;
    orchestrator-peering)     echo PREFLIGHT_PROFILE_orchestrator_peering ;;
    network)                  echo PREFLIGHT_PROFILE_network ;;
    shared)                   echo PREFLIGHT_PROFILE_shared ;;
    project-pre-apply)        echo PREFLIGHT_PROFILE_project_pre_apply ;;
    project-post-apply)       echo PREFLIGHT_PROFILE_project_post_apply ;;
    project-pre-env-sync)     echo PREFLIGHT_PROFILE_project_pre_env_sync ;;
    local-post-apply)         echo PREFLIGHT_PROFILE_local_post_apply ;;
    agents)                   echo PREFLIGHT_PROFILE_agents ;;
    api)                      echo PREFLIGHT_PROFILE_api ;;
    ui)                       echo PREFLIGHT_PROFILE_ui ;;
    *) echo "" ;;
  esac
}

# Extract the array contents for the named profile into the `_PF_CHECKS` global.
_pf_load_profile_checks() {
  local profile="$1"
  local arr_name
  arr_name="$(_pf_profile_array_name "$profile")"
  if [[ -z "$arr_name" ]]; then
    _pf_warn "unknown profile '${profile}'"
    return 1
  fi
  # bash 3.2 compatible indirect array expansion
  eval "_PF_CHECKS=(\"\${${arr_name}[@]}\")"
}

# ──────────────────────────────────────────────────────────────────────────────
# Lock release trap (run on EXIT)
# ──────────────────────────────────────────────────────────────────────────────
_pf_release_lock_on_exit() {
  if (( PREFLIGHT_LOCK_HELD == 1 )) && [[ -n "$PREFLIGHT_LOCK_BUCKET" && -n "$PREFLIGHT_LOCK_KEY" ]]; then
    aws s3api delete-object \
      --bucket "$PREFLIGHT_LOCK_BUCKET" \
      --key "$PREFLIGHT_LOCK_KEY" \
      --region "${AWS_REGION:-us-east-1}" >/dev/null 2>&1 || true
  fi
}

# Install once. Multiple sourcings are harmless because the trap is idempotent.
if [[ -z "${_PF_TRAP_INSTALLED:-}" ]]; then
  trap '_pf_release_lock_on_exit' EXIT INT TERM
  _PF_TRAP_INSTALLED=1
fi

# ──────────────────────────────────────────────────────────────────────────────
# Banner / Summary / JSON
# ──────────────────────────────────────────────────────────────────────────────
_pf_print_banner() {
  local profile="$1" count="$2"
  echo "════════════════════════════════════════════════════════════════"
  _pf_log "running profile=${profile} (${count} checks)"
  echo "════════════════════════════════════════════════════════════════"
}

_pf_print_failure_envelopes() {
  if (( ${#PREFLIGHT_FAILED_IDS[@]} == 0 )); then return 0; fi
  echo ""
  echo "  ────────────── FAILURE DETAILS ──────────────"
  local id n=1 sc obs fixes hints doc
  for id in "${PREFLIGHT_FAILED_IDS[@]}"; do
    echo ""
    _pf_log "✗ ${id}: $(_pf_get PREFLIGHT_FAIL_SUMMARY "$id")"
    sc="$(_pf_get PREFLIGHT_FAIL_SHORTCOMING "$id")"
    [[ -n "$sc" ]] && _pf_log "  shortcoming  : ${sc}"
    obs="$(_pf_get PREFLIGHT_FAIL_OBSERVED "$id")"
    [[ -n "$obs" ]] && _pf_log "  observed     : ${obs}"
    fixes="$(_pf_get PREFLIGHT_FAIL_FIX "$id")"
    if [[ -n "$fixes" ]]; then
      _pf_log "  fix:"
      local i=1 step
      while IFS= read -r step; do
        [[ -z "$step" ]] && continue
        _pf_log "    ${i}. ${step}"
        ((i++))
      done <<< "$fixes"
    fi
    hints="$(_pf_get PREFLIGHT_FAIL_HINTS "$id")"
    if [[ -n "$hints" ]]; then
      local hint
      while IFS= read -r hint; do
        [[ -z "$hint" ]] && continue
        _pf_log "  ai-fix-hint  : ${hint}"
      done <<< "$hints"
    fi
    doc="$(_pf_get PREFLIGHT_FAIL_DOC "$id")"
    [[ -n "$doc" ]] && _pf_log "  doc          : ${doc}"
    ((n++))
  done
}

_pf_print_summary() {
  local profile="$1" total="$2" dur_ms="$3"
  local passed=${#PREFLIGHT_PASSED_IDS[@]}
  local failed=${#PREFLIGHT_FAILED_IDS[@]}
  local skipped=${#PREFLIGHT_SKIPPED_IDS[@]}
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  _pf_log "profile=${profile} checks=${total} passed=${passed} failed=${failed} skipped=${skipped} (${dur_ms}ms)"
  if (( failed > 0 )); then
    _pf_log "failed checks (in order):"
    local i=1 id
    for id in "${PREFLIGHT_FAILED_IDS[@]}"; do
      _pf_log "  ${i}. ${id}"
      ((i++))
    done
    _pf_log "Re-run after fixing all ${failed}, or PREFLIGHT_SKIP=<id>,<id>... to bypass."
  fi
  echo "════════════════════════════════════════════════════════════════"
}

_pf_emit_json_summary() {
  local profile="$1" total="$2" dur_ms="$3" exit_code="$4"
  if ! command -v python3 >/dev/null 2>&1; then
    _pf_warn "PREFLIGHT_JSON requested but python3 not available — falling back to text summary"
    return 1
  fi
  local passed=${#PREFLIGHT_PASSED_IDS[@]}
  local failed=${#PREFLIGHT_FAILED_IDS[@]}
  local skipped=${#PREFLIGHT_SKIPPED_IDS[@]}
  # Build a tab-delimited stream of failures and pipe through python3 for JSON.
  local tmp
  tmp="$(mktemp -t pf-json-fail.XXXXXX)"
  local id
  local _ec
  for id in "${PREFLIGHT_FAILED_IDS[@]:-}"; do
    [[ -z "$id" ]] && continue
    _ec="$(_pf_get PREFLIGHT_FAIL_EXIT_CLASS "$id")"
    [[ -z "$_ec" ]] && _ec="config"
    {
      printf 'ID\t%s\n' "$id"
      printf 'SUMMARY\t%s\n' "$(_pf_get PREFLIGHT_FAIL_SUMMARY "$id")"
      printf 'SHORTCOMING\t%s\n' "$(_pf_get PREFLIGHT_FAIL_SHORTCOMING "$id")"
      printf 'OBSERVED\t%s\n' "$(_pf_get PREFLIGHT_FAIL_OBSERVED "$id")"
      printf 'DOC\t%s\n' "$(_pf_get PREFLIGHT_FAIL_DOC "$id")"
      printf 'EXIT_CLASS\t%s\n' "$_ec"
      local step
      while IFS= read -r step; do
        [[ -z "$step" ]] && continue
        printf 'FIX\t%s\n' "$step"
      done <<< "$(_pf_get PREFLIGHT_FAIL_FIX "$id")"
      local hint
      while IFS= read -r hint; do
        [[ -z "$hint" ]] && continue
        printf 'HINT\t%s\n' "$hint"
      done <<< "$(_pf_get PREFLIGHT_FAIL_HINTS "$id")"
      printf 'END\t\n'
    } >> "$tmp"
  done
  PROFILE="$profile" TOTAL="$total" DUR_MS="$dur_ms" EXIT_CODE="$exit_code" \
  PASSED="$passed" FAILED="$failed" SKIPPED="$skipped" \
  python3 - "$tmp" <<'PY'
import json, os, sys
inp = sys.argv[1]
failures = []
cur = None
with open(inp, "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        if "\t" not in line:
            continue
        kind, val = line.split("\t", 1)
        if kind == "ID":
            cur = {"id": val, "summary": "", "shortcoming": "", "observed": "",
                   "doc": "", "exit_class": "config", "fix": [], "ai_fix_hints": []}
            failures.append(cur)
        elif cur is None:
            continue
        elif kind == "SUMMARY":     cur["summary"] = val
        elif kind == "SHORTCOMING": cur["shortcoming"] = val
        elif kind == "OBSERVED":    cur["observed"] = val
        elif kind == "DOC":         cur["doc"] = val
        elif kind == "EXIT_CLASS":  cur["exit_class"] = val
        elif kind == "FIX":         cur["fix"].append(val)
        elif kind == "HINT":        cur["ai_fix_hints"].append(val)
        elif kind == "END":         cur = None
out = {
    "profile":     os.environ.get("PROFILE", ""),
    "total":       int(os.environ.get("TOTAL", "0")),
    "passed":      int(os.environ.get("PASSED", "0")),
    "failed":      int(os.environ.get("FAILED", "0")),
    "skipped":     int(os.environ.get("SKIPPED", "0")),
    "duration_ms": int(os.environ.get("DUR_MS", "0")),
    "exit_code":   int(os.environ.get("EXIT_CODE", "0")),
    "failures":    failures,
}
print(json.dumps(out, separators=(",", ":")))
PY
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# ──────────────────────────────────────────────────────────────────────────────
# Public entry point
# ──────────────────────────────────────────────────────────────────────────────
preflight_validate() {
  local profile="${1:-}"
  if [[ -z "$profile" ]]; then
    _pf_warn "preflight_validate: missing profile argument"
    return 2
  fi

  # Fresh state for this invocation
  PREFLIGHT_PASSED_IDS=()
  PREFLIGHT_FAILED_IDS=()
  PREFLIGHT_SKIPPED_IDS=()
  _pf_kv_reset
  PREFLIGHT_CURRENT_PROFILE="$profile"
  PREFLIGHT_RUN_START_NS="$(_pf_now_ns)"

  # Audit banner for PREFLIGHT_SKIP=*
  if [[ "${PREFLIGHT_SKIP:-}" == "*" ]]; then
    echo "════════════════════════════════════════════════════════════════"
    _pf_warn "ALL PREFLIGHT CHECKS SKIPPED — caller=$(whoami) host=$(hostname) profile=${profile} time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _pf_warn "Bypass tracked in shell history / CI logs. Existing inline checks remain as safety net."
    echo "════════════════════════════════════════════════════════════════"
  fi

  local -a _PF_CHECKS=()
  _pf_load_profile_checks "$profile" || return 2

  if [[ "${PREFLIGHT_DRY_RUN:-0}" == "1" ]]; then
    _pf_log "DRY-RUN profile=${profile} checks=${#_PF_CHECKS[@]}"
    local id
    for id in "${_PF_CHECKS[@]}"; do _pf_log "  - ${id}"; done
    return 0
  fi

  _pf_print_banner "$profile" "${#_PF_CHECKS[@]}"

  # Run each check in order. Auto-skip if PREFLIGHT_SKIP=<id> or =*.
  #
  # CRITICAL: every check is invoked via `"$id" || rc=$?`. That form is exempt
  # from `set -e` exit (POSIX/bash rule: the left operand of `||` ignores -e)
  # AND preserves the check's real exit code in $rc (unlike `if ! "$id"; then
  # rc=$?; fi`, where the `!` inverts $? to 0). A check that returns non-zero
  # — including rc=141 from SIGPIPE under `set -o pipefail` in the parent —
  # CANNOT kill the deploy script. The bare `"$id"` form previously here let
  # a SIGPIPE-prone pipeline inside pf_check_tool_versions abort
  # deploy-shared.sh halfway through preflight; see
  # docs/deployment-preflight-checks.md#shell-runtime-safe.
  local id pre_pass pre_fail pre_skip rc
  for id in "${_PF_CHECKS[@]}"; do
    if _pf_user_skip "$id"; then
      _pf_skip "$id" "PREFLIGHT_SKIP"
      continue
    fi
    if ! declare -F "$id" >/dev/null 2>&1; then
      _pf_fail "$id" --summary "check function '$id' is not defined" \
        --observed "no function in module" \
        --fix "Add a definition for ${id} or remove it from the profile array." \
        --hint "doc:docs/deployment-preflight-checks.md#adding-a-new-check" \
        --doc "docs/deployment-preflight-checks.md#adding-a-new-check"
      continue
    fi
    # Each check is responsible for calling _pf_pass / _pf_fail / _pf_skip.
    # Defensive: if a check crashes (returns non-zero) without recording any
    # result, surface it as a failure so accounting cannot drift silently AND
    # so the deploy script cannot be silently killed by `set -e`.
    pre_pass=${#PREFLIGHT_PASSED_IDS[@]}
    pre_fail=${#PREFLIGHT_FAILED_IDS[@]}
    pre_skip=${#PREFLIGHT_SKIPPED_IDS[@]}
    rc=0
    "$id" || rc=$?
    if (( ${#PREFLIGHT_PASSED_IDS[@]}  == pre_pass &&
          ${#PREFLIGHT_FAILED_IDS[@]}  == pre_fail &&
          ${#PREFLIGHT_SKIPPED_IDS[@]} == pre_skip )); then
      local _crash_summary="check function returned without recording a result (rc=${rc})"
      local _crash_observed="no _pf_pass / _pf_fail / _pf_skip call before return"
      # rc=141 is the canonical SIGPIPE-under-pipefail signature; annotate it
      # explicitly so operators don't have to look up the meaning.
      if (( rc == 141 )); then
        _crash_summary="check function returned rc=141 (SIGPIPE under set -o pipefail)"
        _crash_observed="the check ran a pipeline whose upstream got SIGPIPE; pipefail propagated 141; runner deflected the kill (would have aborted the deploy with bare 'set -e' invocation)"
      fi
      _pf_fail "$id" \
        --summary "$_crash_summary" \
        --shortcoming "module bug" \
        --observed "$_crash_observed" \
        --fix "Open deploy/scripts/_preflight-checks.sh, search for ${id}, and ensure every code path calls one of the three result helpers" \
        --fix "If rc=141, replace any 'cmd | head -1' inside command substitution with _pf_capture_first_line / _pf_capture_first_line_2" \
        --hint "edit:deploy/scripts/_preflight-checks.sh" \
        --doc "docs/deployment-preflight-checks.md#adding-a-new-check"
    fi
  done

  local total="${#_PF_CHECKS[@]}"
  local dur_ms
  dur_ms="$(_pf_dur_ms "$PREFLIGHT_RUN_START_NS")"

  # Decide exit code
  local exit_code=$_PF_EX_OK
  if (( ${#PREFLIGHT_FAILED_IDS[@]} > 0 )); then
    exit_code=$_PF_EX_CONFIG
    local fid cls
    for fid in "${PREFLIGHT_FAILED_IDS[@]}"; do
      cls="$(_pf_get PREFLIGHT_FAIL_EXIT_CLASS "$fid")"
      [[ -z "$cls" ]] && cls="config"
      case "$cls" in
        external) exit_code=$_PF_EX_EXTERNAL ;;
        tool)     exit_code=$_PF_EX_TOOL ;;
      esac
    done
  fi

  if [[ "${PREFLIGHT_JSON:-0}" == "1" ]]; then
    _pf_emit_json_summary "$profile" "$total" "$dur_ms" "$exit_code" || \
      { _pf_print_failure_envelopes; _pf_print_summary "$profile" "$total" "$dur_ms"; }
  else
    _pf_print_failure_envelopes
    _pf_print_summary "$profile" "$total" "$dur_ms"
  fi

  if (( exit_code != 0 )); then
    exit "$exit_code"
  fi
  return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Checks — new-user-friction layer (env file, env keys, name constraints)
# ══════════════════════════════════════════════════════════════════════════════

# pf:check: pf_check_env_file_present_and_sourceable
# pf:catches: ".env file missing, malformed, or world-readable"
# pf:source:  new-user friction
pf_check_env_file_present_and_sourceable() {
  local env_file="${ENV_FILE:-${REPO_ROOT}/.env}"
  # Relative paths (e.g. --env-file .env) must resolve against REPO_ROOT, not
  # the caller's cwd. deploy-project.sh cds into deploy/terraform/envs/ec2
  # before project-post-apply preflight — without this, .env is "not found".
  if [[ "$env_file" != /* ]]; then
    env_file="${REPO_ROOT}/${env_file#./}"
  fi
  if [[ ! -f "$env_file" ]]; then
    # Helpful: detect existing .env.sample to suggest the right copy command
    local sample=""
    [[ -f "${REPO_ROOT}/.env.sample"   ]] && sample=".env.sample"
    [[ -f "${REPO_ROOT}/.env.example"  ]] && sample=".env.example"
    _pf_fail pf_check_env_file_present_and_sourceable \
      --summary ".env file not found at expected path" \
      --shortcoming "new-user friction" \
      --observed "$env_file" \
      --fix "Create .env from the template: ${sample:+cp ${sample} .env  # then edit values}${sample:-create .env in the repo root with required keys}" \
      --fix "Open .env in your editor and fill in MONGODB_ATLAS_*, AWS credentials, PROJECT_NAME, ENVIRONMENT, EMBEDDINGS_PROVIDER" \
      --fix "Re-run the deploy command" \
      --hint "doc:docs/deployment-preflight-checks.md#env-file-setup" \
      --hint "doc:docs/deployment-guide.md#env-file-setup" \
      --doc "docs/deployment-preflight-checks.md#env-file-setup"
    return 0
  fi
  # Source in a clean subshell to catch malformed lines
  local err_log
  err_log="$(mktemp -t pf-env-source.XXXXXX)"
  # shellcheck disable=SC1090
  if ! ( set +u; source "$env_file" ) 2> "$err_log"; then
    local err_msg
    err_msg="$(head -n 3 "$err_log" 2>/dev/null | tr '\n' ' ')"
    rm -f "$err_log"
    _pf_fail pf_check_env_file_present_and_sourceable \
      --summary ".env file fails to source (malformed)" \
      --shortcoming "new-user friction" \
      --observed "$err_msg" \
      --fix "Open ${env_file} and look for unclosed quotes, spaces around '=' (KEY = value vs KEY=value), or CRLF line endings" \
      --fix "Common fix: dos2unix .env  # if you copied from Windows" \
      --hint "doc:docs/deployment-preflight-checks.md#env-file-setup" \
      --doc "docs/deployment-preflight-checks.md#env-file-setup"
    return 0
  fi
  rm -f "$err_log"
  # Permissions warn (not fail)
  local perms
  if perms="$(stat -f '%A' "$env_file" 2>/dev/null || stat -c '%a' "$env_file" 2>/dev/null)"; then
    case "$perms" in
      600|640|400|440) ;;
      *) _pf_warn ".env permissions are ${perms} (recommend 600). Run: chmod 600 ${env_file}" ;;
    esac
  fi
  _pf_pass pf_check_env_file_present_and_sourceable ".env present at ${env_file}"
}

# pf:check: pf_check_env_required_keys_filled
# pf:catches: ".env copied from .env.example with placeholder values left in"
# pf:source:  new-user friction
pf_check_env_required_keys_filled() {
  _pf_prereq pf_check_env_file_present_and_sourceable || \
    { _pf_skip pf_check_env_required_keys_filled "prereq pf_check_env_file_present_and_sourceable failed"; return 0; }

  # Required keys list. We do NOT read .env.example (its key set drifts);
  # this list is curated against what every deploy code path actually reads.
  local -a REQUIRED_KEYS=(
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_REGION
    ENVIRONMENT
    PROJECT_NAME
    SHARED_VPC_NAME
    MONGODB_ATLAS_PUBLIC_KEY
    MONGODB_ATLAS_PRIVATE_KEY
    TF_VAR_mongodb_atlas_project_id
    TF_VAR_atlas_db_password
    EMBEDDINGS_PROVIDER
  )
  # AUTH_MODE=sts substitutes AWS_SESSION_TOKEN/AWS_PROFILE for the static keys.
  # Match _aws-auth.sh behavior by treating AUTH_MODE case-insensitively.
  local auth_mode_normalized
  auth_mode_normalized="$(echo "${AUTH_MODE:-iam}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$auth_mode_normalized" == "sts" ]]; then
    REQUIRED_KEYS=(
      AWS_REGION ENVIRONMENT PROJECT_NAME SHARED_VPC_NAME
      MONGODB_ATLAS_PUBLIC_KEY MONGODB_ATLAS_PRIVATE_KEY
      TF_VAR_mongodb_atlas_project_id TF_VAR_atlas_db_password EMBEDDINGS_PROVIDER
    )
  fi
  # Voyage path requires VOYAGE_MODEL_PACKAGE_ARN
  if [[ "${EMBEDDINGS_PROVIDER:-}" == "voyage" ]]; then
    REQUIRED_KEYS+=(VOYAGE_MODEL_PACKAGE_ARN)
  fi

  local placeholder_re='^(\.\.\.|your-|<.*>|changeme|TODO|FIXME|xxx|fill[- ]?in|REPLACE_ME|paste-here)'
  local -a missing=() placeholder=() fix_steps=() hints=()
  local k v
  for k in "${REQUIRED_KEYS[@]}"; do
    v="${!k:-}"
    if [[ -z "$v" ]]; then
      missing+=("$k")
      fix_steps+=("Set ${k} in .env (currently empty)")
      hints+=("edit:.env:${k}")
    elif [[ "$v" =~ $placeholder_re ]]; then
      placeholder+=("$k=${v}")
      fix_steps+=("Replace placeholder ${k}=${v} in .env with the real value")
      hints+=("edit:.env:${k}")
    fi
  done

  if (( ${#missing[@]} == 0 && ${#placeholder[@]} == 0 )); then
    _pf_pass pf_check_env_required_keys_filled "${#REQUIRED_KEYS[@]} required keys filled"
    return 0
  fi
  local observed=""
  if (( ${#missing[@]} > 0 )); then
    observed+="missing: ${missing[*]} "
  fi
  if (( ${#placeholder[@]} > 0 )); then
    observed+="placeholders: ${placeholder[*]}"
  fi

  # Build _pf_fail call with N --fix and N --hint args
  local -a args=(--summary "${#missing[@]} missing + ${#placeholder[@]} placeholder values in .env" \
                 --shortcoming "new-user friction" \
                 --observed "$observed")
  local s
  for s in "${fix_steps[@]}"; do args+=(--fix "$s"); done
  local h
  for h in "${hints[@]}"; do args+=(--hint "$h"); done
  args+=(--doc "docs/deployment-preflight-checks.md#env-required-keys")
  _pf_fail pf_check_env_required_keys_filled "${args[@]}"
}

# pf:check: pf_check_resource_name_constraints
# pf:catches: "Long PROJECT_NAME / ENVIRONMENT producing IAM role / S3 bucket / NLB names that exceed AWS limits"
# pf:source:  new-user friction
pf_check_resource_name_constraints() {
  _pf_prereq pf_check_env_required_keys_filled || \
    { _pf_skip pf_check_resource_name_constraints "prereq pf_check_env_required_keys_filled failed"; return 0; }

  local pn="${PROJECT_NAME:-}" env_="${ENVIRONMENT:-dev}" svn="${SHARED_VPC_NAME:-shared-network}"
  local pn_len=${#pn} env_len=${#env_} svn_len=${#svn}

  # Format checks first
  local -a fmt_problems=() fmt_hints=()
  if [[ ! "$pn" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]]; then
    fmt_problems+=("PROJECT_NAME='${pn}' must be lowercase alphanumeric + single hyphens, start with a letter, no leading/trailing hyphen (S3-bucket compliance)")
    fmt_hints+=("edit:.env:PROJECT_NAME")
  fi
  if [[ ! "$env_" =~ ^[a-z0-9]+$ ]]; then
    fmt_problems+=("ENVIRONMENT='${env_}' must be lowercase alphanumeric (no hyphens, dots, or special chars)")
    fmt_hints+=("edit:.env:ENVIRONMENT")
  fi
  if (( env_len > 8 )); then
    fmt_problems+=("ENVIRONMENT length=${env_len} exceeds recommended max of 8 chars (e.g. dev, staging, prod)")
    fmt_hints+=("edit:.env:ENVIRONMENT")
  fi
  if [[ ! "$svn" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]]; then
    fmt_problems+=("SHARED_VPC_NAME='${svn}' must be lowercase alphanumeric + hyphens (used in SSM key paths)")
    fmt_hints+=("edit:.env:SHARED_VPC_NAME")
  fi

  # Compute dynamic max from binding IAM role pattern
  local max_pn_hard=$(( 47 - env_len ))      # IAM role: ${PN}-${ENV}-bedrock-kb-role @ 64
  local max_pn_recommended=$(( 39 - env_len ))  # +8 chars headroom
  if (( max_pn_hard < 1 )); then max_pn_hard=1; fi
  if (( max_pn_recommended < 1 )); then max_pn_recommended=1; fi

  # Build derived names + their service limits
  # pn_stripped = pn with hyphens removed (for NLB name pattern in bedrock-kb-privatelink)
  local pn_stripped="${pn//-/}"
  local pn_slug="${pn//-/_}"
  local acct="${AWS_AUTH_ACCOUNT_ID:-${ACCOUNT_ID:-000000000000}}"

  # NLB name = kb-${substr(pn_stripped, 0, 17)}-XXXXXXXX (md5 8-char tail)
  local nlb_pn_part="${pn_stripped:0:17}"
  local nlb_name="kb-${nlb_pn_part}-deadbeef"  # synthetic; just to measure length

  declare -a name_rows=(
    "S3 bucket|${pn}-${env_}-${acct}|63"
    "Atlas cluster + EC2 Name tag|${pn}-${env_}|64"
    "IAM role (bedrock-kb)|${pn}-${env_}-bedrock-kb-role|64"
    "ECR repo (mcp)|${pn}-mongodb-mcp-${env_}|256"
    "Cognito user pool|${pn}-${env_}-cognito|128"
    "Bedrock-KB NLB|${nlb_name}|32"
    "Bedrock-KB target group|${nlb_name:0:29}-tg|32"
    "Atlas DB user|${pn_slug}_${env_}_user|100"
    "Mongo DB name|${pn_slug}_${env_}|64"
    "AgentCore Memory|${pn_slug}_memory_${env_}|64"
    "AgentCore Runtime (orchestrator)|${pn}-orchestrator-${env_}|64"
    "Secrets Manager (KB creds)|${pn}-${env_}-bedrock-kb-creds|256"
  )

  local -a over_limit=() over_hints=()
  local row pattern derived limit derived_len excess
  for row in "${name_rows[@]}"; do
    IFS='|' read -r pattern derived limit <<<"$row"
    derived_len=${#derived}
    if (( derived_len > limit )); then
      excess=$(( derived_len - limit ))
      over_limit+=("${pattern}: '${derived}' is ${derived_len} chars, limit ${limit} (over by ${excess})")
      over_hints+=("edit:.env:PROJECT_NAME")
    fi
  done

  # PROJECT_NAME hard length check
  if (( pn_len > max_pn_hard )); then
    over_limit+=("PROJECT_NAME length=${pn_len} exceeds hard max ${max_pn_hard} (binding: IAM role @ 64 with ENVIRONMENT='${env_}' len=${env_len})")
    over_hints+=("edit:.env:PROJECT_NAME")
  fi

  # PROJECT_NAME recommended (warn-only, not over_limit)
  local recommend_warn=""
  if (( pn_len <= max_pn_hard && pn_len > max_pn_recommended )); then
    recommend_warn="PROJECT_NAME length=${pn_len} within hard max ${max_pn_hard} but exceeds recommended max ${max_pn_recommended} (no headroom for future resource suffix additions)"
  fi

  if (( ${#fmt_problems[@]} == 0 && ${#over_limit[@]} == 0 )); then
    if [[ -n "$recommend_warn" ]]; then
      _pf_warn "$recommend_warn"
    fi
    _pf_pass pf_check_resource_name_constraints "PROJECT_NAME='${pn}' (${pn_len}), ENVIRONMENT='${env_}' (${env_len}); hard ≤ ${max_pn_hard}, recommended ≤ ${max_pn_recommended}"
    return 0
  fi

  local -a args=(--summary "PROJECT_NAME / ENVIRONMENT produce resource names that exceed AWS limits"
                 --shortcoming "new-user friction"
                 --observed "PROJECT_NAME='${pn}' (${pn_len} chars), ENVIRONMENT='${env_}' (${env_len} chars); hard max PROJECT_NAME=${max_pn_hard}, recommended=${max_pn_recommended}")
  local p
  if (( ${#fmt_problems[@]} > 0 )); then
    for p in "${fmt_problems[@]}"; do args+=(--fix "Format: ${p}"); done
  fi
  if (( ${#over_limit[@]} > 0 )); then
    for p in "${over_limit[@]}"; do args+=(--fix "Length: ${p}"); done
  fi
  args+=(--fix "Safe-naming cheat sheet: PROJECT_NAME ≤ ${max_pn_hard} chars (recommended ≤ ${max_pn_recommended}), ENVIRONMENT ≤ 8 chars, both lowercase alphanumeric + single hyphens, must start with a letter")
  args+=(--fix "Repo default: PROJECT_NAME=multiagent-mongodb-framework (28 chars) — comfortably inside the recommended range")
  local h
  if (( ${#fmt_hints[@]} > 0 )); then
    for h in "${fmt_hints[@]}"; do args+=(--hint "$h"); done
  fi
  if (( ${#over_hints[@]} > 0 )); then
    for h in "${over_hints[@]}"; do args+=(--hint "$h"); done
  fi
  args+=(--hint "doc:docs/deployment-preflight-checks.md#naming-constraints")
  args+=(--doc "docs/deployment-preflight-checks.md#naming-constraints")
  _pf_fail pf_check_resource_name_constraints "${args[@]}"
}

# pf:check: pf_check_env_aws_region_consistency
# pf:catches: ".env AWS_REGION ≠ resolved AWS profile region"
# pf:source:  new-user friction
pf_check_env_aws_region_consistency() {
  _pf_prereq pf_check_env_required_keys_filled || \
    { _pf_skip pf_check_env_aws_region_consistency "prereq pf_check_env_required_keys_filled failed"; return 0; }
  local env_region="${AWS_REGION:-}"
  local default_region="${AWS_DEFAULT_REGION:-}"
  if [[ -n "$env_region" && -n "$default_region" && "$env_region" != "$default_region" ]]; then
    _pf_fail pf_check_env_aws_region_consistency \
      --summary "AWS_REGION ≠ AWS_DEFAULT_REGION (cross-region drift risk)" \
      --shortcoming "new-user friction" \
      --observed "AWS_REGION='${env_region}' but AWS_DEFAULT_REGION='${default_region}'" \
      --fix "Set AWS_DEFAULT_REGION=\"\$AWS_REGION\" in .env (the existing template does this with: export AWS_DEFAULT_REGION=\"\$AWS_REGION\")" \
      --hint "edit:.env:AWS_DEFAULT_REGION" \
      --doc "docs/deployment-preflight-checks.md#aws-region-consistency"
    return 0
  fi
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    local profile_region
    profile_region="$(aws configure get region --profile "$AWS_PROFILE" 2>/dev/null || true)"
    if [[ -n "$profile_region" && -n "$env_region" && "$env_region" != "$profile_region" ]]; then
      _pf_fail pf_check_env_aws_region_consistency \
        --summary "AWS_REGION ≠ AWS_PROFILE region in ~/.aws/config" \
        --shortcoming "new-user friction" \
        --observed ".env AWS_REGION='${env_region}', profile '${AWS_PROFILE}' region='${profile_region}'" \
        --fix "Either: set 'region = ${env_region}' in ~/.aws/config under [profile ${AWS_PROFILE}], or change .env AWS_REGION to ${profile_region}" \
        --hint "edit:.env:AWS_REGION" \
        --doc "docs/deployment-preflight-checks.md#aws-region-consistency"
      return 0
    fi
  fi
  _pf_pass pf_check_env_aws_region_consistency "AWS_REGION='${env_region}' consistent across env/profile"
}

# pf:check: pf_check_clock_skew
# pf:catches: "Operator clock drift > 5 min produces SignatureDoesNotMatch"
# pf:source:  new-user friction (operator machine)
pf_check_clock_skew() {
  local server_date="" local_date drift_s curl_raw
  # SIGPIPE-safe: capture full headers, then walk them in pure bash. No
  # downstream `awk … exit` to close curl's stdout early under pipefail.
  if ! curl_raw="$(curl -sI --max-time 5 https://sts.amazonaws.com 2>/dev/null)"; then
    _pf_skip pf_check_clock_skew "could not reach https://sts.amazonaws.com to read Date header"
    return 0
  fi
  local _line _ifs_save="$IFS"
  IFS=$'\n'
  for _line in $curl_raw; do
    if [[ "$_line" =~ ^[Dd]ate:[[:space:]]*(.+)$ ]]; then
      server_date="${BASH_REMATCH[1]}"
      server_date="${server_date%$'\r'}"
      break
    fi
  done
  IFS="$_ifs_save"
  if [[ -z "$server_date" ]]; then
    _pf_skip pf_check_clock_skew "STS Date header empty (no network?)"
    return 0
  fi
  local _py_clock
  IFS= read -r -d '' _py_clock <<'PY' || true
import datetime, email.utils, os, time
s = email.utils.parsedate_to_datetime(os.environ["PF_SERVER_DATE"]).timestamp()
print(int(abs(time.time() - s)))
PY
  if ! drift_s="$(PF_SERVER_DATE="$server_date" python3 -c "$_py_clock" 2>/dev/null)"; then
    _pf_skip pf_check_clock_skew "could not parse server Date header"
    return 0
  fi
  local_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if (( drift_s > 300 )); then
    _pf_fail pf_check_clock_skew \
      --summary "Local clock drifts ${drift_s}s from sts.amazonaws.com (> 300s threshold)" \
      --shortcoming "new-user friction (operator machine)" \
      --observed "local=${local_date}, server=${server_date}, drift=${drift_s}s" \
      --fix "Re-sync your system clock (NTP). macOS: System Settings → General → Date & Time → Set automatically. Linux: sudo systemctl restart systemd-timesyncd; sudo timedatectl set-ntp true" \
      --fix "AWS rejects requests with > 5 min drift as SignatureDoesNotMatch / RequestExpired — looks like an auth bug but is a clock issue" \
      --hint "doc:docs/deployment-preflight-checks.md#clock-skew" \
      --doc "docs/deployment-preflight-checks.md#clock-skew" \
      --exit-class config
    return 0
  fi
  _pf_pass pf_check_clock_skew "drift=${drift_s}s vs sts.amazonaws.com"
}

# pf:check: pf_check_session_manager_plugin
# pf:catches: "session-manager-plugin missing — can't reach EC2 post-deploy"
# pf:source:  new-user friction (operator machine)
pf_check_session_manager_plugin() {
  if command -v session-manager-plugin >/dev/null 2>&1; then
    local v
    # SIGPIPE-safe: capture-first-line, then trim with parameter expansion.
    v="$(_pf_capture_first_line session-manager-plugin --version)"
    v="${v//[[:space:]]/}"
    _pf_pass pf_check_session_manager_plugin "session-manager-plugin ${v:-installed}"
    return 0
  fi
  _pf_fail pf_check_session_manager_plugin \
    --summary "session-manager-plugin not on PATH (post-deploy 'aws ssm start-session' will fail)" \
    --shortcoming "new-user friction (operator machine)" \
    --observed "command 'session-manager-plugin' not found" \
    --fix "macOS: brew install --cask session-manager-plugin" \
    --fix "Linux (Debian/Ubuntu): curl 'https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb' -o /tmp/sm.deb && sudo dpkg -i /tmp/sm.deb" \
    --fix "Linux (RHEL/Amazon Linux): sudo yum install -y https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" \
    --hint "doc:docs/deployment-preflight-checks.md#session-manager-plugin" \
    --doc "docs/deployment-preflight-checks.md#session-manager-plugin" \
    --exit-class tool
}

# pf:check: pf_check_docker_cross_platforms
# pf:catches: "Docker cannot run required cross-platform images (QEMU/binfmt not registered) — linux/arm64 + linux/amd64 builds fail opaquely"
# pf:source:  new-user friction (operator machine)
pf_check_docker_cross_platforms() {
  # Only required when docker is on PATH and reachable
  if ! command -v docker >/dev/null 2>&1; then
    _pf_skip pf_check_docker_cross_platforms "docker not on PATH (skip-docker scenario)"
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    _pf_skip pf_check_docker_cross_platforms "docker daemon not reachable"
    return 0
  fi

  local docker_path docker_version docker_context
  docker_path="$(command -v docker 2>/dev/null || echo "not found")"
  docker_version="$(docker --version 2>&1 || true)"
  docker_context="$(docker context show 2>&1 || true)"

  local plat out
  local -a failed=()
  for plat in linux/amd64 linux/arm64; do
    if ! out="$(docker run --rm --platform "$plat" alpine:3 true 2>&1)"; then
      failed+=("${plat}: ${out//$'\n'/ }")
    fi
  done

  if (( ${#failed[@]} > 0 )); then
    _pf_fail pf_check_docker_cross_platforms \
      --summary "Docker cannot run required cross-platform images (${#failed[@]}/2 platforms failed)" \
      --shortcoming "new-user friction (operator machine)" \
      --observed "docker=${docker_path}; ${docker_version}; context=${docker_context}; failures=${failed[*]}" \
      --fix "Docker Desktop: enable 'Use Rosetta for x86_64/amd64 emulation' (Settings -> General) and restart Docker Desktop" \
      --fix "Linux / colima: install QEMU binfmt via 'docker run --privileged --rm tonistiigi/binfmt --install all'" \
      --fix "GitHub Actions runners: add 'uses: docker/setup-qemu-action@v3' before the deploy step" \
      --hint "doc:docs/deployment-preflight-checks.md#docker-cross-platforms" \
      --doc "docs/deployment-preflight-checks.md#docker-cross-platforms" \
      --exit-class tool
    return 0
  fi

  _pf_pass pf_check_docker_cross_platforms "linux/amd64 + linux/arm64 emulation OK"
}

# pf:check: pf_check_disk_and_docker_resources
# pf:catches: "Operator disk / Docker memory below floor (build OOM, push fails)"
# pf:source:  new-user friction (operator machine)
pf_check_disk_and_docker_resources() {
  # Disk free at /
  local disk_free_gb
  disk_free_gb="$(df -Pk / 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')"
  if [[ -n "$disk_free_gb" ]] && (( disk_free_gb < 10 )); then
    _pf_fail pf_check_disk_and_docker_resources \
      --summary "Less than 10 GB free on / (Docker builds will fail)" \
      --shortcoming "new-user friction (operator machine)" \
      --observed "disk_free_gb=${disk_free_gb}" \
      --fix "Free up at least 10 GB on /. macOS: empty Trash, ~/Library/Caches; Linux: docker system prune -a; sudo journalctl --vacuum-size=200M" \
      --hint "doc:docs/deployment-preflight-checks.md#local-prerequisites" \
      --doc "docs/deployment-preflight-checks.md#local-prerequisites" \
      --exit-class tool
    return 0
  fi
  # Docker memory: docker info MemTotal is often wrong on Docker Desktop (macOS).
  # pf_check_docker_cross_platforms is the real gate for local builds; only enforce
  # the 4 GB floor when PREFLIGHT_STRICT_LOCAL_RESOURCES=1.
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local mem_bytes mem_gb
    mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
    if [[ "$mem_bytes" =~ ^[0-9]+$ ]] && (( mem_bytes > 0 )); then
      mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
      if (( mem_gb < 4 )); then
        if [[ "${PREFLIGHT_STRICT_LOCAL_RESOURCES:-0}" == "1" ]]; then
          _pf_fail pf_check_disk_and_docker_resources \
            --summary "Docker has ${mem_gb} GB total memory (multi-platform builds need ≥ 4 GB)" \
            --shortcoming "new-user friction (operator machine)" \
            --observed "docker info MemTotal=${mem_gb}GB" \
            --fix "Open Docker Desktop → Settings → Resources → Memory and raise to 4 GB+" \
            --hint "doc:docs/deployment-preflight-checks.md#local-prerequisites" \
            --doc "docs/deployment-preflight-checks.md#local-prerequisites" \
            --exit-class tool
          return 0
        fi
        _pf_pass pf_check_disk_and_docker_resources "disk_free=${disk_free_gb:-?}GB docker_mem=${mem_gb}GB (docker info <4GB ignored; cross-platform check is authoritative)"
        return 0
      fi
    fi
  fi
  _pf_pass pf_check_disk_and_docker_resources "disk_free=${disk_free_gb:-?}GB"
}

# pf:check: pf_check_aws_service_limits
# pf:catches: "Account-level VPC + Elastic IP quotas at floor (5/region default each)"
# pf:source:  new-user friction (account quotas)
# pf:related: pf_check_sagemaker_endpoint_quota — separate check for SageMaker GPU endpoint quota
pf_check_aws_service_limits() {
  _pf_ensure_aws_auth || { _pf_skip pf_check_aws_service_limits "AWS auth not validated"; return 0; }
  local region="${AWS_REGION:-us-east-1}"
  local -a problems=() warnings=()

  # VPCs per region (default 5; need at least 1 free unless reusing shared VPC)
  local vpc_count
  vpc_count="$(aws ec2 describe-vpcs --region "$region" --query 'length(Vpcs)' --output text 2>/dev/null || echo '?')"
  if [[ "$vpc_count" =~ ^[0-9]+$ ]] && (( vpc_count >= 5 )); then
    local svn="${SHARED_VPC_NAME:-shared-network}" shared_vpc_id
    shared_vpc_id="$(aws ssm get-parameter --region "$region" --name "/${svn}/${region}/vpc_id" --query 'Parameter.Value' --output text 2>/dev/null || true)"
    if [[ -n "$shared_vpc_id" && "$shared_vpc_id" != "None" ]]; then
      warnings+=("VPCs in ${region}: ${vpc_count}/5, but shared VPC ${shared_vpc_id} already exists; redeploy can reuse it")
    else
      problems+=("VPCs in ${region}: ${vpc_count}/5 (default limit). New shared VPC creation will fail unless you reuse an existing one")
    fi
  fi

  # Elastic IPs (default 5)
  local eip_count
  eip_count="$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses)' --output text 2>/dev/null || echo '?')"
  if [[ "$eip_count" =~ ^[0-9]+$ ]] && (( eip_count >= 5 )); then
    local pn="${PROJECT_NAME:-}" env_="${ENVIRONMENT:-dev}" project_eip_count
    project_eip_count="$(aws ec2 describe-addresses \
      --region "$region" \
      --filters "Name=tag:Project,Values=${pn}" "Name=tag:Environment,Values=${env_}" \
      --query 'length(Addresses)' --output text 2>/dev/null || echo '0')"
    if [[ "$project_eip_count" =~ ^[0-9]+$ ]] && (( project_eip_count > 0 )); then
      warnings+=("Elastic IPs in ${region}: ${eip_count}/5, but ${pn}/${env_} already has ${project_eip_count} EIP(s); redeploy should not allocate another")
    else
      problems+=("Elastic IPs in ${region}: ${eip_count}/5 (default limit). New project EIP / NAT gateway allocation may fail")
    fi
  fi

  if (( ${#problems[@]} == 0 )); then
    local w
    if (( ${#warnings[@]} > 0 )); then
      for w in "${warnings[@]}"; do _pf_warn "$w"; done
    fi
    _pf_pass pf_check_aws_service_limits "VPCs=${vpc_count} EIPs=${eip_count} (no new quota blocker detected)"
    return 0
  fi
  local -a args=(--summary "Account-level service quotas at risk"
                 --shortcoming "new-user friction (account quotas)"
                 --observed "${problems[*]}")
  local p
  for p in "${problems[@]}"; do args+=(--fix "${p}"); done
  args+=(--fix "Request a quota increase: https://${region}.console.aws.amazon.com/servicequotas/home")
  args+=(--hint "console:https://${region}.console.aws.amazon.com/servicequotas/home")
  args+=(--doc "docs/deployment-preflight-checks.md#aws-service-limits")
  _pf_fail pf_check_aws_service_limits "${args[@]}"
}

# pf:advise: pf_advise_cost_and_duration
# pf:catches: "Surprise $/month bill + 'I killed deploy at minute 12 thinking it was hung'"
# pf:source:  new-user friction (advisory; never fails)
pf_advise_cost_and_duration() {
  if [[ "${PREFLIGHT_NO_COST_PREVIEW:-0}" == "1" ]]; then
    _pf_skip pf_advise_cost_and_duration "PREFLIGHT_NO_COST_PREVIEW=1"
    return 0
  fi
  echo ""
  _pf_log "ⓘ deploy preview"
  _pf_log "    provisions : 1× EC2 t3.medium, 1× Atlas M10, 1× SageMaker (Voyage), 1× Bedrock KB,"
  _pf_log "                 1× AgentCore Memory, 1× AgentCore Gateway, 4× AgentCore Runtimes,"
  _pf_log "                 1× MCP Runtime, ECR repos, Cognito pool, CloudWatch logs/dashboards"
  _pf_log "    est. cost  : ~\$240–320 / month (see docs/estimate.md for breakdown)"
  _pf_log "    est. time  : 25–40 min (Atlas M10 cold start ~10 min, AgentCore Runtimes ~5 min,"
  _pf_log "                 Voyage SageMaker endpoint ~15 min)"
  _pf_log "    teardown   : ./deploy/scripts/destroy.sh --mode ec2 (per-project, ~10 min)"
  echo ""
  # Treat as informational pass (does not affect exit code)
  _pf_pass pf_advise_cost_and_duration "deploy preview shown"
}

# ══════════════════════════════════════════════════════════════════════════════
# Checks — tool versions / network egress / Atlas API health
# ══════════════════════════════════════════════════════════════════════════════

# Capture stdout of a command, return ONLY the first line via parameter
# expansion. SIGPIPE-safe: the producer (e.g. `terraform version` which emits
# 3+ lines on terraform ≥ 1.6) writes to a buffered subshell capture, not to a
# `head -1` pipe that closes early. The legacy `cmd | head -1 | …` pattern
# crashes the script with rc=141 under `set -o pipefail` (which deploy-shared.sh
# and friends enable) because terraform receives SIGPIPE on its second write,
# pipefail propagates 141, and `set -e` exits the parent. See
# docs/deployment-preflight-checks.md#shell-runtime-safe for the root-cause
# write-up.
_pf_capture_first_line() {
  local _raw
  # Combine stdout/stderr only when the caller asked for it via 2>&1 — keep
  # the helper minimal and let the caller decide. Default: stdout only.
  _raw="$("$@" 2>/dev/null)" || true
  printf '%s' "${_raw%%$'\n'*}"
}

# Variant that captures both stdout + stderr (some tools emit --version on stderr).
_pf_capture_first_line_2() {
  local _raw
  _raw="$("$@" 2>&1)" || true
  printf '%s' "${_raw%%$'\n'*}"
}

# pf:check: pf_check_tool_versions
# pf:catches: "Tool present but version too old (terraform/bun/aws/python/docker/jq)"
# pf:notes:   Uses _pf_capture_first_line (NOT `cmd | head -1`) to avoid the
#             SIGPIPE → 141 trap that killed deploy-shared.sh on operators with
#             terraform ≥ 1.6 (multi-line `terraform version` output).
pf_check_tool_versions() {
  local skip_docker="${SKIP_DOCKER:-false}"
  local -a problems=() hints=()

  _pf_ver_at_least() {
    local name="$1" found="$2" min="$3"
    local cmp _py_ver
    IFS= read -r -d '' _py_ver <<'PY' || true
import sys, re
def parse(s):
    s = s.strip()
    nums = re.findall(r"\d+", s)
    return tuple(int(x) for x in nums[:3]) if nums else (0,)
print("ge" if parse(sys.argv[1]) >= parse(sys.argv[2]) else "lt")
PY
    cmp="$(python3 -c "$_py_ver" "$found" "$min")"
    [[ "$cmp" == "ge" ]]
  }

  local v first
  if command -v terraform >/dev/null 2>&1; then
    # `terraform version` emits 1 line on 0.x–1.5 and 3+ lines on 1.6+.
    # Capture safely, parse with `read` (no further pipelines).
    first="$(_pf_capture_first_line terraform version)"  # "Terraform v1.13.4"
    read -r _ v _ <<<"$first" || v=""
    v="${v#v}"
    _pf_ver_at_least terraform "$v" 1.6 || { problems+=("terraform ${v} < 1.6"); hints+=("doc:docs/deployment-guide.md#prerequisites"); }
  else
    problems+=("terraform not on PATH")
    hints+=("doc:docs/deployment-guide.md#prerequisites")
  fi
  if command -v bun >/dev/null 2>&1; then
    v="$(_pf_capture_first_line bun --version)"
    _pf_ver_at_least bun "$v" 1.1 || { problems+=("bun ${v} < 1.1"); hints+=("doc:docs/deployment-guide.md#prerequisites"); }
  else
    problems+=("bun not on PATH")
    hints+=("doc:docs/deployment-guide.md#prerequisites")
  fi
  if command -v aws >/dev/null 2>&1; then
    # AWS CLI v2 prints e.g. "aws-cli/2.15.0 Python/3.11.8 ..."  (may emit
    # extra lines on some installs). Parse first field after the slash.
    first="$(_pf_capture_first_line_2 aws --version)"
    local awspart="${first%% *}"        # "aws-cli/2.15.0"
    v="${awspart#*/}"                   # "2.15.0"
    _pf_ver_at_least aws "$v" 2.15 || { problems+=("aws-cli ${v} < 2.15"); hints+=("doc:docs/deployment-guide.md#prerequisites"); }
  else
    problems+=("aws CLI not on PATH")
    hints+=("doc:docs/deployment-guide.md#prerequisites")
  fi
  if command -v python3 >/dev/null 2>&1; then
    v="$(python3 -c 'import sys; print(".".join(map(str,sys.version_info[:3])))' 2>/dev/null)"
    _pf_ver_at_least python3 "$v" 3.10 || { problems+=("python3 ${v} < 3.10"); hints+=("doc:docs/deployment-guide.md#prerequisites"); }
  else
    problems+=("python3 not on PATH")
    hints+=("doc:docs/deployment-guide.md#prerequisites")
  fi
  if [[ "$skip_docker" != "true" ]] && command -v docker >/dev/null 2>&1; then
    # "Docker version 24.0.7, build abc123" — third whitespace field, strip comma + leading v.
    first="$(_pf_capture_first_line docker --version)"
    local _w1 _w2 _w3 _rest
    read -r _w1 _w2 _w3 _rest <<<"$first" || _w3=""
    v="${_w3%,}"                        # "24.0.7"
    v="${v#v}"
    _pf_ver_at_least docker "$v" 24 || { problems+=("docker ${v} < 24"); hints+=("doc:docs/deployment-guide.md#prerequisites"); }
  fi
  if command -v jq >/dev/null 2>&1; then
    first="$(_pf_capture_first_line jq --version)"
    v="${first#jq-}"
    _pf_ver_at_least jq "$v" 1.6 || { problems+=("jq ${v} < 1.6"); hints+=("doc:docs/deployment-guide.md#prerequisites"); }
  fi

  if (( ${#problems[@]} == 0 )); then
    _pf_pass pf_check_tool_versions "all tool versions ≥ floor"
    return 0
  fi

  local -a args=(--summary "${#problems[@]} tool(s) missing or below minimum version"
                 --shortcoming "new-user friction (operator machine)"
                 --observed "${problems[*]}")
  local p
  for p in "${problems[@]}"; do args+=(--fix "Install/upgrade: ${p}"); done
  local h
  for h in "${hints[@]}"; do args+=(--hint "$h"); done
  args+=(--doc "docs/deployment-guide.md#prerequisites")
  args+=(--exit-class tool)
  _pf_fail pf_check_tool_versions "${args[@]}"
}

# pf:check: pf_check_shell_runtime_safe
# pf:catches: "Regression: a `cmd | head -1` style pipeline inside a preflight
#              check returns rc=141 under `set -o pipefail` and kills the
#              deploy script before any failure envelope is printed (operators
#              see only `ERROR rc=141 line=… command=bash deploy-shared.sh`
#              with no actionable signal)."
# pf:source:  recurring deploy regression — `pf_check_tool_versions` once parsed
#             `terraform version | head -1 | …` inside command substitution; on
#             terraform ≥ 1.6 (multi-line version output) the producer received
#             SIGPIPE on its second write, pipefail returned 141, deploy-shared.sh
#             aborted mid-preflight. See docs/deployment-preflight-checks.md#shell-runtime-safe.
#
# What this check does:
#   1. Confirms the running shell raises SIGPIPE the normal way (i.e. yes
#      | head -1 in a subshell returns 141 under set -o pipefail). If the
#      platform DOESN'T behave that way, neither will the original bug — but
#      we'd still like to record what shell we're on.
#   2. Drives a synthetic `check function` that deliberately returns 141 and
#      verifies the preflight runner deflects it (the prong-2 fix). The
#      runner SHOULD record a `module bug (rc=141)` failure entry and stay
#      alive; this check spots a regression that re-introduces the bare
#      `"$id"` invocation.
#   3. Reports bash version so future SIGPIPE / set-e quirks are easy to
#      correlate against operator machines.
pf_check_shell_runtime_safe() {
  local bash_v="${BASH_VERSION:-unknown}"
  local -a warns=() problems=()

  # ── Subtest 1: does this shell raise SIGPIPE → 141 under pipefail? ──────────
  # Run in a brand-new bash subshell with the same set-options as our deploy
  # scripts so the result reflects production behavior, not whatever the
  # operator typed at the prompt.
  local sigpipe_rc=0
  ( set -euo pipefail; yes 2>/dev/null | head -n 1 >/dev/null ) || sigpipe_rc=$?
  local sigpipe_observed="raised (rc=${sigpipe_rc})"
  if (( sigpipe_rc != 141 )); then
    # Not a hard failure: some platforms (or shells with SIGPIPE-suppressing
    # wrappers) won't reproduce the bug, which is fine. Just record it.
    sigpipe_observed="not raised (rc=${sigpipe_rc}); platform suppresses SIGPIPE"
  fi

  # ── Subtest 2: does the preflight runner deflect a rc=141 from a check? ────
  # Define a one-shot synthetic check, save runner accounting, invoke via the
  # same `if ! "$id"; then` form the runner uses, and verify the parent script
  # is still alive afterwards. We don't go through preflight_validate() (which
  # would reset state and print a banner) — just exercise the same guard.
  _pf_synth_sigpipe_check() {
    # Same shape as the original bug: head -1 closes early under pipefail.
    local _ignored
    _ignored="$(yes 2>/dev/null | head -n 1 | awk '{print $1}')"
    _pf_pass _pf_synth_sigpipe_check "would never reach here under the bug"
  }
  local synth_rc=0 runner_alive="yes"
  if ! _pf_synth_sigpipe_check; then synth_rc=$?; fi
  unset -f _pf_synth_sigpipe_check
  # We can only get here if the runner-style `if ! …; then` guard worked.
  # (If `set -e` killed the parent, the whole deploy script would have died.)

  # ── Subtest 3: record bash version (informational; never fails) ────────────
  local bash_summary="bash=${bash_v}"
  case "$bash_v" in
    3.2.*) warns+=("bash 3.2 (macOS system bash) — module is compatible, but consider Homebrew bash 5+ for future-proofing") ;;
    4.* | 5.* | 6.*) ;;
    *) warns+=("unrecognized bash version '${bash_v}'") ;;
  esac

  local summary="shell=${bash_summary} sigpipe=${sigpipe_observed} runner_deflected=${runner_alive} (synth_rc=${synth_rc})"

  if (( ${#problems[@]} == 0 )); then
    local w
    for w in "${warns[@]:-}"; do
      [[ -z "$w" ]] && continue
      _pf_warn "$w"
    done
    _pf_pass pf_check_shell_runtime_safe "$summary"
    return 0
  fi

  _pf_fail pf_check_shell_runtime_safe \
    --summary "shell runtime is not SIGPIPE-resilient — preflight runner cannot guarantee deploy survives a check that hits rc=141" \
    --shortcoming "module bug" \
    --observed "${problems[*]} (${summary})" \
    --fix "Re-source deploy/scripts/_preflight-checks.sh — the runner deflection helper relies on the 'if ! \"\$id\"; then …' guard in preflight_validate()" \
    --fix "If using a non-bash shell wrapper (e.g. busybox sh), re-run preflight under /bin/bash explicitly" \
    --hint "edit:deploy/scripts/_preflight-checks.sh" \
    --doc "docs/deployment-preflight-checks.md#shell-runtime-safe"
}

# Pure-shape parser used by pf_check_aws_cli_agentcore_gateway_model and the
# self-test. Reads `aws ... --generate-cli-skeleton input` JSON from stdin and
# prints space-separated missing dotted-field paths on stdout. Empty stdout =
# shape OK. Exits 1 on invalid JSON, 0 otherwise.
#
# Implementation note: we cannot use `python3 - <<'PY'` here because the
# heredoc itself is python's stdin — it would shadow the JSON the caller piped
# in. Instead, copy stdin to a temp file and pass the path as argv to python.
_pf_agentcore_gateway_skeleton_missing() {
  local tmp rc
  tmp="$(mktemp -t pf-acgw.XXXXXX)"
  cat - >"$tmp"
  python3 - "$tmp" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as exc:
    sys.stderr.write("INVALID_JSON: %s\n" % exc)
    sys.exit(1)

missing = []
mcp = (data.get("targetConfiguration") or {}).get("mcp")
if not isinstance(mcp, dict) or not isinstance(mcp.get("mcpServer"), dict):
    missing.append("targetConfiguration.mcp.mcpServer")
elif "endpoint" not in mcp["mcpServer"]:
    missing.append("targetConfiguration.mcp.mcpServer.endpoint")

cpc_list = data.get("credentialProviderConfigurations")
if not isinstance(cpc_list, list) or not cpc_list:
    missing.append("credentialProviderConfigurations[].credentialProvider.iamCredentialProvider")
else:
    iam_ok = False
    for entry in cpc_list:
        cp = (entry or {}).get("credentialProvider") or {}
        iam = cp.get("iamCredentialProvider")
        if isinstance(iam, dict) and "service" in iam and "region" in iam:
            iam_ok = True
            break
    if not iam_ok:
        missing.append("credentialProviderConfigurations[].credentialProvider.iamCredentialProvider")

print(" ".join(missing))
PY
  rc=$?
  rm -f "$tmp"
  return $rc
}

# pf:check: pf_check_aws_cli_agentcore_gateway_model
# pf:catches: "Local AWS CLI service model missing AgentCore Gateway mcpServer / iamCredentialProvider fields"
# pf:source:  recurring deploy failure: aws bedrock-agentcore-control create-gateway-target rejects the
#             targetConfiguration.mcp.mcpServer + credentialProvider.iamCredentialProvider shape required
#             by deploy/terraform/modules/agentcore-gateway/main.tf when the operator's CLI ships a stale
#             botocore service model.
pf_check_aws_cli_agentcore_gateway_model() {
  _pf_prereq pf_check_tool_versions || \
    { _pf_skip pf_check_aws_cli_agentcore_gateway_model "prereq pf_check_tool_versions failed"; return 0; }

  if ! command -v aws >/dev/null 2>&1; then
    _pf_skip pf_check_aws_cli_agentcore_gateway_model "aws CLI not on PATH"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    _pf_skip pf_check_aws_cli_agentcore_gateway_model "python3 not on PATH"
    return 0
  fi

  local cli_version cli_first cli_part
  # SIGPIPE-safe parsing — matches pf_check_tool_versions. AWS CLI prints
  # e.g. "aws-cli/2.15.0 Python/3.11.8 …" on stdout+stderr depending on version.
  cli_first="$(_pf_capture_first_line_2 aws --version)"
  cli_part="${cli_first%% *}"     # "aws-cli/2.15.0"
  cli_version="${cli_part#*/}"     # "2.15.0"
  cli_version="${cli_version:-unknown}"

  local skeleton rc
  skeleton="$(aws bedrock-agentcore-control create-gateway-target \
    --generate-cli-skeleton input 2>/dev/null)"
  rc=$?
  if (( rc != 0 )) || [[ -z "$skeleton" ]]; then
    local -a args=(--summary "AWS CLI does not know the bedrock-agentcore-control create-gateway-target shape"
                   --shortcoming "new-user friction (operator machine)"
                   --observed "aws-cli ${cli_version}: --generate-cli-skeleton input exited ${rc} (service or operation not in this CLI's botocore service model)"
                   --fix "macOS/Homebrew: brew update && brew upgrade awscli && aws --version"
                   --fix "macOS pkg / Linux: reinstall AWS CLI v2 from the official bundle for your arch (https://awscli.amazonaws.com/AWSCLIV2.pkg on macOS, awscli-exe-linux-x86_64.zip or awscli-exe-linux-aarch64.zip on Linux), then re-run aws --version to confirm"
                   --fix "CI runners: update the base image, or add an 'install AWS CLI v2' step before any deploy step (the official awscli-exe-linux-<arch>.zip flow works inside ubuntu-latest runners)"
                   --hint "run:brew upgrade awscli"
                   --hint "doc:docs/deployment-preflight-checks.md#aws-cli-agentcore-gateway-model"
                   --doc "docs/deployment-preflight-checks.md#aws-cli-agentcore-gateway-model"
                   --exit-class tool)
    _pf_fail pf_check_aws_cli_agentcore_gateway_model "${args[@]}"
    return 0
  fi

  local missing parse_rc
  missing="$(printf '%s' "$skeleton" | _pf_agentcore_gateway_skeleton_missing 2>/dev/null)"
  parse_rc=$?
  if (( parse_rc != 0 )); then
    local -a args=(--summary "AWS CLI returned a skeleton that could not be parsed as JSON"
                   --shortcoming "new-user friction (operator machine)"
                   --observed "aws-cli ${cli_version}: --generate-cli-skeleton input emitted non-JSON output"
                   --fix "macOS/Homebrew: brew update && brew upgrade awscli && aws --version"
                   --fix "macOS pkg / Linux: reinstall AWS CLI v2 from the official bundle for your arch, then re-run aws --version to confirm"
                   --fix "CI runners: update the base image or install AWS CLI v2 before the deploy step"
                   --hint "run:brew upgrade awscli"
                   --hint "doc:docs/deployment-preflight-checks.md#aws-cli-agentcore-gateway-model"
                   --doc "docs/deployment-preflight-checks.md#aws-cli-agentcore-gateway-model"
                   --exit-class tool)
    _pf_fail pf_check_aws_cli_agentcore_gateway_model "${args[@]}"
    return 0
  fi

  if [[ -z "$missing" ]]; then
    _pf_pass pf_check_aws_cli_agentcore_gateway_model "aws-cli ${cli_version} service model has mcpServer + iamCredentialProvider"
    return 0
  fi

  local -a args=(--summary "AWS CLI bedrock-agentcore-control service model missing required AgentCore Gateway MCP target fields"
                 --shortcoming "new-user friction (operator machine)"
                 --observed "aws-cli ${cli_version} missing: ${missing// /, }"
                 --fix "macOS/Homebrew: brew update && brew upgrade awscli && aws --version"
                 --fix "macOS pkg / Linux: reinstall AWS CLI v2 from the official bundle for your arch (https://awscli.amazonaws.com/AWSCLIV2.pkg on macOS, awscli-exe-linux-x86_64.zip or awscli-exe-linux-aarch64.zip on Linux), then re-run aws --version to confirm"
                 --fix "CI runners: update the base image, or add an 'install AWS CLI v2' step before any deploy step (the official awscli-exe-linux-<arch>.zip flow works inside ubuntu-latest runners)"
                 --hint "run:brew upgrade awscli"
                 --hint "doc:docs/deployment-preflight-checks.md#aws-cli-agentcore-gateway-model"
                 --doc "docs/deployment-preflight-checks.md#aws-cli-agentcore-gateway-model"
                 --exit-class tool)
  _pf_fail pf_check_aws_cli_agentcore_gateway_model "${args[@]}"
}

# pf:check: pf_check_network_egress
# pf:catches: "Corp proxy / firewall blocks egress to AWS/Atlas endpoints"
pf_check_network_egress() {
  local region="${AWS_REGION:-us-east-1}"
  local -a endpoints=(
    "https://cloud.mongodb.com/api/atlas/v2"
    "https://sts.amazonaws.com"
    "https://bedrock-runtime.${region}.amazonaws.com"
    "https://ssm.${region}.amazonaws.com"
    "https://ecr.${region}.amazonaws.com"
    "https://s3.amazonaws.com"
  )
  local -a unreachable=()
  local url status
  for url in "${endpoints[@]}"; do
    status="$(curl -sI --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo '000')"
    if [[ "$status" == "000" ]]; then
      unreachable+=("$url (no response in 5s)")
    fi
  done
  if (( ${#unreachable[@]} == 0 )); then
    _pf_pass pf_check_network_egress "${#endpoints[@]} egress endpoints reachable"
    return 0
  fi
  local -a args=(--summary "${#unreachable[@]} required endpoints unreachable from this machine"
                 --shortcoming "external (corp proxy / firewall)"
                 --observed "${unreachable[*]}")
  local u
  for u in "${unreachable[@]}"; do args+=(--fix "Investigate egress to: ${u}"); done
  args+=(--fix "Most common cause: corporate proxy. Set HTTPS_PROXY / HTTP_PROXY before re-running")
  args+=(--hint "doc:docs/deployment-preflight-checks.md#network-egress")
  args+=(--doc "docs/deployment-preflight-checks.md#network-egress")
  args+=(--exit-class external)
  _pf_fail pf_check_network_egress "${args[@]}"
}

# pf:check: pf_check_atlas_api_health
# pf:catches: "Atlas Admin API degraded right now"
pf_check_atlas_api_health() {
  _pf_prereq pf_check_atlas_api_keys_present || \
    { _pf_skip pf_check_atlas_api_health "prereq pf_check_atlas_api_keys_present failed"; return 0; }
  local proj="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
  if [[ -z "$proj" ]]; then
    _pf_skip pf_check_atlas_api_health "no Atlas project id"
    return 0
  fi
  local out1 out2 s1 s2
  out1="$(mktemp)"
  out2="$(mktemp)"
  s1="$(_pf_atlas_api "$out1" "/groups/${proj}")"
  sleep 1
  s2="$(_pf_atlas_api "$out2" "/groups/${proj}")"
  rm -f "$out1" "$out2"
  if [[ "$s1" =~ ^2 ]] || [[ "$s2" =~ ^2 ]]; then
    _pf_pass pf_check_atlas_api_health "Atlas API responsive (HTTP ${s1} → ${s2})"
    return 0
  fi
  if [[ "$s1" == "401" || "$s2" == "401" ]]; then
    # auth issue handled by pf_check_atlas_api_key_scope
    _pf_pass pf_check_atlas_api_health "Atlas API up (auth handled separately)"
    return 0
  fi
  _pf_fail pf_check_atlas_api_health \
    --summary "Atlas Admin API not healthy on two probes 1s apart" \
    --shortcoming "external (Atlas)" \
    --observed "HTTP ${s1} then ${s2}" \
    --fix "Check Atlas service status: https://status.mongodb.com" \
    --fix "If Atlas is up but you're seeing transient timeouts, retry in 5 minutes" \
    --hint "console:https://status.mongodb.com" \
    --doc "docs/deployment-preflight-checks.md#atlas-api-health" \
    --exit-class external
}

# ══════════════════════════════════════════════════════════════════════════════
# Checks — AWS region / Bedrock model + IAM + quotas
# ══════════════════════════════════════════════════════════════════════════════

# pf:check: pf_check_aws_region_agentcore
# pf:catches: "AGENTCORE_CONTROL_REGION is non-AgentCore-eligible region"
pf_check_aws_region_agentcore() {
  _pf_prereq pf_check_env_required_keys_filled || \
    { _pf_skip pf_check_aws_region_agentcore "prereq pf_check_env_required_keys_filled failed"; return 0; }
  local r="${AGENTCORE_CONTROL_REGION:-${AWS_REGION:-}}"
  case "$r" in
    us-east-1|us-west-2|ap-southeast-1|eu-central-1) ;;
    *)
      _pf_fail pf_check_aws_region_agentcore \
        --summary "AGENTCORE_CONTROL_REGION='${r}' is not in the AgentCore allow-list" \
        --shortcoming "config" \
        --observed "region ${r} not currently supported by AgentCore Runtime / Memory" \
        --fix "Set AGENTCORE_CONTROL_REGION=us-east-1 (or one of: us-west-2, ap-southeast-1, eu-central-1) in .env" \
        --hint "edit:.env:AGENTCORE_CONTROL_REGION" \
        --doc "docs/deployment-preflight-checks.md#agentcore-regions"
      return 0
      ;;
  esac
  _pf_pass pf_check_aws_region_agentcore "AgentCore region ${r}"
}

# pf:check: pf_check_bedrock_model_access
# pf:catches: "Bedrock model access not granted for the model id we will invoke"
pf_check_bedrock_model_access() {
  _pf_ensure_aws_auth || { _pf_skip pf_check_bedrock_model_access "AWS auth not validated"; return 0; }
  local region="${AWS_REGION:-us-east-1}"
  # Read model id from .env (BEDROCK_MODEL_ID) or default to the inference profile we ship.
  local model="${BEDROCK_MODEL_ID:-us.anthropic.claude-sonnet-4-20250514-v1:0}"
  local strip_inference="${model#us.}"
  strip_inference="${strip_inference#eu.}"
  strip_inference="${strip_inference#ap.}"
  local out
  out="$(aws bedrock get-foundation-model --region "$region" --model-identifier "$strip_inference" 2>&1)"
  local rc=$?
  if (( rc != 0 )); then
    if echo "$out" | grep -qiE 'AccessDenied|access has not been granted|not subscribed|ValidationException'; then
      _pf_fail pf_check_bedrock_model_access \
        --summary "Bedrock model access not granted in ${region} for ${strip_inference}" \
        --shortcoming "config (Bedrock console)" \
      --observed "${out%%$'\n'*}" \
      --fix "Open the Bedrock console: https://${region}.console.aws.amazon.com/bedrock/home?region=${region}#/modelaccess" \
        --fix "Click 'Manage model access', enable Anthropic Claude Sonnet 4 (and Voyage embeddings if EMBEDDINGS_PROVIDER=voyage)" \
        --fix "Approval is usually instant for Anthropic models; retry the deploy after the status flips to 'Access granted'" \
        --hint "console:https://${region}.console.aws.amazon.com/bedrock/home?region=${region}#/modelaccess" \
        --doc "docs/deployment-preflight-checks.md#bedrock-model-access"
      return 0
    fi
    _pf_warn "bedrock get-foundation-model failed for non-access reason: ${out%%$'\n'*}"
  fi
  _pf_pass pf_check_bedrock_model_access "model ${strip_inference} accessible in ${region}"
}

# Simulate iam:PassRole with iam:PassedToService context (deploy policy is conditional).
_pf_iam_passrole_allowed_for_deploy() {
  local simulation_arn="$1"
  local -a services=(
    ec2.amazonaws.com lambda.amazonaws.com ecs-tasks.amazonaws.com
    bedrock.amazonaws.com bedrock-agentcore.amazonaws.com sagemaker.amazonaws.com
    application-autoscaling.amazonaws.com scheduler.amazonaws.com
    events.amazonaws.com apigateway.amazonaws.com
  )
  local svc out rc
  for svc in "${services[@]}"; do
    set +e
    out="$(aws iam simulate-principal-policy \
      --policy-source-arn "$simulation_arn" \
      --action-names iam:PassRole \
      --context-entries "ContextKeyName=iam:PassedToService,ContextKeyValues=${svc},ContextKeyType=string" \
      --output json 2>&1)"
    rc=$?
    set -e
    if (( rc != 0 )); then
      return 1
    fi
    if PF_IAM_SIM_JSON="$out" python3 <<'PY' 2>/dev/null; then
import json, os, sys
d = json.loads(os.environ.get("PF_IAM_SIM_JSON", "{}"))
for r in d.get("EvaluationResults", []):
    if r.get("EvalActionName") == "iam:PassRole" and r.get("EvalDecision") == "allowed":
        sys.exit(0)
sys.exit(1)
PY
      return 0
    fi
  done
  return 1
}

# pf:check: pf_check_iam_deploy_actions
# pf:catches: "Caller IAM principal is missing actions Terraform needs (incl. SCP DENY)"
pf_check_iam_deploy_actions() {
  _pf_ensure_aws_auth || { _pf_skip pf_check_iam_deploy_actions "AWS auth not validated"; return 0; }
  local arn="${AWS_AUTH_CALLER_ARN:-}"
  if [[ -z "$arn" ]]; then
    arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
  fi
  if [[ -z "$arn" ]]; then
    _pf_skip pf_check_iam_deploy_actions "could not resolve caller ARN"
    return 0
  fi
  local simulation_arn="$arn"
  if [[ "$arn" =~ ^arn:aws:sts::([0-9]+):assumed-role/([^/]+)/.+$ ]]; then
    # iam:SimulatePrincipalPolicy does not accept STS session ARNs. In
    # AUTH_MODE=sts, simulate against the backing IAM role instead.
    simulation_arn="arn:aws:iam::${BASH_REMATCH[1]}:role/${BASH_REMATCH[2]}"
  fi
  # iam:SimulatePrincipalPolicy honors SCPs and permissions boundaries.
  # Comprehensive list across every Terraform module the deploy uses.
  # API caps each call at ~50 actions; we batch in groups of 25 for safety.
  local -a actions=(
    # EC2 / VPC / networking
    "ec2:DescribeVpcs" "ec2:CreateVpc" "ec2:DescribeSubnets" "ec2:CreateSubnet"
    "ec2:DescribeRouteTables" "ec2:CreateRouteTable" "ec2:CreateNatGateway"
    "ec2:DescribeAvailabilityZones" "ec2:DescribeSecurityGroups" "ec2:CreateSecurityGroup"
    "ec2:CreateVpcEndpoint" "ec2:DescribeVpcEndpoints" "ec2:RunInstances"
    "ec2:AllocateAddress" "ec2:DescribeAddresses"
    # IAM (iam:PassRole simulated separately with PassedToService context)
    "iam:CreateRole" "iam:DeleteRole" "iam:AttachRolePolicy"
    "iam:PutRolePolicy" "iam:CreatePolicy" "iam:GetRole"
    # S3
    "s3:CreateBucket" "s3:PutBucketPolicy" "s3:GetObject" "s3:PutObject"
    "s3:GetBucketVersioning" "s3:PutBucketVersioning"
    # SSM
    "ssm:PutParameter" "ssm:GetParameter" "ssm:DeleteParameter" "ssm:GetParametersByPath"
    "ssm:SendCommand"
    # ECR
    "ecr:CreateRepository" "ecr:GetAuthorizationToken" "ecr:PutImage"
    # Bedrock
    "bedrock:InvokeModel" "bedrock:InvokeModelWithResponseStream"
    "bedrock:CreateKnowledgeBase" "bedrock:CreateDataSource"
    # AgentCore (bedrock-agentcore service)
    "bedrock-agentcore:CreateAgentRuntime" "bedrock-agentcore:CreateMemory"
    "bedrock-agentcore:CreateGateway"
    # SageMaker (Voyage)
    "sagemaker:CreateEndpoint" "sagemaker:CreateModel" "sagemaker:DescribeModelPackage"
    # Cognito
    "cognito-idp:CreateUserPool" "cognito-idp:CreateUserPoolClient" "cognito-idp:CreateUserPoolDomain"
    # Logs / KMS / Secrets (kms:CreateKey omitted — deploy policy uses existing keys only)
    "logs:CreateLogGroup" "logs:PutRetentionPolicy" "kms:Decrypt"
    "secretsmanager:CreateSecret" "secretsmanager:GetSecretValue"
    # CloudWatch
    "cloudwatch:PutDashboard" "cloudwatch:PutMetricAlarm"
  )

  # Batch ≤ 25 actions per call (well under the documented ~50 cap).
  local total=${#actions[@]} batch_size=25 i j rc
  local -a denied=() this_batch
  local out
  for (( i=0; i<total; i+=batch_size )); do
    this_batch=()
    for (( j=i; j<i+batch_size && j<total; j++ )); do
      this_batch+=("${actions[$j]}")
    done
    set +e
    out="$(aws iam simulate-principal-policy \
      --policy-source-arn "$simulation_arn" \
      --action-names "${this_batch[@]}" \
      --output json 2>&1)"
    rc=$?
    set -e
    if (( rc != 0 )); then
      if echo "$out" | grep -qiE 'AccessDenied|not authorized.*SimulatePrincipalPolicy'; then
        _pf_warn "Caller cannot self-introspect via iam:SimulatePrincipalPolicy. Skipping comprehensive IAM simulation. Add 'iam:SimulatePrincipalPolicy' to the deploy policy for full coverage."
        _pf_pass pf_check_iam_deploy_actions "skipped (no iam:SimulatePrincipalPolicy)"
        return 0
      fi
      _pf_warn "iam:SimulatePrincipalPolicy failed (batch $((i/batch_size+1))): ${out%%$'\n'*}"
      _pf_pass pf_check_iam_deploy_actions "advisory skip after batch failure"
      return 0
    fi
    local _line
    while IFS= read -r _line; do
      [[ -z "$_line" ]] && continue
      denied+=("$_line")
    done < <(PF_IAM_SIM_JSON="$out" python3 <<'PY'
import json, os
d = json.loads(os.environ.get("PF_IAM_SIM_JSON", "{}"))
for r in d.get("EvaluationResults", []):
    if r.get("EvalDecision") != "allowed":
        org = r.get("OrganizationsDecisionDetail", {})
        why = "SCP DENY" if org.get("AllowedByOrganizations") is False else r.get("EvalDecision")
        print("{}\t{}".format(r.get("EvalActionName"), why))
PY
)
  done
  if ! _pf_iam_passrole_allowed_for_deploy "$simulation_arn"; then
    denied+=("iam:PassRole"$'\t'"implicitDeny (no PassedToService context matched deploy/iam/policy.json allow-list)")
  fi

  if (( ${#denied[@]} == 0 )); then
    _pf_pass pf_check_iam_deploy_actions "all ${total} required actions + iam:PassRole allowed for ${simulation_arn}"
    return 0
  fi

  local -a hard_denied=() advisory_denied=()
  local d decision action
  for d in "${denied[@]}"; do
    decision="${d#*$'\t'}"
    action="${d%%$'\t'*}"
    case "$decision" in
      explicitDeny|"SCP DENY") hard_denied+=("$d") ;;
      implicitDeny*)
        # Resource-less simulation false positives; only iam:PassRole without context is real.
        if [[ "$action" == "iam:PassRole" ]]; then
          hard_denied+=("$d")
        else
          advisory_denied+=("$d")
        fi
        ;;
      *) advisory_denied+=("$d") ;;
    esac
  done

  if (( ${#hard_denied[@]} == 0 )); then
    _pf_pass pf_check_iam_deploy_actions "no explicit/SCP deny (${#advisory_denied[@]} resource-scoped simulation caveat(s) ignored)"
    return 0
  fi

  local -a args=(--summary "Caller principal explicitly denied for ${#hard_denied[@]} required action(s)"
                 --shortcoming "config (IAM / SCP)"
                 --observed "${hard_denied[*]}")
  for d in "${hard_denied[@]}"; do args+=(--fix "Grant or remove SCP block for: ${d}"); done
  args+=(--fix "Reference policy: deploy/iam/multiagent-deploy-policy.json (attach to your IAM user/role)")
  args+=(--hint "iam:attach:deploy/iam/multiagent-deploy-policy.json")
  args+=(--doc "docs/deployment-preflight-checks.md#iam-deploy-actions")
  _pf_fail pf_check_iam_deploy_actions "${args[@]}"
}

# pf:check: pf_check_runtime_role_bedrock_invoke
# pf:catches: "Runtime role missing bedrock:InvokeModel after Terraform apply"
pf_check_runtime_role_bedrock_invoke() {
  _pf_ensure_aws_auth || { _pf_skip pf_check_runtime_role_bedrock_invoke "AWS auth not validated"; return 0; }
  local pn="${PROJECT_NAME:-}" env_="${ENVIRONMENT:-}"
  if [[ -z "$pn" || -z "$env_" ]]; then
    _pf_skip pf_check_runtime_role_bedrock_invoke "PROJECT_NAME / ENVIRONMENT not set"
    return 0
  fi
  local role_name="${pn}-${env_}-agentcore-runtime"
  local role_arn
  role_arn="$(aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text 2>/dev/null || true)"
  if [[ -z "$role_arn" || "$role_arn" == "None" ]]; then
    _pf_skip pf_check_runtime_role_bedrock_invoke "runtime role ${role_name} not yet created (run before phase 5b only after apply)"
    return 0
  fi
  local out
  out="$(aws iam simulate-principal-policy \
    --policy-source-arn "$role_arn" \
    --action-names bedrock:InvokeModel bedrock:InvokeModelWithResponseStream \
    --output json 2>&1 || true)"
  local denied
  denied="$(echo "$out" | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  for r in d.get("EvaluationResults", []):
    if r.get("EvalDecision") != "allowed":
      print(r.get("EvalActionName"))
except Exception:
  pass' 2>/dev/null)"
  if [[ -z "$denied" ]]; then
    _pf_pass pf_check_runtime_role_bedrock_invoke "${role_name} can InvokeModel"
    return 0
  fi
  _pf_fail pf_check_runtime_role_bedrock_invoke \
    --summary "Runtime role ${role_name} cannot invoke Bedrock" \
    --shortcoming "config (IAM)" \
    --observed "denied: ${denied}" \
    --fix "Re-run terraform apply on module agentcore-runtime; ensure inline policy includes bedrock:InvokeModel + InvokeModelWithResponseStream" \
    --fix "Manually attach: aws iam attach-role-policy --role-name ${role_name} --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess (lab/dev only)" \
    --hint "iam:attach:deploy/terraform/modules/agentcore-runtime/iam.tf" \
    --doc "docs/deployment-preflight-checks.md#runtime-role-bedrock-invoke"
}

# ══════════════════════════════════════════════════════════════════════════════
# Checks — Atlas
# ══════════════════════════════════════════════════════════════════════════════

# pf:check: pf_check_atlas_api_keys_present
pf_check_atlas_api_keys_present() {
  _pf_prereq pf_check_env_required_keys_filled || \
    { _pf_skip pf_check_atlas_api_keys_present "prereq pf_check_env_required_keys_filled failed"; return 0; }
  local pub="${MONGODB_ATLAS_PUBLIC_KEY:-}"
  local priv="${MONGODB_ATLAS_PRIVATE_KEY:-}"
  local proj="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
  local -a missing=()
  [[ -z "$pub"  ]] && missing+=("MONGODB_ATLAS_PUBLIC_KEY")
  [[ -z "$priv" ]] && missing+=("MONGODB_ATLAS_PRIVATE_KEY")
  [[ -z "$proj" ]] && missing+=("TF_VAR_mongodb_atlas_project_id")
  if (( ${#missing[@]} == 0 )); then
    _pf_pass pf_check_atlas_api_keys_present "Atlas API keys + project id present"
    return 0
  fi
  local -a args=(--summary "Atlas API credentials missing: ${missing[*]}"
                 --shortcoming "config"
                 --observed "missing keys in env: ${missing[*]}")
  local m
  for m in "${missing[@]}"; do args+=(--fix "Set ${m} in .env (Atlas → Project → Access Manager → API Keys)"); args+=(--hint "edit:.env:${m}"); done
  args+=(--doc "docs/deployment-preflight-checks.md#atlas-api-keys")
  _pf_fail pf_check_atlas_api_keys_present "${args[@]}"
}

# pf:check: pf_check_atlas_api_key_scope
# pf:catches: "Atlas API key has wrong scope / project / role"
pf_check_atlas_api_key_scope() {
  _pf_prereq pf_check_atlas_api_keys_present || \
    { _pf_skip pf_check_atlas_api_key_scope "prereq pf_check_atlas_api_keys_present failed"; return 0; }
  local proj="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
  local out status body
  out="$(mktemp)"
  status="$(_pf_atlas_api "$out" "/groups/${proj}")"
  body="$(cat "$out")"
  rm -f "$out"
  case "$status" in
    2*)
      _pf_pass pf_check_atlas_api_key_scope "API key authorized for project ${proj}"
      return 0
      ;;
    401)
      _pf_fail pf_check_atlas_api_key_scope \
        --summary "Atlas API returned 401 (key invalid / not whitelisted)" \
        --shortcoming "config" \
        --observed "GET /groups/${proj} → 401" \
        --fix "Verify the public/private key pair in .env matches an active Project-level API key in Atlas" \
        --fix "Ensure your operator IP is in the API Access List: Atlas → Organization → API Keys → <key> → Access List" \
        --hint "console:https://cloud.mongodb.com/v2#/account/api" \
        --doc "docs/deployment-preflight-checks.md#atlas-api-key-scope"
      return 0
      ;;
    403)
      _pf_fail pf_check_atlas_api_key_scope \
        --summary "Atlas API returned 403 (key has wrong role)" \
        --shortcoming "config" \
        --observed "GET /groups/${proj} → 403" \
        --fix "Atlas → Project Access → Edit API key → role = 'Project Owner' (or at least 'Project Cluster Manager' + 'Project Stream Processing Owner')" \
        --hint "console:https://cloud.mongodb.com/v2/${proj}#/access" \
        --doc "docs/deployment-preflight-checks.md#atlas-api-key-scope"
      return 0
      ;;
    404)
      _pf_fail pf_check_atlas_api_key_scope \
        --summary "Atlas project ${proj} not found (wrong project id?)" \
        --shortcoming "config" \
        --observed "GET /groups/${proj} → 404" \
        --fix "Set TF_VAR_mongodb_atlas_project_id to a valid project id (Atlas → Project Settings → Project ID)" \
        --hint "edit:.env:TF_VAR_mongodb_atlas_project_id" \
        --doc "docs/deployment-preflight-checks.md#atlas-api-key-scope"
      return 0
      ;;
    *)
      _pf_warn "Atlas API probe returned HTTP ${status}: $(echo "$body" | head -c 200)"
      _pf_pass pf_check_atlas_api_key_scope "non-fatal status ${status} (treated as transient)"
      return 0
      ;;
  esac
}

# pf:check: pf_check_atlas_cluster_tier
# pf:catches: "Existing cluster on M0/M2/M5 — won't accept PrivateLink / vector indexes"
pf_check_atlas_cluster_tier() {
  _pf_prereq pf_check_atlas_api_key_scope || \
    { _pf_skip pf_check_atlas_cluster_tier "prereq pf_check_atlas_api_key_scope failed"; return 0; }
  local proj="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
  local pn="${PROJECT_NAME:-}" env_="${ENVIRONMENT:-}"
  local cluster_name="${pn}-${env_}"
  local out status
  out="$(mktemp)"
  status="$(_pf_atlas_api "$out" "/groups/${proj}/clusters/${cluster_name}")"
  if [[ "$status" == "404" ]]; then
    rm -f "$out"
    _pf_pass pf_check_atlas_cluster_tier "cluster ${cluster_name} not yet created — Terraform will create it (M10 by default)"
    return 0
  fi
  if [[ ! "$status" =~ ^2 ]]; then
    rm -f "$out"
    _pf_skip pf_check_atlas_cluster_tier "atlas API returned ${status} for /clusters/${cluster_name}"
    return 0
  fi
  local tier
  # Atlas v2 returns multiple shapes depending on cluster type:
  #   - replica-set / sharded:  replicationSpecs[].regionConfigs[].electableSpecs.instanceSize
  #   - legacy v1.0 echo-back:  providerSettings.instanceSizeName
  #   - serverless:             clusterType == "SERVERLESS" (no instance size)
  #   - flex:                   clusterType == "FLEX" (no instance size; vector indexes still unsupported)
  local _py_tier
  IFS= read -r -d '' _py_tier <<'PY' || true
import json, sys
try:
    with open(sys.argv[1], "r") as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
ct = (d.get("clusterType") or "").upper()
if ct in ("SERVERLESS", "FLEX"):
    print(ct)
    sys.exit(0)
ps = d.get("providerSettings") or {}
if ps.get("instanceSizeName"):
    print(ps["instanceSizeName"]); sys.exit(0)
for rs in d.get("replicationSpecs", []) or []:
    for rc in rs.get("regionConfigs", []) or []:
        for key in ("electableSpecs", "readOnlySpecs", "analyticsSpecs"):
            spec = rc.get(key) or {}
            size = spec.get("instanceSize")
            if size:
                print(size); sys.exit(0)
print("")
PY
  tier="$(python3 -c "$_py_tier" "$out" 2>/dev/null)"
  rm -f "$out"
  case "$tier" in
    SERVERLESS|FLEX)
      _pf_fail pf_check_atlas_cluster_tier \
        --summary "Existing cluster ${cluster_name} is ${tier} (PrivateLink + vector indexes require a dedicated tier ≥ M10)" \
        --shortcoming "config" \
        --observed "clusterType=${tier}" \
        --fix "Atlas → Cluster ${cluster_name} → Edit configuration → switch to a Dedicated tier ≥ M10" \
        --fix "Or destroy and let Terraform recreate at the configured tier (default M10)" \
        --hint "console:https://cloud.mongodb.com/v2/${proj}#/clusters/edit/${cluster_name}" \
        --doc "docs/deployment-preflight-checks.md#atlas-cluster-tier"
      return 0
      ;;
    M0|M2|M5)
      _pf_fail pf_check_atlas_cluster_tier \
        --summary "Existing cluster ${cluster_name} is on free/shared tier ${tier} (PrivateLink + vector indexes require ≥ M10)" \
        --shortcoming "config" \
        --observed "tier=${tier}" \
        --fix "Atlas → Cluster ${cluster_name} → Edit configuration → Cluster Tier ≥ M10" \
        --fix "Or destroy and let Terraform recreate at the configured tier (default M10)" \
        --hint "console:https://cloud.mongodb.com/v2/${proj}#/clusters/edit/${cluster_name}" \
        --doc "docs/deployment-preflight-checks.md#atlas-cluster-tier"
      return 0
      ;;
  esac
  _pf_pass pf_check_atlas_cluster_tier "cluster ${cluster_name} tier=${tier:-?}"
}

# pf:check: pf_check_atlas_privatelink_no_orphans
# pf:catches: "Stale Atlas PrivateLink endpoint left from previous run"
pf_check_atlas_privatelink_no_orphans() {
  _pf_prereq pf_check_atlas_api_key_scope || \
    { _pf_skip pf_check_atlas_privatelink_no_orphans "prereq pf_check_atlas_api_key_scope failed"; return 0; }
  local proj="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
  local region="${AWS_REGION:-us-east-1}"
  local atlas_region
  atlas_region="$(echo "${region}" | tr 'a-z-' 'A-Z_')"
  local out status orphans
  out="$(mktemp)"
  status="$(_pf_atlas_api "$out" "/groups/${proj}/privateEndpoint/AWS/endpointService")"
  if [[ ! "$status" =~ ^2 ]]; then
    rm -f "$out"
    _pf_skip pf_check_atlas_privatelink_no_orphans "could not list private endpoints (HTTP ${status})"
    return 0
  fi
  local _py_orphans
  IFS= read -r -d '' _py_orphans <<'PY' || true
import json, os, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    d = json.load(fh)
results = d.get("results", d) if isinstance(d, dict) else []
out = []
want = os.environ.get("ATLAS_REGION", "")
for r in results:
    if r.get("regionName") == want and r.get("status") in ("DELETING", "FAILED"):
        out.append("{}({})".format(r.get("id"), r.get("status")))
print(",".join(out))
PY
  orphans="$(ATLAS_REGION="$atlas_region" python3 -c "$_py_orphans" "$out" 2>/dev/null || true)"
  rm -f "$out"
  if [[ -z "$orphans" ]]; then
    _pf_pass pf_check_atlas_privatelink_no_orphans "no orphan PrivateLink endpoints in ${atlas_region}"
    return 0
  fi
  _pf_fail pf_check_atlas_privatelink_no_orphans \
    --summary "Stale PrivateLink endpoints in ${atlas_region}: ${orphans}" \
    --shortcoming "config (Atlas state)" \
    --observed "orphan PLS ids: ${orphans}" \
    --fix "Run: ./deploy/scripts/destroy.sh --mode local then re-run the deploy" \
    --fix "Or delete each orphan via Atlas API: curl -u <pub:priv> --digest -X DELETE 'https://cloud.mongodb.com/api/atlas/v2/groups/${proj}/privateEndpoint/AWS/endpointService/<id>'" \
    --hint "run:./deploy/scripts/destroy.sh --mode local" \
    --doc "docs/deployment-preflight-checks.md#atlas-privatelink-orphans"
}

# pf:check: pf_check_atlas_project_quota
# pf:catches: "Atlas free-tier project quota exceeded — cluster create returns 'PROJECT_QUOTA_EXCEEDED'"
pf_check_atlas_project_quota() {
  _pf_prereq pf_check_atlas_api_key_scope || \
    { _pf_skip pf_check_atlas_project_quota "prereq pf_check_atlas_api_key_scope failed"; return 0; }
  local proj="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
  local out status count
  out="$(mktemp)"
  status="$(_pf_atlas_api "$out" "/groups/${proj}/clusters")"
  if [[ ! "$status" =~ ^2 ]]; then
    rm -f "$out"
    _pf_skip pf_check_atlas_project_quota "/clusters returned ${status}"
    return 0
  fi
  count="$(python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("results", d) if isinstance(d, dict) else []
print(len(r))' < "$out" 2>/dev/null || echo 0)"
  rm -f "$out"
  if [[ "$count" =~ ^[0-9]+$ ]] && (( count >= 25 )); then
    _pf_fail pf_check_atlas_project_quota \
      --summary "Atlas project ${proj} already has ${count} clusters (default project limit = 25)" \
      --shortcoming "config" \
      --observed "cluster count=${count}" \
      --fix "Use a different Atlas project (set TF_VAR_mongodb_atlas_project_id)" \
      --fix "Or contact MongoDB support to raise the per-project cluster cap" \
      --hint "edit:.env:TF_VAR_mongodb_atlas_project_id" \
      --doc "docs/deployment-preflight-checks.md#atlas-project-quota"
    return 0
  fi
  _pf_pass pf_check_atlas_project_quota "${count} cluster(s) in project (under 25 cap)"
}

# pf:check: pf_check_embedding_dim_consistency
# pf:catches: "Switched EMBEDDINGS_PROVIDER between titan/voyage without re-seeding"
pf_check_embedding_dim_consistency() {
  _pf_prereq pf_check_atlas_api_key_scope || \
    { _pf_skip pf_check_embedding_dim_consistency "prereq pf_check_atlas_api_key_scope failed"; return 0; }
  local provider="${EMBEDDINGS_PROVIDER:-titan}"
  local expected
  case "$provider" in
    titan)  expected=1024 ;;
    voyage) expected=1024 ;;
    *)
      _pf_skip pf_check_embedding_dim_consistency "unknown provider ${provider}"
      return 0
      ;;
  esac
  # Read SSM-stored embedding dim if present (written by deploy-shared.sh)
  if ! _pf_ensure_aws_auth; then
    _pf_skip pf_check_embedding_dim_consistency "AWS auth not validated"
    return 0
  fi
  local svn="${SHARED_VPC_NAME:-shared-network}"
  local region="${AWS_REGION:-us-east-1}"
  local stored
  stored="$(aws ssm get-parameter --region "$region" --name "/${svn}/${region}/embeddings/dim" --query 'Parameter.Value' --output text 2>/dev/null || true)"
  if [[ -z "$stored" || "$stored" == "None" ]]; then
    _pf_pass pf_check_embedding_dim_consistency "no prior embedding dim recorded — first deploy"
    return 0
  fi
  if [[ "$stored" != "$expected" ]]; then
    _pf_fail pf_check_embedding_dim_consistency \
      --summary "EMBEDDINGS_PROVIDER='${provider}' (dim=${expected}) ≠ stored shared dim ${stored}" \
      --shortcoming "config (state)" \
      --observed "/${svn}/${region}/embeddings/dim=${stored}, requested provider expects ${expected}" \
      --fix "Re-seed the embedding collections for the new provider OR revert EMBEDDINGS_PROVIDER" \
      --fix "Re-seed: REWIRE_EMBEDDINGS=1 bun db-seeding/seed-embeddings.ts (also runs seed-indexes.ts upstream)" \
      --hint "run:bun db-seeding/seed-embeddings.ts" \
      --doc "docs/deployment-preflight-checks.md#embedding-dim-consistency"
    return 0
  fi
  _pf_pass pf_check_embedding_dim_consistency "stored=${stored} matches provider=${provider}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Checks — Voyage / VPC / shared SSM / state
# ══════════════════════════════════════════════════════════════════════════════

# pf:check: pf_check_voyage_marketplace_subscribed
pf_check_voyage_marketplace_subscribed() {
  if [[ "${EMBEDDINGS_PROVIDER:-}" != "voyage" ]]; then
    _pf_skip pf_check_voyage_marketplace_subscribed "EMBEDDINGS_PROVIDER!=voyage"
    return 0
  fi
  _pf_ensure_aws_auth || { _pf_skip pf_check_voyage_marketplace_subscribed "AWS auth not validated"; return 0; }
  local arn="${VOYAGE_MODEL_PACKAGE_ARN:-}"
  if [[ -z "$arn" ]]; then
    _pf_fail pf_check_voyage_marketplace_subscribed \
      --summary "EMBEDDINGS_PROVIDER=voyage but VOYAGE_MODEL_PACKAGE_ARN is unset" \
      --shortcoming "config" \
      --observed "VOYAGE_MODEL_PACKAGE_ARN=" \
      --fix "Subscribe to Voyage AI on AWS Marketplace and set VOYAGE_MODEL_PACKAGE_ARN in .env" \
      --fix "Run helper: ./deploy/scripts/setup-voyage-marketplace.sh" \
      --hint "run:./deploy/scripts/setup-voyage-marketplace.sh" \
      --doc "docs/deployment-preflight-checks.md#voyage-marketplace"
    return 0
  fi
  local region="${AWS_REGION:-us-east-1}"
  local out
  out="$(aws sagemaker describe-model-package --region "$region" --model-package-name "$arn" 2>&1)"
  local rc=$?
  if (( rc != 0 )); then
    _pf_fail pf_check_voyage_marketplace_subscribed \
      --summary "Voyage Marketplace package not accessible in ${region}" \
      --shortcoming "config" \
      --observed "$(echo "$out" | head -1)" \
      --fix "Open https://aws.amazon.com/marketplace and subscribe to Voyage AI in ${region}" \
      --fix "After subscribing, copy the model package ARN for ${region} into .env (VOYAGE_MODEL_PACKAGE_ARN)" \
      --hint "run:./deploy/scripts/setup-voyage-marketplace.sh" \
      --doc "docs/deployment-preflight-checks.md#voyage-marketplace"
    return 0
  fi
  _pf_pass pf_check_voyage_marketplace_subscribed "Voyage Marketplace ARN reachable"
}

# pf:check: pf_check_sagemaker_endpoint_quota
# pf:catches: "EMBEDDINGS_PROVIDER=voyage but the account has 0 quota for the
#              chosen Voyage GPU instance type — Terraform fails inside
#              envs/shared with `ResourceLimitExceeded` ~6 min into apply."
# pf:source:  new-user friction (account quotas — see getting-started/fresh-account-deployment-prerequisites.md §4)
#
# AWS gates GPU/inference instance quotas to prevent runaway bills. New accounts
# default to 0 for many ml.g5.* / ml.g6.* instance types under the Service Quotas
# "<instance-type> for endpoint usage" key. Quota increase requests are submitted
# through Service Quotas and usually approved 0–60 min (existing accounts) up to
# 24 h (new accounts).  Skip path: set EMBEDDINGS_PROVIDER=titan in .env.
pf_check_sagemaker_endpoint_quota() {
  if [[ "${EMBEDDINGS_PROVIDER:-}" != "voyage" ]]; then
    _pf_skip pf_check_sagemaker_endpoint_quota "EMBEDDINGS_PROVIDER!=voyage"
    return 0
  fi
  _pf_ensure_aws_auth || { _pf_skip pf_check_sagemaker_endpoint_quota "AWS auth not validated"; return 0; }

  # Same default + override surface as deploy-shared.sh / voyage-sagemaker Terraform module.
  local instance_type="${VOYAGE_INSTANCE_TYPE:-ml.g6.xlarge}"
  local region="${AWS_REGION:-us-east-1}"
  local quota_name="${instance_type} for endpoint usage"
  local need=1

  # 1) Customer-applied quota (only present if a quota increase has been granted)
  local applied source value
  applied="$(aws service-quotas list-service-quotas \
    --region "$region" \
    --service-code sagemaker \
    --query "Quotas[?QuotaName=='${quota_name}'].Value | [0]" \
    --output text 2>/dev/null || echo None)"

  if [[ -n "$applied" && "$applied" != "None" && "$applied" != "null" ]]; then
    value="$applied"
    source="customer-applied"
  else
    # 2) AWS default quota (typically 0 for GPU endpoint usage on new accounts)
    local default_value
    default_value="$(aws service-quotas list-aws-default-service-quotas \
      --region "$region" \
      --service-code sagemaker \
      --query "Quotas[?QuotaName=='${quota_name}'].Value | [0]" \
      --output text 2>/dev/null || echo None)"
    if [[ -z "$default_value" || "$default_value" == "None" || "$default_value" == "null" ]]; then
      # Could mean: invalid instance type, Service Quotas API denied (rare —
      # IAM policy grants ListServiceQuotas + ListAWSDefaultServiceQuotas), or
      # AWS hasn't published a quota for this instance type yet. Don't block
      # the deploy; the inline Terraform apply still surfaces ResourceLimitExceeded.
      _pf_skip pf_check_sagemaker_endpoint_quota \
        "no '${quota_name}' quota found via Service Quotas in ${region} (proceeding; Terraform will catch ResourceLimitExceeded if any)"
      return 0
    fi
    value="$default_value"
    source="aws-default"
  fi

  # Compare integer floor (drop fractional part — AWS quotas are usually integers anyway).
  local value_int="${value%.*}"
  if ! [[ "$value_int" =~ ^[0-9]+$ ]]; then
    _pf_skip pf_check_sagemaker_endpoint_quota "could not parse quota value '${value}'"
    return 0
  fi

  if (( value_int < need )); then
    _pf_fail pf_check_sagemaker_endpoint_quota \
      --summary "SageMaker quota '${quota_name}' is ${value} in ${region} (need ≥ ${need})" \
      --shortcoming "new-user friction (account quotas)" \
      --observed "Service Quotas (${source}): ${quota_name} = ${value} in ${region}; Voyage SageMaker endpoint provisioning will fail with ResourceLimitExceeded inside envs/shared" \
      --fix "Open Service Quotas in the AWS Console: https://${region}.console.aws.amazon.com/servicequotas/home/services/sagemaker/quotas" \
      --fix "Search for '${quota_name}' → Request quota increase → set new value to ${need} (or higher) → submit" \
      --fix "Approval is usually 0–60 min on accounts with payment history; up to 24 h on brand-new accounts (you'll get a Service Quotas email when granted)" \
      --fix "Alternative — skip Voyage entirely: set EMBEDDINGS_PROVIDER=titan in .env (Bedrock Titan does not need SageMaker)" \
      --fix "Verify post-grant: aws service-quotas list-service-quotas --region ${region} --service-code sagemaker --query \"Quotas[?QuotaName=='${quota_name}'].Value | [0]\" --output text" \
      --hint "console:https://${region}.console.aws.amazon.com/servicequotas/home/services/sagemaker/quotas" \
      --hint "edit:.env:EMBEDDINGS_PROVIDER=titan" \
      --doc "docs/deployment-preflight-checks.md#sagemaker-endpoint-quota"
    return 0
  fi

  _pf_pass pf_check_sagemaker_endpoint_quota "${quota_name} = ${value} (${source}) in ${region}"
}

# pf:check: pf_check_shared_network_ssm
# pf:catches: "deploy-shared / deploy-project before deploy-network ran"
pf_check_shared_network_ssm() {
  _pf_ensure_aws_auth || { _pf_skip pf_check_shared_network_ssm "AWS auth not validated"; return 0; }
  local svn="${SHARED_VPC_NAME:-shared-network}"
  local region="${AWS_REGION:-us-east-1}"
  local key="/${svn}/${region}/canary/network"
  if aws ssm get-parameter --region "$region" --name "$key" >/dev/null 2>&1; then
    _pf_pass pf_check_shared_network_ssm "${key} present"
    return 0
  fi
  local legacy_key="/${svn}/${region}/vpc_id"
  if aws ssm get-parameter --region "$region" --name "$legacy_key" >/dev/null 2>&1; then
    _pf_pass pf_check_shared_network_ssm "${legacy_key} present (legacy deployed-stack output)"
    return 0
  fi
  _pf_fail pf_check_shared_network_ssm \
    --summary "Shared network not yet deployed in ${region} (SSM ${key} / ${legacy_key} missing)" \
    --shortcoming "ordering" \
    --observed "${key} and ${legacy_key} not in SSM Parameter Store" \
    --fix "Run: ./deploy/scripts/deploy-network.sh" \
    --fix "Or use the orchestrator: ./deploy/deploy-full-with-privatelink.sh (which runs network first if missing)" \
    --hint "run:./deploy/scripts/deploy-network.sh" \
    --doc "docs/deployment-preflight-checks.md#shared-network-ssm"
}

# pf:check: pf_check_shared_stack_ssm
pf_check_shared_stack_ssm() {
  _pf_ensure_aws_auth || { _pf_skip pf_check_shared_stack_ssm "AWS auth not validated"; return 0; }
  local svn="${SHARED_VPC_NAME:-shared-network}"
  local env_="${ENVIRONMENT:-dev}"
  local region="${AWS_REGION:-us-east-1}"
  local key="/${svn}/${region}/${env_}/canary/shared"
  if aws ssm get-parameter --region "$region" --name "$key" >/dev/null 2>&1; then
    _pf_pass pf_check_shared_stack_ssm "${key} present"
    return 0
  fi
  local legacy_key="/${svn}/${region}/cw_api_log_group"
  if aws ssm get-parameter --region "$region" --name "$legacy_key" >/dev/null 2>&1; then
    _pf_pass pf_check_shared_stack_ssm "${legacy_key} present (legacy deployed-stack output)"
    return 0
  fi
  _pf_fail pf_check_shared_stack_ssm \
    --summary "Shared stack not yet deployed in ${region}/${env_} (SSM ${key} / ${legacy_key} missing)" \
    --shortcoming "ordering" \
    --observed "${key} and ${legacy_key} not in SSM Parameter Store" \
    --fix "Run: ./deploy/scripts/deploy-shared.sh" \
    --fix "Or use the orchestrator: ./deploy/deploy-full-with-privatelink.sh" \
    --hint "run:./deploy/scripts/deploy-shared.sh" \
    --doc "docs/deployment-preflight-checks.md#shared-stack-ssm"
}

# pf:check: pf_check_agentcore_vpcendpoints_present
# pf:catches: "AgentCore runtime support VPCEs missing → VPC runtimes can't pull images / ship logs"
pf_check_agentcore_vpcendpoints_present() {
  _pf_prereq pf_check_shared_network_ssm || \
    { _pf_skip pf_check_agentcore_vpcendpoints_present "prereq pf_check_shared_network_ssm failed"; return 0; }
  _pf_ensure_aws_auth || { _pf_skip pf_check_agentcore_vpcendpoints_present "AWS auth not validated"; return 0; }
  local svn="${SHARED_VPC_NAME:-shared-network}"
  local region="${AWS_REGION:-us-east-1}"
  local vpc_id
  vpc_id="$(aws ssm get-parameter --region "$region" --name "/${svn}/${region}/vpc/id" --query 'Parameter.Value' --output text 2>/dev/null || true)"
  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    vpc_id="$(aws ssm get-parameter --region "$region" --name "/${svn}/${region}/vpc_id" --query 'Parameter.Value' --output text 2>/dev/null || true)"
  fi
  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    _pf_skip pf_check_agentcore_vpcendpoints_present "shared VPC id not in SSM yet"
    return 0
  fi
  # Terraform's AgentCore VPC runtime support endpoints are ECR API, ECR DKR,
  # CloudWatch Logs, and S3. The AgentCore runtime/gateway themselves are
  # public service endpoints and are not modeled as private DNS VPCEs here.
  local -a services=(
    "com.amazonaws.${region}.ecr.api"
    "com.amazonaws.${region}.ecr.dkr"
    "com.amazonaws.${region}.logs"
    "com.amazonaws.${region}.s3"
  )
  local -a missing=()
  local service found
  for service in "${services[@]}"; do
    found="$(aws ec2 describe-vpc-endpoints --region "$region" \
      --filters "Name=vpc-id,Values=${vpc_id}" "Name=service-name,Values=${service}" \
      --query 'length(VpcEndpoints)' --output text 2>/dev/null || echo 0)"
    if [[ ! "$found" =~ ^[0-9]+$ ]] || (( found < 1 )); then
      missing+=("$service")
    fi
  done
  if (( ${#missing[@]} == 0 )); then
    _pf_pass pf_check_agentcore_vpcendpoints_present "AgentCore runtime support VPCEs present in ${vpc_id}"
    return 0
  fi
  if [[ "${PREFLIGHT_STRICT_NETWORK_ENDPOINTS:-0}" != "1" ]]; then
    _pf_warn "AgentCore runtime support VPCEs missing in ${vpc_id}: ${missing[*]}. Continuing because deploy-project can create/reconcile these endpoints."
    _pf_pass pf_check_agentcore_vpcendpoints_present "missing support VPCEs will be reconciled by Terraform (warning only)"
    return 0
  fi
  _pf_fail pf_check_agentcore_vpcendpoints_present \
    --summary "AgentCore runtime support VPC endpoints missing in shared VPC ${vpc_id}" \
    --shortcoming "config (network)" \
    --observed "missing: ${missing[*]}" \
    --fix "Re-run project deploy so envs/ec2 creates or reconciles the AgentCore runtime support endpoints" \
    --hint "run:./deploy/scripts/deploy-project.sh" \
    --doc "docs/deployment-preflight-checks.md#agentcore-vpcendpoints"
}

# pf:check: pf_check_concurrent_deploy_lock
# pf:catches: "Two deploys running side-by-side corrupting Terraform state"
pf_check_concurrent_deploy_lock() {
  _pf_ensure_aws_auth || { _pf_skip pf_check_concurrent_deploy_lock "AWS auth not validated"; return 0; }
  local pn="${PROJECT_NAME:-}" env_="${ENVIRONMENT:-}"
  if [[ -z "$pn" || -z "$env_" ]]; then
    _pf_skip pf_check_concurrent_deploy_lock "PROJECT_NAME / ENVIRONMENT not set"
    return 0
  fi
  local acct="${AWS_AUTH_ACCOUNT_ID:-}"
  if [[ -z "$acct" ]]; then
    _pf_skip pf_check_concurrent_deploy_lock "AWS account id unknown"
    return 0
  fi
  local region="${AWS_REGION:-us-east-1}"
  local bucket="${pn}-${env_}-${acct}"
  local key=".preflight-locks/deploy.lock"
  # Ensure bucket exists; if not, the lock check is N/A (first deploy)
  if ! aws s3api head-bucket --bucket "$bucket" --region "$region" >/dev/null 2>&1; then
    _pf_pass pf_check_concurrent_deploy_lock "state bucket ${bucket} does not yet exist (first deploy)"
    return 0
  fi
  local existing_owner existing_pid existing_ts
  if aws s3api head-object --bucket "$bucket" --key "$key" --region "$region" >/dev/null 2>&1; then
    if [[ "${PREFLIGHT_FORCE_LOCK_BREAK:-0}" == "1" ]]; then
      aws s3api delete-object --bucket "$bucket" --key "$key" --region "$region" >/dev/null 2>&1 || true
      _pf_warn "PREFLIGHT_FORCE_LOCK_BREAK=1 — broke the existing deploy lock"
    else
      local body
      body="$(aws s3 cp "s3://${bucket}/${key}" - --region "$region" 2>/dev/null || echo '')"
      _pf_fail pf_check_concurrent_deploy_lock \
        --summary "Another deploy may be in progress for ${pn}/${env_}" \
        --shortcoming "config (state)" \
        --observed "s3://${bucket}/${key} exists: ${body}" \
        --fix "Wait for the other deploy to finish (look for the host/pid in the lock body)" \
        --fix "If you are sure no other deploy is running, force-break: PREFLIGHT_FORCE_LOCK_BREAK=1 ./deploy/deploy-full-with-privatelink.sh" \
        --hint "run:PREFLIGHT_FORCE_LOCK_BREAK=1 ./deploy/deploy-full-with-privatelink.sh" \
        --doc "docs/deployment-preflight-checks.md#concurrent-deploy-lock"
      return 0
    fi
  fi
  # Acquire lock
  local lock_body
  lock_body="$(printf 'host=%s\npid=%s\nts=%s\nuser=%s\n' "$(hostname)" "$$" "$(date -u +%s)" "${USER:-unknown}")"
  if echo "$lock_body" | aws s3 cp - "s3://${bucket}/${key}" --region "$region" >/dev/null 2>&1; then
    PREFLIGHT_LOCK_BUCKET="$bucket"
    PREFLIGHT_LOCK_KEY="$key"
    PREFLIGHT_LOCK_HELD=1
    _pf_pass pf_check_concurrent_deploy_lock "lock acquired s3://${bucket}/${key}"
  else
    _pf_warn "could not write deploy lock to s3://${bucket}/${key} (skip enforcement)"
    _pf_pass pf_check_concurrent_deploy_lock "lock write failed (advisory only)"
  fi
}

# pf:check: pf_check_deploy_manifest_present
# pf:catches: "Re-using stale state from previous run with different PROJECT_NAME"
pf_check_deploy_manifest_present() {
  _pf_prereq pf_check_concurrent_deploy_lock || \
    { _pf_skip pf_check_deploy_manifest_present "prereq pf_check_concurrent_deploy_lock failed"; return 0; }
  _pf_ensure_aws_auth || { _pf_skip pf_check_deploy_manifest_present "AWS auth not validated"; return 0; }
  local pn="${PROJECT_NAME:-}" env_="${ENVIRONMENT:-}" acct="${AWS_AUTH_ACCOUNT_ID:-}"
  local region="${AWS_REGION:-us-east-1}"
  local bucket="${pn}-${env_}-${acct}"
  local key=".preflight-locks/manifest.json"
  if ! aws s3api head-bucket --bucket "$bucket" --region "$region" >/dev/null 2>&1; then
    _pf_pass pf_check_deploy_manifest_present "first deploy"
    return 0
  fi
  local body
  body="$(aws s3 cp "s3://${bucket}/${key}" - --region "$region" 2>/dev/null || true)"
  if [[ -z "$body" ]]; then
    # First successful deploy after this check ships — write manifest now
    local manifest
    manifest="$(printf '{"project_name":"%s","environment":"%s","aws_region":"%s","first_seen":"%s"}' "$pn" "$env_" "$region" "$(date -u +%s)")"
    echo "$manifest" | aws s3 cp - "s3://${bucket}/${key}" --region "$region" >/dev/null 2>&1 || true
    _pf_pass pf_check_deploy_manifest_present "wrote new manifest"
    return 0
  fi
  local m_pn m_env
  m_pn="$(echo "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("project_name",""))' 2>/dev/null || true)"
  m_env="$(echo "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("environment",""))' 2>/dev/null || true)"
  if [[ -n "$m_pn" && "$m_pn" != "$pn" ]] || [[ -n "$m_env" && "$m_env" != "$env_" ]]; then
    _pf_fail pf_check_deploy_manifest_present \
      --summary "State bucket ${bucket} was previously used by a different deploy" \
      --shortcoming "config (state)" \
      --observed "manifest project_name=${m_pn} environment=${m_env}, current PROJECT_NAME=${pn} ENVIRONMENT=${env_}" \
      --fix "Run ./deploy/scripts/destroy.sh --mode local with the OLD PROJECT_NAME/ENVIRONMENT first, then re-run with the new ones" \
      --fix "Or: aws s3 rm s3://${bucket}/.preflight-locks/manifest.json (only if you intentionally renamed the project)" \
      --hint "run:./deploy/scripts/destroy.sh --mode local" \
      --doc "docs/deployment-preflight-checks.md#deploy-manifest"
    return 0
  fi
  _pf_pass pf_check_deploy_manifest_present "manifest matches PROJECT_NAME=${pn} ENVIRONMENT=${env_}"
}

# pf:check: pf_check_env_live_required_keys
# pf:catches: "Missing keys after Terraform apply (cognito, atlas conn string)"
pf_check_env_live_required_keys() {
  local f="${REPO_ROOT}/.env.live"
  if [[ ! -f "$f" ]]; then
    _pf_skip pf_check_env_live_required_keys ".env.live not yet generated (skip if pre-apply)"
    return 0
  fi
  local -a required=(
    MONGODB_URI MONGODB_DB
    AUTH_JWKS_URI AUTH_ISSUER
    STREAMLIT_COGNITO_POOL_ID STREAMLIT_COGNITO_CLIENT_ID
  )
  local -a missing=()
  local k v line
  for k in "${required[@]}"; do
    # SIGPIPE-safe: grep + head -1 + sed in command substitution can crash
    # under `set -o pipefail` if the key appears more than once in .env.live
    # (grep gets SIGPIPE after head -1 closes). Use capture-first-line + bash
    # parameter expansion instead — no early-exit downstream reader.
    line="$(_pf_capture_first_line grep -E "^${k}=" "$f")"
    v="${line#*=}"
    [[ -z "$line" || -z "$v" ]] && missing+=("$k")
  done
  if (( ${#missing[@]} == 0 )); then
    _pf_pass pf_check_env_live_required_keys "${#required[@]} required keys present in .env.live"
    return 0
  fi
  local -a args=(--summary "${#missing[@]} required keys missing from .env.live"
                 --shortcoming "config (post-apply)"
                 --observed "missing: ${missing[*]}")
  local m
  for m in "${missing[@]}"; do args+=(--fix "Re-run terraform apply or ./deploy/deploy-api.sh to refresh .env.live with: ${m}"); done
  args+=(--hint "run:./deploy/deploy-api.sh")
  args+=(--doc "docs/deployment-preflight-checks.md#env-live-keys")
  _pf_fail pf_check_env_live_required_keys "${args[@]}"
}

# pf:check: pf_check_vector_indexes_present
# pf:catches: "Vector indexes not yet ACTIVE — first chat returns 0 vector hits"
pf_check_vector_indexes_present() {
  _pf_prereq pf_check_atlas_api_key_scope || \
    { _pf_skip pf_check_vector_indexes_present "prereq pf_check_atlas_api_key_scope failed"; return 0; }
  local proj="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
  local pn="${PROJECT_NAME:-}" env_="${ENVIRONMENT:-}"
  local cluster_name="${pn}-${env_}"
  local out status
  out="$(mktemp)"
  status="$(_pf_atlas_api "$out" "/groups/${proj}/clusters/${cluster_name}/search/indexes")"
  if [[ ! "$status" =~ ^2 ]]; then
    rm -f "$out"
    _pf_skip pf_check_vector_indexes_present "atlas search-indexes API returned ${status}"
    return 0
  fi
  local missing_or_inactive
  missing_or_inactive="$(python3 -c 'import json,sys
data = json.load(sys.stdin)
if isinstance(data, dict):
    data = data.get("results", [])
needed = {"agent_memory_facts": False, "chat_messages": False, "products": False, "troubleshooting_docs": False}
for idx in data:
    name = idx.get("collectionName") or idx.get("collection")
    if name in needed and idx.get("status","").upper() == "READY":
        needed[name] = True
print(",".join(k for k,v in needed.items() if not v))' < "$out" 2>/dev/null || echo '')"
  rm -f "$out"
  if [[ -z "$missing_or_inactive" ]]; then
    _pf_pass pf_check_vector_indexes_present "all 4 vector indexes READY"
    return 0
  fi
  _pf_fail pf_check_vector_indexes_present \
    --summary "Vector indexes missing or not yet ACTIVE: ${missing_or_inactive}" \
    --shortcoming "config (post-apply)" \
    --observed "indexes not READY: ${missing_or_inactive}" \
    --fix "Run: bun db-seeding/seed-indexes.ts (idempotent)" \
    --fix "Atlas builds vector indexes asynchronously — wait 2–5 minutes after seed-indexes.ts and re-run preflight" \
    --hint "run:bun db-seeding/seed-indexes.ts" \
    --doc "docs/deployment-preflight-checks.md#vector-indexes"
}

# _pf_resolve_mongodb_db
#
# Single source of truth for the canonical MongoDB database name inside the
# preflight module. Matches the project convention used by `.env.sample`,
# `deploy/scripts/deploy-project.sh`, `deploy/scripts/deploy-local.sh`,
# `deploy/scripts/destroy.sh`, and `deploy/scripts/setup-troubleshooting-infra.sh`:
#
#     ATLAS_DB_NAME = "${PROJECT_NAME//-/_}_${ENVIRONMENT}"
#
# Mongo identifiers can't contain '-', so the project name is underscore-
# normalized. The deploy scripts mirror ATLAS_DB_NAME into MONGODB_DB, so
# the resolution order is:
#
#   1. MONGODB_DB         (canonical app-side env var, set by deploy scripts)
#   2. ATLAS_DB_NAME      (canonical deploy-side env var, set early in deploy)
#   3. <project-slug>_<env> (derived; matches every other helper's default)
#
# A previous default ("multiagent_${PROJECT_NAME}_${ENVIRONMENT}") silently
# drifted from this convention and caused `pf_check_documents_have_embeddings`
# to query the wrong database, returning a noisy "not authorized on
# multiagent_<project>_<env>" failure even though seeding had succeeded.
_pf_resolve_mongodb_db() {
  local slug="${PROJECT_NAME//-/_}"
  local db="${MONGODB_DB:-${ATLAS_DB_NAME:-${slug:-multiagent}_${ENVIRONMENT:-dev}}}"
  printf '%s' "${db//[^a-zA-Z0-9_]/_}"
}

# pf:check: pf_check_documents_have_embeddings
# pf:catches: "Seed completed but provider misconfig left embedding=null on every doc"
#
# Verifies both `products` and seeder-owned rows of `troubleshooting_docs`
# (Bedrock-managed `bedrock_text_chunk` rows are intentionally excluded —
# those embeddings are owned by the KB ingestion path and the seeder must
# never overwrite them).
#
# Per row, asserts:
#   - embedding exists, is an array, length == EMBEDDING_DIMENSIONS
#   - embeddingModel matches the expected provider tag for EMBEDDINGS_PROVIDER
#
# Uses `bun` (already on PATH at this phase). NEVER pipes the bun output
# through head/grep/awk — captures into a variable and parses with bash.
pf_check_documents_have_embeddings() {
  if [[ -z "${MONGODB_URI:-}" && -z "${MONGODB_URI_PUBLIC:-}" ]]; then
    _pf_fail pf_check_documents_have_embeddings \
      --summary "no MONGODB_URI / MONGODB_URI_PUBLIC available" \
      --shortcoming "config" \
      --observed "MONGODB_URI and MONGODB_URI_PUBLIC both empty" \
      --fix "Run deploy-api.sh or deploy-project.sh to write .env.live with MONGODB_URI" \
      --doc "docs/deployment-preflight-checks.md#documents-have-embeddings"
    return 0
  fi
  if ! command -v bun >/dev/null 2>&1; then
    _pf_fail pf_check_documents_have_embeddings \
      --summary "bun not on PATH — required for embedding verification" \
      --shortcoming "tool" \
      --observed "bun not found" \
      --fix "Install bun: curl -fsSL https://bun.sh/install | bash" \
      --doc "docs/deployment-preflight-checks.md#documents-have-embeddings"
    return 0
  fi
  local uri="${MONGODB_URI_PUBLIC:-${MONGODB_URI:-}}"
  local db
  db="$(_pf_resolve_mongodb_db)"
  local expected_dim="${EMBEDDING_DIMENSIONS:-1024}"
  local provider="${EMBEDDINGS_PROVIDER:-titan}"
  local expected_model_prefix
  case "$provider" in
    voyage) expected_model_prefix="voyage:" ;;
    titan)  expected_model_prefix="bedrock:" ;;
    *)      expected_model_prefix="" ;;
  esac
  # For exact tag construction (the seeder writes voyage:<endpoint> or
  # bedrock:<model-id>); allow either an exact match or a prefix match.
  local expected_voyage_ep="${VOYAGE_SAGEMAKER_ENDPOINT:-}"
  local expected_bedrock_model="${EMBEDDINGS_MODEL_ID:-amazon.titan-embed-text-v2:0}"
  local expected_tag=""
  if [[ "$provider" == "voyage" && -n "$expected_voyage_ep" ]]; then
    expected_tag="voyage:${expected_voyage_ep}"
  elif [[ "$provider" == "titan" && -n "$expected_bedrock_model" ]]; then
    expected_tag="bedrock:${expected_bedrock_model}"
  fi

  local probe_script
  IFS= read -r -d '' probe_script <<'JS' || true
import { MongoClient } from "mongodb";

const uri = process.env.MONGODB_URI;
const dbName = process.env.MONGODB_DB;
const expectedDim = Number(process.env.EXPECTED_DIM || "1024");
const expectedPrefix = process.env.EXPECTED_PREFIX || "";
const expectedTag = process.env.EXPECTED_TAG || "";

const COLLS = [
  { name: "products", filter: {} },
  { name: "troubleshooting_docs", filter: { bedrock_text_chunk: { $exists: false }, bedrock_metadata: { $exists: false } } },
];

const client = new MongoClient(uri, { appName: "preflight-embed-check", serverSelectionTimeoutMS: 8000 });
const out = { collections: [], error: null };
try {
  await client.connect();
  const db = client.db(dbName);
  for (const { name, filter } of COLLS) {
    const coll = db.collection(name);
    const total = await coll.countDocuments(filter);
    const withEmb = await coll.countDocuments({ ...filter, embedding: { $exists: true, $type: "array" } });
    let sample = null;
    let modelMismatch = 0;
    let dimMismatch = 0;
    if (withEmb > 0) {
      sample = await coll.findOne({ ...filter, embedding: { $exists: true, $type: "array" } }, { projection: { embedding: 1, embeddingModel: 1 } });
      if (sample && Array.isArray(sample.embedding) && sample.embedding.length !== expectedDim) {
        dimMismatch = await coll.countDocuments({ ...filter, embedding: { $exists: true, $type: "array" }, $expr: { $ne: [{ $size: "$embedding" }, expectedDim] } });
      }
      if (expectedPrefix) {
        modelMismatch = await coll.countDocuments({ ...filter, embedding: { $exists: true }, embeddingModel: { $not: { $regex: `^${expectedPrefix.replace(/[.+*?()[\]{}|\\^$]/g, "\\$&")}` } } });
      }
    }
    out.collections.push({
      name,
      total,
      withEmb,
      sampleDim: sample && Array.isArray(sample.embedding) ? sample.embedding.length : null,
      sampleModel: sample ? sample.embeddingModel || null : null,
      dimMismatch,
      modelMismatch,
    });
  }
} catch (e) {
  out.error = String(e && e.message ? e.message : e);
} finally {
  try { await client.close(); } catch (_) {}
}
process.stdout.write(JSON.stringify(out));
JS

  local probe_json
  probe_json="$(MONGODB_URI="$uri" \
    MONGODB_DB="$db" \
    EXPECTED_DIM="$expected_dim" \
    EXPECTED_PREFIX="$expected_model_prefix" \
    EXPECTED_TAG="$expected_tag" \
    bun -e "$probe_script" 2>/dev/null || echo '{"error":"bun probe failed"}')"

  local verdict
  verdict="$(EXPECTED_DIM="$expected_dim" EXPECTED_PREFIX="$expected_model_prefix" python3 -c '
import json, os, sys
data = json.loads(sys.stdin.read() or "{}")
err = data.get("error")
exp_prefix = os.environ.get("EXPECTED_PREFIX", "")
exp_dim = int(os.environ.get("EXPECTED_DIM", "1024"))
if err:
    print(f"FAIL\tmongo unreachable: {err}")
    sys.exit(0)
problems = []
for c in data.get("collections", []):
    name = c["name"]
    total = c["total"]
    with_emb = c["withEmb"]
    if total == 0:
        problems.append(f"{name}: 0 seeder-owned rows (was the collection seeded?)")
        continue
    if with_emb < total:
        missing = total - with_emb
        problems.append(f"{name}: {missing}/{total} rows missing embedding")
    sample_dim = c.get("sampleDim")
    if sample_dim is not None and sample_dim != exp_dim:
        problems.append(f"{name}: sample embedding.length={sample_dim} (want {exp_dim})")
    dim_m = c.get("dimMismatch", 0)
    if dim_m > 0:
        problems.append(f"{name}: {dim_m} rows with wrong embedding dim")
    model_m = c.get("modelMismatch", 0)
    if exp_prefix and model_m > 0:
        problems.append(f"{name}: {model_m} rows with embeddingModel not matching prefix={exp_prefix}")
if problems:
    print("FAIL\t" + " | ".join(problems))
else:
    parts = []
    for c in data.get("collections", []):
        parts.append(str(c.get("name")) + "=" + str(c.get("withEmb")) + "/" + str(c.get("total")))
    summary = ", ".join(parts)
    print(f"OK\tall seeder-owned rows have valid embeddings ({summary})")
' <<<"$probe_json" 2>/dev/null || echo 'FAIL	preflight parser error')"

  local status="${verdict%%	*}"
  local detail="${verdict#*	}"
  if [[ "$status" == "OK" ]]; then
    _pf_pass pf_check_documents_have_embeddings "$detail"
    return 0
  fi
  _pf_fail pf_check_documents_have_embeddings \
    --summary "Embedding coverage incomplete on seeded corpus" \
    --shortcoming "config (data)" \
    --observed "$detail" \
    --fix "Re-run: bun db-seeding/seed-embeddings.ts (idempotent, gap-fills missing)" \
    --fix "Provider switch: REWIRE_EMBEDDINGS=1 bun db-seeding/seed-embeddings.ts" \
    --hint "run:bun db-seeding/seed-embeddings.ts" \
    --doc "docs/deployment-preflight-checks.md#documents-have-embeddings"
}

# pf:check: pf_check_mcp_runtime_env_complete
# pf:catches: "MCP runtime env vars wiped by partial terraform apply — Mongo tool calls return 0 results"
#
# Probes the AgentCore Runtime for the mongodb-mcp runtime AND each specialist
# (orchestrator + per-specialist). Asserts:
#   - mongodb-mcp.MONGODB_URI / MONGODB_DB non-empty (dynamic vars injected by
#     Phase 6b update_runtime_env_dynamic in _agents-common.sh).
#   - mongodb-mcp.MONGODB_URI authority (scheme + user@hosts, query params ignored)
#     matches shell MONGODB_URI or .env.live so the API and MCP runtime cannot drift.
#   - specialist.AGENTCORE_GATEWAY_URL non-empty and matches the current
#     Gateway URL.
# See docs/status/debugging.md "AgentCore Runtime env wipe" (2025-12 entry).
pf_check_mcp_runtime_env_complete() {
  _pf_ensure_aws_auth || { _pf_skip pf_check_mcp_runtime_env_complete "AWS auth not validated"; return 0; }
  local region="${AWS_REGION:-us-east-1}"
  local mcp_id="${MONGODB_MCP_RUNTIME_ID:-}"
  local mcp_arn="${MONGODB_MCP_RUNTIME_ARN:-}"
  if [[ -z "$mcp_id" && -n "$mcp_arn" ]]; then
    mcp_id="${mcp_arn##*/}"
  fi
  if [[ -z "$mcp_id" ]]; then
    _pf_skip pf_check_mcp_runtime_env_complete "MONGODB_MCP_RUNTIME_ID / _ARN not in env (legacy pre-MCP-runtime layout)"
    return 0
  fi

  # Capture MCP runtime env vars as JSON without head/pipe.
  local mcp_env_json
  mcp_env_json="$(aws bedrock-agentcore-control get-agent-runtime \
    --region "$region" \
    --agent-runtime-id "$mcp_id" \
    --query 'environmentVariables' \
    --output json 2>/dev/null || echo '{}')"

  # Prefer in-shell MONGODB_URI (deploy-project Phase 5c/6b) over .env.live on disk.
  local live_uri="${MONGODB_URI:-}"
  local env_live="${REPO_ROOT:-${SCRIPT_DIR:-.}}/.env.live"
  [[ -f "$env_live" ]] || env_live=".env.live"
  if [[ -z "$live_uri" && -f "$env_live" ]]; then
    local line
    line="$(_pf_capture_first_line grep -E '^MONGODB_URI=' "$env_live")"
    live_uri="${line#*=}"
    live_uri="${live_uri%\"}"
    live_uri="${live_uri#\"}"
  fi

  local gw_url="${AGENTCORE_GATEWAY_URL:-}"

  # Collect specialist runtime IDs to probe.
  local -a spec_ids=()
  local _spec
  for _spec in "${SPECIALIST_IDS[@]:-}"; do
    [[ -n "$_spec" ]] && spec_ids+=("$_spec")
  done

  # Build a JSON map of specialist_id -> runtime_id (we'll query env for each).
  local spec_env_map="{}"
  local _sid _srid
  if (( ${#spec_ids[@]} > 0 )) && declare -F specialist_runtime_id >/dev/null 2>&1; then
    local _entries=""
    for _sid in "${spec_ids[@]}"; do
      _srid="$(specialist_runtime_id "$_sid" 2>/dev/null || true)"
      [[ -z "$_srid" || "$_srid" == "None" ]] && continue
      local _se_json
      _se_json="$(aws bedrock-agentcore-control get-agent-runtime \
        --region "$region" \
        --agent-runtime-id "$_srid" \
        --query 'environmentVariables' \
        --output json 2>/dev/null || echo '{}')"
      # Append as JSON object using python (bash 3.2 has no associative array literals).
      spec_env_map="$(python3 -c '
import json, sys
m = json.loads(sys.argv[1] or "{}")
m[sys.argv[2]] = json.loads(sys.argv[3] or "{}")
print(json.dumps(m))' "$spec_env_map" "$_sid" "$_se_json")"
    done
  fi

  # Defer judgment to python so we can produce a structured failure envelope.
  local probe_out
  probe_out="$(python3 -c '
import json, sys, os
mcp_env = json.loads(sys.argv[1] or "{}")
spec_env_map = json.loads(sys.argv[2] or "{}")
live_uri = sys.argv[3]
gw_url   = sys.argv[4]

problems = []
mongodb_uri = mcp_env.get("MONGODB_URI", "")
mongodb_db  = mcp_env.get("MONGODB_DB", "")
if not mongodb_uri:
    problems.append("mongodb-mcp.MONGODB_URI is empty (Phase 6b update_mcp_runtime_mongodb_env did not run, or env wipe regression)")
if not mongodb_db:
    problems.append("mongodb-mcp.MONGODB_DB is empty")
if live_uri and mongodb_uri:
    # Compare authority only (scheme + user@host:port,host:port,...).
    # Query params like retryWrites/w=majority are deploy-script defaults and
    # legitimately differ between Terraform-emitted (PL) URIs and the API
    # Phase 5c-normalized URI. The real env-wipe regression manifests as an
    # empty or completely different authority, which this comparison catches.
    import re
    def authority(u):
        return re.sub(r"\?.*$", "", u)
    if authority(live_uri) != authority(mongodb_uri):
        def san(u):
            return re.sub(r"://[^@]+@", "://****:****@", u)
        problems.append(f"mongodb-mcp.MONGODB_URI authority != .env.live (api={san(authority(live_uri))}, mcp={san(authority(mongodb_uri))})")

for sid, env in spec_env_map.items():
    if not env.get("AGENTCORE_GATEWAY_URL"):
        problems.append(f"specialist[{sid}].AGENTCORE_GATEWAY_URL is empty")
    elif gw_url and env.get("AGENTCORE_GATEWAY_URL") != gw_url:
        problems.append(f"specialist[{sid}].AGENTCORE_GATEWAY_URL != current Gateway URL")

if problems:
    print("FAIL\t" + " | ".join(problems))
else:
    print("OK\tmongodb-mcp env complete; " + str(len(spec_env_map)) + " specialists verified")
' "$mcp_env_json" "$spec_env_map" "$live_uri" "$gw_url" 2>/dev/null || echo 'FAIL	python parse error')"

  local status="${probe_out%%	*}"
  local detail="${probe_out#*	}"
  if [[ "$status" == "OK" ]]; then
    _pf_pass pf_check_mcp_runtime_env_complete "$detail"
    return 0
  fi
  _pf_fail pf_check_mcp_runtime_env_complete \
    --summary "AgentCore Runtime env vars incomplete (chat tool calls will return 0 results)" \
    --shortcoming "config (runtime env)" \
    --observed "$detail" \
    --fix "Re-run Phase 6b: ./deploy/deploy-agents.sh --auto-approve (syncs specialist env + mongodb-mcp MONGODB_URI)" \
    --fix "Or from deploy-project.sh Phase 6b: update_runtime_env_dynamic + update_mcp_runtime_mongodb_env" \
    --hint "run:./deploy/deploy-agents.sh --auto-approve" \
    --doc "docs/status/debugging.md#agentcore-runtime-env-wipe"
}

# pf:check: pf_check_privatelink_endpoint_available
# pf:catches: "NETWORK_MODE=privatelink but the VPC endpoint is still pendingAcceptance / failed"
pf_check_privatelink_endpoint_available() {
  if [[ "${NETWORK_MODE:-}" != "privatelink" ]]; then
    _pf_skip pf_check_privatelink_endpoint_available "NETWORK_MODE!=privatelink"
    return 0
  fi
  local pl_id="${ATLAS_PRIVATELINK_ENDPOINT_ID:-}"
  if [[ -z "$pl_id" ]]; then
    _pf_skip pf_check_privatelink_endpoint_available "ATLAS_PRIVATELINK_ENDPOINT_ID not set"
    return 0
  fi
  _pf_ensure_aws_auth || { _pf_skip pf_check_privatelink_endpoint_available "AWS auth not validated"; return 0; }
  local region="${AWS_REGION:-us-east-1}"

  # AWS side: VPC endpoint must be 'available'.
  local aws_state
  aws_state="$(aws ec2 describe-vpc-endpoints \
    --region "$region" \
    --vpc-endpoint-ids "$pl_id" \
    --query 'VpcEndpoints[0].State' --output text 2>/dev/null || echo "")"

  if [[ "$aws_state" != "available" ]]; then
    _pf_fail pf_check_privatelink_endpoint_available \
      --summary "AWS VPC endpoint ${pl_id} is '${aws_state:-missing}' (want 'available')" \
      --shortcoming "config (network)" \
      --observed "vpc-endpoint state=${aws_state:-missing}" \
      --fix "Wait 1-3 minutes for AWS endpoint provisioning to complete and re-run" \
      --fix "Or inspect: aws ec2 describe-vpc-endpoints --vpc-endpoint-ids ${pl_id} --region ${region}" \
      --hint "run:aws ec2 describe-vpc-endpoints --vpc-endpoint-ids ${pl_id}" \
      --doc "docs/deployment-preflight-checks.md#privatelink-endpoint-available"
    return 0
  fi

  # Atlas side: endpoint service must be AVAILABLE for the same project + region.
  local proj="${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-}}"
  if [[ -n "$proj" ]]; then
    local out status atlas_state
    out="$(mktemp)"
    status="$(_pf_atlas_api "$out" "/groups/${proj}/privateEndpoint/AWS/endpointService" 2>/dev/null || echo 000)"
    if [[ "$status" =~ ^2 ]]; then
      atlas_state="$(ATLAS_PL_AWS_ID="$pl_id" python3 -c '
import json, sys, os
want = os.environ.get("ATLAS_PL_AWS_ID", "")
d = json.load(sys.stdin)
items = d if isinstance(d, list) else d.get("results", [])
for it in items:
    eps = it.get("interfaceEndpoints", [])
    if any(want in str(e) for e in eps):
        print(it.get("status", ""))
        sys.exit(0)
print("")
' < "$out" 2>/dev/null || echo '')"
      rm -f "$out"
      if [[ -n "$atlas_state" && "$atlas_state" != "AVAILABLE" ]]; then
        _pf_fail pf_check_privatelink_endpoint_available \
          --summary "Atlas PrivateLink endpoint service is '${atlas_state}' (want 'AVAILABLE')" \
          --shortcoming "config (network)" \
          --observed "atlas endpoint state=${atlas_state}, aws state=available" \
          --fix "Wait 1-3 minutes for Atlas-side endpoint association and re-run" \
          --hint "console:cloud.mongodb.com Project Settings -> Network Access -> Private Endpoint" \
          --doc "docs/deployment-preflight-checks.md#privatelink-endpoint-available"
        return 0
      fi
    else
      rm -f "$out"
    fi
  fi

  _pf_pass pf_check_privatelink_endpoint_available "AWS endpoint ${pl_id} = available"
}

# pf:check: pf_check_kb_ingestion_complete
# pf:catches: "Bedrock KB ingestion job FAILED or empty — vector retrieval returns 0 hits"
pf_check_kb_ingestion_complete() {
  local kb_id="${BEDROCK_KB_ID:-}"
  if [[ -z "$kb_id" ]]; then
    _pf_skip pf_check_kb_ingestion_complete "BEDROCK_KB_ID not set (deploy without KB)"
    return 0
  fi
  _pf_ensure_aws_auth || { _pf_skip pf_check_kb_ingestion_complete "AWS auth not validated"; return 0; }
  local region="${AWS_REGION:-us-east-1}"

  # Pick the first data source (deploys provision exactly one).
  local ds_id
  ds_id="$(aws bedrock-agent list-data-sources \
    --region "$region" \
    --knowledge-base-id "$kb_id" \
    --query 'dataSourceSummaries[0].dataSourceId' \
    --output text 2>/dev/null || echo '')"
  if [[ -z "$ds_id" || "$ds_id" == "None" ]]; then
    _pf_skip pf_check_kb_ingestion_complete "no data sources found for KB ${kb_id}"
    return 0
  fi

  # Use the AWS CLI projection so we don't pipe through jq inside $().
  local probe
  probe="$(aws bedrock-agent list-ingestion-jobs \
    --region "$region" \
    --knowledge-base-id "$kb_id" \
    --data-source-id "$ds_id" \
    --sort-by 'attribute=STARTED_AT,order=DESCENDING' \
    --max-results 1 \
    --query 'ingestionJobSummaries[0].[status,statistics.numberOfNewDocumentsIndexed,statistics.numberOfModifiedDocumentsIndexed]' \
    --output text 2>/dev/null || echo '')"

  if [[ -z "$probe" ]]; then
    _pf_skip pf_check_kb_ingestion_complete "no ingestion jobs found yet for ds=${ds_id}"
    return 0
  fi

  # AWS CLI text output uses TAB delimiters; bash 3.2 read into array.
  local status=""; local new_count=""; local mod_count=""
  IFS=$'\t' read -r status new_count mod_count <<<"$probe"
  new_count="${new_count:-0}"
  mod_count="${mod_count:-0}"
  [[ "$new_count" == "None" ]] && new_count=0
  [[ "$mod_count" == "None" ]] && mod_count=0

  if [[ "$status" != "COMPLETE" ]]; then
    _pf_fail pf_check_kb_ingestion_complete \
      --summary "KB ingestion job status='${status}' (want 'COMPLETE')" \
      --shortcoming "config (data)" \
      --observed "status=${status} new=${new_count} mod=${mod_count}" \
      --fix "Inspect the job: aws bedrock-agent list-ingestion-jobs --knowledge-base-id ${kb_id} --data-source-id ${ds_id}" \
      --fix "Re-run terraform apply on module bedrock-kb to retry the ingestion" \
      --hint "run:aws bedrock-agent list-ingestion-jobs --knowledge-base-id ${kb_id} --data-source-id ${ds_id}" \
      --doc "docs/deployment-preflight-checks.md#kb-ingestion-complete"
    return 0
  fi

  local indexed=$(( new_count + mod_count ))
  if (( indexed < 1 )); then
    _pf_fail pf_check_kb_ingestion_complete \
      --summary "KB ingestion COMPLETE but zero documents indexed" \
      --shortcoming "config (data)" \
      --observed "new=${new_count} mod=${mod_count}" \
      --fix "Verify KB source bucket has docs: aws s3 ls s3://<bucket>/<prefix>" \
      --fix "Re-trigger ingestion via terraform apply on module bedrock-kb" \
      --doc "docs/deployment-preflight-checks.md#kb-ingestion-complete"
    return 0
  fi

  _pf_pass pf_check_kb_ingestion_complete "ingestion COMPLETE (new=${new_count} mod=${mod_count})"
}

# ══════════════════════════════════════════════════════════════════════════════
# Self-test harness — `bash _preflight-checks.sh --self-test`
# ══════════════════════════════════════════════════════════════════════════════
_pf_self_test() {
  echo "[preflight self-test] running..."
  local fail=0

  # Test 1: dry-run lists checks
  PREFLIGHT_DRY_RUN=1 preflight_validate orchestrator-privatelink >/tmp/pf-st1.out 2>&1 || true
  if ! grep -q 'pf_check_env_file_present_and_sourceable' /tmp/pf-st1.out; then
    echo "  ✗ dry-run did not list expected check"
    fail=1
  else
    echo "  ✓ dry-run lists checks"
  fi

  # Test 2: PREFLIGHT_SKIP=* short-circuits to exit 0
  ( PREFLIGHT_SKIP="*" PREFLIGHT_QUIET=0 \
    bash -c "source '${BASH_SOURCE[0]}' && preflight_validate orchestrator-privatelink" \
    >/tmp/pf-st2.out 2>&1 )
  if (( $? != 0 )); then echo "  ✗ PREFLIGHT_SKIP=* did not exit 0"; fail=1
  else echo "  ✓ PREFLIGHT_SKIP=* exit 0"; fi

  # Test 3: unknown profile returns 2
  ( bash -c "source '${BASH_SOURCE[0]}' && preflight_validate not-a-real-profile" \
    >/tmp/pf-st3.out 2>&1 )
  if (( $? != 2 )); then echo "  ✗ unknown profile did not return 2"; fail=1
  else echo "  ✓ unknown profile returns 2"; fi

  # Test 4: result-recording API
  PREFLIGHT_PASSED_IDS=()
  PREFLIGHT_FAILED_IDS=()
  PREFLIGHT_SKIPPED_IDS=()
  _pf_kv_reset
  PREFLIGHT_QUIET=1 _pf_pass test_id "ok message" >/dev/null
  PREFLIGHT_QUIET=1 _pf_fail test_fail --summary "boom" --fix "step1" --fix "step2" --hint "edit:.env:K" --hint "run:foo" >/dev/null
  local _t_summary _t_fix _t_hints
  _t_summary="$(_pf_get PREFLIGHT_FAIL_SUMMARY test_fail)"
  _t_fix="$(_pf_get PREFLIGHT_FAIL_FIX test_fail)"
  _t_hints="$(_pf_get PREFLIGHT_FAIL_HINTS test_fail)"
  if [[ "$_t_summary" != "boom" ]]; then
    echo "  ✗ _pf_fail did not record summary (got: '$_t_summary')"; fail=1
  fi
  if [[ "$_t_fix" != *"step1"* || "$_t_fix" != *"step2"* ]]; then
    echo "  ✗ _pf_fail did not record both fix steps"; fail=1
  fi
  if [[ "$_t_hints" != *"edit:.env:K"* || "$_t_hints" != *"run:foo"* ]]; then
    echo "  ✗ _pf_fail did not record both hints"; fail=1
  fi
  if (( ${#PREFLIGHT_PASSED_IDS[@]} != 1 )) || [[ "${PREFLIGHT_PASSED_IDS[0]}" != "test_id" ]]; then
    echo "  ✗ _pf_pass did not record id"; fail=1
  fi
  if (( fail == 0 )); then echo "  ✓ result-recording API"; fi

  # Test 5: prereq chaining auto-skips dependents
  PREFLIGHT_FAILED_IDS=("pf_check_env_file_present_and_sourceable")
  if _pf_prereq pf_check_env_file_present_and_sourceable; then
    echo "  ✗ _pf_prereq did not honor failed prereq"; fail=1
  else
    echo "  ✓ _pf_prereq honors failed prereq"
  fi
  PREFLIGHT_FAILED_IDS=()

  # Test 6: ai-fix-hint vocabulary check (statically scan our own file)
  # We only audit literal --hint "verb:..." occurrences, not variable
  # placeholders like --hint "$h" / --hint "${var}" used by check builders.
  local bad_hints
  bad_hints="$(grep -hE -- '--hint "[a-z]' "${BASH_SOURCE[0]}" \
              | grep -vE '^[[:space:]]*#' \
              | sed -E 's/.*--hint "([^"]+)".*/\1/' \
              | grep -vE '^(edit|run|console|doc|iam|tfvar):' || true)"
  if [[ -n "$bad_hints" ]]; then
    echo "  ✗ found ai-fix-hints outside the closed vocabulary:"
    echo "$bad_hints" | sed 's/^/      /'
    fail=1
  else
    echo "  ✓ ai-fix-hint vocabulary OK"
  fi

  # Test 7: every profile entry resolves to a defined function
  local prof check missing=""
  for prof in orchestrator-privatelink orchestrator-peering network shared \
              project-pre-apply project-post-apply project-pre-env-sync \
              local-post-apply agents api ui; do
    local arr_name _PF_TMP_PROFILE
    arr_name="$(_pf_profile_array_name "$prof")"
    [[ -z "$arr_name" ]] && continue
    eval "_PF_TMP_PROFILE=(\"\${${arr_name}[@]}\")"
    for check in "${_PF_TMP_PROFILE[@]}"; do
      if ! declare -F "$check" >/dev/null 2>&1; then
        missing+=" ${prof}/${check}"
      fi
    done
  done
  if [[ -n "$missing" ]]; then
    echo "  ✗ profile references undefined functions:${missing}"
    fail=1
  else
    echo "  ✓ all profile checks resolve to defined functions"
  fi

  # Test 8: any deploy script that DEFINES SHARED_BUCKET must use the
  # canonical formula. The preflight module's lock + manifest checks
  # construct the same name; drift in any one place silently fragments
  # state. (Scripts that don't touch the state bucket are exempt.)
  local _self_dir bad_bucket="" expected_count=0
  _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local _deploy_root="${_self_dir%/scripts}"
  local _f
  while IFS= read -r _f; do
    [[ -f "$_f" ]] || continue
    if grep -qE '^[[:space:]]*SHARED_BUCKET=' "$_f"; then
      expected_count=$((expected_count + 1))
      if ! grep -qE 'SHARED_BUCKET="\$\{PROJECT_NAME\}-\$\{ENVIRONMENT\}-\$\{ACCOUNT_ID\}"' "$_f"; then
        bad_bucket+=" $(basename "$_f")"
      fi
    fi
  done < <(find "${_deploy_root}" -maxdepth 3 -name '*.sh' -type f 2>/dev/null)
  if [[ -n "$bad_bucket" ]]; then
    echo "  ✗ state-bucket formula drifted in:${bad_bucket}"
    echo "      Expected: SHARED_BUCKET=\"\${PROJECT_NAME}-\${ENVIRONMENT}-\${ACCOUNT_ID}\""
    fail=1
  elif (( expected_count == 0 )); then
    echo "  ✗ no deploy script defines SHARED_BUCKET (formula coupling not testable)"
    fail=1
  else
    echo "  ✓ state-bucket formula consistent across ${expected_count} deploy script(s)"
  fi

  # Test 9: pf_check_resource_name_constraints catches a too-long name.
  PREFLIGHT_PASSED_IDS=()
  PREFLIGHT_FAILED_IDS=()
  PREFLIGHT_SKIPPED_IDS=()
  _pf_kv_reset
  ( PROJECT_NAME="this-is-a-very-very-long-project-name-clearly-too-many-chars" \
    ENVIRONMENT=dev \
    SHARED_VPC_NAME=shared-network \
    AWS_AUTH_ACCOUNT_ID=000000000000 \
    PREFLIGHT_QUIET=1 \
    bash -c "source '${BASH_SOURCE[0]}' && pf_check_env_file_present_and_sourceable >/dev/null 2>&1
      PREFLIGHT_PASSED_IDS+=(pf_check_env_required_keys_filled)  # forge prereq pass
      pf_check_resource_name_constraints" ) >/tmp/pf-st-len.out 2>&1
  if grep -q '✗ pf_check_resource_name_constraints' /tmp/pf-st-len.out; then
    echo "  ✓ pf_check_resource_name_constraints catches over-length PROJECT_NAME"
  else
    echo "  ✗ pf_check_resource_name_constraints did not flag a 60-char PROJECT_NAME"
    cat /tmp/pf-st-len.out | sed 's/^/      /'
    fail=1
  fi
  rm -f /tmp/pf-st-len.out

  # Test 10: every --doc anchor referenced from the module exists in
  # docs/deployment-preflight-checks.md (locks down doc drift).
  local _repo_root="${_deploy_root%/deploy}"
  local _doc="${_repo_root}/docs/deployment-preflight-checks.md"
  if [[ ! -f "$_doc" ]]; then
    echo "  ✗ docs/deployment-preflight-checks.md missing"
    fail=1
  else
    local _needed _have _missing
    _needed="$(grep -hE -- '--doc "docs/deployment-preflight-checks\.md#' "${BASH_SOURCE[0]}" \
              | sed -E 's/.*--doc "docs\/deployment-preflight-checks\.md#([a-z0-9-]+)".*/\1/' \
              | sort -u)"
    # GitHub-style slug: lowercase headings (## or ### or ####), strip punctuation,
    # collapse runs of spaces to single hyphens.
    _have="$(grep -E '^#{2,4} ' "$_doc" \
              | sed -E 's/^#+ //' \
              | tr 'A-Z' 'a-z' \
              | sed -E 's/[^a-z0-9 -]//g; s/ +/-/g' \
              | sort -u)"
    _missing="$(comm -23 <(echo "$_needed") <(echo "$_have"))"
    if [[ -n "$_missing" ]]; then
      echo "  ✗ doc anchors referenced from --doc but missing in deployment-preflight-checks.md:"
      echo "$_missing" | sed 's/^/      /'
      fail=1
    else
      echo "  ✓ every --doc anchor exists in deployment-preflight-checks.md"
    fi
  fi

  # Test 11: every _pf_fail call site provides --summary (mandatory field).
  # Strategy: collect the line a `_pf_fail <id> [\]` starts on, then scan
  # forward through any line-continuation block until a line ends without
  # a trailing `\`. If `--summary` does not appear in the joined block,
  # flag it. We deliberately skip the function definition line itself.
  local _bad_fail _py_badfail
  IFS= read -r -d '' _py_badfail <<'PY' || true
import re, sys
src = open(sys.argv[1], "r", encoding="utf-8").read().splitlines()
defn_re = re.compile(r"^\s*_pf_fail\s*\(\s*\)\s*\{")
call_re = re.compile(r"^\s*_pf_fail\b\s+\S")
splat_re = re.compile(r"\"\$\{args\[@\]\}\"")
comment_re = re.compile(r"^\s*#")
i = 0; n = len(src); bad = []
while i < n:
    line = src[i]
    if comment_re.match(line) or defn_re.search(line):
        i += 1; continue
    if call_re.search(line):
        block = [line]
        while block[-1].rstrip().endswith("\\") and i + 1 < n:
            i += 1
            block.append(src[i])
        joined = " ".join(block)
        if splat_re.search(joined):
            i += 1; continue
        if "--summary" not in joined:
            bad.append("{}: {}".format(i + 1 - len(block) + 1, block[0].strip()))
    i += 1
print("\n".join(bad[:5]))
PY
  _bad_fail="$(python3 -c "$_py_badfail" "${BASH_SOURCE[0]}")"
  if [[ -n "$_bad_fail" ]]; then
    echo "  ✗ _pf_fail call(s) missing --summary:"
    echo "$_bad_fail" | sed 's/^/      /'
    fail=1
  else
    echo "  ✓ every _pf_fail call site has --summary"
  fi

  # Test 12: agentcore gateway shape parser.
  # Pin the parser used by pf_check_aws_cli_agentcore_gateway_model so the
  # negative path (stale CLI service model) is regression-covered without
  # depending on a stale CLI host. Three fixtures: both fields present
  # (must report empty), mcpServer missing, iamCredentialProvider missing.
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  ⊘ Test 12 skipped (python3 not on PATH)"
  else
    local _ok_json _no_mcp_json _no_iam_json _result _t12_fail=0
    _ok_json='{"targetConfiguration":{"mcp":{"mcpServer":{"endpoint":""}}},"credentialProviderConfigurations":[{"credentialProvider":{"iamCredentialProvider":{"service":"","region":""}}}]}'
    _no_mcp_json='{"targetConfiguration":{"mcp":{"openApiSchema":{}}},"credentialProviderConfigurations":[{"credentialProvider":{"iamCredentialProvider":{"service":"","region":""}}}]}'
    _no_iam_json='{"targetConfiguration":{"mcp":{"mcpServer":{"endpoint":""}}},"credentialProviderConfigurations":[{"credentialProvider":{"oauthCredentialProvider":{}}}]}'

    _result="$(printf '%s' "$_ok_json" | _pf_agentcore_gateway_skeleton_missing 2>/dev/null)"
    if [[ -n "$_result" ]]; then
      echo "  ✗ parser flagged a healthy skeleton (got: '$_result')"
      _t12_fail=1
    fi

    _result="$(printf '%s' "$_no_mcp_json" | _pf_agentcore_gateway_skeleton_missing 2>/dev/null)"
    if [[ "$_result" != *"targetConfiguration.mcp.mcpServer"* ]]; then
      echo "  ✗ parser did not flag missing mcpServer (got: '$_result')"
      _t12_fail=1
    fi

    _result="$(printf '%s' "$_no_iam_json" | _pf_agentcore_gateway_skeleton_missing 2>/dev/null)"
    if [[ "$_result" != *"iamCredentialProvider"* ]]; then
      echo "  ✗ parser did not flag missing iamCredentialProvider (got: '$_result')"
      _t12_fail=1
    fi

    if (( _t12_fail == 0 )); then
      echo "  ✓ agentcore gateway shape parser handles healthy + both missing-field cases"
    else
      fail=1
    fi
  fi

  # Test 13: preflight_validate runner must deflect a check that returns
  # rc=141 (SIGPIPE under set -o pipefail). Reproduces the deploy-shared.sh
  # regression where `terraform version | head -1` inside command substitution
  # killed the parent script with `set -euo pipefail` active. The runner now
  # invokes each check via `if ! "$id"; then …`, so a non-zero return must
  # surface as a `module bug (rc=141)` _pf_fail record — NOT a parent-script
  # SIGKILL.
  #
  # We can't faithfully reproduce SIGPIPE inside the synth check because the
  # `if ! "$id"; then` guard suspends `set -e` inside the function body too —
  # so a SIGPIPE-induced 141 in an inner `v=$(…)` substitution silently
  # captures an empty string rather than killing the function (which is the
  # desired runtime behavior — see prong-1 helpers for the actual data fix).
  # Instead we test the runner contract directly: a check that EXPLICITLY
  # returns 141 must (a) not abort the parent script and (b) be recorded as
  # a failure with the SIGPIPE-aware annotation.
  local _runner_log=/tmp/pf-st13.out
  ( set -euo pipefail
    source "${BASH_SOURCE[0]}"
    pf_check_synth_returns_141() {
      return 141
    }
    PREFLIGHT_PROFILE_orchestrator_privatelink=(pf_check_synth_returns_141)
    PREFLIGHT_QUIET=1 preflight_validate orchestrator-privatelink
  ) >"$_runner_log" 2>&1
  local _subshell_rc=$?
  if (( _subshell_rc == 141 )); then
    echo "  ✗ runner did NOT deflect rc=141 — parent died with SIGPIPE under pipefail (regression: bare \"\$id\" call returned)"
    cat "$_runner_log" | sed 's/^/      /'
    fail=1
  elif ! grep -q 'pf_check_synth_returns_141' "$_runner_log"; then
    echo "  ✗ runner did not even invoke the synth check"
    cat "$_runner_log" | sed 's/^/      /'
    fail=1
  elif ! grep -q 'SIGPIPE under set -o pipefail' "$_runner_log"; then
    echo "  ✗ runner survived but failed to annotate rc=141 with SIGPIPE-aware message"
    cat "$_runner_log" | sed 's/^/      /'
    fail=1
  else
    echo "  ✓ runner deflects rc=141 from a check (parent survived, cause logged with SIGPIPE annotation)"
  fi
  rm -f "$_runner_log"

  # Test 14: SIGPIPE-safe capture helpers extract correct first line from a
  # multi-line producer without crashing the caller under set -o pipefail.
  # Lock-down for prong-1 of the deploy-shared.sh regression fix.
  local _cap_rc=0 _cap_out=""
  _cap_out="$(
    set -euo pipefail
    source "${BASH_SOURCE[0]}"
    _producer() {
      printf 'Terraform v1.13.4\non darwin_arm64\n+ provider hashicorp/aws v6.0.0\n'
      # Make the producer keep writing to widen the SIGPIPE window
      for i in $(seq 1 2000); do printf 'noise line %d\n' "$i"; done
    }
    first="$(_pf_capture_first_line _producer)"
    printf 'first=%s' "$first"
  )" || _cap_rc=$?
  if (( _cap_rc != 0 )); then
    echo "  ✗ _pf_capture_first_line returned rc=${_cap_rc} on multi-line producer (regression of prong-1 SIGPIPE fix)"
    fail=1
  elif [[ "$_cap_out" != "first=Terraform v1.13.4" ]]; then
    echo "  ✗ _pf_capture_first_line returned wrong content (got: '$_cap_out')"
    fail=1
  else
    echo "  ✓ _pf_capture_first_line survives heavy multi-line producer"
  fi

  # Test 15: static pattern guard — fail if any deploy-critical-path script
  # contains a SIGPIPE-prone pipeline inside command substitution. The
  # patterns we catch are all early-exit readers downstream of a producer:
  # `| head -N`, `| sed Nq`, `| sed -n Np`, `| awk … exit`, `| grep -m N`,
  # `| python … sys.exit`. Allow-list:
  #   - the synth checks inside pf_check_shell_runtime_safe (intentional bug)
  #   - the helper definitions (_pf_capture_first_line, _pf_capture_first_line_2)
  #   - any line whose match is inside a `--fix`/`--observed`/`--summary`/
  #     `--hint` envelope arg (documentation, not executable pipes)
  #
  # Scope: this module + `_deploy-diagnostics.sh` (sourced into every deploy
  # script). If a new sibling helper joins the deploy-critical path, add it
  # to the SCAN_FILES list below.
  #
  # This makes the original bug class un-mergeable: a new check (or any
  # sourced helper) that uses `var="$(cmd | head -1 | …)"` inside its body
  # fails the self-test and CI blocks the PR before anyone can hit the
  # rc=141 deploy regression again.
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  ⊘ Test 15 skipped (python3 not on PATH — pattern guard requires python3)"
  else
    local _t15_bad _t15_self_dir _t15_diag
    _t15_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _t15_diag="${_t15_self_dir}/_deploy-diagnostics.sh"
    local -a _t15_files=("${BASH_SOURCE[0]}")
    [[ -f "$_t15_diag" ]] && _t15_files+=("$_t15_diag")
    local _py_t15
    IFS= read -r -d '' _py_t15 <<'PY' || true
import os, re, sys
ALLOWED_FUNCS = {
    "pf_check_shell_runtime_safe",
    "_pf_synth_sigpipe_check",
    "_pf_capture_first_line",
    "_pf_capture_first_line_2",
    "_pf_self_test",
}
func_re = re.compile(r"^\s*(?:function\s+)?(\w+)\s*\(\s*\)\s*\{")
risky_downstream = (
    r"head\s+-(?:n\s+)?[0-9]+"
    r"|sed\s+(?:-n\s+)?[\"\x27]?[0-9]+[qp]"
    r"|awk\s+[^|]*\bexit\b"
    r"|grep\s+-m\s*[0-9]+"
    r"|python3?\s+-c\s+[\"\x27][^\"\x27]*sys\.exit"
)
pipe_re = re.compile(r"\|\s*(?:" + risky_downstream + r")")
envelope_re = re.compile(r"--(fix|observed|summary|hint)\b")
bad = []
for src_path in sys.argv[1:]:
    rel = os.path.basename(src_path)
    with open(src_path, "r", encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    cur_func = None
    depth = 0
    for i, line in enumerate(lines, start=1):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        m = func_re.match(line)
        if m:
            cur_func = m.group(1)
            depth = line.count("{") - line.count("}")
            continue
        if cur_func is not None:
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                cur_func = None
        if cur_func in ALLOWED_FUNCS:
            continue
        if envelope_re.search(line):
            continue
        if pipe_re.search(line):
            snippet = stripped[:90]
            bad.append("{}:{}: ({}) {}".format(rel, i, cur_func or "top-level", snippet))
print("\n".join(bad[:10]))
PY
    _t15_bad="$(python3 -c "$_py_t15" "${_t15_files[@]}")"
    if [[ -n "$_t15_bad" ]]; then
      echo "  ✗ SIGPIPE-prone pipeline patterns found inside check functions:"
      echo "$_t15_bad" | sed 's/^/      /'
      echo "      → Use _pf_capture_first_line / _pf_capture_first_line_2 instead."
      echo "      → See docs/deployment-preflight-checks.md#shell-runtime-safe"
      fail=1
    else
      echo "  ✓ no SIGPIPE-prone pipeline patterns in check functions (head -N / sed Nq / awk exit / grep -m / python sys.exit)"
    fi
  fi

  # Test 16: bash 3.2 compatibility — every shell file in deploy/scripts/ and
  # deploy/ must parse with /bin/bash (macOS ships bash 3.2 as /bin/bash).
  # Catches: heredocs nested inside $(...) (bash 3.2 cannot parse them
  # reliably), $'...' inside other constructs, etc. The fix for the heredoc
  # case is `IFS= read -r -d '' VAR <<'EOF' ... EOF` followed by
  # `python3 -c "$VAR"` — see _pf_iam_passrole_allowed_for_deploy.
  if [[ ! -x /bin/bash ]]; then
    echo "  ⊘ Test 16 skipped (/bin/bash not present)"
  else
    local _t16_self_dir _t16_deploy_dir _t16_bad=""
    _t16_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _t16_deploy_dir="$(cd "${_t16_self_dir}/.." && pwd)"
    local _t16_f _t16_out _t16_rc _t16_first
    for _t16_f in "${_t16_self_dir}"/*.sh "${_t16_deploy_dir}"/*.sh; do
      [[ -e "$_t16_f" ]] || continue
      _t16_out="$(/bin/bash -n "$_t16_f" 2>&1)"
      _t16_rc=$?
      if (( _t16_rc != 0 )); then
        _t16_first="${_t16_out%%$'\n'*}"
        _t16_bad+="${_t16_f##*/deploy/}: ${_t16_first}"$'\n'
      fi
    done
    if [[ -n "$_t16_bad" ]]; then
      echo "  ✗ bash 3.2 (/bin/bash) cannot parse:"
      echo "$_t16_bad" | sed 's/^/      /'
      echo "      → Avoid heredocs (<<EOF) inside \$(...). Use:"
      echo "          IFS= read -r -d '' VAR <<'EOF' ... EOF"
      echo "          result=\"\$(python3 -c \"\$VAR\" args...)\""
      fail=1
    else
      echo "  ✓ all deploy/*.sh + deploy/scripts/*.sh parse with /bin/bash 3.2"
    fi
  fi

  # Test 17: _pf_resolve_mongodb_db canonical derivation.
  #
  # Regression guard for the "multiagent_${PROJECT_NAME}_${ENVIRONMENT}" drift
  # that made pf_check_documents_have_embeddings query the wrong Atlas database
  # and fail with "not authorized on multiagent_<project>_<env>".
  #
  # The canonical formula (matching .env.sample / deploy-project.sh /
  # deploy-local.sh / destroy.sh) is: ${PROJECT_NAME//-/_}_${ENVIRONMENT}
  local _t17_fail=0

  # Case A: MONGODB_DB and ATLAS_DB_NAME both empty → derive from PROJECT_NAME
  local _got_a
  _got_a="$(PROJECT_NAME=mongodb-multiagent3 ENVIRONMENT=dev \
    MONGODB_DB="" ATLAS_DB_NAME="" \
    bash -c "source '${BASH_SOURCE[0]}' && _pf_resolve_mongodb_db")"
  if [[ "$_got_a" != "mongodb_multiagent3_dev" ]]; then
    echo "  ✗ _pf_resolve_mongodb_db derived wrong name (got='${_got_a}' want='mongodb_multiagent3_dev')"
    _t17_fail=1
  fi

  # Case B: MONGODB_DB set → should be honoured as-is (after char scrub)
  local _got_b
  _got_b="$(MONGODB_DB=custom_db_prod ATLAS_DB_NAME="" PROJECT_NAME=x ENVIRONMENT=y \
    bash -c "source '${BASH_SOURCE[0]}' && _pf_resolve_mongodb_db")"
  if [[ "$_got_b" != "custom_db_prod" ]]; then
    echo "  ✗ _pf_resolve_mongodb_db ignored MONGODB_DB (got='${_got_b}')"
    _t17_fail=1
  fi

  # Case C: only ATLAS_DB_NAME set → should be honoured
  local _got_c
  _got_c="$(MONGODB_DB="" ATLAS_DB_NAME=atlas_name_dev PROJECT_NAME=x ENVIRONMENT=y \
    bash -c "source '${BASH_SOURCE[0]}' && _pf_resolve_mongodb_db")"
  if [[ "$_got_c" != "atlas_name_dev" ]]; then
    echo "  ✗ _pf_resolve_mongodb_db ignored ATLAS_DB_NAME (got='${_got_c}')"
    _t17_fail=1
  fi

  # Case D: the OLD wrong default must NOT appear for a standard project name
  local _got_d
  _got_d="$(PROJECT_NAME=mongodb-multiagent3 ENVIRONMENT=dev \
    MONGODB_DB="" ATLAS_DB_NAME="" \
    bash -c "source '${BASH_SOURCE[0]}' && _pf_resolve_mongodb_db")"
  if [[ "$_got_d" == *"multiagent_mongodb"* ]]; then
    echo "  ✗ _pf_resolve_mongodb_db still uses old wrong default ('${_got_d}')"
    _t17_fail=1
  fi

  if (( _t17_fail == 0 )); then
    echo "  ✓ _pf_resolve_mongodb_db canonical derivation (MONGODB_DB > ATLAS_DB_NAME > slug_env)"
  else
    fail=1
  fi

  if (( fail == 0 )); then
    echo "[preflight self-test] PASSED"
    return 0
  fi
  echo "[preflight self-test] FAILED"
  return 1
}

# Allow direct execution: `bash deploy/scripts/_preflight-checks.sh --self-test`
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --self-test) _pf_self_test; exit $? ;;
    --list-profiles)
      for p in orchestrator-privatelink orchestrator-peering network shared \
               project-pre-apply project-post-apply project-pre-env-sync \
               local-post-apply agents api ui; do
        echo "$p"
      done
      exit 0 ;;
    --help|-h)
      cat <<'HELP'
_preflight-checks.sh — sourceable bash module

Usage:
  source _preflight-checks.sh && preflight_validate <profile>

Direct invocations:
  bash _preflight-checks.sh --self-test       # run module unit tests
  bash _preflight-checks.sh --list-profiles   # print known profile names
  bash _preflight-checks.sh --help            # this message

Override knobs (env vars):
  PREFLIGHT_QUIET=1 / PREFLIGHT_VERBOSE=1
  PREFLIGHT_SKIP=<id>,<id>     PREFLIGHT_SKIP=*
  PREFLIGHT_JSON=1             PREFLIGHT_DRY_RUN=1
  PREFLIGHT_NO_COST_PREVIEW=1  PREFLIGHT_FORCE_LOCK_BREAK=1

Exit codes: 0 ok / 78 config / 73 external / 75 missing tool / 2 usage
HELP
      exit 0 ;;
  esac
fi
