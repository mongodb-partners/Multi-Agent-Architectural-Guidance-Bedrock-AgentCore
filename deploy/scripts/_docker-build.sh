#!/usr/bin/env bash
# Shared Docker image build/push helper for deploy scripts.
#
# Prefer buildx when the Docker CLI can load it, but fall back to plain
# `docker build --platform` plus explicit `docker push` so client machines with
# working Docker builds are not blocked by a broken Buildx plugin install.

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

  if docker buildx version >/dev/null 2>&1; then
    docker buildx build \
      --platform "$platform" \
      -f "$dockerfile" \
      "${tag_args[@]}" \
      --push \
      "$context"
    return
  fi

  echo "  [docker] ⚠ docker buildx is unavailable; using docker build + docker push fallback"
  DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}" docker build \
    --platform "$platform" \
    -f "$dockerfile" \
    "${tag_args[@]}" \
    "$context"

  for tag in "${tags[@]}"; do
    docker push "$tag"
  done
}
