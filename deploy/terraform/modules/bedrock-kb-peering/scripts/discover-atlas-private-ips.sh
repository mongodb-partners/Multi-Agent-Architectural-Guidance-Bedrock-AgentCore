#!/usr/bin/env bash
# discover-atlas-private-ips.sh — resolve Atlas mongod peering IPs via SSM dig
#
# DUAL-MODE script — protocol detected automatically:
#
#   1. terraform-external mode (default): no env vars, reads JSON query from
#      stdin (Terraform `data "external"` protocol), writes a flat JSON object
#      with comma-joined IPs to stdout:
#          {"ips": "10.0.1.5,10.0.1.6,10.0.1.7", "count": "3", ...}
#      This is what modules/bedrock-kb-peering/main.tf calls — plan-time
#      discovery without an intermediate file-on-disk that breaks fresh
#      deploys (the previous design used a local_file data source that fails
#      with "no such file or directory" on the very first `terraform plan`,
#      forcing a two-pass apply).
#
#   2. legacy STATE_FILE mode: set STATE_FILE env var and the script writes
#      the same data to that file as JSON. Used to be the only mode; kept
#      for any out-of-tree caller still wired to the old shape.
#
# Atlas peering exposes mongod hosts at <shard>.<cluster>.<region>-pri.mongodb.net
# whose A records resolve to private IPs ONLY from a VPC that's peered with
# Atlas (with "Private DNS for Peering" enabled at the project level, or via
# Atlas SRV resolution over the peered DNS path).
#
# Operator's laptop sees public IPs (or NXDOMAIN); EC2 in the peered VPC sees
# private IPs in ATLAS_PEERING_CIDR. We therefore run `dig` from EC2 via
# SSM send-command, capture stdout, parse IPs, sanity-check against
# ATLAS_PEERING_CIDR, and surface the result.
#
# Failure modes are HARD failures (set -euo pipefail). NLB target group has a
# precondition that empty IP list aborts the apply.

set -euo pipefail

# Detect mode. If STATE_FILE is set (legacy) or the caller is running this
# script directly with explicit env, skip the stdin JSON read. Otherwise the
# script is acting as a terraform `data "external"` and must read its
# parameters from a JSON object on stdin.
EXTERNAL_MODE=true
if [[ -n "${STATE_FILE:-}" ]]; then
  EXTERNAL_MODE=false
fi

# In external mode all logging goes to stderr so stdout stays pure JSON.
if [[ "$EXTERNAL_MODE" == "true" ]]; then
  log() { echo "[bedrock-kb-peering] $*" >&2; }
  err() { echo "[bedrock-kb-peering] ERROR: $*" >&2; exit 1; }
else
  log() { echo "[bedrock-kb-peering] $*"; }
  err() { echo "[bedrock-kb-peering] ERROR: $*" >&2; exit 1; }
fi

command -v aws     >/dev/null || err "aws CLI not in PATH"
command -v python3 >/dev/null || err "python3 not in PATH"
command -v jq      >/dev/null || err "jq not in PATH"

# ── Parameter source ────────────────────────────────────────────────────────
# external mode: parse JSON from stdin (Terraform passes the `query` block).
# legacy mode  : read env vars as before.
if [[ "$EXTERNAL_MODE" == "true" ]]; then
  QUERY_JSON=$(cat)
  AWS_REGION=$(echo "$QUERY_JSON" | jq -r '.aws_region // empty')
  EC2_INSTANCE_ID=$(echo "$QUERY_JSON" | jq -r '.ec2_instance_id // empty')
  ATLAS_SRV_HOST=$(echo "$QUERY_JSON" | jq -r '.atlas_srv_host // empty')
  ATLAS_PEERING_CIDR=$(echo "$QUERY_JSON" | jq -r '.atlas_peering_cidr // empty')

  # On the very first plan (before EC2 exists yet), ec2_instance_id is empty
  # because module.ec2 hasn't been applied. Return an empty IP list so the
  # data source succeeds; the NLB target_group precondition (length>0) then
  # fires AT APPLY TIME after EC2 has been created and the second pass of
  # plan can call SSM successfully. This is the key to single-shot apply.
  if [[ -z "$EC2_INSTANCE_ID" || "$EC2_INSTANCE_ID" == "null" ]]; then
    log "ec2_instance_id is empty — likely first plan, EC2 not yet created. Returning empty IP set so plan succeeds; real discovery happens after EC2 is up."
    printf '{"ips":"","count":"0","ec2_instance_id":"","ssm_command_id":"","discovered_at":""}\n'
    exit 0
  fi
else
  : "${AWS_REGION:?required}"
  : "${EC2_INSTANCE_ID:?required}"
  : "${ATLAS_SRV_HOST:?required}"
  : "${ATLAS_PEERING_CIDR:?required}"
  : "${STATE_FILE:?required}"
fi

[[ -n "$AWS_REGION"         ]] || err "aws_region missing from query"
[[ -n "$ATLAS_SRV_HOST"     ]] || err "atlas_srv_host missing from query"
[[ -n "$ATLAS_PEERING_CIDR" ]] || err "atlas_peering_cidr missing from query"

log "running SSM send-command on ${EC2_INSTANCE_ID} to resolve _mongodb._tcp.${ATLAS_SRV_HOST}"

