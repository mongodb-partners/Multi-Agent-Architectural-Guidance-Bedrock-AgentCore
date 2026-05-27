#!/usr/bin/env bash
# =============================================================================
# setup-troubleshooting-infra.sh
#
# Creates minimum AWS + Atlas infrastructure to run the troubleshooting agent
# live (no mocks).  Safe to re-run — all steps are idempotent.
#
# What this script provisions:
#   Atlas    — M10 cluster (or reuse existing), DB user, IP allowlist
#   MongoDB  — seed all collections + vector search indexes + Bedrock embeddings
#   AWS      — S3 bucket (KB source docs), IAM role, OpenSearch Serverless
#              collection + vector index, Bedrock Knowledge Base + sync job
#
# Prerequisites:
#   brew install jq awscli
#   curl (system), python3 (system), bun (https://bun.sh)
#
# Usage:
#   source .env                                           # load credentials
#   bash deploy/scripts/setup-troubleshooting-infra.sh   # run
#
# Outputs:
#   .env.live   — copy these exports to start the API against live backends
# =============================================================================
set -euo pipefail

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC}  $*"; }
success() { echo -e "${GREEN}✅${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠️ ${NC}  $*"; }
die()     { echo -e "${RED}❌${NC}  $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_FILE="$REPO_ROOT/.infra-state.sh"

# ── flag parsing ──────────────────────────────────────────────────────────────
NEW_INFRA=0
for arg in "$@"; do
  case "$arg" in
    --new-infra) NEW_INFRA=1 ;;
    *) die "Unknown argument: $arg. Usage: bash setup-troubleshooting-infra.sh [--new-infra]" ;;
  esac
done

