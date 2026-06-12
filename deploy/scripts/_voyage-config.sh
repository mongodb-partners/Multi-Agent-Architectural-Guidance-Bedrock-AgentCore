#!/usr/bin/env bash
# _voyage-config.sh — bash SOURCE OF TRUTH for Voyage knowledge in deploy scripts.
#
# Sourceable bash module. Provides:
#   voyage_canonical_body <text> <input_type>   → prints JSON envelope to stdout
#   voyage_supported_models                     → prints space-separated model list
#   voyage_embedding_dims                       → prints embedding dim as bare integer
#   voyage_model_family <model>                 → echoes 'multimodal' or 'text'
#   voyage_assert_multimodal_or_die <model>     → exit 1 if model is not multimodal
#   voyage_sagemaker_endpoint_suffix <value>    → prints SageMaker-safe endpoint suffix
#
# Every deploy script that touches Voyage or embedding-dim knowledge MUST
# source this file rather than hand-roll the body, model list, or dim
# values. Architecture-guard tests + `pf_check_voyage_ssot_only_source`
# fail CI if any script reads these literals directly.
#
# Implementation: shells out to `api/scripts/voyage-print.ts` (the bun
# one-shot that re-exports the TypeScript SSOT in
# `api/src/adapters/voyage-embedding.ts`). Models + dims are cached in
# process globals so each deploy script invocation pays the ~200ms Bun
# startup at most once per knob.
#
# Drift prevention:
#   - api/tests/unit/voyage-ssot-guard.test.ts asserts bash <-> TS parity.
#   - api/tests/unit/voyage-preflight-body-parity.test.ts asserts bash
#     voyage_canonical_body matches TS buildVoyageRequestBody byte-for-byte.
#
# Idempotent sourcing — guarded against double-source.

if [[ -n "${_VOYAGE_CONFIG_SH_SOURCED:-}" ]]; then
  return 0
fi
_VOYAGE_CONFIG_SH_SOURCED=1

# Resolve repo root so the include works regardless of which deploy script
# sourced it. Walks up from this file's directory.
_VOYAGE_CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VOYAGE_REPO_ROOT="$(cd "$_VOYAGE_CFG_DIR/../.." && pwd)"
_VOYAGE_PRINT_TS="$_VOYAGE_REPO_ROOT/api/scripts/voyage-print.ts"

_vc_err() { echo "  [voyage-config] ✗ $*" >&2; }

# Per-invocation caches so we run bun once per knob per deploy script.
_VOYAGE_MODELS_CACHE=""
_VOYAGE_DIMS_CACHE=""

# Ensure `bun` is on PATH. Many of our deploy scripts add ~/.bun/bin
# already but this guard makes the helper usable on its own.
_voyage_require_bun() {
  if ! command -v bun >/dev/null 2>&1; then
    if [[ -x "$HOME/.bun/bin/bun" ]]; then
      export PATH="$HOME/.bun/bin:$PATH"
    fi
  fi
  if ! command -v bun >/dev/null 2>&1; then
    _vc_err "bun not found on PATH and not at ~/.bun/bin/bun — install Bun before sourcing _voyage-config.sh"
    return 1
  fi
  if [[ ! -f "$_VOYAGE_PRINT_TS" ]]; then
    _vc_err "voyage-print.ts not found at $_VOYAGE_PRINT_TS — repo layout drift"
    return 1
  fi
}

# voyage_canonical_body <text> <input_type>
# Prints the canonical SageMaker multimodal envelope for a single-text-segment
# payload. Used by preflight smoke + parity test. NOT cached (body depends
# on input).
voyage_canonical_body() {
  local text="$1"
  local input_type="${2:-document}"
  if [[ -z "$text" ]]; then
    _vc_err "voyage_canonical_body: <text> is required"
    return 1
  fi
  _voyage_require_bun || return 1
  bun "$_VOYAGE_PRINT_TS" body "$text" "$input_type"
}

# voyage_supported_models
# Prints the space-separated list of supported Voyage models exactly as
# declared in SUPPORTED_VOYAGE_MODELS in api/src/adapters/voyage-embedding.ts.
voyage_supported_models() {
  if [[ -z "$_VOYAGE_MODELS_CACHE" ]]; then
    _voyage_require_bun || return 1
    _VOYAGE_MODELS_CACHE="$(bun "$_VOYAGE_PRINT_TS" models)" || return 1
  fi
  printf '%s' "$_VOYAGE_MODELS_CACHE"
}

# voyage_embedding_dims
# Prints the resolved embedding dim (an integer) from the TS SSOT — the env
# override when set, else the default (1024). Tracks the env automatically
# because it shells out to `voyage-print.ts dims` (getVoyageEmbeddingDims()).
voyage_embedding_dims() {
  if [[ -z "$_VOYAGE_DIMS_CACHE" ]]; then
    _voyage_require_bun || return 1
    _VOYAGE_DIMS_CACHE="$(bun "$_VOYAGE_PRINT_TS" dims)" || return 1
  fi
  printf '%s' "$_VOYAGE_DIMS_CACHE"
}

# voyage_sagemaker_endpoint_suffix <value>
# Normalizes a model-derived string into a SageMaker endpoint-name fragment.
# SageMaker endpoint names allow alphanumerics and hyphens; model names such as
# `voyage-multimodal-3.5` need the dot converted before Terraform creates the
# endpoint.
voyage_sagemaker_endpoint_suffix() {
  printf '%s' "${1:-}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'
}

# voyage_model_family <model>
# Echoes 'multimodal' if <model> is in the SSOT supported list, else 'text'.
# Used by preflight + deploy scripts to keep family classification
# in lockstep with the TS SSOT.
voyage_model_family() {
  local needle="$1"
  if [[ -z "$needle" ]]; then
    echo "text"
    return 0
  fi
  local m
  for m in $(voyage_supported_models); do
    if [[ "$needle" == "$m" ]]; then
      echo "multimodal"
      return 0
    fi
  done
  echo "text"
}

# voyage_assert_multimodal_or_die <model>
# Exits 1 with a clear error if <model> is not a multimodal model.
# Used by preflight/deploy validation before accepting any Voyage ARN so an
# operator cannot accidentally configure a text-only Voyage listing
# (voyage-3-5-lite, voyage-3, voyage-4 ...) while the stack expects multimodal.
voyage_assert_multimodal_or_die() {
  local model="$1"
  if [[ -z "$model" ]]; then
    _vc_err "voyage_assert_multimodal_or_die: model name is required"
    return 1
  fi
  local family
  family="$(voyage_model_family "$model")"
  if [[ "$family" != "multimodal" ]]; then
    _vc_err "Voyage model '$model' is not multimodal."
    _vc_err "This stack is multimodal-only."
    _vc_err "Supported models: $(voyage_supported_models)"
    _vc_err "Re-run with --model voyage-multimodal-3 (or voyage-multimodal-3.5)."
    return 1
  fi
}
