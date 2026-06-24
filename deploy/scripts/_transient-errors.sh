#!/usr/bin/env bash
# _transient-errors.sh — shared classification of transient deploy-time failures.
#
# Sourceable bash module. Provides ONE source of truth for "is this error a
# transient local-resolver / network blip that is safe to retry or rerun?" so
# every deploy surface (Terraform apply, the Mongo connectivity probe, Atlas /
# AWS curl probes, Docker push, ECR login) classifies failures the same way.
#
# Rationale: recent deploy hardening made the Mongo reachability + seed gate
# fail fast (good), but the various retry loops each hand-rolled a narrow regex
# (e.g. `cloud.mongodb.com.*(i/o timeout|...)`) that missed common local DNS
# resolver wording — so a transient `querySrv ETIMEOUT` / `EAI_AGAIN` / "Could
# not resolve host" blip aborted the whole deploy with a misleading
# "non-transient error", even though a rerun reliably succeeds.
#
# Functions (all accept a single string arg unless noted):
#   deploy_error_is_transient_dns <text>      → 0 if text matches a local DNS
#                                                resolver failure
#   deploy_error_is_transient_network <text>  → 0 if text matches a retryable
#                                                network/transport failure
#   deploy_error_is_transient <text>          → 0 if dns OR network
#   deploy_log_has_transient_error <file>     → 0 if file content is transient
#   deploy_error_kind <text>                  → echoes 'dns' | 'network' | 'none'
#
# Deliberately NOT classified as transient (these stay fatal):
#   - auth / credential errors (401/403, AccessDenied, SignatureDoesNotMatch,
#     authentication failed, bad auth)
#   - malformed URI / invalid connection string
#   - TLS *certificate* validation errors (cert mismatch / expired / self-signed)
#   - authorization / IAM denials
# Callers that need those fatal are responsible for ordering their own checks;
# these matchers only ever answer "is it a retryable resolver/network blip?".
#
# Idempotent sourcing — guarded against double-source.

if [[ -n "${_TRANSIENT_ERRORS_SH_SOURCED:-}" ]]; then
  return 0
fi
_TRANSIENT_ERRORS_SH_SOURCED=1

# ── Mongo driver spec for deploy-time `bun -e` probes ────────────────────────
# Single source of truth, consumed by every deploy-time `bun -e` Mongo probe
# (_mongo-connect.sh, deploy-project.sh seed-state check, _seed-embeddings.sh
# rewire-detect, _preflight-checks.sh embedding check) via dynamic import of
# $MONGO_PROBE_DRIVER_SPEC.
#
# Why this exists: those probes run a bare `import "mongodb"` from the repo root,
# where there is no package.json/node_modules, so Bun resolves the NEWEST cached
# version. bson@7.3.0 (a transitive dep of mongodb@7.3.0) calls
# `node:v8 startupSnapshot.isBuildingSnapshot()` at module load, which Bun 1.3.13
# has not implemented → the import throws ERR_NOT_IMPLEMENTED before any network
# attempt and the deploy aborts with a misleading "mongo connectivity failure".
# Pin to a Bun-safe 6.x line (matches what api/ ships). Override per-environment
# by exporting MONGO_PROBE_DRIVER_SPEC before invoking the deploy scripts (e.g.
# once Bun implements the API or a newer driver is verified safe).
# See mongo-probe-bun-bson-failure-report.md.
: "${MONGO_PROBE_DRIVER_SPEC:=mongodb@6.21.0}"
export MONGO_PROBE_DRIVER_SPEC

# ── Local DNS resolver failures ──────────────────────────────────────────────
# Covers every tool a deploy shells out to:
#   • Node.js dns/mongodb SRV: querySrv ETIMEOUT / ENOTFOUND / EAI_AGAIN
#   • libc getaddrinfo: macOS "nodename nor servname", glibc "Name or service
#     not known" / "Temporary failure in name resolution"
#   • Go net resolver (Terraform/providers/docker): "lookup ... no such host",
#     "server misbehaving", "SERVFAIL"
#   • curl: "Could not resolve host"
#   • AWS CLI / botocore: "Could not connect to the endpoint URL" (DNS-or-route
#     ambiguous; treated as transient because the deploy action is identical)
#   • Python requests/urllib3: "Failed to resolve" / "getaddrinfo failed"
# These are operator-machine / VPN / resolver state, never a code/Terraform/
# IAM/AWS-resource problem. NXDOMAIN is deliberately EXCLUDED — a definitive
# "host does not exist" usually means a real typo/misconfig, not a blip.
_TE_DNS_PATTERN='querySrv|EAI_AGAIN|ENOTFOUND|ETIMEOUT|getaddrinfo|nodename nor servname|could not resolve host|couldn'"'"'t resolve host|could not connect to the endpoint url|failed to resolve|temporary failure in name resolution|name or service not known|no such host|server misbehaving|servfail|dns operation timed out|dns lookup|name resolution'

