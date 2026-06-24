#!/usr/bin/env bash
# _mongo-connect.sh — shared helper for MongoDB connectivity assertion.
#
# Sourceable bash module. Provides:
#   sanitize_mongo_uri <uri>                  → echoes redacted form
#   assert_mongo_reachable <uri> <db> [budget_sec]
#                                            → exit 0 on success, non-zero on failure
#
# Behavior:
#   - Uses `bun -e` to run a minimal MongoClient ping (no mongosh/pymongo deps).
#   - Retries with exponential backoff (30s → 60s) up to a total budget
#     (default 300s / 5 min). Logs sanitized URI on each attempt.
#   - On final failure, emits a structured diagnostic envelope to stderr:
#       URI host, NETWORK_MODE, allowlist CIDR, cluster stateName,
#       PrivateLink endpoint state (where derivable from env).
#   - SIGPIPE-safe: never pipes bun output through head/grep/awk inside $().
#
# Idempotent sourcing — guarded against double-source.

if [[ -n "${_MONGO_CONNECT_SH_SOURCED:-}" ]]; then
  return 0
fi
_MONGO_CONNECT_SH_SOURCED=1

# Shared transient-error classifier (DNS resolver + network/transport blips).
# shellcheck source=deploy/scripts/_transient-errors.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_transient-errors.sh"

_mc_log()  { echo "  [mongo-probe] $*"; }
_mc_warn() { echo "  [mongo-probe] ⚠ $*" >&2; }
_mc_err()  { echo "  [mongo-probe] ✗ $*" >&2; }

# Redact `user:password` from a Mongo URI for safe logging.
sanitize_mongo_uri() {
  local uri="${1:-}"
  # Match `://userpart:passwordpart@` and replace with `://****:****@`.
  printf '%s' "$uri" | sed -E 's|://[^@]+@|://****:****@|'
}

# Inner bun script — receives URI + DB from env, prints OK <host> or an error
# message. The <host> on success is the actual node the driver connected to
# (from hello.me) so callers can verify NETWORK_MODE-correct DNS resolution.
# Inlined so callers don't need an extra file on disk.
_mc_run_bun_ping() {
  # URI/DB come from MONGO_URI / MONGO_DB env (set by assert_mongo_reachable caller).
  # Driver spec resolved from $MONGO_PROBE_DRIVER_SPEC (single source of truth in
  # _transient-errors.sh) — a bare `import "mongodb"` at repo root floats to the
  # newest cached version, and bson@7.3.0 crashes at module load under Bun 1.3.13.
  bun -e '
const { MongoClient } = await import(process.env.MONGO_PROBE_DRIVER_SPEC || "mongodb");
const uri = process.env.MONGO_URI;
const dbName = process.env.MONGO_DB;
const timeoutMs = Number(process.env.MONGO_TIMEOUT_MS || "8000");
const client = new MongoClient(uri, { appName: "deploy-mongo-probe", serverSelectionTimeoutMS: timeoutMs });
try {
  await client.connect();
  await client.db(dbName).command({ ping: 1 });
  let connectedHost = "";
  try {
    const hello = await client.db(dbName).command({ hello: 1 });
    connectedHost = String(hello?.me || hello?.primary || "");
  } catch (_) {}
  process.stdout.write("OK " + connectedHost);
} catch (e) {
  process.stdout.write("ERR " + (e && e.message ? e.message : String(e)));
} finally {
  try { await client.close(); } catch (_) {}
}
' <<<"" 2>&1 || true
}

