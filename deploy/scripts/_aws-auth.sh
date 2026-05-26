#!/usr/bin/env bash
# _aws-auth.sh — Shared AUTH_MODE validator for all deploy scripts.
#
# Usage (in calling scripts, after sourcing .env):
#   source "<path>/_aws-auth.sh"
#   validate_aws_auth
#
# Honors:
#   AUTH_MODE = iam | sts   (default: iam, case-insensitive)
#
# Modes:
#   iam — long-lived IAM user access keys. Requires AWS_ACCESS_KEY_ID +
#         AWS_SECRET_ACCESS_KEY. Refuses if the resolved caller ARN is an
#         assumed role (catches profile-override drift).
#   sts — temporary credentials (STS assume-role / SSO / OIDC).
#         Requires either:
#           (a) AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY + AWS_SESSION_TOKEN
#           (b) AWS_PROFILE   (named profile resolving to SSO or assume-role)
#         Refuses if the resolved caller ARN is an IAM user.
#
# Exports on success:
#   AWS_AUTH_MODE        — normalized mode (lowercase, "iam"|"sts")
#   AWS_AUTH_CALLER_ARN  — caller ARN as returned by sts:GetCallerIdentity
#   AWS_AUTH_ACCOUNT_ID  — 12-digit account ID parsed out of the ARN

# Intentionally NOT calling `set -euo pipefail` here — this file is sourced by
# scripts that may or may not already have those flags set. The function below
# uses explicit `return 1` on every error so it works under either regime.

_auth_log()  { echo "  [auth] $*"; }
_auth_err()  { echo "  [auth] ✗ $*" >&2; }   # returns 0 — caller does `return 1`
_auth_warn() { echo "  [auth] ⚠ $*" >&2; }

validate_aws_auth() {
  local raw_mode mode
  raw_mode="${AUTH_MODE:-iam}"
  mode="$(echo "$raw_mode" | tr '[:upper:]' '[:lower:]')"

  case "$mode" in
    iam|sts) ;;
    *)
      _auth_err "Unrecognized AUTH_MODE='${raw_mode}'. Use 'iam' or 'sts'."
      return 1
      ;;
  esac

  # ── Mode-specific env-var checks ─────────────────────────────────────────
  if [[ "$mode" == "iam" ]]; then
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
      _auth_err "AUTH_MODE=iam requires AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY in your env or .env file.
    If your org prohibits long-lived IAM user keys, set AUTH_MODE=sts and use temporary credentials instead.
    See deploy/iam/README.md for the STS / SSO / OIDC setup."
      return 1
    fi
    # AUTH_MODE=iam + static keys present is the unambiguous case. The AWS
    # SDK v3 emits a loud "Multiple credential sources detected" warning
    # whenever both AWS_PROFILE and the static key pair coexist (visible to
    # operators in db-seeding/seed-embeddings.ts and any other node-side
    # tool downstream of the deploy). Same fix for AWS_SESSION_TOKEN: a
    # token from a previous STS run, left behind in the shell, can
    # short-circuit static-key signing if the SDK picks the wrong chain.
    # We actively unset both — opt-out is to flip AUTH_MODE=sts in .env.
    if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
      _auth_warn "AWS_SESSION_TOKEN is set with AUTH_MODE=iam — unsetting it. Mixing static keys with a session token is the #1 source of 'wrong creds used' bugs. Switch to AUTH_MODE=sts if you intended a token-based flow."
      unset AWS_SESSION_TOKEN
    fi
    if [[ -n "${AWS_PROFILE:-}" ]]; then
      _auth_warn "AWS_PROFILE='${AWS_PROFILE}' is set with AUTH_MODE=iam — unsetting it so downstream tools (AWS SDK v3, bun, node) signal-source the static keys without ambiguity. Switch to AUTH_MODE=sts if you intended profile-based credentials."
      unset AWS_PROFILE
    fi
  else
    # sts
    local have_static=0 have_profile=0
    [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && have_static=1
    [[ -n "${AWS_PROFILE:-}" ]] && have_profile=1

    if (( have_static == 0 && have_profile == 0 )); then
      _auth_err "AUTH_MODE=sts requires either:
    (a) AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY + AWS_SESSION_TOKEN (from 'aws sts assume-role' / 'aws configure export-credentials'), OR
    (b) AWS_PROFILE pointing at an SSO or assume-role named profile in ~/.aws/config.
  Neither is currently set. See deploy/iam/README.md § STS-assumed role setup."
      return 1
    fi

    if (( have_static == 1 )) && [[ -z "${AWS_SESSION_TOKEN:-}" ]]; then
      _auth_err "AUTH_MODE=sts with static env-var keys also requires AWS_SESSION_TOKEN.
    Temporary STS credentials always come with a session token — yours is missing.
    Run 'aws sts assume-role ...' / 'aws configure export-credentials ...' to get a fresh triple,
    or unset AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY and export AWS_PROFILE instead."
      return 1
    fi
  fi

  # ── Live identity probe (uses whichever creds resolved above) ────────────
  local caller_arn account_id
  caller_arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
  if [[ $? -ne 0 || -z "$caller_arn" || "$caller_arn" == "None" ]]; then
    _auth_err "aws sts get-caller-identity failed (or returned empty).
    Credentials are invalid, expired, or your AWS_PROFILE/SSO session is not active.
    Re-authenticate (aws sso login / sts assume-role) and retry."
    return 1
  fi

  # ── ARN-shape assertion (catches mode-vs-actual drift) ──────────────────
  if [[ "$mode" == "iam" ]]; then
    if [[ ! "$caller_arn" =~ ^arn:aws:iam::[0-9]+:user/ ]]; then
      _auth_err "AUTH_MODE=iam but caller ARN is '${caller_arn}' — that is not an IAM user.
    Either set AUTH_MODE=sts, or unset AWS_PROFILE / AWS_SESSION_TOKEN so the AWS CLI uses your static keys."
      return 1
    fi
  else
    # sts
    if [[ ! "$caller_arn" =~ ^arn:aws:sts::[0-9]+:assumed-role/ ]]; then
      _auth_err "AUTH_MODE=sts but caller ARN is '${caller_arn}' — that is not an assumed role.
    Either set AUTH_MODE=iam, or fix your AWS_PROFILE / STS env vars to point at an assumed role."
      return 1
    fi
  fi

  # Parse the 12-digit account ID out of the ARN (shape: arn:aws:<svc>::<acct>:...).
  account_id="$(echo "$caller_arn" | awk -F: '{print $5}')"

  export AWS_AUTH_MODE="$mode"
  export AWS_AUTH_CALLER_ARN="$caller_arn"
  export AWS_AUTH_ACCOUNT_ID="$account_id"

  _auth_log "mode=${mode} arn=${caller_arn}"
  return 0
}