# ── Retryable network / transport failures ───────────────────────────────────
# Discrete, specific phrases only — intentionally NO bare "timeout" so genuinely
# fatal errors that merely mention the word are not silently retried. Covers:
#   • Go/Terraform/Atlas control plane: i/o timeout, TLS handshake timeout,
#     connection reset|refused, EOF, dial tcp, 502/503/504
#   • botocore / AWS CLI: EndpointConnectionError, ConnectTimeoutError,
#     ReadTimeoutError, "Connect timeout on endpoint URL"
#   • Python requests/urllib3: "Max retries exceeded", "Failed to establish a
#     new connection", "Connection aborted", "Read timed out"
_TE_NET_PATTERN='i/o timeout|tls handshake timeout|connection reset|connection refused|connection aborted|network is unreachable|broken pipe|dial tcp|failed to do request|request canceled|\bEOF\b|502 bad gateway|503 service|504 gateway|service unavailable|temporarily unavailable|connection timed out|operation timed out|read timed out|the read operation timed out|endpointconnectionerror|connecttimeouterror|readtimeouterror|connect timeout on endpoint|max retries exceeded|failed to establish a new connection'

deploy_error_is_transient_dns() {
  local text="${1:-}"
  [[ -z "$text" ]] && return 1
  printf '%s' "$text" | grep -qiE "$_TE_DNS_PATTERN"
}

deploy_error_is_transient_network() {
  local text="${1:-}"
  [[ -z "$text" ]] && return 1
  printf '%s' "$text" | grep -qiE "$_TE_NET_PATTERN"
}

deploy_error_is_transient() {
  local text="${1:-}"
  deploy_error_is_transient_dns "$text" || deploy_error_is_transient_network "$text"
}

# Echoes the classification so callers can branch on the cause for messaging.
deploy_error_kind() {
  local text="${1:-}"
  if deploy_error_is_transient_dns "$text"; then
    printf 'dns'
  elif deploy_error_is_transient_network "$text"; then
    printf 'network'
  else
    printf 'none'
  fi
}

# File wrapper for Terraform / Docker log files captured via `tee`.
deploy_log_has_transient_error() {
  local file="${1:-}"
  [[ -f "$file" ]] || return 1
  grep -qiE "${_TE_DNS_PATTERN}|${_TE_NET_PATTERN}" "$file"
}

