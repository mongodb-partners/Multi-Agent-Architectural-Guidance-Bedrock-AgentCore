#!/usr/bin/env bash
# discover-or-create-container.sh — idempotent Atlas network container lookup
#
# Atlas allows ONLY ONE network container per (Atlas project, providerName=AWS,
# region). When multiple terraform deployments share an Atlas project + region,
# they MUST share that single container — Atlas returns HTTP 409 on the second
# create.
#
# This script:
#   1. Lists existing AWS containers for the project.
#   2. If exactly one exists for ATLAS_REGION → reuses it (verifies CIDR
#      matches ATLAS_PEERING_CIDR; warns and uses existing CIDR if not).
#   3. If none → creates one with ATLAS_PEERING_CIDR. If creation 409s
#      (concurrent run won the race), re-lists and reuses the winner.
#   4. Writes {container_id, atlas_cidr_block, region} to STATE_FILE.
#
# All errors are HARD failures (set -euo pipefail). No silent fallbacks.

set -euo pipefail

: "${ATLAS_PROJECT_ID:?required}"
: "${ATLAS_REGION:?required}"           # underscored, e.g. US_EAST_1
: "${ATLAS_PEERING_CIDR:?required}"
: "${STATE_FILE:?required}"
: "${MONGODB_ATLAS_PUBLIC_KEY:?required — export from .env}"
: "${MONGODB_ATLAS_PRIVATE_KEY:?required — export from .env}"

ATLAS_API="https://cloud.mongodb.com/api/atlas/v2"
AUTH="${MONGODB_ATLAS_PUBLIC_KEY}:${MONGODB_ATLAS_PRIVATE_KEY}"
ACCEPT_HDR="Accept: application/vnd.atlas.2025-01-01+json"

LIST_URL="${ATLAS_API}/groups/${ATLAS_PROJECT_ID}/containers?providerName=AWS"
CREATE_URL="${ATLAS_API}/groups/${ATLAS_PROJECT_ID}/containers"

log() { echo "[atlas-vpc-peering] $*"; }

curl_atlas_get() {
  curl --silent --show-error --fail --user "$AUTH" --digest -H "$ACCEPT_HDR" "$@"
}

# Returns "<container_id>\t<cidr>" for ATLAS_REGION (or empty if none).
list_existing_container() {
  local body
  body=$(curl_atlas_get "$LIST_URL")
  echo "$body" | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get('results', [])

def norm(value):
    return str(value or '').replace('-', '_').upper()

def region(item):
    return item.get('regionName') or item.get('region') or ''

matches = [c for c in items if norm(region(c)) == '${ATLAS_REGION}']
if len(matches) > 1:
    print('ERROR: multiple AWS network containers found for region ${ATLAS_REGION} in project ${ATLAS_PROJECT_ID}', file=sys.stderr)
    sys.exit(1)
if matches:
    c = matches[0]
    print(f\"{c['id']}\t{c.get('atlasCidrBlock','')}\")
"
}

EXISTING=$(list_existing_container || true)

if [[ -n "$EXISTING" ]]; then
  CONTAINER_ID=$(echo "$EXISTING" | cut -f1)
  CIDR=$(echo "$EXISTING" | cut -f2)
  log "reusing existing container: ${CONTAINER_ID} (cidr=${CIDR})"
  if [[ "$CIDR" != "$ATLAS_PEERING_CIDR" ]]; then
    log "WARNING: existing container CIDR ${CIDR} differs from requested ${ATLAS_PEERING_CIDR}."
    log "         Using existing CIDR; if you must change it, destroy the container first."
    log "         (Container is shared across deployments — destroy in the Atlas console only when no other peerings depend on it.)"
  fi
else
  log "no existing container for region ${ATLAS_REGION} — creating new (cidr=${ATLAS_PEERING_CIDR})"
  set +e
  RESPONSE=$(curl --silent --show-error --user "$AUTH" --digest \
    -H "$ACCEPT_HDR" -H "Content-Type: application/json" \
    -X POST "$CREATE_URL" \
    -d "{\"providerName\":\"AWS\",\"regionName\":\"${ATLAS_REGION}\",\"atlasCidrBlock\":\"${ATLAS_PEERING_CIDR}\"}" \
    -w $'\n__HTTP_CODE__:%{http_code}')
  CURL_RC=$?
  set -e
  if (( CURL_RC != 0 )); then
    echo "[atlas-vpc-peering] ERROR: curl failed (rc=$CURL_RC) on container create" >&2
    exit 1
  fi
  HTTP_CODE=$(echo "$RESPONSE" | grep '^__HTTP_CODE__:' | cut -d: -f2)
  BODY=$(echo "$RESPONSE" | grep -v '^__HTTP_CODE__:')
  case "$HTTP_CODE" in
    200|201)
      CONTAINER_ID=$(echo "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
      CIDR=$(echo "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin).get('atlasCidrBlock','${ATLAS_PEERING_CIDR}'))")
      log "created: ${CONTAINER_ID} (cidr=${CIDR})"
      ;;
    409)
      log "race detected (HTTP 409) — another deployment created the container first; re-listing"
      EXISTING=""
      for attempt in $(seq 1 30); do
        EXISTING=$(list_existing_container || true)
        [[ -n "$EXISTING" ]] && break
        log "container not visible in Atlas list yet after 409; waiting 10s (${attempt}/30)"
        sleep 10
      done
      if [[ -z "$EXISTING" ]]; then
        echo "[atlas-vpc-peering] ERROR: 409 on create but no container found on re-list" >&2
        exit 1
      fi
      CONTAINER_ID=$(echo "$EXISTING" | cut -f1)
      CIDR=$(echo "$EXISTING" | cut -f2)
      log "reusing container from race: ${CONTAINER_ID} (cidr=${CIDR})"
      ;;
    *)
      echo "[atlas-vpc-peering] ERROR: unexpected HTTP ${HTTP_CODE} on container create" >&2
      echo "$BODY" >&2
      exit 1
      ;;
  esac
fi

python3 - <<PY
import json
with open('${STATE_FILE}', 'w') as f:
    json.dump({
        'container_id': '${CONTAINER_ID}',
        'atlas_cidr_block': '${CIDR}',
        'region': '${ATLAS_REGION}',
    }, f, indent=2)
PY
log "state written: ${STATE_FILE}"
log "container id : ${CONTAINER_ID} (cidr=${CIDR})"
