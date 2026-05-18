#!/usr/bin/env bash
# discover-or-create-pl.sh — idempotent PrivateLink endpoint service lookup
#
# Atlas allows ONLY ONE PrivateLink endpoint service per (Atlas project, AWS
# region). When multiple terraform deployments share an Atlas project + region,
# they MUST share that single endpoint service — Atlas returns HTTP 409
# (PRIVATE_ENDPOINT_SERVICE_ALREADY_EXISTS_FOR_REGION) on the second create.
#
# This script:
#   1. Lists existing endpoint services for (project, region).
#   2. If exactly one exists → reuses it.
#   3. If none → creates one. If creation 409s (concurrent run won the race),
#      re-lists and reuses the winner.
#   4. Waits for endpointServiceName to be populated (Atlas may need a few
#      seconds after creation).
#   5. Writes {private_link_id, endpoint_service_name, region} to STATE_FILE.
#
# All errors are HARD failures (set -euo pipefail). No silent fallbacks.

set -euo pipefail

: "${ATLAS_PROJECT_ID:?required}"
: "${ATLAS_REGION:?required}"           # underscored, e.g. US_EAST_1
: "${STATE_FILE:?required}"
: "${MONGODB_ATLAS_PUBLIC_KEY:?required — export from .env}"
: "${MONGODB_ATLAS_PRIVATE_KEY:?required — export from .env}"

ATLAS_API="https://cloud.mongodb.com/api/atlas/v2"
AUTH="${MONGODB_ATLAS_PUBLIC_KEY}:${MONGODB_ATLAS_PRIVATE_KEY}"
ACCEPT_HDR="Accept: application/vnd.atlas.2025-01-01+json"

LIST_URL="${ATLAS_API}/groups/${ATLAS_PROJECT_ID}/privateEndpoint/AWS/endpointService"
CREATE_URL="${ATLAS_API}/groups/${ATLAS_PROJECT_ID}/privateEndpoint/endpointService"
GET_URL_BASE="${ATLAS_API}/groups/${ATLAS_PROJECT_ID}/privateEndpoint/AWS/endpointService"

log() { echo "[atlas-privatelink] $*"; }

curl_atlas_get() {
  curl --silent --show-error --fail --user "$AUTH" --digest -H "$ACCEPT_HDR" "$@"
}

# Returns the endpoint service ID for ATLAS_REGION (or empty if none).
list_existing_id() {
  local body
  body=$(curl_atlas_get "$LIST_URL")
  echo "$body" | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('results', [])

def norm(value):
    return str(value or '').replace('-', '_').upper()

def endpoint_region(endpoint):
    return endpoint.get('regionName') or endpoint.get('region') or endpoint.get('region_name') or ''

def endpoint_id(endpoint):
    return endpoint.get('id') or endpoint.get('privateLinkId') or endpoint.get('private_link_id') or ''

matches = [e for e in items if norm(endpoint_region(e)) == '${ATLAS_REGION}']
if len(matches) > 1:
    print('ERROR: multiple privatelink endpoint services found for region ${ATLAS_REGION} in project ${ATLAS_PROJECT_ID}', file=sys.stderr)
    sys.exit(1)
print(endpoint_id(matches[0]) if matches else '')
"
}

PL_ID=$(list_existing_id)

if [[ -z "$PL_ID" ]]; then
  log "no existing endpoint service for region ${ATLAS_REGION} — creating new"
  set +e
  RESPONSE=$(curl --silent --show-error --user "$AUTH" --digest \
    -H "$ACCEPT_HDR" -H "Content-Type: application/json" \
    -X POST "$CREATE_URL" \
    -d "{\"providerName\":\"AWS\",\"region\":\"${ATLAS_REGION}\"}" \
    -w $'\n__HTTP_CODE__:%{http_code}')
  CURL_RC=$?
  set -e
  if (( CURL_RC != 0 )); then
    echo "[atlas-privatelink] ERROR: curl failed (rc=$CURL_RC) on create" >&2
    exit 1
  fi
  HTTP_CODE=$(echo "$RESPONSE" | grep '^__HTTP_CODE__:' | cut -d: -f2)
  BODY=$(echo "$RESPONSE" | grep -v '^__HTTP_CODE__:')
  case "$HTTP_CODE" in
    200|201)
      PL_ID=$(echo "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
      log "created: $PL_ID"
      ;;
    409)
      log "race detected (HTTP 409) — another deployment created the service first; re-listing"
      for attempt in $(seq 1 30); do
        PL_ID=$(list_existing_id)
        [[ -n "$PL_ID" ]] && break
        log "service not visible in Atlas list yet after 409; waiting 10s (${attempt}/30)"
        sleep 10
      done
      [[ -z "$PL_ID" ]] && {
        echo "[atlas-privatelink] ERROR: 409 on create but no service found on re-list" >&2
        exit 1
      }
      log "reusing service from race: $PL_ID"
      ;;
    *)
      echo "[atlas-privatelink] ERROR: unexpected HTTP ${HTTP_CODE} on create" >&2
      echo "$BODY" >&2
      exit 1
      ;;
  esac
else
  log "reusing existing service: $PL_ID"
fi

GET_URL="${GET_URL_BASE}/${PL_ID}"
ENDPOINT_SERVICE_NAME=""
STATUS=""
# Atlas populates endpointServiceName a few seconds after create. AVAILABLE
# means a VPC endpoint is already attached; WAITING_FOR_USER means none is
# yet attached — both are valid for our purposes.
for _ in $(seq 1 60); do
  DETAILS=$(curl_atlas_get "$GET_URL")
  ENDPOINT_SERVICE_NAME=$(echo "$DETAILS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('endpointServiceName') or '')")
  STATUS=$(echo "$DETAILS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status') or '')")
  if [[ -n "$ENDPOINT_SERVICE_NAME" && ( "$STATUS" == "AVAILABLE" || "$STATUS" == "WAITING_FOR_USER" ) ]]; then
    break
  fi
  sleep 5
done

if [[ -z "$ENDPOINT_SERVICE_NAME" ]]; then
  echo "[atlas-privatelink] ERROR: endpointServiceName not populated within 5 minutes (last status=${STATUS})" >&2
  exit 1
fi

python3 - <<PY
import json
with open('${STATE_FILE}', 'w') as f:
    json.dump({
        'private_link_id': '${PL_ID}',
        'endpoint_service_name': '${ENDPOINT_SERVICE_NAME}',
        'region': '${ATLAS_REGION}',
    }, f, indent=2)
PY
log "state written: ${STATE_FILE}"
log "service name: ${ENDPOINT_SERVICE_NAME} (status=${STATUS})"
