#!/usr/bin/env python3
"""Print a Cognito IdToken for live E2E smoke/benchmark helpers.

Run from the repository root or from this directory:

    python3 e2e-smoke/get_token.py

Environment overrides:
    DEPLOY_MANIFEST_PATH   Path to deploy-manifest.json
    E2E_USER               Cognito smoke user, default alex@example.com
    E2E_PASS               Cognito smoke password, default DemoUser#2026
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import boto3


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "deploy-manifest.json"


def main() -> None:
    manifest_path = Path(os.environ.get("DEPLOY_MANIFEST_PATH", DEFAULT_MANIFEST))
    manifest = json.loads(manifest_path.read_text())
    resources = manifest["resources"]
    client_id = resources["cognito_client_id"]
    region = resources.get("aws_region") or manifest.get("aws_region") or os.environ.get("AWS_REGION", "us-east-1")
    user = os.environ.get("E2E_USER", "alex@example.com")
    password = os.environ.get("E2E_PASS", "DemoUser#2026")

    client = boto3.client("cognito-idp", region_name=region)
    response = client.initiate_auth(
        ClientId=client_id,
        AuthFlow="USER_PASSWORD_AUTH",
        AuthParameters={"USERNAME": user, "PASSWORD": password},
    )
    print(response["AuthenticationResult"]["IdToken"])


if __name__ == "__main__":
    main()
