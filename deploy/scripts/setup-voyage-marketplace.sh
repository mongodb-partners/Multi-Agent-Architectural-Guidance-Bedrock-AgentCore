#!/usr/bin/env bash
# setup-voyage-marketplace.sh — one-time setup for Voyage AI on a new AWS account
#
# What this does:
#   1. Verifies AWS credentials are loaded and valid.
#   2. Checks whether this AWS account is already subscribed to a Voyage AI
#      model package on AWS Marketplace (default: voyage-3).
#   3. If NOT subscribed — opens the Marketplace listing in your browser and
#      polls until you've accepted the EULA.
#   4. Once subscribed — discovers the model package ARN via SageMaker.
#   5. Optionally:
#        - Appends / updates VOYAGE_MODEL_PACKAGE_ARN in .env
#        - Pushes VOYAGE_MODEL_PACKAGE_ARN to GitHub Secrets (for CI)
#
# Subscription itself cannot be automated — it requires clicking "Accept Terms"
# in the AWS console. Everything else is CLI-driven.
#
# Usage:
#   ./deploy/scripts/setup-voyage-marketplace.sh                     # interactive
#   ./deploy/scripts/setup-voyage-marketplace.sh --model voyage-3    # specific model
#   ./deploy/scripts/setup-voyage-marketplace.sh --skip-env --skip-gh
#
# One-time. Re-run safely — it's idempotent (won't duplicate .env lines).

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# Default to the SoW model, but keep voyage-3-5-lite as a supported legacy
# option for lower-cost/text-only deployments.
MODEL="${VOYAGE_MARKETPLACE_MODEL:-voyage-multimodal-3}"
MODEL_FROM_ARGS=false
REQUIRE_VOYAGE_MULTIMODAL_3="${REQUIRE_VOYAGE_MULTIMODAL_3:-false}"
AWS_REGION="${AWS_REGION:-us-east-1}"
UPDATE_ENV=true
UPDATE_GH=true
GH_REPO="PeerIslands/mongodb-aws-bedrock-multi-agent-framework"

# Voyage AI's AWS Marketplace seller account (model packages are published here).
# Note: as of 2026 MongoDB is the official publisher; the underlying account ARN
# stays the same.
VOYAGE_VENDOR_ACCOUNT="865070037744"

# Per-model Marketplace landing pages — resolved after `--model` is parsed.
declare -A MARKETPLACE_URLS=(
  [voyage-multimodal-3]="https://aws.amazon.com/marketplace/pp/prodview-hrid2zxusacxy"
  [voyage-3-5-lite]="https://aws.amazon.com/marketplace/pp/prodview-xj76cqxng4wyw"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)     MODEL="$2"; MODEL_FROM_ARGS=true; shift ;;
    --region)    AWS_REGION="$2"; shift ;;
    --env-file)  ENV_FILE="$2"; shift ;;
    --gh-repo)   GH_REPO="$2"; shift ;;
    --skip-env)  UPDATE_ENV=false ;;
    --skip-gh)   UPDATE_GH=false ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "  [voyage] Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "  [voyage] $*"; }
ok()   { echo "  [voyage] ✓ $*"; }
err()  { echo "  [voyage] ✗ $*" >&2; exit 1; }
warn() { echo "  [voyage] ⚠ $*"; }
sep()  { echo "────────────────────────────────────────────────"; }

open_url() {
  # macOS 'open', Linux 'xdg-open', WSL 'cmd.exe /c start'. No-op if none work.
  if   command -v open      >/dev/null 2>&1; then open "$1"
  elif command -v xdg-open  >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1
  else log "Open in browser: $1"
  fi
}

# ── Phase 1 — Preflight ───────────────────────────────────────────────────────
sep
log "Phase 1 — Preflight checks..."

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || err "'$cmd' not found in PATH"
done

# Load .env so AWS creds are available (don't require the user to have sourced it).
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  log "Sourced $ENV_FILE"
else
  warn ".env not found at $ENV_FILE — relying on current shell's AWS creds"
fi

if [[ "$MODEL_FROM_ARGS" != "true" ]]; then
  MODEL="${VOYAGE_MARKETPLACE_MODEL:-$MODEL}"
fi
MARKETPLACE_URL="${MARKETPLACE_URLS[$MODEL]:-https://aws.amazon.com/marketplace/seller-profile?id=c9032c7b-70dd-459f-834f-c1e23cf3d092}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || err "AWS credentials invalid or expired. Run: source .env"
ok "AWS account: $ACCOUNT_ID (region: $AWS_REGION)"

