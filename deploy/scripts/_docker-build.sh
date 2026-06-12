#!/usr/bin/env bash
# Shared Docker image build/push helper for deploy scripts.
#
# Builds a single-platform image with plain `docker build --platform` (BuildKit
# enabled by default) and pushes each tag with `docker push`. ARM64 builds rely
# on QEMU binfmt being registered on the operator's machine; the
# `pf_check_docker_cross_platforms` preflight verifies this before any deploy.
#
# Provenance + SBOM attestations are explicitly disabled. Without this, Docker
# 23+ wraps every BuildKit build in an OCI image index that carries an
# `attestation-manifest` entry with `architecture: unknown`. AgentCore Runtime's
# image puller has been observed to follow the attestation entry instead of the
# real arm64 manifest, which leaves the container task unable to start: no logs
# appear, the runtime status stays READY at the control plane, but every
# invocation times out with `Runtime initialization time exceeded`. Forcing the
# build to emit a single-platform manifest sidesteps that bug; see
# `docs/status/debugging.md` "Known persistent pitfalls" for the failure signature.

# Shared transient-error classifier (DNS resolver + network/transport blips).
# shellcheck source=deploy/scripts/_transient-errors.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_transient-errors.sh"

DOCKER_PUSH_MAX_ATTEMPTS="${DOCKER_PUSH_MAX_ATTEMPTS:-4}"
DOCKER_PUSH_RETRY_DELAY_SECONDS="${DOCKER_PUSH_RETRY_DELAY_SECONDS:-15}"
ECR_LOGIN_MAX_ATTEMPTS="${ECR_LOGIN_MAX_ATTEMPTS:-4}"
ECR_LOGIN_RETRY_DELAY_SECONDS="${ECR_LOGIN_RETRY_DELAY_SECONDS:-10}"

docker_push_is_transient() {
  local log_file="$1"
  # Shared DNS + network classifier, plus the legacy bare-`timeout` term that
  # the Docker registry client emits on slow pushes (kept for back-compat).
  deploy_log_has_transient_error "$log_file" && return 0
  grep -qiE 'temporary failure|\btimeout\b' "$log_file"
}

# ecr_login_with_retry <region> <registry>
#
# `aws ecr get-login-password | docker login` is the first network call on most
# deploy paths; a transient local DNS blip resolving ecr/sts/STS endpoints (or
# the registry host) aborts the whole deploy before the Docker push retry loop
# can help. Retry the login pipeline on transient DNS / network failures only.
ecr_login_with_retry() {
  local region="$1"
  local registry="$2"
  local attempt=1
  local log_file
  log_file=$(mktemp -t ecr-login.XXXXXX)

  while (( attempt <= ECR_LOGIN_MAX_ATTEMPTS )); do
    if aws ecr get-login-password --region "$region" 2>"$log_file" \
        | docker login --username AWS --password-stdin "$registry" >>"$log_file" 2>&1; then
      rm -f "$log_file"
      return 0
    fi
    if deploy_log_has_transient_error "$log_file" && (( attempt < ECR_LOGIN_MAX_ATTEMPTS )); then
      echo "  [docker] ⚠ ECR login failed (attempt ${attempt}/${ECR_LOGIN_MAX_ATTEMPTS}) — transient network/DNS, retrying in ${ECR_LOGIN_RETRY_DELAY_SECONDS}s..." >&2
      cat "$log_file" >&2
      sleep "$ECR_LOGIN_RETRY_DELAY_SECONDS"
      attempt=$((attempt + 1))
      continue
    fi
    cat "$log_file" >&2
    rm -f "$log_file"
    return 1
  done
  rm -f "$log_file"
  return 1
}

docker_push_with_retry() {
  local tag="$1"
  local attempt=1
  local log_file
  log_file=$(mktemp -t docker-push.XXXXXX)

  while (( attempt <= DOCKER_PUSH_MAX_ATTEMPTS )); do
    if docker push "$tag" >"$log_file" 2>&1; then
      rm -f "$log_file"
      return 0
    fi
    if docker_push_is_transient "$log_file" && (( attempt < DOCKER_PUSH_MAX_ATTEMPTS )); then
      echo "  [docker] ⚠ push failed for ${tag} (attempt ${attempt}/${DOCKER_PUSH_MAX_ATTEMPTS}) — retrying in ${DOCKER_PUSH_RETRY_DELAY_SECONDS}s..." >&2
      cat "$log_file" >&2
      sleep "$DOCKER_PUSH_RETRY_DELAY_SECONDS"
      attempt=$((attempt + 1))
      continue
    fi
    cat "$log_file" >&2
    rm -f "$log_file"
    return 1
  done
  rm -f "$log_file"
  return 1
}

docker_build_push_image() {
  local platform="$1"
  local dockerfile="$2"
  local context="$3"
  shift 3

  local -a tags=("$@")
  if (( ${#tags[@]} == 0 )); then
    echo "  [docker] ✗ docker_build_push_image requires at least one tag" >&2
    return 2
  fi

  local -a tag_args=()
  local tag
  for tag in "${tags[@]}"; do
    tag_args+=(-t "$tag")
  done

  DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}" docker build \
    --platform "$platform" \
    --provenance=false \
    --sbom=false \
    -f "$dockerfile" \
    "${tag_args[@]}" \
    "$context"

  for tag in "${tags[@]}"; do
    docker_push_with_retry "$tag"
  done
}
