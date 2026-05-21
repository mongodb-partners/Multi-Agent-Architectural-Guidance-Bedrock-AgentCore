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
  pf_check_resource_name_constraints
  pf_check_env_aws_region_consistency
  pf_check_aws_region_agentcore
  pf_check_atlas_api_keys_present
  pf_check_atlas_api_health
  pf_check_atlas_api_key_scope
  pf_check_atlas_cluster_tier
  pf_check_tool_versions
  pf_check_clock_skew
  pf_check_session_manager_plugin
  pf_check_docker_buildx
  pf_check_disk_and_docker_resources
  pf_check_network_egress
  pf_check_atlas_privatelink_no_orphans
  pf_check_atlas_project_quota
  pf_check_voyage_marketplace_subscribed
  pf_check_bedrock_model_access
  pf_check_bedrock_service_quotas
  pf_check_iam_deploy_actions
  pf_check_aws_service_limits
  pf_advise_cost_and_duration
)

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
  pf_check_aws_region_agentcore
  pf_check_tool_versions
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
  pf_check_clock_skew
  pf_check_disk_and_docker_resources
  pf_check_docker_buildx
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
  pf_check_vector_indexes_present
  pf_check_documents_have_embeddings
  pf_check_embedding_dim_consistency
)

PREFLIGHT_PROFILE_project_pre_env_sync=(
  pf_check_env_live_required_keys
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
  pf_check_docker_buildx
  pf_check_session_manager_plugin
)