# Emit a structured failure envelope to stderr — operator-actionable signal.
# Uses bash globals when available; safe to call with most of them unset.
_mc_emit_failure_envelope() {
  local uri="$1"
  local err="$2"
  local sanitized
  sanitized="$(sanitize_mongo_uri "$uri")"
  # Classify the final error so the operator knows whether this is a local
  # resolver blip (safe to rerun) vs a real Atlas/allowlist/state problem.
  local kind hint
  kind="$(deploy_error_kind "$err")"
  case "$kind" in
    dns)
      hint="local DNS resolver failure — NOT a code, Terraform, IAM, or AWS-side problem. Check VPN/proxy/resolver state and simply rerun the deploy."
      ;;
    network)
      hint="transient network/transport blip — usually clears on a rerun. If it persists, check egress (corp proxy/firewall) and Atlas status."
      ;;
    *)
      hint="check Atlas allowlist, PrivateLink/peering state, cluster IDLE state"
      ;;
  esac
  echo "  ╭── mongo connectivity failure ────────────────────────────────────" >&2
  echo "  │ uri          : ${sanitized}" >&2
  echo "  │ last_error   : ${err}" >&2
  echo "  │ error_class  : ${kind}" >&2
  echo "  │ network_mode : ${NETWORK_MODE:-(unset)}" >&2
  echo "  │ atlas_project: ${TF_VAR_atlas_project_id:-${TF_VAR_mongodb_atlas_project_id:-(unset)}}" >&2
  echo "  │ atlas_host   : ${ATLAS_MONGO_HOST:-(unset)}" >&2
  echo "  │ peering_cidr : ${ATLAS_PEERING_CIDR:-(unset)}" >&2
  echo "  │ pl_endpoint  : ${ATLAS_PRIVATELINK_ENDPOINT_ID:-(unset)}" >&2
  echo "  │ hint         : ${hint}" >&2
  echo "  │ doc          : docs/status/debugging.md#mongo-connectivity-deploy-time" >&2
  echo "  ╰────────────────────────────────────────────────────────────────────" >&2
}

# assert_mongo_reachable <uri> <db_name> [retry_max_sec]
#
# Returns 0 on success, 1 on auth/parse failure, 2 on timeout/budget exhausted.
assert_mongo_reachable() {
  local uri="$1"
  local db="$2"
  # Default 300s budget; override via MONGO_PROBE_BUDGET_SEC (e.g. on flaky
  # local resolvers / VPNs) without touching call sites.
  local budget_sec="${3:-${MONGO_PROBE_BUDGET_SEC:-300}}"
  if [[ -z "$uri" ]]; then
    _mc_err "MONGODB_URI is empty"
    return 1
  fi
  if [[ -z "$db" ]]; then
    _mc_err "MONGODB_DB is empty"
    return 1
  fi
  if ! command -v bun >/dev/null 2>&1; then
    _mc_err "bun not on PATH — required for mongo connectivity probe"
    return 1
  fi

  local sanitized
  sanitized="$(sanitize_mongo_uri "$uri")"
  local started=$SECONDS
  local delay=30
  local attempt=1
  local last_err=""

  while (( SECONDS - started < budget_sec )); do
    _mc_log "attempt ${attempt}: ${sanitized}"
    local probe_out
    probe_out="$(MONGO_URI="$uri" MONGO_DB="$db" MONGO_TIMEOUT_MS=8000 _mc_run_bun_ping)"
    if [[ "$probe_out" == "OK" || "$probe_out" == OK\ * ]]; then
      local connected_host="${probe_out#OK}"
      connected_host="${connected_host# }"
      _mc_log "✓ ${sanitized} reachable (db=${db}, attempt=${attempt}${connected_host:+, host=${connected_host}})"
      return 0
    fi
    last_err="${probe_out#ERR }"
    # Single-attempt diagnostic so operator sees each retry's real cause.
    _mc_warn "attempt ${attempt} failed: ${last_err}"
    local remaining=$(( budget_sec - (SECONDS - started) ))
    if (( remaining <= 0 )); then break; fi
    local sleep_for=$(( delay < remaining ? delay : remaining ))
    sleep "$sleep_for"
    attempt=$(( attempt + 1 ))
    # Exponential backoff: 30 → 45 → 60 (capped).
    delay=$(( delay + 15 ))
    (( delay > 60 )) && delay=60
  done

  _mc_err "Mongo connection did not succeed within ${budget_sec}s after ${attempt} attempts"
  _mc_emit_failure_envelope "$uri" "$last_err"
  return 2
}
