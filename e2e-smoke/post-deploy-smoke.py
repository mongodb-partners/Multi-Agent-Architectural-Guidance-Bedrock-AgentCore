#!/usr/bin/env python3
"""Post-deploy smoke tests for the live AWS stack.

This script is intentionally outside the unit/integration test tree. It talks
to the already-deployed API, Cognito, SageMaker, Bedrock KB, and Terraform
outputs produced by deploy/scripts/deploy.sh.

Run from the repository root after deployment:

    python3 e2e-smoke/post-deploy-smoke.py

Environment overrides:
    DEPLOY_MANIFEST_PATH   Path to deploy-manifest.json
    E2E_USER               Cognito smoke user, default alex@example.com
    E2E_PASS               Cognito smoke password, default DemoUser#2026
    SKIP_TERRAFORM_CHECKS  Set to 1 to skip local terraform output checks
    SKIP_CHAT_CHECKS       Set to 1 to skip live /chat checks
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "deploy-manifest.json"
TF_DIR = ROOT / "deploy" / "terraform" / "envs" / "ec2"


class SmokeFailure(Exception):
    pass


def log(message: str) -> None:
    print(message, flush=True)


def run(cmd: list[str], *, cwd: Path | None = None, timeout: int = 120) -> str:
    try:
        return subprocess.check_output(
            cmd,
            cwd=str(cwd) if cwd else None,
            text=True,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        ).strip()
    except subprocess.CalledProcessError as exc:
        raise SmokeFailure(
            f"command failed ({exc.returncode}): {' '.join(cmd)}\n{exc.output}"
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise SmokeFailure(f"command timed out: {' '.join(cmd)}") from exc


def load_json_url(url: str, *, timeout: int = 30, token: str | None = None) -> Any:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SmokeFailure(message)


def manifest_resources(path: Path) -> dict[str, Any]:
    require(path.exists(), f"deploy manifest not found: {path}")
    doc = json.loads(path.read_text())
    resources = doc.get("resources")
    require(isinstance(resources, dict), "deploy manifest missing resources object")
    # deploy-manifest.json keeps AWS account/region/environment at the top
    # level, while most runtime identifiers live under resources.
    for key in ("aws_account", "aws_region", "environment"):
        resources.setdefault(key, doc.get(key) or os.environ.get(key.upper(), ""))
    return resources


def check_health(api_url: str) -> None:
    log("\n== Health ==")
    health = load_json_url(f"{api_url}/health")
    deps = health.get("dependencies", {})
    log(json.dumps({"status": health.get("status"), "dependencies": deps}, sort_keys=True))
    require(health.get("status") == "ok", f"/health status is not ok: {health.get('status')}")
    for dep in ("mongodb", "agentcore", "mcpServer"):
        require(deps.get(dep) == "connected", f"/health dependency {dep} is {deps.get(dep)!r}")


def check_agents_endpoint(api_url: str, token: str) -> None:
    log("\n== Agents metadata ==")
    agents_doc = load_json_url(f"{api_url}/agents", token=token)
    if isinstance(agents_doc, list):
        agent_ids = [a.get("id") for a in agents_doc if isinstance(a, dict)]
    else:
        agent_ids = [
            a.get("id")
            for a in agents_doc.get("agents", [])
            if isinstance(a, dict)
        ]
    log(f"agents={agent_ids}")
    for expected in (
        "orchestrator",
        "order-management",
        "product-recommendation",
        "troubleshooting",
    ):
        require(expected in agent_ids, f"/agents missing {expected}")


def check_embedding_manifest_and_sagemaker(resources: dict[str, Any]) -> None:
    log("\n== Embedding provider ==")
    provider = resources.get("embeddings_provider")
    model = resources.get("embeddings_model")
    aligned = resources.get("embeddings_sow_aligned")
    endpoint = resources.get("voyage_sagemaker_endpoint")
    region = resources.get("aws_region")
    log(
        json.dumps(
            {
                "provider": provider,
                "model": model,
                "sow_aligned": aligned,
                "endpoint": endpoint,
            },
            sort_keys=True,
        )
    )

    require(provider in ("voyage", "titan"), f"unknown embeddings_provider={provider!r}")
    if provider == "voyage":
        require(aligned is True, "voyage provider must be marked embeddings_sow_aligned=true")
        require(
            isinstance(model, str) and re.match(r"^voyage-multimodal-3($|-)", model),
            f"voyage embeddings_model is not voyage-multimodal-3: {model!r}",
        )
        require(endpoint, "voyage provider requires voyage_sagemaker_endpoint")
        status = run(
            [
                "aws",
                "sagemaker",
                "describe-endpoint",
                "--region",
                str(region),
                "--endpoint-name",
                str(endpoint),
                "--query",
                "EndpointStatus",
                "--output",
                "text",
            ],
            timeout=60,
        )
        log(f"sagemaker_endpoint_status={status}")
        require(status == "InService", f"Voyage SageMaker endpoint is not InService: {status}")
    else:
        require(aligned is False, "titan provider must be marked embeddings_sow_aligned=false")
        require(model == "amazon.titan-embed-text-v2:0", f"unexpected titan model: {model!r}")
        require(not endpoint, "titan provider should not publish a Voyage endpoint")


def check_terraform_outputs(resources: dict[str, Any]) -> None:
    log("\n== Terraform outputs ==")
    if os.environ.get("SKIP_TERRAFORM_CHECKS") == "1":
        log("skipped via SKIP_TERRAFORM_CHECKS=1")
        return

    voyage_output = run(["terraform", "output", "-raw", "voyage_endpoint_name"], cwd=TF_DIR)
    kb_pl_enabled = run(
        ["terraform", "output", "-raw", "bedrock_kb_privatelink_enabled"],
        cwd=TF_DIR,
    )
    kb_endpoint_service = run(
        ["terraform", "output", "-raw", "bedrock_kb_endpoint_service_name"],
        cwd=TF_DIR,
    )
    log(
        json.dumps(
            {
                "voyage_endpoint_name": voyage_output,
                "bedrock_kb_privatelink_enabled": kb_pl_enabled,
                "bedrock_kb_endpoint_service_name": kb_endpoint_service,
            },
            sort_keys=True,
        )
    )

    if resources.get("embeddings_provider") == "voyage":
        require(
            voyage_output == resources.get("voyage_sagemaker_endpoint"),
            "terraform voyage_endpoint_name does not match deploy manifest",
        )
    require(kb_pl_enabled == "true", "Bedrock KB PrivateLink must be enabled")
    require(
        kb_endpoint_service.startswith("com.amazonaws.vpce."),
        f"Bedrock KB endpoint service name missing/invalid: {kb_endpoint_service}",
    )


def check_bedrock_kb(resources: dict[str, Any]) -> None:
    log("\n== Bedrock KB PrivateLink ==")
    kb_id = resources.get("bedrock_kb_id")
    region = resources.get("aws_region")
    require(kb_id, "deploy manifest missing bedrock_kb_id")
    raw = run(
        [
            "aws",
            "bedrock-agent",
            "get-knowledge-base",
            "--region",
            str(region),
            "--knowledge-base-id",
            str(kb_id),
            "--query",
            "knowledgeBase.{status:status,endpointServiceName:storageConfiguration.mongoDbAtlasConfiguration.endpointServiceName,endpoint:storageConfiguration.mongoDbAtlasConfiguration.endpoint}",
            "--output",
            "json",
        ],
        timeout=60,
    )
    info = json.loads(raw)
    log(json.dumps(info, sort_keys=True))
    require(info.get("status") == "ACTIVE", f"Bedrock KB is not ACTIVE: {info.get('status')}")
    require(
        str(info.get("endpointServiceName", "")).startswith("com.amazonaws.vpce."),
        "Bedrock KB is not configured with endpointServiceName PrivateLink",
    )
    require("-pl-" in str(info.get("endpoint", "")), "Bedrock KB endpoint is not the Atlas -pl host")


def cognito_token(client_id: str) -> str:
    user = os.environ.get("E2E_USER", "alex@example.com")
    password = os.environ.get("E2E_PASS", "DemoUser#2026")
    token = run(
        [
            "aws",
            "cognito-idp",
            "initiate-auth",
            "--client-id",
            client_id,
            "--auth-flow",
            "USER_PASSWORD_AUTH",
            "--auth-parameters",
            f"USERNAME={user},PASSWORD={password}",
            "--query",
            "AuthenticationResult.IdToken",
            "--output",
            "text",
        ],
        timeout=60,
    )
    require(len(token) > 100, "Cognito IdToken was not returned")
    return token


def post_chat(api_url: str, token: str, agent: str, message: str) -> str:
    payload = json.dumps(
        {
            "agentId": agent,
            "sessionId": f"post-deploy-smoke-{agent}-{int(time.time() * 1000)}",
            "message": message,
        }
    ).encode()
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    last_error: BaseException | None = None
    for attempt in range(1, 4):
        try:
            request = urllib.request.Request(
                f"{api_url}/chat",
                data=payload,
                headers=headers,
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=240) as response:
                return response.read().decode("utf-8", "replace")
        except (
            http.client.IncompleteRead,
            http.client.HTTPException,
            TimeoutError,
            urllib.error.URLError,
        ) as exc:
            last_error = exc
            if attempt < 3:
                time.sleep(5 * attempt)
    raise SmokeFailure(f"chat stream failed after retries for {agent}: {last_error}")


def parse_sse(body: str) -> tuple[str, list[str], list[str], list[dict[str, Any]], list[Any]]:
    tokens: list[str] = []
    events: list[str] = []
    traces: list[str] = []
    handoffs: list[dict[str, Any]] = []
    errors: list[Any] = []
    for block in body.split("\n\n"):
        lines = block.strip().splitlines()
        if not lines:
            continue
        event = ""
        data_lines: list[str] = []
        for line in lines:
            if line.startswith("event: "):
                event = line[7:].strip()
            elif line.startswith("data:"):
                data_lines.append(line[5:].lstrip())
        if not event:
            continue
        events.append(event)
        raw = "\n".join(data_lines)
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"raw": raw}
        if event == "token":
            tokens.append(str(payload.get("text", "")))
        elif event == "trace":
            traces.append(str(payload.get("type", "?")))
        elif event == "handoff":
            handoffs.append(payload)
        elif event == "error":
            errors.append(payload)
    return "".join(tokens), events, traces, handoffs, errors


def check_all_agents(api_url: str, token: str) -> None:
    log("\n== Live agent chat checks ==")
    if os.environ.get("SKIP_CHAT_CHECKS") == "1":
        log("skipped via SKIP_CHAT_CHECKS=1")
        return

    cases = [
        {
            "agent": "orchestrator",
            "message": "I need to return order ORD-1003 for alex@example.com. Please help me start the return.",
            "needles": ["ORD-1003", "return"],
            "trace_any": ["handoff", "mongo.query", "mcp.call"],
        },
        {
            "agent": "order-management",
            "message": "What's the status of order ORD-1001?",
            "needles": ["ORD-1001", "Shipped", "Tracking"],
            "trace_any": ["mongo.query", "mcp.call", "handoff"],
        },
        {
            "agent": "product-recommendation",
            "message": "I need waterproof outdoor headphones or rugged audio gear under $80 for rain.",
            "needles": ["waterproof", "rugged", "IP67", "outdoor"],
            "trace_any": ["mongo.vector_search", "mcp.call", "handoff"],
        },
        {
            "agent": "troubleshooting",
            "message": "My device will not turn on after I left it in the rain. What should I check?",
            "needles": ["dry", "power", "battery", "moisture", "water"],
            "trace_any": ["bedrock.kb.retrieve", "tool.call", "mongo.vector_search", "handoff"],
        },
    ]

    for case in cases:
        agent = case["agent"]
        log(f"\n-- {agent} --")
        body = post_chat(api_url, token, str(agent), str(case["message"]))
        text, events, traces, handoffs, errors = parse_sse(body)
        flat = re.sub(r"\s+", " ", text).strip()
        checks = {
            "token": "token" in events and len(flat) > 20,
            "done": "done" in events,
            "no_error": not errors,
            "content": any(n.lower() in flat.lower() for n in case["needles"]),
            "trace_or_handoff": any(t in traces for t in case["trace_any"])
            or ("handoff" in case["trace_any"] and bool(handoffs)),
        }
        log(f"events={sorted(set(events))}")
        log(f"traces_sample={sorted(set(traces))[:20]}")
        if handoffs:
            log(f"handoffs={handoffs[:3]}")
        if errors:
            log(f"errors={errors[:3]}")
        log(f"reply={flat[:700]}")
        log(f"checks={json.dumps(checks, sort_keys=True)}")
        require(all(checks.values()), f"{agent} smoke failed: {checks}")
        log(f"PASS {agent}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        default=os.environ.get("DEPLOY_MANIFEST_PATH", str(DEFAULT_MANIFEST)),
        help="Path to deploy-manifest.json",
    )
    args = parser.parse_args()

    resources = manifest_resources(Path(args.manifest))
    api_url = str(resources.get("ec2_api_url", "")).rstrip("/")
    client_id = str(resources.get("cognito_client_id", ""))
    require(api_url, "deploy manifest missing ec2_api_url")
    require(client_id, "deploy manifest missing cognito_client_id")

    log(f"API={api_url}")
    log(f"UI={resources.get('ec2_ui_url')}")
    log(f"manifest={args.manifest}")

    check_health(api_url)
    token = cognito_token(client_id)
    log(f"cognito_token_len={len(token)}")
    check_agents_endpoint(api_url, token)
    check_embedding_manifest_and_sagemaker(resources)
    check_terraform_outputs(resources)
    check_bedrock_kb(resources)
    check_all_agents(api_url, token)

    log("\nALL_POST_DEPLOY_SMOKE_CHECKS_PASSED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SmokeFailure as exc:
        print(f"\nSMOKE_FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