# ── load prior state (skipped with --new-infra) ───────────────────────────────
if [[ "$NEW_INFRA" -eq 0 && -f "$STATE_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$STATE_FILE"
  info "Loaded prior state from .infra-state.sh (use --new-infra to create fresh resources)"
elif [[ "$NEW_INFRA" -eq 1 ]]; then
  warn "--new-infra: ignoring prior state — a new S3 bucket and Bedrock KB will be created"
fi

# ── config knobs (override via env before sourcing) ───────────────────────────
# Resource names are project+env-derived so multiple deployments in one AWS
# account do not collide on account/region-global identifiers (IAM role,
# Secrets Manager secret, Bedrock KB name).
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
_PROJECT_SLUG="${PROJECT_NAME//-/_}"
MONGODB_DB="${MONGODB_DB:-${_PROJECT_SLUG}_${ENVIRONMENT}}"
CLUSTER_NAME="${ATLAS_CLUSTER_NAME:-${PROJECT_NAME}-${ENVIRONMENT}}"
CLUSTER_TIER="${ATLAS_CLUSTER_TIER:-M10}"        # M10 required for vector search
DB_USER="${ATLAS_DB_USER:-${_PROJECT_SLUG}_${ENVIRONMENT}_user}"
unset _PROJECT_SLUG
# KB_BUCKET is loaded from .infra-state.sh on re-runs; only generated fresh on
# first run or when --new-infra is passed.
if [[ -z "${KB_BUCKET:-}" ]]; then
  KB_BUCKET_SUFFIX="${KB_BUCKET_SUFFIX:-$(date +%s | tail -c 7)}"
  KB_BUCKET="${PROJECT_NAME}-kb-${ENVIRONMENT}-${KB_BUCKET_SUFFIX}"
fi
KB_NAME="${PROJECT_NAME}-troubleshooting-kb-${ENVIRONMENT}"
ATLAS_COLLECTION="troubleshooting_docs"
ATLAS_VECTOR_INDEX="troubleshooting-vector-index"
ATLAS_SECRET_NAME="${PROJECT_NAME}-bedrock-kb-creds-${ENVIRONMENT}"
IAM_ROLE_NAME="${PROJECT_NAME}-bedrock-kb-${ENVIRONMENT}-role"
EMBED_MODEL_ID="${EMBEDDING_MODEL_ID:-amazon.titan-embed-text-v2:0}"
# Embedding dimension comes from the Voyage TS SSOT
# (api/src/adapters/voyage-embedding.ts → VOYAGE_EMBEDDING_DIMS). The bash
# bridge `voyage_embedding_dims` reads the same constant; both the Voyage
# and Titan stacks index at the same dim.
# shellcheck source=deploy/scripts/_voyage-config.sh
source "$SCRIPT_DIR/_voyage-config.sh"
EMBEDDING_DIMENSIONS="$(voyage_embedding_dims)"

# ── derive Atlas vars from TF_ vars if not set directly ──────────────────────
ATLAS_PROJECT_ID="${ATLAS_PROJECT_ID:-${TF_VAR_mongodb_atlas_project_id:-}}"
ATLAS_PUBLIC_KEY="${ATLAS_PUBLIC_KEY:-${MONGODB_ATLAS_PUBLIC_KEY:-}}"
ATLAS_PRIVATE_KEY="${ATLAS_PRIVATE_KEY:-${MONGODB_ATLAS_PRIVATE_KEY:-}}"
DB_PASSWORD="${DB_PASSWORD:-${TF_VAR_mongodb_password:-}}"

# ── prerequisite checks ───────────────────────────────────────────────────────
header "Checking prerequisites"

for cmd in aws jq curl python3; do
  command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

# bun check — used for seed scripts
BUN_CMD=""
for candidate in bun "$HOME/.bun/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
  if command -v "$candidate" &>/dev/null 2>&1; then
    BUN_CMD="$candidate"; break
  fi
done
[[ -n "$BUN_CMD" ]] || die "bun not found. Install from https://bun.sh then re-run."
success "bun found at $BUN_CMD"
# Make bun available as plain "bun" for sub-processes (seed-all.ts uses Bun.spawn(["bun",...]))
export PATH="$(dirname "$BUN_CMD"):$PATH"

# AWS credentials
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "AWS credentials not set or expired. Source .env first."
success "AWS account: $AWS_ACCOUNT_ID  region: $AWS_REGION"

# Atlas credentials
[[ -n "$ATLAS_PROJECT_ID" ]]  || die "ATLAS_PROJECT_ID not set (expected from .env TF_VAR_mongodb_atlas_project_id)"
[[ -n "$ATLAS_PUBLIC_KEY" ]]  || die "ATLAS_PUBLIC_KEY not set (expected from .env MONGODB_ATLAS_PUBLIC_KEY)"
[[ -n "$ATLAS_PRIVATE_KEY" ]] || die "ATLAS_PRIVATE_KEY not set (expected from .env MONGODB_ATLAS_PRIVATE_KEY)"
[[ -n "$DB_PASSWORD" ]]       || die "DB_PASSWORD not set (expected from .env TF_VAR_mongodb_password)"
success "Atlas project: $ATLAS_PROJECT_ID"

ATLAS_BASE="https://cloud.mongodb.com/api/atlas/v2"
atlas_curl() {
  # Digest auth wrapper for Atlas Admin API
  # 2024-08-05 is required for the regionConfigs cluster create schema
  local RESPONSE HTTP_CODE
  RESPONSE="$(curl --silent --write-out '\n__HTTP_CODE__%{http_code}' \
       --user "$ATLAS_PUBLIC_KEY:$ATLAS_PRIVATE_KEY" --digest \
       -H "Content-Type: application/json" \
       -H "Accept: application/vnd.atlas.2024-08-05+json" \
       "$@")"
  HTTP_CODE="$(echo "$RESPONSE" | grep '__HTTP_CODE__' | sed 's/__HTTP_CODE__//')"
  BODY="$(echo "$RESPONSE" | grep -v '__HTTP_CODE__')"
  if [[ "$HTTP_CODE" -ge 400 ]] 2>/dev/null; then
    echo -e "${RED}Atlas API error (HTTP $HTTP_CODE):${NC} $BODY" >&2
    return 1
  fi
  echo "$BODY"
}

# =============================================================================
# PHASE 1 — Atlas cluster
# =============================================================================
header "Atlas — cluster"

EXISTING_CLUSTER="$(atlas_curl "$ATLAS_BASE/groups/$ATLAS_PROJECT_ID/clusters" 2>/dev/null \
  | jq -r ".results[]? | select(.name==\"$CLUSTER_NAME\") | .name" 2>/dev/null || true)"

if [[ -n "$EXISTING_CLUSTER" ]]; then
  success "Cluster '$CLUSTER_NAME' already exists — skipping create"
else
  info "Creating Atlas $CLUSTER_TIER cluster '$CLUSTER_NAME' in US_EAST_1..."
  atlas_curl -X POST "$ATLAS_BASE/groups/$ATLAS_PROJECT_ID/clusters" \
    -d "{
      \"name\": \"$CLUSTER_NAME\",
      \"clusterType\": \"REPLICASET\",
      \"replicationSpecs\": [{
        \"regionConfigs\": [{
          \"electableSpecs\": {
            \"instanceSize\": \"$CLUSTER_TIER\",
            \"nodeCount\": 3,
            \"ebsVolumeType\": \"STANDARD\"
          },
          \"providerName\": \"AWS\",
          \"regionName\": \"US_EAST_1\",
          \"priority\": 7
        }]
      }]
    }" | jq -r '.name // empty' > /dev/null
  success "Cluster creation initiated — waiting for IDLE state (this can take 3-5 min)..."
fi

# Wait for cluster to be IDLE
for i in $(seq 1 40); do
  STATE="$(atlas_curl "$ATLAS_BASE/groups/$ATLAS_PROJECT_ID/clusters/$CLUSTER_NAME" \
    | jq -r '.stateName' 2>/dev/null || echo "UNKNOWN")"
  if [[ "$STATE" == "IDLE" ]]; then
    success "Cluster is IDLE"; break
  fi
  [[ $i -eq 40 ]] && die "Timed out waiting for cluster IDLE (state: $STATE)"
  echo "  ... cluster state: $STATE (${i}/40)"
  sleep 15
done

# =============================================================================
# PHASE 2 — Atlas DB user + IP allowlist
# =============================================================================
header "Atlas — DB user and network access"