PREFLIGHT_PROFILE_ui=(
  pf_check_env_file_present_and_sourceable
  pf_check_tool_versions
  pf_check_concurrent_deploy_lock
  pf_check_deploy_manifest_present
  pf_check_docker_buildx
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
    # result, surface it as a failure so accounting cannot drift silently.
    pre_pass=${#PREFLIGHT_PASSED_IDS[@]}
    pre_fail=${#PREFLIGHT_FAILED_IDS[@]}
    pre_skip=${#PREFLIGHT_SKIPPED_IDS[@]}
    "$id"
    rc=$?
    if (( ${#PREFLIGHT_PASSED_IDS[@]}  == pre_pass &&
          ${#PREFLIGHT_FAILED_IDS[@]}  == pre_fail &&
          ${#PREFLIGHT_SKIPPED_IDS[@]} == pre_skip )); then
      _pf_fail "$id" \
        --summary "check function returned without recording a result (rc=${rc})" \
        --shortcoming "module bug" \
        --observed "no _pf_pass / _pf_fail / _pf_skip call before return" \
        --fix "Open deploy/scripts/_preflight-checks.sh, search for ${id}, and ensure every code path calls one of the three result helpers" \
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
  if [[ "${AUTH_MODE:-iam}" == "sts" ]]; then
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
  local server_date local_date drift_s
  if ! server_date="$(curl -sI --max-time 5 https://sts.amazonaws.com 2>/dev/null | awk -F': ' '/^[Dd]ate:/ {print $2; exit}' | tr -d '\r')"; then
    _pf_skip pf_check_clock_skew "could not reach https://sts.amazonaws.com to read Date header"
    return 0
  fi
  if [[ -z "$server_date" ]]; then
    _pf_skip pf_check_clock_skew "STS Date header empty (no network?)"
    return 0
  fi
  if ! drift_s="$(python3 - <<PY 2>/dev/null
import datetime, email.utils, time
s = email.utils.parsedate_to_datetime("${server_date}").timestamp()
print(int(abs(time.time() - s)))
PY
)"; then
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
    v="$(session-manager-plugin --version 2>/dev/null | head -1 | tr -d '[:space:]')"
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

# pf:check: pf_check_docker_buildx
# pf:catches: "docker buildx missing — ARM64 multi-platform build fails opaquely"
# pf:source:  new-user friction (operator machine)
pf_check_docker_buildx() {
  # Only required when docker is on PATH and reachable
  if ! command -v docker >/dev/null 2>&1; then
    _pf_skip pf_check_docker_buildx "docker not on PATH (skip-docker scenario)"
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    _pf_skip pf_check_docker_buildx "docker daemon not reachable"
    return 0
  fi
  if ! docker buildx version >/dev/null 2>&1; then
    _pf_fail pf_check_docker_buildx \
      --summary "docker buildx is not available (linux/arm64 builds will fail)" \
      --shortcoming "new-user friction (operator machine)" \
      --observed "'docker buildx version' returned non-zero" \
      --fix "Install Docker Desktop (which bundles buildx) or 'docker buildx install'" \
      --fix "On Linux without Docker Desktop: docker buildx create --use --name multiagent-builder" \
      --hint "doc:docs/deployment-preflight-checks.md#docker-buildx" \
      --doc "docs/deployment-preflight-checks.md#docker-buildx" \
      --exit-class tool
    return 0
  fi
  if ! docker buildx ls 2>/dev/null | grep -qE 'linux/(arm64|amd64)'; then
    _pf_warn "docker buildx is installed but no multi-platform builder is active. Run: docker buildx create --use"
  fi
  _pf_pass pf_check_docker_buildx "buildx available"
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
  # Docker memory (only when daemon reachable)
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local mem_bytes mem_gb
    mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
    if [[ "$mem_bytes" =~ ^[0-9]+$ ]]; then
      mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
      if (( mem_gb < 4 )); then
        if [[ "${PREFLIGHT_STRICT_LOCAL_RESOURCES:-0}" != "1" ]]; then
          _pf_warn "Docker has ${mem_gb} GB total memory (recommend ≥ 4 GB for local image builds). Continuing because existing deploy/redeploy paths may not need a fresh local build."
          _pf_pass pf_check_disk_and_docker_resources "disk_free=${disk_free_gb:-?}GB docker_mem=${mem_gb}GB (warning only)"
          return 0
        fi
        _pf_fail pf_check_disk_and_docker_resources \
          --summary "Docker has ${mem_gb} GB total memory (multi-platform buildx needs ≥ 4 GB)" \
          --shortcoming "new-user friction (operator machine)" \
          --observed "docker info MemTotal=${mem_gb}GB" \
          --fix "Open Docker Desktop → Settings → Resources → Memory and raise to 4 GB+" \
          --hint "doc:docs/deployment-preflight-checks.md#local-prerequisites" \
          --doc "docs/deployment-preflight-checks.md#local-prerequisites" \
          --exit-class tool
        return 0
      fi
    fi
  fi
  _pf_pass pf_check_disk_and_docker_resources "disk_free=${disk_free_gb:-?}GB"
}

# pf:check: pf_check_aws_service_limits
# pf:catches: "Account-level VPC/EIP/SageMaker/Cognito quotas below floor"
# pf:source:  new-user friction (account quotas)
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

# pf:check: pf_check_tool_versions
# pf:catches: "Tool present but version too old (terraform/bun/aws/python/docker/jq)"
pf_check_tool_versions() {
  local skip_docker="${SKIP_DOCKER:-false}"
  local -a problems=() hints=()

  _pf_ver_at_least() {
    # Compare semver-ish. Args: <name> <found> <min>
    local name="$1" found="$2" min="$3"
    local cmp
    cmp="$(python3 - "$found" "$min" <<'PY'
import sys, re
def parse(s):
    s = s.strip()
    nums = re.findall(r'\d+', s)
    return tuple(int(x) for x in nums[:3]) if nums else (0,)
print("ge" if parse(sys.argv[1]) >= parse(sys.argv[2]) else "lt")
PY
)"
    [[ "$cmp" == "ge" ]]
  }

  local v
  if command -v terraform >/dev/null 2>&1; then
    v="$(terraform version 2>/dev/null | head -1 | awk '{print $2}' | tr -d v)"
    _pf_ver_at_least terraform "$v" 1.6 || { problems+=("terraform ${v} < 1.6"); hints+=("doc:docs/deployment-guide.md#prerequisites"); }
  else
    problems+=("terraform not on PATH")
    hints+=("doc:docs/deployment-guide.md#prerequisites")
  fi
  if command -v bun >/dev/null 2>&1; then
    v="$(bun --version 2>/dev/null | head -1)"
    _pf_ver_at_least bun "$v" 1.1 || { problems+=("bun ${v} < 1.1"); hints+=("doc:docs/deployment-guide.md#prerequisites"); }
  else
    problems+=("bun not on PATH")
    hints+=("doc:docs/deployment-guide.md#prerequisites")
  fi
  if command -v aws >/dev/null 2>&1; then
    v="$(aws --version 2>&1 | head -1 | awk '{print $1}' | awk -F/ '{print $2}')"
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
    v="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',v')"
    _pf_ver_at_least docker "$v" 24 || { problems+=("docker ${v} < 24"); hints+=("doc:docs/deployment-guide.md#prerequisites"); }
  fi
  if command -v jq >/dev/null 2>&1; then
    v="$(jq --version 2>/dev/null | head -1 | tr -d 'jq-')"
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
        --observed "$(echo "$out" | head -1)" \
        --fix "Open the Bedrock console: https://${region}.console.aws.amazon.com/bedrock/home?region=${region}#/modelaccess" \
        --fix "Click 'Manage model access', enable Anthropic Claude Sonnet 4 (and Voyage embeddings if EMBEDDINGS_PROVIDER=voyage)" \
        --fix "Approval is usually instant for Anthropic models; retry the deploy after the status flips to 'Access granted'" \
        --hint "console:https://${region}.console.aws.amazon.com/bedrock/home?region=${region}#/modelaccess" \
        --doc "docs/deployment-preflight-checks.md#bedrock-model-access"
      return 0
    fi
    _pf_warn "bedrock get-foundation-model failed for non-access reason: $(echo "$out" | head -1)"
  fi
  _pf_pass pf_check_bedrock_model_access "model ${strip_inference} accessible in ${region}"
}

# pf:check: pf_check_bedrock_service_quotas
# pf:catches: "Bedrock TPM/RPM quotas at floor — first turn 429s"
pf_check_bedrock_service_quotas() {
  _pf_ensure_aws_auth || { _pf_skip pf_check_bedrock_service_quotas "AWS auth not validated"; return 0; }
  local region="${AWS_REGION:-us-east-1}"
  # We cannot reliably enumerate Bedrock per-model quotas via the Quotas API in
  # all regions (codes vary). Probe two well-known ones; if both come back as
  # default (low) values, surface a warning rather than a fail. This check is
  # advisory: it never sets exit-class config.
  local out_rpm out_tpm rpm_value tpm_value
  # Bedrock quota names vary across regions/launches:
  #   "On-demand model inference requests per minute for Anthropic Claude 3 Sonnet"
  #   "Cross-region model inference requests per minute for Anthropic Claude Sonnet 4"
  #   etc. We match on Anthropic|Claude family + RPM|TPM dimension.
  local _quota_json
  _quota_json="$(aws service-quotas list-service-quotas --region "$region" --service-code bedrock --output json 2>/dev/null || echo '{}')"
  out_rpm="$(echo "$_quota_json" | python3 -c '
import json, sys
try:
    q = json.load(sys.stdin).get("Quotas", []) or []
except Exception:
    q = []
hits = [x for x in q if (("Anthropic" in x.get("QuotaName","") or "Claude" in x.get("QuotaName","")) and "requests per minute" in x.get("QuotaName","").lower())]
print(int(min(h["Value"] for h in hits))) if hits else print("")
' 2>/dev/null || echo '')"
  out_tpm="$(echo "$_quota_json" | python3 -c '
import json, sys
try:
    q = json.load(sys.stdin).get("Quotas", []) or []
except Exception:
    q = []
hits = [x for x in q if (("Anthropic" in x.get("QuotaName","") or "Claude" in x.get("QuotaName","")) and "tokens per minute" in x.get("QuotaName","").lower())]
print(int(min(h["Value"] for h in hits))) if hits else print("")
' 2>/dev/null || echo '')"
  rpm_value="${out_rpm:-?}"
  tpm_value="${out_tpm:-?}"
  if [[ "$rpm_value" == "?" && "$tpm_value" == "?" ]]; then
    _pf_pass pf_check_bedrock_service_quotas "service-quotas API didn't enumerate Bedrock entries (advisory check skipped)"
    return 0
  fi
  if [[ "$rpm_value" =~ ^[0-9]+$ ]] && (( rpm_value < 50 )); then
    _pf_warn "Bedrock RPM quota for Claude in ${region} is ${rpm_value}/min (recommend ≥ 50). Open https://${region}.console.aws.amazon.com/servicequotas/home/services/bedrock/quotas to request an increase."
  fi
  if [[ "$tpm_value" =~ ^[0-9]+$ ]] && (( tpm_value < 50000 )); then
    _pf_warn "Bedrock TPM quota for Claude in ${region} is ${tpm_value}/min (recommend ≥ 50,000). Same console link as above."
  fi
  _pf_pass pf_check_bedrock_service_quotas "RPM=${rpm_value} TPM=${tpm_value}"
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
    # IAM
    "iam:CreateRole" "iam:DeleteRole" "iam:PassRole" "iam:AttachRolePolicy"
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
    # Logs / KMS / Secrets
    "logs:CreateLogGroup" "logs:PutRetentionPolicy" "kms:CreateKey" "kms:Decrypt"
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
    out="$(aws iam simulate-principal-policy \
      --policy-source-arn "$arn" \
      --action-names "${this_batch[@]}" \
      --output json 2>&1)"
    rc=$?
    if (( rc != 0 )); then
      if echo "$out" | grep -qiE 'AccessDenied|not authorized.*SimulatePrincipalPolicy'; then
        _pf_warn "Caller cannot self-introspect via iam:SimulatePrincipalPolicy. Skipping comprehensive IAM simulation. Add 'iam:SimulatePrincipalPolicy' to the deploy policy for full coverage."
        _pf_pass pf_check_iam_deploy_actions "skipped (no iam:SimulatePrincipalPolicy)"
        return 0
      fi
      _pf_warn "iam:SimulatePrincipalPolicy failed (batch $((i/batch_size+1))): $(echo "$out" | head -1)"
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
  if (( ${#denied[@]} == 0 )); then
    _pf_pass pf_check_iam_deploy_actions "all ${total} required actions allowed for ${arn}"
    return 0
  fi

  local -a hard_denied=() advisory_denied=()
  local d decision
  for d in "${denied[@]}"; do
    decision="${d#*$'\t'}"
    case "$decision" in
      explicitDeny|"SCP DENY") hard_denied+=("$d") ;;
      *) advisory_denied+=("$d") ;;
    esac
  done

  if (( ${#hard_denied[@]} == 0 )); then
    local a
    for a in "${advisory_denied[@]}"; do
      _pf_warn "iam:SimulatePrincipalPolicy returned ${a}; treating implicit denies as advisory because resource-scoped policies can simulate as denied even when an existing-stack redeploy works."
    done
    _pf_pass pf_check_iam_deploy_actions "no explicit/SCP deny detected (${#advisory_denied[@]} advisory implicit deny result(s))"
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
  tier="$(python3 - "$out" <<'PY' 2>/dev/null
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
# Legacy provider settings (v1.0 shape)
ps = d.get("providerSettings") or {}
if ps.get("instanceSizeName"):
    print(ps["instanceSizeName"]); sys.exit(0)
# v2 shape — walk replicationSpecs → regionConfigs → priority spec.
for rs in d.get("replicationSpecs", []) or []:
    for rc in rs.get("regionConfigs", []) or []:
        for key in ("electableSpecs", "readOnlySpecs", "analyticsSpecs"):
            spec = rc.get(key) or {}
            size = spec.get("instanceSize")
            if size:
                print(size); sys.exit(0)
print("")
PY
)"
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
  orphans="$(ATLAS_REGION="$atlas_region" python3 - "$out" <<'PY' 2>/dev/null || true
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
)"
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
      --fix "Re-seed the chunks collection for the new provider OR revert EMBEDDINGS_PROVIDER" \
      --fix "Re-seed: bun db-seeding/seed-indexes.ts && bun db-seeding/seed-knowledge-base.ts" \
      --hint "run:bun db-seeding/seed-indexes.ts" \
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
  local k v
  for k in "${required[@]}"; do
    v="$(grep -E "^${k}=" "$f" 2>/dev/null | head -1 | sed 's/^[^=]*=//')"
    [[ -z "$v" ]] && missing+=("$k")
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

# pf:check: pf_check_documents_have_embeddings
# pf:catches: "Seed completed but provider misconfig left embedding=null on every doc"
pf_check_documents_have_embeddings() {
  if [[ -z "${MONGODB_URI:-}" && -z "${MONGODB_URI_PUBLIC:-}" ]]; then
    _pf_skip pf_check_documents_have_embeddings "no MONGODB_URI / MONGODB_URI_PUBLIC available (run after deploy-api.sh writes .env.live)"
    return 0
  fi
  local uri="${MONGODB_URI_PUBLIC:-${MONGODB_URI:-}}"
  local db="${MONGODB_DB:-multiagent_${PROJECT_NAME:-multiagent}_${ENVIRONMENT:-dev}}"
  db="${db//[^a-zA-Z0-9_]/_}"
  local n_total="?" n_with_emb="?"

  if command -v mongosh >/dev/null 2>&1; then
    n_total="$(mongosh "$uri" --quiet --eval "db.getSiblingDB('${db}').products.countDocuments({})" 2>/dev/null || echo '?')"
    n_with_emb="$(mongosh "$uri" --quiet --eval "db.getSiblingDB('${db}').products.countDocuments({embedding:{\$exists:true}})" 2>/dev/null || echo '?')"
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import pymongo' >/dev/null 2>&1; then
    # Fallback: Python + pymongo (often already installed for the seeders).
    local _py_out
    _py_out="$(MONGODB_URI="$uri" MONGODB_DB="$db" python3 - <<'PY' 2>/dev/null
import os, sys
try:
    import pymongo
    c = pymongo.MongoClient(os.environ["MONGODB_URI"], serverSelectionTimeoutMS=5000)
    coll = c[os.environ["MONGODB_DB"]]["products"]
    print(f"{coll.count_documents({})}\t{coll.count_documents({'embedding': {'$exists': True}})}")
except Exception as e:
    print(f"?\t?")
PY
)"
    n_total="$(echo "$_py_out" | awk -F'\t' '{print $1}')"
    n_with_emb="$(echo "$_py_out" | awk -F'\t' '{print $2}')"
  else
    _pf_skip pf_check_documents_have_embeddings "neither mongosh nor python3+pymongo available — install one to enable this check (brew install mongosh OR pip install pymongo)"
    return 0
  fi

  if [[ "$n_total" == "0" || "$n_total" == "?" ]]; then
    _pf_skip pf_check_documents_have_embeddings "products collection empty or unreachable (n=${n_total})"
    return 0
  fi
  if [[ "$n_with_emb" =~ ^[0-9]+$ ]] && (( n_with_emb < n_total )); then
    local missing=$(( n_total - n_with_emb ))
    _pf_fail pf_check_documents_have_embeddings \
      --summary "${missing}/${n_total} documents in 'products' have no embedding field" \
      --shortcoming "config (data)" \
      --observed "n_total=${n_total} n_with_embedding=${n_with_emb}" \
      --fix "Re-run: bun db-seeding/seed-knowledge-base.ts (forces embedding regeneration)" \
      --hint "run:bun db-seeding/seed-knowledge-base.ts" \
      --doc "docs/deployment-preflight-checks.md#documents-have-embeddings"
    return 0
  fi
  _pf_pass pf_check_documents_have_embeddings "all ${n_total} products have embeddings"
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
              agents api ui; do
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
  local _bad_fail
  _bad_fail="$(python3 - "${BASH_SOURCE[0]}" <<'PY'
import re, sys
src = open(sys.argv[1], "r", encoding="utf-8").read().splitlines()
# Skip the function definition line and any comment line.
defn_re = re.compile(r"^\s*_pf_fail\s*\(\s*\)\s*\{")
call_re = re.compile(r"^\s*_pf_fail\b\s+\S")  # call must be at start (after indent)
splat_re = re.compile(r'"\$\{args\[@\]\}"')   # splat callers build args=(--summary ...) explicitly
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
            bad.append(f"{i+1-len(block)+1}: {block[0].strip()}")
    i += 1
print("\n".join(bad[:5]))
PY
)"
  if [[ -n "$_bad_fail" ]]; then
    echo "  ✗ _pf_fail call(s) missing --summary:"
    echo "$_bad_fail" | sed 's/^/      /'
    fail=1
  else
    echo "  ✓ every _pf_fail call site has --summary"
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
               project-pre-apply project-post-apply project-pre-env-sync agents api ui; do
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
