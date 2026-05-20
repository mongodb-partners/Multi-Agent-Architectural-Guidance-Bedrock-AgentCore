#!/usr/bin/env bash
# enable-private-dns.sh — toggle Atlas "Private DNS for Peering" (aka
# "Use Custom DNS for AWS" / awsCustomDNS) on the project.
#
# Atlas project setting: when enabled, the cluster's connection_strings[0].private_srv
# is populated and clients in a peered VPC resolve the SRV form to private
# peering IPs natively (no per-cluster Route 53 zone needed). When disabled,
# only connection_strings[0].private (multi-host non-SRV) is available — still
# private, but uglier.
#
# Idempotent: PATCH returns 200 even when the setting is already enabled.
# Non-200 prints a warning and writes {enabled: false} to STATE_FILE; the
# deploy continues — the non-SRV form still works. NEVER hard-fails the apply.
#
# Endpoint:  PATCH /api/atlas/v1.0/groups/{groupId}/awsCustomDNS
#            body: {"enabled": true}
# This is the ONLY endpoint that controls Private DNS for Peering as of the
# Atlas Admin API 2024 release line. An earlier version of this script used
# `/privateIpMode` which is a DIFFERENT (legacy) setting and returns 404 on
# modern Atlas — the deploy would silently continue with the SRV form
# missing, and modules/bedrock-kb-peering would then dig empty A records.

set -euo pipefail

: "${ATLAS_PROJECT_ID:?required}"
: "${STATE_FILE:?required}"
: "${MONGODB_ATLAS_PUBLIC_KEY:?required — export from .env}"
: "${MONGODB_ATLAS_PRIVATE_KEY:?required — export from .env}"

AUTH="${MONGODB_ATLAS_PUBLIC_KEY}:${MONGODB_ATLAS_PRIVATE_KEY}"
V1_URL="https://cloud.mongodb.com/api/atlas/v1.0/groups/${ATLAS_PROJECT_ID}/awsCustomDNS"
V1_ACCEPT="Accept: application/json"

log()  { echo "[atlas-private-dns] $*"; }
warn() { echo "[atlas-private-dns] WARNING: $*" >&2; }

write_state() {
  local enabled="$1"
  local source="$2"
  python3 - <<PY
import json
with open('${STATE_FILE}', 'w') as f:
    json.dump({'enabled': ${enabled}, 'source': '${source}'}, f, indent=2)
PY
}

# ── Read current state (v1 GET) ──────────────────────────────────────────────
set +e
CURRENT=$(curl --silent --show-error --user "$AUTH" --digest -H "$V1_ACCEPT" "$V1_URL")
GET_RC=$?
set -e

if (( GET_RC == 0 )); then
  ALREADY=$(echo "$CURRENT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print('true' if d.get('enabled') is True else 'false')
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")
  if [[ "$ALREADY" == "true" ]]; then
    log "Private DNS for Peering already enabled on project ${ATLAS_PROJECT_ID}"
    write_state "True" "already-enabled"
    exit 0
  fi
fi

# ── Enable via v1 PATCH ──────────────────────────────────────────────────────
log "enabling Private DNS for Peering on project ${ATLAS_PROJECT_ID} (v1 PATCH)"
set +e
RESPONSE=$(curl --silent --show-error --user "$AUTH" --digest \
  -H "$V1_ACCEPT" -H "Content-Type: application/json" \
  -X PATCH "$V1_URL" \
  -d '{"enabled": true}' \
  -w $'\n__HTTP_CODE__:%{http_code}')
CURL_RC=$?
set -e

if (( CURL_RC != 0 )); then
  warn "curl failed (rc=${CURL_RC}); SRV peering URI will be unavailable — runtime falls back to multi-host non-SRV (still private)"
  write_state "False" "curl-failure"
  exit 0
fi

HTTP_CODE=$(echo "$RESPONSE" | grep '^__HTTP_CODE__:' | cut -d: -f2)
BODY=$(echo "$RESPONSE" | grep -v '^__HTTP_CODE__:')

case "$HTTP_CODE" in
  200|202)
    log "enabled successfully (HTTP ${HTTP_CODE})"
    write_state "True" "patched"
    ;;
  401|403)
    warn "Atlas API rejected the toggle (HTTP ${HTTP_CODE}) — your API key likely lacks GROUP_OWNER scope. SRV peering URI unavailable; runtime falls back to multi-host non-SRV (still private)"
    warn "Response: ${BODY}"
    write_state "False" "permission-denied"
    ;;
  *)
    warn "unexpected HTTP ${HTTP_CODE} when enabling Private DNS for Peering. SRV peering URI unavailable; runtime falls back to multi-host non-SRV (still private)"
    warn "Response: ${BODY}"
    write_state "False" "http-${HTTP_CODE}"
    ;;
esac