# Optional SoW guard — fail fast on any silent deviation from voyage-multimodal-3.
if [[ "$REQUIRE_VOYAGE_MULTIMODAL_3" == "true" && "$MODEL" != "voyage-multimodal-3" ]]; then
  err "Refusing to subscribe to '$MODEL' — SoW pins this stack to 'voyage-multimodal-3'.
     To override, re-run with REQUIRE_VOYAGE_MULTIMODAL_3=false (requires written sign-off)."
fi
if [[ ! "$MODEL" =~ ^voyage- ]]; then
  err "Unsupported model '$MODEL'. Voyage model labels must start with 'voyage-'."
fi
if [[ -z "${MARKETPLACE_URLS[$MODEL]:-}" ]]; then
  warn "No dedicated Marketplace URL configured for '$MODEL' — opening the Voyage seller page."
fi
ok "Target Voyage model: $MODEL"

# ── Phase 2 — Check subscription state ────────────────────────────────────────
sep
log "Phase 2 — Checking Marketplace subscription for '$MODEL'..."

model_package_groups() {
  # Voyage's public model name is voyage-multimodal-3, but some Marketplace
  # package groups use a voyage-multimodel-3-updated-* tail.
  case "$MODEL" in
    voyage-multimodal-3)
      printf '%s\n' "voyage-multimodal-3" "voyage-multimodel-3-updated"
      ;;
    *)
      printf '%s\n' "$MODEL"
      ;;
  esac
}

discover_arn() {
  # Returns the latest approved model-package ARN for $MODEL, or empty string.
  local group arn
  while IFS= read -r group; do
    arn="$(aws sagemaker list-model-packages \
      --region "$AWS_REGION" \
      --model-package-group-name "$group" \
      --model-approval-status Approved \
      --sort-by CreationTime --sort-order Descending \
      --query 'ModelPackageSummaryList[0].ModelPackageArn' \
      --output text 2>/dev/null || echo "")"
    [[ "$arn" == "None" ]] && arn=""
    if [[ -n "$arn" ]]; then
      echo "$arn"
      return 0
    fi
  done < <(model_package_groups)
  echo ""
}

ARN="$(discover_arn)"
[[ "$ARN" == "None" ]] && ARN=""

if [[ -n "$ARN" ]]; then
  ok "Already subscribed — found model package"
  echo "  ARN: $ARN"
else
  # ── Phase 2a — Not subscribed: walk the user through Marketplace ────────────
  sep
  warn "No approved '$MODEL' model package visible in this account."
  echo ""
  echo "  You need to subscribe to Voyage AI on AWS Marketplace (one-time,"
  echo "  requires clicking \"Accept Terms\" in the AWS console). The subscription"
  echo "  itself is free — you only pay when a SageMaker endpoint is running."
  echo ""
  echo "  1. Opening: $MARKETPLACE_URL"
  echo "  2. In your browser:"
  echo "       a. Find the '$MODEL' product listing"
  echo "       b. Click \"Continue to Subscribe\""
  echo "       c. Click \"Accept Terms\" (EULA)"
  echo "       d. Wait for \"Subscription effective date\" to populate"
  echo "  3. Come back here and press Enter to re-check."
  echo ""

  open_url "$MARKETPLACE_URL"

  for attempt in 1 2 3 4 5; do
    read -r -p "  Press Enter to re-check (attempt $attempt/5)... " _
    ARN="$(discover_arn)"
    [[ "$ARN" == "None" ]] && ARN=""
    if [[ -n "$ARN" ]]; then
      ok "Subscription detected!"
      echo "  ARN: $ARN"
      break
    fi
    warn "Still not visible. Marketplace can take ~30-60 seconds to propagate."
  done

  if [[ -z "$ARN" ]]; then
    err "Gave up after 5 attempts. Once subscribed, re-run this script."
  fi
fi

# Sanity-check the ARN format
if [[ ! "$ARN" =~ ^arn:aws:sagemaker:[a-z0-9-]+:[0-9]+:model-package/ ]]; then
  err "Discovered ARN doesn't look right: $ARN"
fi