# Create or update DB user
atlas_curl -X POST "$ATLAS_BASE/groups/$ATLAS_PROJECT_ID/databaseUsers" \
  -d "{
    \"databaseName\": \"admin\",
    \"username\": \"$DB_USER\",
    \"password\": \"$DB_PASSWORD\",
    \"roles\": [
      { \"databaseName\": \"$MONGODB_DB\", \"roleName\": \"readWrite\" },
      { \"databaseName\": \"admin\",        \"roleName\": \"dbAdmin\" }
    ]
  }" > /dev/null 2>&1 || \
atlas_curl -X PATCH "$ATLAS_BASE/groups/$ATLAS_PROJECT_ID/databaseUsers/admin/$DB_USER" \
  -d "{ \"password\": \"$DB_PASSWORD\" }" > /dev/null 2>&1 || true
success "DB user '$DB_USER' created/updated"

# Add current IP to allowlist (0.0.0.0/0 as fallback for demo — restrict for prod)
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"
atlas_curl -X POST "$ATLAS_BASE/groups/$ATLAS_PROJECT_ID/accessList" \
  -d "[{ \"ipAddress\": \"$MY_IP\", \"comment\": \"setup-script $(date -u +%Y-%m-%d)\" }]" \
  > /dev/null 2>&1 || true
success "IP $MY_IP added to allowlist"

# =============================================================================
# PHASE 3 — Get connection string
# =============================================================================
header "Atlas — connection string"

SRV_HOST="$(atlas_curl "$ATLAS_BASE/groups/$ATLAS_PROJECT_ID/clusters/$CLUSTER_NAME" \
  | jq -r '.connectionStrings.standardSrv' | sed 's|mongodb+srv://||')"
[[ -n "$SRV_HOST" ]] || die "Could not get SRV host from Atlas API"

MONGODB_URI="mongodb+srv://${DB_USER}:${DB_PASSWORD}@${SRV_HOST}/?retryWrites=true&w=majority"
success "Connection string: mongodb+srv://${DB_USER}:***@${SRV_HOST}/..."

# =============================================================================
# PHASE 4 — MongoDB seed (all collections + indexes + embeddings)
# =============================================================================
header "MongoDB — seed collections"

cd "$REPO_ROOT"

info "Running seed-all.ts (customers, products, troubleshooting_docs, orders, indexes)..."
MONGODB_URI="$MONGODB_URI" \
MONGODB_DB="$MONGODB_DB" \
EMBEDDING_DIMENSIONS="$EMBEDDING_DIMENSIONS" \
  "$BUN_CMD" db-seeding/seed-all.ts

info "Running seed-embeddings.ts via shared helper..."
# Migrated from the legacy temp-workspace + node --experimental-strip-types
# approach to the shared run_embedding_seed helper. The helper:
#   - waits for Voyage SageMaker InService when EMBEDDINGS_PROVIDER=voyage
#   - auto-detects REWIRE on provider/dim drift (SSM + in-Mongo fingerprint)
#   - exits non-zero on incomplete results (no warn-only fallback)
#   - never touches Bedrock KB-managed chunks
# shellcheck source=deploy/scripts/_mongo-connect.sh
source "$SCRIPT_DIR/_mongo-connect.sh"
# shellcheck source=deploy/scripts/_seed-embeddings.sh
source "$SCRIPT_DIR/_seed-embeddings.sh"

# Provider selection: setup-troubleshooting-infra.sh historically forced Titan,
# but the Voyage path expects EMBEDDINGS_PROVIDER from the operator's env. Honor
# whatever was passed; only default when unset.
export EMBEDDINGS_PROVIDER="${EMBEDDINGS_PROVIDER:-titan}"
export EMBEDDING_MODEL_ID="${EMBEDDING_MODEL_ID:-$EMBED_MODEL_ID}"
export EMBEDDING_DIMENSIONS="$EMBEDDING_DIMENSIONS"
export AWS_REGION="$AWS_REGION"

run_embedding_seed "$MONGODB_DB" "$MONGODB_URI" \
  || die "Embedding seed failed — see [embed-seed] envelope above"

success "MongoDB seeding complete"

# =============================================================================
# PHASE 5 — S3 bucket + KB source documents
# =============================================================================
header "AWS — S3 bucket for Bedrock KB"

# Check if bucket exists
if aws s3api head-bucket --bucket "$KB_BUCKET" 2>/dev/null; then
  success "Bucket s3://$KB_BUCKET already exists"
else
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$KB_BUCKET" --region "$AWS_REGION" > /dev/null
  else
    aws s3api create-bucket --bucket "$KB_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION" > /dev/null
  fi
  # Block public access
  aws s3api put-public-access-block --bucket "$KB_BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
    > /dev/null
  success "Created s3://$KB_BUCKET"
fi

# Persist the bucket name so re-runs reuse the same bucket instead of creating a new one
echo "KB_BUCKET=${KB_BUCKET}" > "$STATE_FILE"
success "State saved to .infra-state.sh"

# Upload KB source documents — unstructured text files that Bedrock will chunk + index
KB_TMP="$(mktemp -d)"
trap 'rm -rf "$KB_TMP"' EXIT

# Doc 1: Power and boot issues
cat > "$KB_TMP/power-boot-guide.txt" << 'EOF'
# Product Support Guide: Power and Boot Issues

## Device will not power on (Error: PWR-001)

If your device shows no signs of power, follow these steps:

1. Check the power cable — ensure it is firmly seated at both ends of the cable and the device.
2. Try a different wall outlet — avoid power strips and extension cords for initial testing.
3. Use a known-good USB-C cable that supports at least 5V/2A power delivery.
4. Hold the power button for 10 seconds to force a hardware reset.
5. If the companion app shows error code PWR-001, the power path has been interrupted.
6. If two different cables and two different outlets do not resolve the issue, the device needs service.

## Device restarts randomly or freezes (Error: BOOT-010)

Random restarts and boot loops are typically caused by firmware corruption or memory issues:

1. Update the device firmware using the companion app (Settings > Updates).
2. Disable background sync and location services to reduce memory pressure.
3. Calibrate the battery: fully discharge, then charge to 100% without interruption.
4. If the device enters a boot loop (BOOT-010), hold Power and Volume-Down for 15 seconds.
5. A factory reset resolves most BOOT-010 cases. Back up data first using cloud sync.
6. Persistent boot loops after a clean firmware install require hardware service.

## Warranty and service options

Standard devices carry a 12-month hardware warranty. Pro series devices have a 24-month warranty.
Premium-tier customers receive an extended 36-month warranty.
For hardware faults under warranty, express replacement is available within 2 business days.
EOF

# Doc 2: Connectivity
cat > "$KB_TMP/connectivity-guide.txt" << 'EOF'
# Product Support Guide: Wi-Fi and Bluetooth Connectivity

## Intermittent Wi-Fi drops (Error: NET-204)

NET-204 indicates repeated network disconnects. Resolution steps:

1. Move the device within 5 metres of the router for initial reconnection.
2. Temporarily disable any VPN or firewall software — these can block device traffic.
3. Ensure the router broadcasts on 2.4GHz; the device defaults to 2.4GHz for stability.
4. Check for a firmware update in Settings > Updates — NET-204 was patched in several releases.
5. Perform a network settings reset: hold the Network Reset button (pin-hole on base) for 5 seconds until the LED blinks amber three times.
6. If NET-204 returns within 24 hours after a factory reset, the Wi-Fi module is defective and the device needs replacement.

## Bluetooth pairing fails (Error: BT-301)

Bluetooth pairing failures are usually caused by stale pairing records or firmware issues:

1. Delete the existing pairing record on your phone: go to Bluetooth settings and forget the device.
2. Reset the device's Bluetooth stack: hold the Bluetooth button for 8 seconds until the LED blinks white.
3. Ensure no more than 3 devices are simultaneously paired (firmware limit).
4. Keep the device within 1 metre during pairing.
5. Update the device firmware — BT-301 was resolved in firmware version 2.3.1 and later.
6. If pairing fails on multiple phones after a stack reset, the Bluetooth module needs replacement.

## Smart home hub not detected in app (SKU-5 only)

1. Confirm the phone and hub are on the same Wi-Fi SSID — not a guest network.
2. Force-close and reopen the companion app.
3. Unplug the hub for 30 seconds and reconnect.
4. Revoke and re-grant the app's local network permission in phone settings.
5. Delete the hub and re-add as a new device.
EOF

# Doc 3: Hardware faults and escalation
cat > "$KB_TMP/hardware-escalation-guide.txt" << 'EOF'
# Product Support Guide: Hardware Faults and Escalation

## Hardware fault indicator — HW-900

HW-900 and a three-blink red LED pattern indicate a non-recoverable hardware fault.
This is detected by the device's self-test routine at boot.

IMPORTANT: Do NOT continue asking the customer to power-cycle the device. Repeated resets will not fix HW-900 and can worsen the fault.

Immediate escalation procedure:
1. Ask the customer for the serial number printed on the underside of the device or in Settings > About.
2. Request proof of purchase (order ID, receipt, or delivery confirmation).
3. Capture a brief description of when the fault first appeared.
4. Check warranty status: standard 12 months, Pro series 24 months, Premium tier 36 months.
5. For in-warranty devices, initiate express replacement — target delivery within 2 business days.
6. For out-of-warranty devices, present repair vs. replacement cost options.
7. Generate a support ticket with error code HW-900, serial number, and proof of purchase.

## Thermal shutdowns (Error: THERM-101)

Repeated thermal shutdowns indicate inadequate heat dissipation:

1. Remove any case or cover — restricted airflow is the most common cause.
2. Move the device to a cool, hard, well-ventilated surface.
3. Wait 15 minutes before powering on.
4. Clear dust from the ventilation vents using compressed air.
5. Avoid using the device while it is charging.
6. Three or more THERM-101 events in one week indicate a failing thermal management system — escalate.

## Display issues (Error: DISP-201)

Screen blank, flickering lines, or colour artefacts:

1. Press the power button twice rapidly to force a display reset.
2. Check brightness — it may be set to minimum.
3. Connect to an external display via the video output port (if available).
4. If the external display works but the built-in screen does not, the internal panel needs replacement.
5. DISP-201 with a working external display requires internal panel replacement service.

## Battery degradation (Error: BAT-401)

Fast battery drain and BAT-401 indicate cell degradation:

1. Check Settings > Battery > Health — readings below 80% trigger BAT-401.
2. Under 18 months old: eligible for warranty battery replacement.
3. Out of warranty: refer to the paid battery replacement programme.
4. Temporary workarounds: reduce brightness, disable background refresh, avoid simultaneous charging and heavy use.

## Firmware update failures (Error: FW-501)

Stuck or failed firmware updates:

1. Do not power off mid-update — wait at least 20 minutes before intervening.
2. If progress is stuck, use the recovery tool (downloadable from the support portal) to flash firmware manually.
3. Connect to a PC, launch the recovery tool, and follow the on-screen instructions.
4. If the recovery tool also fails, a factory reflash by the service team is required — escalate with code FW-501.

## Return and replacement policy

- Standard defect returns: 30 days from delivery.
- Defective unit (hardware fault): 90 days from delivery.
- HW-900 fault: 90-day window, extended to end of warranty for Pro/Premium.
- Always confirm eligibility via the order management tools before promising a replacement.
EOF

# Doc 4: Product warranty and support tiers
cat > "$KB_TMP/warranty-support-tiers.txt" << 'EOF'
# Warranty and Support Tier Guide

## Product warranty periods

| Product line | Warranty period | Notes |
|---|---|---|
| Standard widgets (SKU-1, SKU-3, SKU-6, SKU-9) | 12 months | From date of purchase |
| Pro series (SKU-2, SKU-4, SKU-5, SKU-7, SKU-8) | 24 months | From date of purchase |
| Premium-tier customers (all SKUs) | 36 months | Requires Premium subscription active at time of claim |

## Support response SLAs

| Priority | Trigger | Initial response | Resolution target |
|---|---|---|---|
| High | HW-900, BAT-401, DISP-201, THERM-101 (3+) | 4 business hours | 2 business days |
| Medium | BT-301, FW-501, BOOT-010 (persistent) | 1 business day | 5 business days |
| Low | NET-204, PWR-001, RET-010, general queries | 2 business days | 10 business days |

## Escalation triggers — when to open a ticket immediately

- Any HW-900 error code (do not attempt further DIY steps)
- Battery health below 80% on device under 18 months old
- DISP-201 with working external display
- Three or more THERM-101 shutdowns in one week
- NET-204 returning within 24 hours of a factory reset
- FW-501 where the recovery tool also fails
- Any issue on a device with a Premium-tier customer (priority queue)

## What to collect before opening a ticket

Required for high-priority hardware faults:
- Serial number (underside label or Settings > About)
- Proof of purchase date (order ID or receipt)
- Error code(s) displayed
- Steps already attempted

Optional but helpful for all tickets:
- Firmware version (Settings > About > Software version)
- Companion app version
- Brief description of when the issue first appeared
- Frequency (constant, intermittent, on specific actions)

## Factory reset procedure

Always confirm the customer has backed up data before a factory reset:
1. Cloud sync: Settings > Backup > Sync now
2. Navigate to Settings > System > Factory Reset > Confirm
3. The device reboots and shows a progress bar — do not power off (takes 3-8 minutes)
4. After reset, device boots to initial setup screen
5. If the factory reset fails or loops, use hardware recovery mode:
   - Power off
   - Hold Power + Volume-Up for 10 seconds until the recovery menu appears
   - Select "Wipe data / factory reset"
6. If recovery mode is inaccessible, escalate — eMMC storage may be failing
EOF

# Upload all KB docs to S3
for f in "$KB_TMP"/*.txt; do
  fname="$(basename "$f")"
  aws s3 cp "$f" "s3://$KB_BUCKET/docs/$fname" --quiet
  info "  Uploaded: docs/$fname"
done
success "KB source documents uploaded to s3://$KB_BUCKET/docs/"

# =============================================================================
# PHASE 6 — IAM role for Bedrock Knowledge Base
# =============================================================================
header "AWS — IAM role for Bedrock KB"

TRUST_POLICY="{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": { \"Service\": \"bedrock.amazonaws.com\" },
    \"Action\": \"sts:AssumeRole\",
    \"Condition\": {
      \"StringEquals\": { \"aws:SourceAccount\": \"$AWS_ACCOUNT_ID\" },
      \"ArnLike\": { \"aws:SourceArn\": \"arn:aws:bedrock:${AWS_REGION}:${AWS_ACCOUNT_ID}:knowledge-base/*\" }
    }
  }]
}"

IAM_ROLE_ARN="$(aws iam get-role --role-name "$IAM_ROLE_NAME" \
  --query 'Role.Arn' --output text 2>/dev/null || true)"

if [[ -z "$IAM_ROLE_ARN" ]]; then
  IAM_ROLE_ARN="$(aws iam create-role \
    --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Allows Bedrock Knowledge Base to access S3 and OpenSearch Serverless" \
    --query 'Role.Arn' --output text)"
  success "Created IAM role: $IAM_ROLE_ARN"
else
  # Role already exists — skip trust policy update (requires iam:UpdateAssumeRolePolicy
  # which SSO PowerUser roles typically don't have; the role was created correctly on first run)
  success "IAM role already exists: $IAM_ROLE_ARN"
fi

# S3 read policy
S3_POLICY="{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Action\": [\"s3:GetObject\", \"s3:ListBucket\"],
    \"Resource\": [
      \"arn:aws:s3:::${KB_BUCKET}\",
      \"arn:aws:s3:::${KB_BUCKET}/*\"
    ]
  }]
}"
aws iam put-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-name "BedrockKB-S3-${KB_BUCKET}" \
  --policy-document "$S3_POLICY" > /dev/null
success "S3 read policy attached"

# Secrets Manager policy — Bedrock KB needs to read the Atlas connection secret
SM_POLICY="{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Action\": [\"secretsmanager:GetSecretValue\", \"secretsmanager:DescribeSecret\"],
    \"Resource\": \"arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:${ATLAS_SECRET_NAME}*\"
  }]
}"
aws iam put-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-name "BedrockKB-SecretsManager" \
  --policy-document "$SM_POLICY" > /dev/null
success "Secrets Manager policy attached"

# Bedrock model invocation policy (for embedding during ingestion)
BEDROCK_POLICY="{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Action\": \"bedrock:InvokeModel\",
    \"Resource\": \"arn:aws:bedrock:${AWS_REGION}::foundation-model/amazon.titan-embed-text-v2:0\"
  }]
}"
aws iam put-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-name "BedrockKB-EmbedModel" \
  --policy-document "$BEDROCK_POLICY" > /dev/null
success "Bedrock embed model policy attached"

info "Waiting 10s for IAM role propagation..."
sleep 10

# =============================================================================
# PHASE 7 — Secrets Manager secret for Atlas credentials
# =============================================================================
header "AWS — Secrets Manager (Atlas credentials for Bedrock KB)"

# Store Atlas connection string + credentials in Secrets Manager so Bedrock KB
# can authenticate to MongoDB Atlas without hardcoding credentials.
# Secret value shape required by Bedrock KB MongoDB Atlas integration:
#   { "connectionString": "mongodb+srv://...", "username": "...", "password": "..." }
ATLAS_SECRET_VALUE="{
  \"connectionString\": \"mongodb+srv://${SRV_HOST}\",
  \"username\": \"${DB_USER}\",
  \"password\": \"${DB_PASSWORD}\"
}"

ATLAS_SECRET_ARN="$(aws secretsmanager describe-secret \
  --secret-id "$ATLAS_SECRET_NAME" \
  --query 'ARN' --output text 2>/dev/null || true)"

if [[ -z "$ATLAS_SECRET_ARN" || "$ATLAS_SECRET_ARN" == "None" ]]; then
  ATLAS_SECRET_ARN="$(aws secretsmanager create-secret \
    --name "$ATLAS_SECRET_NAME" \
    --description "MongoDB Atlas credentials for Bedrock KB troubleshooting-kb" \
    --secret-string "$ATLAS_SECRET_VALUE" \
    --query 'ARN' --output text)"
  success "Created Secrets Manager secret: $ATLAS_SECRET_ARN"
else
  aws secretsmanager put-secret-value \
    --secret-id "$ATLAS_SECRET_NAME" \
    --secret-string "$ATLAS_SECRET_VALUE" > /dev/null
  success "Updated Secrets Manager secret: $ATLAS_SECRET_ARN"
fi

# Resolve caller role ARN (needed for helper role creation in Phase 9)
CALLER_SESSION_ARN="$(aws sts get-caller-identity --query Arn --output text)"
CALLER_ROLE_NAME="$(echo "$CALLER_SESSION_ARN" | sed 's|.*assumed-role/||' | cut -d'/' -f1)"
CALLER_ROLE_ARN="$(aws iam get-role --role-name "$CALLER_ROLE_NAME" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "")"
if [[ -z "$CALLER_ROLE_ARN" ]]; then
  CALLER_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CALLER_ROLE_NAME}"
fi

# =============================================================================
# PHASE 8 — (skipped — no longer needed; Atlas Vector Search index already
#             exists as 'troubleshooting-vector-index' on troubleshooting_docs)
# =============================================================================

# =============================================================================
# PHASE 9 — Bedrock Knowledge Base
# =============================================================================
header "AWS — Bedrock Knowledge Base"

# The SSO PowerUser role is AWS-managed and cannot have iam:PassRole added to it.
# We create (once) a helper role with iam:PassRole + bedrock-agent:* permissions
# and assume it for Phases 9–10 only.  Original credentials are restored in Phase 11.
BEDROCK_HELPER_ROLE="${PROJECT_NAME}-bedrock-kb-creator-${ENVIRONMENT}"

HELPER_ARN="$(aws iam get-role --role-name "$BEDROCK_HELPER_ROLE" \
  --query 'Role.Arn' --output text 2>/dev/null || true)"

if [[ -z "$HELPER_ARN" || "$HELPER_ARN" == "None" ]]; then
  info "Creating helper role '$BEDROCK_HELPER_ROLE' for Bedrock KB creation..."
  HELPER_ARN="$(aws iam create-role \
    --role-name "$BEDROCK_HELPER_ROLE" \
    --assume-role-policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[{
        \"Effect\":\"Allow\",
        \"Principal\":{\"AWS\":\"${CALLER_ROLE_ARN}\"},
        \"Action\":\"sts:AssumeRole\"
      }]
    }" \
    --description "Temporary helper: PassRole + bedrock-agent:* for KB creation" \
    --query 'Role.Arn' --output text)"
  success "Created helper role: $HELPER_ARN"
else
  success "Helper role already exists: $HELPER_ARN"
fi

aws iam put-role-policy \
  --role-name "$BEDROCK_HELPER_ROLE" \
  --policy-name "BedrockKBCreate" \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"bedrock-agent:*\",\"bedrock:*\"],\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":\"iam:PassRole\",
       \"Resource\":\"${IAM_ROLE_ARN}\",
       \"Condition\":{\"StringEquals\":{\"iam:PassedToService\":\"bedrock.amazonaws.com\"}}}
    ]
  }" > /dev/null
success "Helper role policies updated"

info "Waiting 10s for helper role IAM propagation..."
sleep 10

# Assume helper role and swap credentials for Phases 9–10.
# Capture pattern is AUTH_MODE-aware so AWS_PROFILE callers restore correctly:
#   - If the caller had static keys, ORIG_KEY is non-empty → restore by re-exporting.
#   - If the caller used AWS_PROFILE (no static keys in env), ORIG_KEY is empty →
#     restore by `unset`-ing the three vars so AWS_PROFILE takes effect again.
ORIG_KEY="${AWS_ACCESS_KEY_ID:-}"
ORIG_SECRET="${AWS_SECRET_ACCESS_KEY:-}"
ORIG_TOKEN="${AWS_SESSION_TOKEN:-}"
ORIG_PROFILE="${AWS_PROFILE:-}"

HELPER_CREDS="$(aws sts assume-role \
  --role-arn "$HELPER_ARN" \
  --role-session-name "bedrock-kb-setup" \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text)"
export AWS_ACCESS_KEY_ID="$(echo "$HELPER_CREDS" | awk '{print $1}')"
export AWS_SECRET_ACCESS_KEY="$(echo "$HELPER_CREDS" | awk '{print $2}')"
export AWS_SESSION_TOKEN="$(echo "$HELPER_CREDS" | awk '{print $3}')"
info "Assumed helper role for Bedrock KB operations"

# Check if KB already exists
EXISTING_KB_ID="$(aws bedrock-agent list-knowledge-bases \
  --query "knowledgeBaseSummaries[?name=='${KB_NAME}'].knowledgeBaseId | [0]" \
  --output text 2>/dev/null || echo "None")"

if [[ "$EXISTING_KB_ID" != "None" && -n "$EXISTING_KB_ID" ]]; then
  BEDROCK_KB_ID="$EXISTING_KB_ID"
  success "Bedrock KB '$KB_NAME' already exists (id: $BEDROCK_KB_ID)"
else
  info "Creating Bedrock Knowledge Base '$KB_NAME'..."
  BEDROCK_KB_ID="$(aws bedrock-agent create-knowledge-base \
    --name "$KB_NAME" \
    --description "Troubleshooting product support articles (power, connectivity, hardware faults, warranty)" \
    --role-arn "$IAM_ROLE_ARN" \
    --knowledge-base-configuration "{
      \"type\": \"VECTOR\",
      \"vectorKnowledgeBaseConfiguration\": {
        \"embeddingModelArn\": \"arn:aws:bedrock:${AWS_REGION}::foundation-model/amazon.titan-embed-text-v2:0\"
      }
    }" \
    --storage-configuration "{
      \"type\": \"MONGO_DB_ATLAS\",
      \"mongoDbAtlasConfiguration\": {
        \"connectionStringSecretArn\": \"${ATLAS_SECRET_ARN}\",
        \"databaseName\": \"${MONGODB_DB}\",
        \"collectionName\": \"${ATLAS_COLLECTION}\",
        \"vectorIndexName\": \"${ATLAS_VECTOR_INDEX}\",
        \"fieldMapping\": {
          \"vectorField\": \"embedding\",
          \"textField\": \"body\",
          \"metadataField\": \"metadata\"
        }
      }
    }" \
    --query 'knowledgeBase.knowledgeBaseId' --output text)"
  success "Bedrock KB created: $BEDROCK_KB_ID"
fi

# Wait for KB to be ACTIVE
for i in $(seq 1 20); do
  KB_STATE="$(aws bedrock-agent get-knowledge-base --knowledge-base-id "$BEDROCK_KB_ID" \
    --query 'knowledgeBase.status' --output text 2>/dev/null || echo "CREATING")"
  if [[ "$KB_STATE" == "ACTIVE" ]]; then
    success "Knowledge Base is ACTIVE"; break
  fi
  [[ $i -eq 20 ]] && die "Timed out waiting for KB ACTIVE (state: $KB_STATE)"
  echo "  ... KB state: $KB_STATE (${i}/20)"
  sleep 15
done

# =============================================================================
# PHASE 10 — Bedrock KB data source + sync
# =============================================================================
header "AWS — Bedrock KB data source and sync"

# Check if data source exists
EXISTING_DS_ID="$(aws bedrock-agent list-data-sources \
  --knowledge-base-id "$BEDROCK_KB_ID" \
  --query "dataSourceSummaries[?name=='${KB_NAME}-s3'].dataSourceId | [0]" \
  --output text 2>/dev/null || echo "None")"

if [[ "$EXISTING_DS_ID" != "None" && -n "$EXISTING_DS_ID" ]]; then
  DS_ID="$EXISTING_DS_ID"
  success "Data source already exists (id: $DS_ID)"
else
  info "Creating S3 data source..."
  DS_ID="$(aws bedrock-agent create-data-source \
    --knowledge-base-id "$BEDROCK_KB_ID" \
    --name "${KB_NAME}-s3" \
    --description "Troubleshooting guides from S3" \
    --data-source-configuration "{
      \"type\": \"S3\",
      \"s3Configuration\": {
        \"bucketArn\": \"arn:aws:s3:::${KB_BUCKET}\",
        \"inclusionPrefixes\": [\"docs/\"]
      }
    }" \
    --vector-ingestion-configuration "{
      \"chunkingConfiguration\": {
        \"chunkingStrategy\": \"FIXED_SIZE\",
        \"fixedSizeChunkingConfiguration\": {
          \"maxTokens\": 300,
          \"overlapPercentage\": 20
        }
      }
    }" \
    --query 'dataSource.dataSourceId' --output text)"
  success "Data source created: $DS_ID"
fi

# Start ingestion sync job
info "Starting KB sync job (ingesting docs from S3)..."
INGESTION_JOB_ID="$(aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "$BEDROCK_KB_ID" \
  --data-source-id "$DS_ID" \
  --query 'ingestionJob.ingestionJobId' --output text)"

# Wait for ingestion to complete
info "Waiting for ingestion job to complete..."
for i in $(seq 1 30); do
  JOB_STATUS="$(aws bedrock-agent get-ingestion-job \
    --knowledge-base-id "$BEDROCK_KB_ID" \
    --data-source-id "$DS_ID" \
    --ingestion-job-id "$INGESTION_JOB_ID" \
    --query 'ingestionJob.status' --output text 2>/dev/null || echo "IN_PROGRESS")"
  if [[ "$JOB_STATUS" == "COMPLETE" ]]; then
    success "Ingestion complete"; break
  elif [[ "$JOB_STATUS" == "FAILED" ]]; then
    warn "Ingestion job failed — check AWS console for details. Continuing..."
    break
  fi
  [[ $i -eq 30 ]] && { warn "Ingestion still in progress — check console later"; break; }
  echo "  ... ingestion status: $JOB_STATUS (${i}/30)"
  sleep 10
done

# Restore original credentials after Bedrock operations.
# When the caller used AWS_PROFILE (no static keys in env), unset the three
# helper-role vars so the CLI re-resolves credentials via the profile.
if [[ -n "$ORIG_KEY" ]]; then
  export AWS_ACCESS_KEY_ID="$ORIG_KEY"
  export AWS_SECRET_ACCESS_KEY="$ORIG_SECRET"
  if [[ -n "$ORIG_TOKEN" ]]; then
    export AWS_SESSION_TOKEN="$ORIG_TOKEN"
  else
    unset AWS_SESSION_TOKEN
  fi
else
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
fi
if [[ -n "$ORIG_PROFILE" ]]; then
  export AWS_PROFILE="$ORIG_PROFILE"
fi
info "Restored original credentials"

# =============================================================================
# PHASE 11 — Write .env.live
# =============================================================================
header "Writing .env.live"

ENV_FILE="$REPO_ROOT/.env.live"
cat > "$ENV_FILE" << ENVEOF
# Generated by setup-troubleshooting-infra.sh — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Start the API:  source .env.live && cd api && bun run dev
# Note: the API still requires AGENTCORE_ORCHESTRATOR_ARN at startup.

export MONGODB_URI="${MONGODB_URI}"
export MONGODB_DB="${MONGODB_DB}"
export BEDROCK_KB_ID="${BEDROCK_KB_ID}"
# Strict-mode embeddings — EMBEDDINGS_PROVIDER must be set explicitly so the
# API boot guard accepts this .env.live. Troubleshooting infra is Titan-only
# (no Voyage SageMaker provisioned).
export EMBEDDINGS_PROVIDER="titan"
export EMBEDDING_MODEL_ID="${EMBED_MODEL_ID}"
export EMBEDDING_DIMENSIONS="${EMBEDDING_DIMENSIONS}"
export AWS_REGION="${AWS_REGION}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
export LOG_LEVEL=info
ENVEOF

success ".env.live written to $ENV_FILE"
info  "  NOTE: AWS STS session tokens expire. Refresh from .env when they do."

# =============================================================================
# SUMMARY
# =============================================================================
header "Setup complete"
echo ""
echo -e "  ${GREEN}Atlas cluster${NC}      $CLUSTER_NAME  (${CLUSTER_TIER}, US_EAST_1)"
echo -e "  ${GREEN}MongoDB URI${NC}        mongodb+srv://${DB_USER}:***@${SRV_HOST}/..."
echo -e "  ${GREEN}Bedrock KB${NC}         $BEDROCK_KB_ID  (vector store: MongoDB Atlas)"
echo -e "  ${GREEN}S3 bucket${NC}          s3://$KB_BUCKET"
echo -e "  ${GREEN}Atlas collection${NC}   ${MONGODB_DB}.${ATLAS_COLLECTION}  (index: ${ATLAS_VECTOR_INDEX})"
echo -e "  ${GREEN}Atlas secret${NC}       $ATLAS_SECRET_ARN"
echo -e "  ${GREEN}Embed model${NC}        $EMBED_MODEL_ID  (${EMBEDDING_DIMENSIONS}d)"
echo ""
echo -e "${BOLD}To start the API against live backends:${NC}"
echo "  source .env.live"
echo "  cd api && bun run dev"
echo ""
echo -e "${BOLD}Smoke test:${NC}"
echo "  curl -s http://localhost:3000/health | jq .dependencies"
echo ""
echo -e "${YELLOW}Atlas vector search indexes build asynchronously — allow 2-3 minutes${NC}"
echo -e "${YELLOW}after seeding before running vector search queries.${NC}"
echo ""
