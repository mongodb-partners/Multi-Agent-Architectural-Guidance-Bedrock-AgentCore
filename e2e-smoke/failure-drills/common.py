#!/usr/bin/env python3
"""Shared helpers for live failure-drill smoke tests.

These helpers intentionally target an already deployed dev stack described by
deploy-manifest.json. They should not print secrets.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import boto3


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = ROOT / "deploy-manifest.json"


class DrillFailure(Exception):
    pass


def log(message: str) -> None:
    print(message, flush=True)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise DrillFailure(message)


def load_manifest(path: Path | None = None) -> dict[str, Any]:
    manifest_path = path or Path(os.environ.get("DEPLOY_MANIFEST_PATH", DEFAULT_MANIFEST))
    require(manifest_path.exists(), f"deploy manifest not found: {manifest_path}")
    manifest = json.loads(manifest_path.read_text())
    resources = manifest.get("resources")
    require(isinstance(resources, dict), "deploy manifest missing resources object")
    for key in ("aws_account", "aws_region", "environment"):
        resources.setdefault(key, manifest.get(key) or os.environ.get(key.upper(), ""))
    return resources


def project_name(resources: dict[str, Any]) -> str:
    repo = str(resources.get("ecr_api_repo", "")).rsplit("/", 1)[-1]
    env = str(resources.get("environment") or "dev")
    suffix = f"-api-{env}"
    if repo.endswith(suffix):
        return repo[: -len(suffix)]
    return repo.removesuffix("-api") or os.environ.get("PROJECT_NAME") or "mongodb-multiagent"


def boto_client(resources: dict[str, Any], service: str):
    return boto3.client(service, region_name=str(resources.get("aws_region") or "us-east-1"))


def cognito_token(resources: dict[str, Any], user: str | None = None, password: str | None = None) -> str:
    user = user or os.environ.get("E2E_USER", "alex@example.com")
    password = password or os.environ.get("E2E_PASS", "DemoUser#2026")
    client_id = resources.get("cognito_client_id")
    require(bool(client_id), "deploy manifest missing cognito_client_id")
    client = boto_client(resources, "cognito-idp")
    response = client.initiate_auth(
        ClientId=str(client_id),
        AuthFlow="USER_PASSWORD_AUTH",
        AuthParameters={"USERNAME": user, "PASSWORD": password},
    )
    return str(response["AuthenticationResult"]["IdToken"])


def http_request(
    resources: dict[str, Any],
    path: str,
    *,
    token: str | None = None,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    timeout: int = 30,
) -> tuple[int, str]:
    api_url = str(resources["ec2_api_url"]).rstrip("/")
    headers: dict[str, str] = {}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(api_url + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", errors="replace")
    except Exception as exc:
        return 0, repr(exc)


def health(resources: dict[str, Any]) -> dict[str, Any]:
    status, text = http_request(resources, "/health", timeout=20)
    require(status == 200, f"/health returned {status}: {text[:300]}")
    return json.loads(text)


def ssm_run(
    resources: dict[str, Any],
    label: str,
    commands: list[str],
    *,
    timeout: int = 120,
) -> dict[str, Any]:
    instance_id = resources.get("ec2_instance_id")
    require(bool(instance_id), "deploy manifest missing ec2_instance_id")
    ssm = boto_client(resources, "ssm")
    response = ssm.send_command(
        InstanceIds=[str(instance_id)],
        DocumentName="AWS-RunShellScript",
        Comment=label,
        Parameters={"commands": commands},
        TimeoutSeconds=timeout,
    )
    command_id = response["Command"]["CommandId"]
    waiter = ssm.get_waiter("command_executed")
    waiter.wait(
        CommandId=command_id,
        InstanceId=str(instance_id),
        WaiterConfig={"Delay": 3, "MaxAttempts": max(1, timeout // 3)},
    )
    output = ssm.get_command_invocation(CommandId=command_id, InstanceId=str(instance_id))
    result = {
        "status": output["Status"],
        "responseCode": output["ResponseCode"],
        "stdout": output.get("StandardOutputContent", ""),
        "stderr": output.get("StandardErrorContent", ""),
    }
    log(json.dumps({"label": label, "status": result["status"], "responseCode": result["responseCode"]}))
    if result["stdout"]:
        log(str(result["stdout"]))
    if result["stderr"]:
        log("STDERR: " + str(result["stderr"]))
    require(result["responseCode"] == 0, f"SSM command failed: {label}")
    return result


def restart_api(resources: dict[str, Any], label: str = "restart multiagent-api") -> dict[str, Any]:
    return ssm_run(
        resources,
        label,
        [
            "set -euo pipefail",
            "systemctl daemon-reload",
            "systemctl restart multiagent-api",
            "sleep 12",
            "curl -sS -m 20 http://127.0.0.1:3000/health",
        ],
        timeout=120,
    )


def chat_order_status(resources: dict[str, Any], token: str, session_id: str) -> tuple[int, str]:
    return http_request(
        resources,
        "/chat",
        token=token,
        method="POST",
        body={
            "agentId": "order-management",
            "sessionId": session_id,
            "message": "status of order ORD-1001",
        },
        timeout=75,
    )


def list_project_alarms(resources: dict[str, Any]) -> list[str]:
    cw = boto_client(resources, "cloudwatch")
    project = project_name(resources)
    env = str(resources.get("environment") or "dev")
    names: list[str] = []
    for page in cw.get_paginator("describe_alarms").paginate():
        for alarm in page.get("MetricAlarms", []):
            name = str(alarm["AlarmName"])
            if name.startswith(f"{project}-{env}-") or name.startswith(f"{project}-dev-"):
                names.append(name)
    return sorted(set(names))


def wait(seconds: int) -> None:
    time.sleep(seconds)
