#!/usr/bin/env python3
"""API image rollback drill.

Retags ECR `latest` to a previous API image, restarts the EC2 API, verifies
/health, then retags `latest` back to the original current image and verifies
health again.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from common import DrillFailure, boto_client, health, load_manifest, log, require, ssm_run


MANIFEST_TYPES = [
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
]


def describe_tag(ecr, repo: str, tag: str) -> dict[str, Any]:
    response = ecr.describe_images(repositoryName=repo, imageIds=[{"imageTag": tag}])
    details = response.get("imageDetails", [])
    require(bool(details), f"ECR tag not found: {tag}")
    return details[0]


def image_manifest(ecr, repo: str, tag: str) -> str:
    response = ecr.batch_get_image(
        repositoryName=repo,
        imageIds=[{"imageTag": tag}],
        acceptedMediaTypes=MANIFEST_TYPES,
    )
    require(not response.get("failures"), f"failed to fetch ECR image {tag}: {response.get('failures')}")
    images = response.get("images", [])
    require(bool(images), f"ECR image manifest not found for {tag}")
    return str(images[0]["imageManifest"])


def choose_previous_tag(ecr, repo: str, current_digest: str) -> str:
    candidates: list[tuple[Any, str, str]] = []
    paginator = ecr.get_paginator("describe_images")
    for page in paginator.paginate(repositoryName=repo):
        for detail in page.get("imageDetails", []):
            digest = str(detail.get("imageDigest", ""))
            for tag in detail.get("imageTags", []) or []:
                if tag.startswith("sha-") and digest != current_digest:
                    candidates.append((detail.get("imagePushedAt"), tag, digest))
    require(bool(candidates), "no previous sha-* API image tag found for rollback")
    candidates.sort(key=lambda item: item[0], reverse=True)
    return candidates[0][1]


def restart_api_with_latest(resources: dict[str, Any], label: str) -> None:
    repo_uri = str(resources["ecr_api_repo"])
    registry = repo_uri.split("/", 1)[0]
    region = str(resources.get("aws_region") or "us-east-1")
    command = (
        f"aws ecr get-login-password --region {region} "
        f"| docker login --username AWS --password-stdin {registry} >/dev/null "
        f"&& docker pull {repo_uri}:latest >/dev/null "
        "&& systemctl restart multiagent-api "
        "&& sleep 15 "
        "&& curl -sS -m 20 http://127.0.0.1:3000/health"
    )
    ssm_run(resources, label, [command], timeout=150)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=None)
    parser.add_argument("--previous-tag", default="", help="Specific previous API image tag, e.g. sha-abc1234.")
    args = parser.parse_args()

    resources = load_manifest(args.manifest)
    repo_uri = str(resources["ecr_api_repo"])
    repo = repo_uri.split("/", 1)[1]
    ecr = boto_client(resources, "ecr")

    latest_before = describe_tag(ecr, repo, "latest")
    current_digest = str(latest_before["imageDigest"])
    current_tag = next((tag for tag in latest_before.get("imageTags", []) or [] if tag.startswith("sha-")), "latest")
    previous_tag = args.previous_tag or choose_previous_tag(ecr, repo, current_digest)

    log("ROLLBACK_TAGS " + json.dumps({"repo": repo, "current": current_tag, "previous": previous_tag}))
    current_manifest = image_manifest(ecr, repo, current_tag)
    previous_manifest = image_manifest(ecr, repo, previous_tag)

    rollback_ok = False
    try:
        ecr.put_image(repositoryName=repo, imageTag="latest", imageManifest=previous_manifest)
        restart_api_with_latest(resources, "failure drill: rollback api latest to previous image")
        rollback_health = health(resources)
        rollback_ok = rollback_health.get("status") == "ok"
        log("ROLLBACK_HEALTH " + json.dumps(rollback_health, sort_keys=True))
    finally:
        ecr.put_image(repositoryName=repo, imageTag="latest", imageManifest=current_manifest)
        restart_api_with_latest(resources, "failure drill: restore api latest to current image")

    restored_health = health(resources)
    latest_after = describe_tag(ecr, repo, "latest")
    restored_digest = str(latest_after["imageDigest"]) == current_digest
    log("RESTORED_HEALTH " + json.dumps(restored_health, sort_keys=True))
    log("ROLLBACK_RESULT " + json.dumps({"rollbackOk": rollback_ok, "restoredOk": restored_health.get("status") == "ok", "latestDigestRestored": restored_digest}))

    require(rollback_ok, "rollback health check did not pass")
    require(restored_health.get("status") == "ok", "restored health check did not pass")
    require(restored_digest, "ECR latest digest was not restored")
    log("PASS api_rollback")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except DrillFailure as exc:
        log(f"FAIL api_rollback: {exc}")
        raise SystemExit(1)
