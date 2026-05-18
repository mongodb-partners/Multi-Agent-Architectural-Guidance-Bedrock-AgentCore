#!/usr/bin/env bash
# Tag and push both images to Amazon ECR. Prerequisites:
#   - aws CLI configured; docker login to ECR
#   - Repositories created by Terraform: ${PROJECT_NAME}-api-${ENVIRONMENT}
#     and ${PROJECT_NAME}-ui-${ENVIRONMENT}
#
# Usage:
#   source .env                                      # supplies PROJECT_NAME + ENVIRONMENT
#   export AWS_ACCOUNT_ID=123456789012
#   # ECR_REPO_API / ECR_REPO_UI default to ${PROJECT_NAME}-{api,ui}-${ENVIRONMENT}
#   TAG=$(git rev-parse --short HEAD) ./deploy/scripts/docker-push-ecr.sh
#
# This is a manual helper for ad-hoc pushes. The orchestrated path is
# `deploy/scripts/deploy-project.sh` Phase 5.5, which reads the actual repo URLs from
# Terraform output instead of recomputing them here.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

: "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
: "${AWS_REGION:?Set AWS_REGION}"
: "${PROJECT_NAME:?Set PROJECT_NAME (matches deploy-project.sh / .env)}"
: "${ENVIRONMENT:?Set ENVIRONMENT (matches deploy-project.sh / .env)}"

# Images are expected tagged locally as multi-agent-api:${SOURCE_TAG} / multi-agent-streamlit:${SOURCE_TAG}
# (e.g. run deploy/scripts/docker-build.sh first; default SOURCE_TAG=local).
SOURCE_TAG="${SOURCE_TAG:-local}"
TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
# Repo names match what the ECR Terraform module creates. Override via env var
# only if you renamed the repos out of band.
ECR_REPO_API="${ECR_REPO_API:-${PROJECT_NAME}-api-${ENVIRONMENT}}"
ECR_REPO_UI="${ECR_REPO_UI:-${PROJECT_NAME}-ui-${ENVIRONMENT}}"
REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

login() {
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${REGISTRY}"
}

if [[ "${SKIP_ECR_LOGIN:-}" != "1" ]]; then
  echo "Logging in to ${REGISTRY}..."
  login
fi

push_one() {
  local local_image="$1"
  local repo_name="$2"
  local remote="${REGISTRY}/${repo_name}:${TAG}"
  echo "Tagging ${local_image} -> ${remote}"
  docker tag "${local_image}" "${remote}"
  docker push "${remote}"
}

echo "Pushing ${ECR_REPO_API}:${TAG} and ${ECR_REPO_UI}:${TAG} (from local :${SOURCE_TAG})..."
push_one "multi-agent-api:${SOURCE_TAG}" "${ECR_REPO_API}"
push_one "multi-agent-streamlit:${SOURCE_TAG}" "${ECR_REPO_UI}"

echo "Push complete."