# Pre-installed on AL2023 standard AMI v9.18.28+ via bind-utils. Command does:
#   1. dig SRV record to get the per-shard hostnames Atlas advertises.
#   2. dig A record for each hostname to get the peering IPs.
#   3. dedup and print.
CMD_ID=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$EC2_INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "bedrock-kb-peering: discover Atlas private IPs" \
  --parameters "commands=[\"set -e; for h in \$(dig +short SRV _mongodb._tcp.${ATLAS_SRV_HOST} | awk '{print \$4}' | sed 's/\\\\.$//'); do dig +short A \$h; done | sort -u\"]" \
  --query "Command.CommandId" --output text)

[[ -n "$CMD_ID" ]] || err "SSM send-command returned no CommandId"
log "SSM command id: ${CMD_ID} — polling for completion"

# Poll for completion (up to 2 minutes — SSM agent takes ~5-10s to ack, then dig is sub-second)
STATUS=""
STDOUT=""
STDERR=""
for attempt in $(seq 1 24); do
  sleep 5
  INVOCATION=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$CMD_ID" \
    --instance-id "$EC2_INSTANCE_ID" \
    --output json 2>/dev/null || echo '{}')
  STATUS=$(echo "$INVOCATION" | jq -r '.Status // "Pending"')
  case "$STATUS" in
    Success)
      STDOUT=$(echo "$INVOCATION" | jq -r '.StandardOutputContent // ""')
      break
      ;;
    Failed|Cancelled|TimedOut)
      STDERR=$(echo "$INVOCATION" | jq -r '.StandardErrorContent // ""')
      err "SSM command status=${STATUS}. stderr: ${STDERR}"
      ;;
    *)
      log "  status=${STATUS} (attempt ${attempt}/24, sleeping 5s)"
      ;;
  esac
done

if [[ "$STATUS" != "Success" ]]; then
  err "SSM command did not reach Success within 2 minutes (last status=${STATUS})"
fi

log "raw dig output:"
echo "$STDOUT" | sed 's/^/    /' >&2

# Parse IPs (one per line, IPv4 dotted-quad). Use while-read loop because
# macOS ships bash 3.2 which doesn't have mapfile/readarray (added in 4.0).
RAW_IPS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && RAW_IPS+=("$line")
done < <(echo "$STDOUT" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)

if (( ${#RAW_IPS[@]} == 0 )); then
  err "no IPs discovered from dig output. Verify Atlas peering is ACTIVE and 'Private DNS for Peering' is enabled (or that ${ATLAS_SRV_HOST} resolves to private IPs from inside the peered VPC)."
fi

# Sanity-check: discovered IPs must fall inside ATLAS_PEERING_CIDR. If they
# don't, peering isn't routing right (or DNS is resolving to public IPs) and
# the NLB would proxy public traffic to Bedrock — abort.
VALID_IPS=()
for ip in "${RAW_IPS[@]}"; do
  if python3 -c "
import ipaddress, sys
ip = ipaddress.ip_address('${ip}')
net = ipaddress.ip_network('${ATLAS_PEERING_CIDR}')
sys.exit(0 if ip in net else 1)
"; then
    VALID_IPS+=("$ip")
  else
    log "WARNING: discovered IP ${ip} is OUTSIDE ATLAS_PEERING_CIDR ${ATLAS_PEERING_CIDR} — likely public IP, skipping"
  fi
done

if (( ${#VALID_IPS[@]} == 0 )); then
  err "no discovered IPs fall inside ATLAS_PEERING_CIDR ${ATLAS_PEERING_CIDR}. Atlas Private DNS for Peering is likely off, or the project peering is not yet ACTIVE — re-run after enabling."
fi

log "discovered ${#VALID_IPS[@]} valid IP(s): ${VALID_IPS[*]}"

# ── Emit result ──────────────────────────────────────────────────────────────
# external mode: flat JSON object to stdout (Terraform external protocol).
# legacy mode  : full JSON object to STATE_FILE.
if [[ "$EXTERNAL_MODE" == "true" ]]; then
  # comma-join the IPs — terraform external only allows flat string values.
  # Caller splits with `split(",", data.external.atlas_ips.result.ips)`.
  IFS=,
  IPS_CSV="${VALID_IPS[*]}"
  unset IFS
  printf '{"ips":"%s","count":"%d","ec2_instance_id":"%s","ssm_command_id":"%s","discovered_at":"%s"}\n' \
    "$IPS_CSV" "${#VALID_IPS[@]}" "$EC2_INSTANCE_ID" "$CMD_ID" "$(date -u +%FT%TZ)"
else
  printf '%s\n' "${VALID_IPS[@]}" | STATE_FILE="$STATE_FILE" CMD_ID="$CMD_ID" EC2_INSTANCE_ID="$EC2_INSTANCE_ID" python3 - <<'PY'
import json, os, datetime, sys
ips = [line.strip() for line in sys.stdin if line.strip()]
with open(os.environ['STATE_FILE'], 'w') as f:
    json.dump({
        'ips': ips,
        'discovered_at': datetime.datetime.utcnow().isoformat() + 'Z',
        'ssm_command_id': os.environ['CMD_ID'],
        'ec2_instance_id': os.environ['EC2_INSTANCE_ID'],
    }, f, indent=2)
PY
  log "state written: ${STATE_FILE}"
fi
