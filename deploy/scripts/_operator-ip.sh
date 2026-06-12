#!/usr/bin/env bash
# _operator-ip.sh — Resolve the operator / deploy-machine public IP as a /32 CIDR
# for the Atlas project IP access list.
#
# Why: the Atlas IP access list must NOT contain 0.0.0.0/0 (no public-internet
# path). Instead it is scoped to "anywhere it was created from" — the machine
# running the deploy. In privatelink + local modes this /32 is the only
# public-SRV allowlist entry the mongodb-atlas module creates; runtime traffic
# reaches Atlas privately (PrivateLink / peering) and bypasses the allowlist.
#
# Resolution order (first non-empty wins):
#   1. $OPERATOR_IP_CIDR  (explicit override, e.g. 203.0.113.42/32)
#   2. $TF_VAR_my_ip      (legacy alias kept in sync in .env.sample)
#   3. autodetect via https://checkip.amazonaws.com  → A.B.C.D/32
#
# On success exports OPERATOR_IP_CIDR (already CIDR form) and returns 0.
# On failure leaves OPERATOR_IP_CIDR empty and returns 1 so the caller decides
# whether that is fatal (privatelink / local need it) or just a warning.
#
# Usage:
#   source "$SCRIPT_DIR/_operator-ip.sh"
#   resolve_operator_ip_cidr "network"   # arg = log prefix label

resolve_operator_ip_cidr() {
  local label="${1:-deploy}"

  if [[ -z "${OPERATOR_IP_CIDR:-}" && -n "${TF_VAR_my_ip:-}" ]]; then
    OPERATOR_IP_CIDR="$TF_VAR_my_ip"
  fi

  if [[ -z "${OPERATOR_IP_CIDR:-}" ]]; then
    echo "  [${label}] Auto-detecting operator public IP via checkip.amazonaws.com (override with OPERATOR_IP_CIDR=A.B.C.D/32)..."
    local detected
    detected=$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$detected" && "$detected" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      OPERATOR_IP_CIDR="${detected}/32"
      echo "  [${label}] ✓ operator IP detected: $OPERATOR_IP_CIDR"
    else
      OPERATOR_IP_CIDR=""
    fi
  fi

  export OPERATOR_IP_CIDR
  [[ -n "${OPERATOR_IP_CIDR:-}" ]]
}