# ──────────────────────────────────────────────────────────────────────────────
# Self-test — run directly: `bash deploy/scripts/_transient-errors.sh --self-test`
# Pure string classification, no AWS / network. Safe for CI.
# ──────────────────────────────────────────────────────────────────────────────
_te_self_test() {
  local fail=0 n=0
  _te_expect() { # <desc> <expect:0|1> <fn> <text>
    local desc="$1" expect="$2" fn="$3" text="$4"
    n=$((n + 1))
    "$fn" "$text"
    local rc=$?
    if [[ "$expect" == "0" && $rc -eq 0 ]] || [[ "$expect" == "1" && $rc -ne 0 ]]; then
      echo "  ✓ ${desc}"
    else
      echo "  ✗ ${desc} (fn=${fn} expect=${expect} got_rc=${rc} text='${text}')"
      fail=1
    fi
  }

  echo "── _transient-errors.sh self-test ──"

  # DNS-class — must be transient (the reported failure mode).
  _te_expect "node SRV querySrv ETIMEOUT"      0 deploy_error_is_transient_dns "querySrv ETIMEOUT _mongodb._tcp.cluster.mongodb.net"
  _te_expect "node ENOTFOUND"                  0 deploy_error_is_transient_dns "getaddrinfo ENOTFOUND cluster.mongodb.net"
  _te_expect "node EAI_AGAIN"                  0 deploy_error_is_transient_dns "getaddrinfo EAI_AGAIN sts.amazonaws.com"
  _te_expect "macOS nodename nor servname"     0 deploy_error_is_transient_dns "nodename nor servname provided, or not known"
  _te_expect "curl could not resolve host"     0 deploy_error_is_transient_dns "curl: (6) Could not resolve host: cloud.mongodb.com"
  _te_expect "glibc name resolution"           0 deploy_error_is_transient_dns "Temporary failure in name resolution"
  _te_expect "go resolver no such host"        0 deploy_error_is_transient_dns "lookup ecr.us-east-1.amazonaws.com: no such host"
  _te_expect "go resolver server misbehaving"  0 deploy_error_is_transient_dns "read udp: server misbehaving"

  # AWS CLI / botocore / python — must be transient (tools deploy shells out to).
  _te_expect "aws cli endpoint url (dns)"      0 deploy_error_is_transient_dns "Could not connect to the endpoint URL: \"https://ecr.us-east-1.amazonaws.com/\""
  _te_expect "python failed to resolve"        0 deploy_error_is_transient_dns "Failed to resolve 'sts.amazonaws.com' ([Errno -3])"
  _te_expect "go SERVFAIL"                     0 deploy_error_is_transient_dns "lookup cloud.mongodb.com: SERVFAIL"
  _te_expect "botocore EndpointConnection"     0 deploy_error_is_transient_network "EndpointConnectionError: Could not connect to the endpoint URL"
  _te_expect "botocore ConnectTimeout"         0 deploy_error_is_transient_network "ConnectTimeoutError: Connect timeout on endpoint URL"
  _te_expect "urllib3 max retries"             0 deploy_error_is_transient_network "HTTPSConnectionPool: Max retries exceeded with url"
  _te_expect "requests new connection"         0 deploy_error_is_transient_network "Failed to establish a new connection: [Errno 110]"
  _te_expect "requests connection aborted"     0 deploy_error_is_transient_network "Connection aborted, RemoteDisconnected"
  _te_expect "requests read timed out"         0 deploy_error_is_transient_network "HTTPSConnectionPool: Read timed out"

  # Network-class — must be transient.
  _te_expect "i/o timeout"                     0 deploy_error_is_transient_network "Post cloud.mongodb.com: dial tcp: i/o timeout"
  _te_expect "connection reset"                0 deploy_error_is_transient_network "read: connection reset by peer"
  _te_expect "TLS handshake timeout"           0 deploy_error_is_transient_network "net/http: TLS handshake timeout"
  _te_expect "503 service"                     0 deploy_error_is_transient_network "received 503 Service Unavailable"

  # Combined helper.
  _te_expect "combined catches DNS"            0 deploy_error_is_transient "Could not resolve host: ecr.amazonaws.com"
  _te_expect "combined catches network"        0 deploy_error_is_transient "dial tcp 1.2.3.4:443: i/o timeout"

  # NON-transient — must stay fatal (must NOT classify as transient).
  _te_expect "auth 401 not transient"          1 deploy_error_is_transient "HTTP 401 Unauthorized: bad auth Authentication failed"
  _te_expect "access denied not transient"     1 deploy_error_is_transient "AccessDenied: User is not authorized to perform iam:PassRole"
  _te_expect "malformed uri not transient"     1 deploy_error_is_transient "Invalid connection string: missing host"
  _te_expect "cert mismatch not transient"     1 deploy_error_is_transient "x509: certificate is valid for a.com, not b.com"
  _te_expect "signature not transient"         1 deploy_error_is_transient "SignatureDoesNotMatch: request signature mismatch"
  _te_expect "NXDOMAIN not transient"          1 deploy_error_is_transient "lookup typo-host.invalid: NXDOMAIN (host does not exist)"
  _te_expect "no such bucket not transient"    1 deploy_error_is_transient "NoSuchBucket: The specified bucket does not exist"
  _te_expect "validation err not transient"    1 deploy_error_is_transient "ValidationException: parameter is invalid"
  _te_expect "empty string not transient"      1 deploy_error_is_transient ""

  # deploy_error_kind classification.
  _te_expect_kind() { # <desc> <expect> <text>
    n=$((n + 1))
    local got; got="$(deploy_error_kind "$3")"
    if [[ "$got" == "$2" ]]; then echo "  ✓ $1"; else echo "  ✗ $1 (expect=$2 got=$got)"; fail=1; fi
  }
  _te_expect_kind "kind dns"     dns     "ENOTFOUND cluster.mongodb.net"
  _te_expect_kind "kind network" network "dial tcp: i/o timeout"
  _te_expect_kind "kind none"    none    "401 Unauthorized"

  # File wrapper — Terraform/Docker log files.
  local tmp; tmp="$(mktemp)"
  printf 'Error: Post "https://cloud.mongodb.com": dial tcp: lookup cloud.mongodb.com: no such host\n' >"$tmp"
  _te_expect "log file DNS detected"           0 deploy_log_has_transient_error "$tmp"
  printf 'Error: AccessDenied: not authorized\n' >"$tmp"
  _te_expect "log file auth NOT transient"     1 deploy_log_has_transient_error "$tmp"
  rm -f "$tmp"

  # Docker/ECR saved-plan staleness stays a separate concern — not DNS/network.
  _te_expect "saved plan stale not dns/net"    1 deploy_error_is_transient "Saved plan is stale"

  echo "── ran ${n} assertions ──"
  if (( fail )); then echo "  SELF-TEST FAILED"; return 1; fi
  echo "  SELF-TEST PASSED"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --self-test) _te_self_test; exit $? ;;
    *) echo "Usage: $0 --self-test" >&2; exit 2 ;;
  esac
fi