# ── Phase 3 — Verify we can describe the package ──────────────────────────────
sep
log "Phase 3 — Verifying describe access..."
PKG_JSON="$(aws sagemaker describe-model-package \
  --region "$AWS_REGION" \
  --model-package-name "$ARN" 2>&1)" \
  || err "describe-model-package failed — subscription may not be fully active yet.
    Wait 60s and re-run. Error: $PKG_JSON"

PKG_STATUS="$(echo "$PKG_JSON" | jq -r '.ModelPackageStatus // "?"')"
PKG_APPROVAL="$(echo "$PKG_JSON" | jq -r '.ModelApprovalStatus // "?"')"
ok "Model package status: $PKG_STATUS  approval: $PKG_APPROVAL"

if [[ "$PKG_APPROVAL" != "Approved" ]]; then
  warn "Model package is not Approved. Deploy will likely fail."
fi

# ── Phase 4 — Persist ARN to .env ────────────────────────────────────────────
if [[ "$UPDATE_ENV" == "true" ]]; then
  sep
  log "Phase 4 — Updating $ENV_FILE..."
  REQUEST_FORMAT="${VOYAGE_REQUEST_FORMAT:-multimodal}"
  ENDPOINT_SUFFIX="$MODEL"
  if [[ "$MODEL" == "voyage-3-5-lite" ]]; then
    REQUEST_FORMAT="legacy"
  fi

  upsert_export() {
    local key="$1"
    local value="$2"
    local tmp
    tmp="$(mktemp)"
    if grep -q "^export ${key}=" "$ENV_FILE"; then
      sed "s|^export ${key}=.*|export ${key}=\"${value}\"|" "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
    else
      cp "$ENV_FILE" "$tmp"
      printf '\nexport %s="%s"\n' "$key" "$value" >> "$tmp"
      mv "$tmp" "$ENV_FILE"
    fi
  }

  if [[ ! -f "$ENV_FILE" ]]; then
    warn ".env not found — creating from scratch"
    cat > "$ENV_FILE" <<EOF
#!/bin/bash
export EMBEDDINGS_PROVIDER="voyage"
export VOYAGE_MODEL_PACKAGE_ARN="$ARN"
export VOYAGE_MARKETPLACE_MODEL="$MODEL"
export VOYAGE_REQUEST_FORMAT="$REQUEST_FORMAT"
export VOYAGE_OUTPUT_DIM="1024"
export TF_VAR_voyage_endpoint_name_suffix="$ENDPOINT_SUFFIX"
EOF
    chmod 600 "$ENV_FILE"
    ok "Created $ENV_FILE"
  else
    upsert_export "EMBEDDINGS_PROVIDER" "voyage"
    upsert_export "VOYAGE_MODEL_PACKAGE_ARN" "$ARN"
    upsert_export "VOYAGE_MARKETPLACE_MODEL" "$MODEL"
    upsert_export "VOYAGE_REQUEST_FORMAT" "$REQUEST_FORMAT"
    upsert_export "VOYAGE_OUTPUT_DIM" "1024"
    upsert_export "TF_VAR_voyage_endpoint_name_suffix" "$ENDPOINT_SUFFIX"
    ok "Updated Voyage env vars in $ENV_FILE"
  fi
else
  log "Skipped .env update (--skip-env)"
fi

# ── Phase 5 — Push to GitHub Secrets (optional) ───────────────────────────────
if [[ "$UPDATE_GH" == "true" ]]; then
  sep
  log "Phase 5 — Setting GitHub secret VOYAGE_MODEL_PACKAGE_ARN on $GH_REPO..."
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh CLI not installed — skipping GitHub secret update"
  elif ! gh auth status >/dev/null 2>&1; then
    warn "gh not authenticated — run 'gh auth login' then:"
    echo "    printf '%s' '$ARN' | gh secret set VOYAGE_MODEL_PACKAGE_ARN --repo $GH_REPO"
  else
    printf '%s' "$ARN" | gh secret set VOYAGE_MODEL_PACKAGE_ARN --repo "$GH_REPO" \
      && ok "GitHub secret set"
  fi
else
  log "Skipped GitHub secret update (--skip-gh)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
sep
ok "Voyage AI Marketplace setup complete."
echo ""
echo "  Model:   $MODEL"
echo "  Region:  $AWS_REGION"
echo "  ARN:     $ARN"
echo ""
echo "  Next: run ./deploy/deploy-full-with-privatelink.sh — the envs/ec2 stack will now"
echo "        provision a SageMaker endpoint for Voyage embeddings instead of"
echo "        falling back to Bedrock Titan."
echo ""
