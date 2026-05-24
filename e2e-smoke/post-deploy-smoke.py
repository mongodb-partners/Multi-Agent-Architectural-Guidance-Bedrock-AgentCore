#!/usr/bin/env python3
"""Post-deploy smoke tests for the live AWS stack.

This script is intentionally outside the unit/integration test tree. It talks
to the already-deployed API, Cognito, SageMaker, Bedrock KB, and Terraform
outputs produced by deploy/scripts/deploy-project.sh.

Run from the repository root after deployment:

    python3 e2e-smoke/post-deploy-smoke.py

Environment overrides:
    DEPLOY_MANIFEST_PATH   Path to deploy-manifest.json
    E2E_USER               Cognito smoke user, default alex@example.com
    E2E_PASS               Cognito smoke password, default DemoUser#2026
    POST_DEPLOY_CHAT_ATTEMPTS
                           Retry count for live chat assertions, default 5
    POST_DEPLOY_CHAT_RETRY_DELAY_SECONDS
                           Base backoff for live chat assertion retries, default 8
    SKIP_TERRAFORM_CHECKS  Set to 1 to skip local terraform output checks
    SKIP_CHAT_CHECKS       Set to 1 to skip live /chat checks
    SKIP_LTM_CHECK         Set to 1 to skip the long-term memory recall check
    SKIP_AGENTCORE_ENV_CHECK
                           Set to 1 to skip the per-runtime env wiring check
                           (verifies AGENTCORE_GATEWAY_URL is present on every
                           AgentCore Runtime)
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
import urllib.parse
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


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def chat_attempts() -> int:
    return max(1, env_int("POST_DEPLOY_CHAT_ATTEMPTS", 5))


def chat_retry_delay_seconds() -> int:
    return max(0, env_int("POST_DEPLOY_CHAT_RETRY_DELAY_SECONDS", 8))


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


def manifest_doc(path: Path) -> dict[str, Any]:
    """Full manifest doc — needed for top-level keys like `network` that the
    `check_*` helpers introspect to branch on NETWORK_MODE."""
    require(path.exists(), f"deploy manifest not found: {path}")
    return json.loads(path.read_text())


def check_health(api_url: str, resources: dict[str, Any]) -> None:
    """
    /health smoke. We mirror deploy-project.sh Phase 9a2's contract:
    - mongodb + agentcore: HARD-REQUIRE 'connected'.
    - bedrockKnowledgeBase: HARD-REQUIRE 'connected' when KB id is provisioned.
    - mcpServer: WARN ONLY when not 'connected'. The MCP runtime is an
      AgentCore Runtime that can be scaled to zero between deploys; its first
      probe after an idle period frequently times out on cold start (MCP client
      timeout 60s > API health probe timeout 2.5s, so `/health` reports
      'unreachable' even though invocations from chat will eventually succeed
      once the container warms). Real MCP regressions are caught downstream by
      `check_agentcore_runtime_env` (env wiring) + the per-agent chat checks
      (vector_search / aggregate trace events). Failing here would force every
      operator to run smoke twice. Matches the warning behaviour at
      deploy/scripts/deploy-project.sh:1510-1512.
    """
    log("\n== Health ==")
    health = load_json_url(f"{api_url}/health")
    deps = health.get("dependencies", {})
    log(json.dumps({"status": health.get("status"), "dependencies": deps}, sort_keys=True))
    require(health.get("status") == "ok", f"/health status is not ok: {health.get('status')}")
    for dep in ("mongodb", "agentcore"):
        require(deps.get(dep) == "connected", f"/health dependency {dep} is {deps.get(dep)!r}")
    mcp_status = deps.get("mcpServer")
    if mcp_status != "connected":
        log(
            f"  warning: /health dependency mcpServer is {mcp_status!r}; "
            "MongoDB MCP runtime likely cold-starting. Downstream env-wiring + "
            "chat checks will catch real MCP regressions."
        )
    if resources.get("bedrock_kb_id"):
        require(
            deps.get("bedrockKnowledgeBase") == "connected",
            f"/health dependency bedrockKnowledgeBase is {deps.get('bedrockKnowledgeBase')!r}",
        )


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
        require(
            isinstance(model, str) and re.match(r"^voyage-", model),
            f"voyage embeddings_model is not a Voyage package tail: {model!r}",
        )
        if aligned is True:
            require(
                re.match(r"^voyage-multimo(?:dal|del)-3($|-)", model),
                f"embeddings_sow_aligned=true but model is not voyage-multimodal-3 family: {model!r}",
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


def _network_mode_from_manifest(manifest: dict[str, Any]) -> str:
    """Return network_mode from the manifest, defaulting to 'privatelink' for
    back-compat with pre-NETWORK_MODE manifests. Top-level resolution because
    older manifests stored nothing; new ones nest it under 'network'."""
    nm = ((manifest.get("network") or {}).get("mode") or "").strip().lower()
    return nm or "privatelink"


def _kb_connectivity_mode_from_manifest(manifest: dict[str, Any]) -> str:
    """Resolved at deploy time by envs/ec2. One of: privatelink, peering-nlb,
    public-srv. Defaults to 'privatelink' for pre-NETWORK_MODE manifests."""
    return (
        ((manifest.get("network") or {}).get("kb_connectivity_mode") or "").strip().lower()
        or "privatelink"
    )


def check_terraform_outputs(resources: dict[str, Any], manifest: dict[str, Any]) -> None:
    log("\n== Terraform outputs ==")
    if os.environ.get("SKIP_TERRAFORM_CHECKS") == "1":
        log("skipped via SKIP_TERRAFORM_CHECKS=1")
        return

    network_mode = _network_mode_from_manifest(manifest)
    kb_conn_mode = _kb_connectivity_mode_from_manifest(manifest)
    log(f"network_mode={network_mode}  kb_connectivity_mode={kb_conn_mode}")

    voyage_output = run(["terraform", "output", "-raw", "voyage_endpoint_name"], cwd=TF_DIR)
    cw_api = run(["terraform", "output", "-raw", "cloudwatch_api_log_group"], cwd=TF_DIR)
    cw_ui = run(["terraform", "output", "-raw", "cloudwatch_ui_log_group"], cwd=TF_DIR)
    tf_network_mode = run(["terraform", "output", "-raw", "network_mode"], cwd=TF_DIR)
    kb_pl_enabled = run(
        ["terraform", "output", "-raw", "bedrock_kb_privatelink_enabled"],
        cwd=TF_DIR,
    )
    kb_peering_enabled = run(
        ["terraform", "output", "-raw", "bedrock_kb_peering_enabled"],
        cwd=TF_DIR,
    )
    kb_endpoint_service = run(
        ["terraform", "output", "-raw", "bedrock_kb_endpoint_service_name"],
        cwd=TF_DIR,
    )
    tf_kb_conn_mode = run(["terraform", "output", "-raw", "kb_connectivity_mode"], cwd=TF_DIR)
    log(
        json.dumps(
            {
                "voyage_endpoint_name": voyage_output,
                "network_mode": tf_network_mode,
                "bedrock_kb_privatelink_enabled": kb_pl_enabled,
                "bedrock_kb_peering_enabled": kb_peering_enabled,
                "bedrock_kb_endpoint_service_name": kb_endpoint_service,
                "kb_connectivity_mode": tf_kb_conn_mode,
                "cloudwatch_api_log_group": cw_api,
                "cloudwatch_ui_log_group": cw_ui,
            },
            sort_keys=True,
        )
    )

    if resources.get("embeddings_provider") == "voyage":
        require(
            voyage_output == resources.get("voyage_sagemaker_endpoint"),
            "terraform voyage_endpoint_name does not match deploy manifest",
        )

    # Mode parity: TF and manifest must agree on connectivity mode.
    require(
        tf_network_mode == network_mode,
        f"terraform network_mode={tf_network_mode!r} disagrees with manifest network.mode={network_mode!r}",
    )
    require(
        tf_kb_conn_mode == kb_conn_mode,
        f"terraform kb_connectivity_mode={tf_kb_conn_mode!r} disagrees with manifest {kb_conn_mode!r}",
    )

    # Mutual exclusion: privatelink and peering KB modes must NEVER both be on.
    require(
        not (kb_pl_enabled == "true" and kb_peering_enabled == "true"),
        "PrivateLink and peering KB modes are mutually exclusive but both are reported enabled — hybrid mode is forbidden",
    )

    if network_mode == "privatelink":
        require(kb_pl_enabled == "true", "Bedrock KB PrivateLink must be enabled in privatelink mode")
        require(kb_peering_enabled == "false", "Bedrock KB peering must be disabled in privatelink mode")
        require(
            kb_endpoint_service.startswith("com.amazonaws.vpce."),
            f"Bedrock KB endpoint service name missing/invalid: {kb_endpoint_service}",
        )
    else:
        require(kb_pl_enabled == "false", "Bedrock KB PrivateLink must be disabled in peering mode")
        if kb_conn_mode == "peering-nlb":
            require(kb_peering_enabled == "true", "Bedrock KB peering-NLB must be enabled when kb_connectivity_mode=peering-nlb")
            require(
                kb_endpoint_service.startswith("com.amazonaws.vpce."),
                f"Bedrock KB peering endpoint service name missing/invalid: {kb_endpoint_service}",
            )
        elif kb_conn_mode == "public-srv":
            require(kb_peering_enabled == "false", "Bedrock KB peering must be disabled when kb_connectivity_mode=public-srv")
        else:
            require(False, f"unexpected kb_connectivity_mode in peering mode: {kb_conn_mode!r}")

    require("/" in cw_api and cw_api.rstrip("/").endswith("/api"), f"unexpected api log group: {cw_api!r}")
    require("/" in cw_ui and cw_ui.rstrip("/").endswith("/ui"), f"unexpected ui log group: {cw_ui!r}")


def check_bedrock_kb(resources: dict[str, Any], manifest: dict[str, Any]) -> None:
    network_mode = _network_mode_from_manifest(manifest)
    kb_conn_mode = _kb_connectivity_mode_from_manifest(manifest)
    log(f"\n== Bedrock KB connectivity ({network_mode} / kb={kb_conn_mode}) ==")
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

    endpoint_service = str(info.get("endpointServiceName") or "")
    endpoint_host = str(info.get("endpoint") or "")
    if kb_conn_mode == "privatelink":
        require(
            endpoint_service.startswith("com.amazonaws.vpce."),
            "Bedrock KB is not configured with endpointServiceName PrivateLink",
        )
        require("-pl-" in endpoint_host, f"Bedrock KB endpoint is not the Atlas -pl host: {endpoint_host}")
    elif kb_conn_mode == "peering-nlb":
        require(
            endpoint_service.startswith("com.amazonaws.vpce."),
            "Bedrock KB peering-NLB path must still publish a VPCE endpoint service name",
        )
        # The peering NLB fronts the standard cluster hostname so the cert SAN
        # matches; we don't require any specific token in the hostname.
        require(endpoint_host, "Bedrock KB endpoint host is empty in peering-NLB mode")
    else:
        # public-srv mode — endpointServiceName must be empty, endpoint is the
        # cluster's public SRV host.
        require(
            not endpoint_service,
            f"Bedrock KB is in public-srv mode but endpointServiceName is set: {endpoint_service}",
        )


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


def post_chat(
    api_url: str,
    token: str,
    agent: str,
    message: str,
    *,
    session_id: str | None = None,
) -> tuple[str, str | None]:
    """
    POST /chat and return the SSE body + X-Trace-Id.

    Reads the SSE stream incrementally and tolerates premature TCP closes when
    meaningful events have already arrived (handoff, agent_info, stream_error,
    done, message). This is necessary because the API today emits a burst of
    trace/agent_info/handoff events at the start, then **goes idle for the
    duration of the AgentCore Runtime invocation** (often 60-150s on cold
    start). AWS-side NAT / NLB / target-group idle timeouts can drop the TCP
    connection during that silent window, even though the server is still
    successfully processing and ultimately persists the assistant turn.
    Failing the smoke on those drops would flake every run after an idle
    runtime. Real failures (missing handoff/done, surfaced stream_error) are
    still asserted downstream by the per-agent checks.
    """
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    last_error: BaseException | None = None
    max_attempts = min(chat_attempts(), 3)
    for attempt in range(1, max_attempts + 1):
        turn_session_id = session_id or f"post-deploy-smoke-{agent}-{int(time.time() * 1000)}-{attempt}"
        payload = json.dumps(
            {
                "agentId": agent,
                "sessionId": turn_session_id,
                "message": message,
            }
        ).encode()
        chunks: list[bytes] = []
        try:
            request = urllib.request.Request(
                f"{api_url}/chat",
                data=payload,
                headers=headers,
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=300) as response:
                x_trace = response.headers.get("X-Trace-Id") or response.headers.get("x-trace-id")
                try:
                    while True:
                        chunk = response.read(8192)
                        if not chunk:
                            break
                        chunks.append(chunk)
                except (http.client.IncompleteRead, TimeoutError, urllib.error.URLError) as stream_exc:
                    partial = getattr(stream_exc, "partial", None)
                    if isinstance(partial, (bytes, bytearray)) and partial:
                        chunks.append(bytes(partial))
                    body = b"".join(chunks).decode("utf-8", "replace")
                    if _sse_has_useful_event(body):
                        log(
                            f"  warning: SSE stream truncated for {agent} "
                            f"({type(stream_exc).__name__}: {stream_exc}); "
                            f"using {len(body)} bytes of partial response that "
                            f"already contains the events downstream checks need."
                        )
                        return body, x_trace
                    raise
                body = b"".join(chunks).decode("utf-8", "replace")
                return body, x_trace
        except urllib.error.HTTPError as exc:
            try:
                body = exc.read().decode("utf-8", "replace")
            except Exception:
                body = ""
            if body:
                return body, None
            last_error = exc
        except (
            http.client.IncompleteRead,
            http.client.HTTPException,
            TimeoutError,
            urllib.error.URLError,
        ) as exc:
            last_error = exc
            if attempt < max_attempts:
                time.sleep(5 * attempt)
    raise SmokeFailure(f"chat stream failed after retries for {agent}: {last_error}")


_USEFUL_SSE_EVENT_RE = re.compile(
    r'^event:\s*(?:handoff|agent_info|stream_error|done|message|token)\s*$',
    re.MULTILINE,
)


def _sse_has_useful_event(body: str) -> bool:
    """True if the partial SSE body already contains an event downstream checks key off."""
    if not body:
        return False
    return bool(_USEFUL_SSE_EVENT_RE.search(body))


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


def poll_persisted_turn(
    api_url: str,
    token: str,
    session_id: str,
    *,
    timeout_seconds: int = 240,
) -> tuple[str, str | None]:
    """Return the persisted assistant reply + messageId for a chat session.

    Used when the live SSE stream is cut during a long AgentCore Runtime call.
    The API persists the assistant turn before storing the trace, so the
    session document is the earliest reliable signal that the server finished.
    """
    deadline = time.time() + timeout_seconds
    last_error = ""
    while time.time() < deadline:
        try:
            doc = load_json_url(
                f"{api_url}/sessions/{urllib.parse.quote(session_id, safe='')}",
                timeout=30,
                token=token,
            )
            messages = doc.get("messages", []) if isinstance(doc, dict) else []
            for msg in reversed(messages if isinstance(messages, list) else []):
                if not isinstance(msg, dict):
                    continue
                if msg.get("role") != "assistant":
                    continue
                content = str(msg.get("content") or "")
                if content.strip():
                    message_id = msg.get("messageId") or msg.get("id")
                    return content, str(message_id) if message_id else None
        except Exception as exc:
            last_error = f"{type(exc).__name__}: {exc}"
        time.sleep(5)
    raise SmokeFailure(
        f"assistant reply was not persisted for session {session_id!r} within "
        f"{timeout_seconds}s; last_error={last_error}"
    )


def poll_trace_event_types(
    api_url: str,
    token: str,
    session_id: str,
    message_id: str | None,
    *,
    timeout_seconds: int = 120,
) -> list[str]:
    """Poll /trace for event types associated with a persisted assistant turn."""
    if not message_id:
        return []
    encoded_session = urllib.parse.quote(session_id, safe="")
    encoded_message = urllib.parse.quote(message_id, safe="")
    url = f"{api_url}/trace?sessionId={encoded_session}&messageId={encoded_message}&include=full"
    deadline = time.time() + timeout_seconds
    last_error = ""
    while time.time() < deadline:
        try:
            trace_doc = load_json_url(url, timeout=30, token=token)
            events = trace_doc.get("events", []) if isinstance(trace_doc, dict) else []
            out: list[str] = []
            for ev in events if isinstance(events, list) else []:
                if isinstance(ev, dict) and ev.get("type"):
                    out.append(str(ev["type"]))
            if out:
                return out
        except Exception as exc:
            last_error = f"{type(exc).__name__}: {exc}"
        time.sleep(5)
    log(
        f"  warning: trace events unavailable for session={session_id} "
        f"messageId={message_id}; last_error={last_error}"
    )
    return []


def _read_env_live(path: Path) -> dict[str, str]:
    """Parse a KEY=VALUE .env file (no `export`, no quoting). Returns {} when
    the file is missing so older deploys without .env.live don't hard-fail."""
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    return out


def check_agentcore_runtime_env(resources: dict[str, Any]) -> None:
    """Fail fast when a specialist (or orchestrator) AgentCore Runtime is
    missing MongoDB MCP Gateway wiring env vars. This catches the Terraform-vs-script
    drift documented in docs/status/debugging.md (Specialist runtime env reset by
    `terraform apply`) before the live chat checks waste 5 retries on a
    silently-degraded runtime.

    Failure mode this prevents: TF reapplies the agentcore-agent-runtime
    module and overwrites the dynamic env injected by Phase 6b, leaving the
    runtime with only AWS_REGION/AGENT_ID/LOG_LEVEL/AGENTCORE_MEMORY_STORE_ID
    and every `mongodb_*` tool call failing before it can reach Gateway.
    """
    log("\n== AgentCore runtime env wiring ==")
    if os.environ.get("SKIP_AGENTCORE_ENV_CHECK") == "1":
        log("skipped via SKIP_AGENTCORE_ENV_CHECK=1")
        return

    region = str(resources.get("aws_region") or os.environ.get("AWS_REGION") or "").strip()
    require(region, "aws_region missing — needed for bedrock-agentcore-control calls")

    env_live = _read_env_live(ROOT / ".env.live")
    runtime_arns: dict[str, str] = {}
    if env_live.get("AGENTCORE_ORCHESTRATOR_ARN"):
        runtime_arns["orchestrator"] = env_live["AGENTCORE_ORCHESTRATOR_ARN"]
    for key, value in env_live.items():
        if not key.startswith("AGENTCORE_") or not key.endswith("_ARN"):
            continue
        if key in ("AGENTCORE_ORCHESTRATOR_ARN", "AGENTCORE_RUNTIME_ARN"):
            continue
        # AGENTCORE_PRODUCT_RECOMMENDATION_ARN -> product-recommendation
        spec_id = key[len("AGENTCORE_") : -len("_ARN")].lower().replace("_", "-")
        if spec_id:
            runtime_arns[spec_id] = value

    if not runtime_arns:
        log("WARN: no AGENTCORE_*_ARN entries found in .env.live; runtime env check skipped")
        return

    log(f"runtimes_checked={sorted(runtime_arns)}")

    # Vars every specialist + orchestrator runtime needs. Mirrors the strict
    # checks in deploy/scripts/_agents-common.sh::verify_runtime_env_dynamic.
    required = (
        "AGENTCORE_GATEWAY_URL",
        "MONGODB_URI",
        "AGENTCORE_MEMORY_STORE_ID",
    )

    failures: list[str] = []
    for agent_id, runtime_arn in sorted(runtime_arns.items()):
        runtime_id = runtime_arn.rsplit("/", 1)[-1]
        try:
            raw = run(
                [
                    "aws",
                    "bedrock-agentcore-control",
                    "get-agent-runtime",
                    "--region",
                    region,
                    "--agent-runtime-id",
                    runtime_id,
                    "--query",
                    "environmentVariables",
                    "--output",
                    "json",
                ],
                timeout=30,
            )
        except SmokeFailure as exc:
            failures.append(f"{agent_id} ({runtime_id}): get-agent-runtime failed: {exc}")
            continue

        try:
            env_map: dict[str, str] = json.loads(raw or "{}") or {}
        except json.JSONDecodeError:
            failures.append(f"{agent_id} ({runtime_id}): non-JSON environmentVariables: {raw[:200]!r}")
            continue

        missing = [name for name in required if not env_map.get(name)]
        if missing:
            failures.append(
                f"{agent_id} ({runtime_id}): missing required env vars {missing}. "
                f"Runtime has only {sorted(env_map)}. "
                "Re-run ./deploy/deploy-agents.sh --auto-approve to restore Gateway env."
            )
            continue
        log(f"PASS {agent_id} runtime env wiring (has {len(env_map)} vars)")

    if failures:
        raise SmokeFailure(
            "AgentCore runtime env wiring failed for "
            f"{len(failures)} runtime(s):\n  - " + "\n  - ".join(failures)
        )


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
        last_failure = ""
        max_attempts = chat_attempts()
        for attempt in range(1, max_attempts + 1):
            if attempt > 1:
                log(f"retrying {agent} chat assertion ({attempt}/{max_attempts})")
            turn_session_id = f"post-deploy-smoke-{agent}-{int(time.time() * 1000)}-{attempt}"
            body, x_trace = post_chat(
                api_url,
                token,
                str(agent),
                str(case["message"]),
                session_id=turn_session_id,
            )
            text, events, traces, handoffs, errors = parse_sse(body)
            flat = re.sub(r"\s+", " ", text).strip()
            used_persisted_fallback = False

            # If the SSE stream was dropped during a long silent AgentCore
            # invoke, validate the server-completed turn from persisted session
            # + trace data. This keeps smoke aligned with the actual contract:
            # the turn must finish, persist an assistant reply, and emit the
            # relevant trace or handoff signal. It does not mask application
            # errors because `errors` from the partial SSE still fail below.
            if ("done" not in events or "token" not in events or len(flat) <= 20) and _sse_has_useful_event(body):
                log(
                    f"  warning: SSE for {agent} ended before token/done; "
                    f"polling persisted session {turn_session_id} for completion"
                )
                persisted_reply, persisted_message_id = poll_persisted_turn(
                    api_url,
                    token,
                    turn_session_id,
                )
                persisted_traces = poll_trace_event_types(
                    api_url,
                    token,
                    turn_session_id,
                    persisted_message_id,
                )
                if persisted_reply:
                    flat = re.sub(r"\s+", " ", persisted_reply).strip()
                    events = sorted(set(events + ["token", "done"]))
                    used_persisted_fallback = True
                if persisted_traces:
                    traces = sorted(set(traces + persisted_traces))

            checks = {
                "trace_id": isinstance(x_trace, str)
                and len(x_trace) == 32
                and re.match(r"^[0-9a-f]{32}$", x_trace, re.I) is not None,
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
            if used_persisted_fallback:
                log("used_persisted_fallback=true")
            log(f"checks={json.dumps(checks, sort_keys=True)}")
            if all(checks.values()):
                break
            last_failure = (
                f"{agent} smoke failed after attempt {attempt}/{max_attempts}: "
                f"checks={checks} x_trace={x_trace!r}"
            )
            if attempt < max_attempts:
                time.sleep(chat_retry_delay_seconds() * attempt)
        else:
            raise SmokeFailure(last_failure)
        log(f"PASS {agent}")


def check_long_term_memory_recall(api_url: str, token: str) -> None:
    """End-to-end LTM regression: plant a memorable fact, then ask a fresh
    session to recall it. Fails if either turn errors or the recall reply
    doesn't surface the planted token.

    Promoted from `memory-recall-diagnostic.py::scenario_B`. Lightweight —
    one plant + one recall, ~30 s total. Skip with SKIP_CHAT_CHECKS=1 or
    SKIP_LTM_CHECK=1.
    """
    log("\n== Long-term memory recall ==")
    if os.environ.get("SKIP_CHAT_CHECKS") == "1" or os.environ.get("SKIP_LTM_CHECK") == "1":
        log("skipped via SKIP_CHAT_CHECKS=1 or SKIP_LTM_CHECK=1")
        return

    needle = "HELIOTROPE-LANTERN"
    run_id = int(time.time() * 1000)
    plant_msg = (
        f"Please remember this preference for future support tickets: my "
        f"favorite mnemonic phrase is {needle}. Treat it as a stable user "
        "preference, not a one-off."
    )
    recall_msg = (
        "We talked earlier about a memorable phrase you should keep on file "
        "as one of my preferences. Quote that exact phrase back to me."
    )

    def _stream(session_id: str, message: str) -> tuple[str, list[str], list[Any]]:
        body, _x_trace = post_chat(api_url, token, "orchestrator", message, session_id=session_id)
        text, events, _traces, _handoffs, errors = parse_sse(body)
        return text, events, errors

    plant_text = ""
    last_plant_failure = ""
    for attempt in range(1, chat_attempts() + 1):
        plant_session = f"post-deploy-smoke-ltm-plant-{run_id}-{attempt}"
        plant_text, plant_events, plant_errors = _stream(plant_session, plant_msg)
        if "done" in plant_events and not plant_errors:
            break
        last_plant_failure = f"LTM plant attempt {attempt} failed: events={plant_events} errors={plant_errors}"
        if attempt < chat_attempts():
            time.sleep(chat_retry_delay_seconds() * attempt)
    else:
        raise SmokeFailure(last_plant_failure)
    log(f"plant reply head: {plant_text[:160]!r}")

    # Let fact extraction + embedding + dedup index settle before recall.
    # Empirically writeLongTermMemory + chat_messages mirror complete < 5 s
    # on the live stack; we give it 8 s to absorb cold-start jitter.
    time.sleep(8)

    flat = ""
    last_recall_failure = ""
    for attempt in range(1, chat_attempts() + 1):
        recall_session = f"post-deploy-smoke-ltm-recall-{run_id}-{attempt}"
        recall_text, recall_events, recall_errors = _stream(recall_session, recall_msg)
        flat = re.sub(r"\s+", " ", recall_text).strip()
        log(f"recall reply head: {flat[:400]!r}")
        if "done" in recall_events and not recall_errors and needle.lower() in flat.lower():
            break
        last_recall_failure = (
            f"LTM recall attempt {attempt} failed: events={recall_events} "
            f"errors={recall_errors} reply={flat[:400]!r}"
        )
        if attempt < chat_attempts():
            time.sleep(chat_retry_delay_seconds() * attempt)
    else:
        raise SmokeFailure(f"LTM recall did not surface needle {needle!r}: {last_recall_failure}")
    log(f"PASS LTM cross-session recall ({needle})")


def check_cloudwatch_join(resources: dict[str, Any], api_url: str, token: str) -> None:
    """Cross-boundary OTel correlation — Phase 10 smoke check.

    POST /chat, capture `X-Trace-Id`, then verify ≥1 CloudWatch Logs entry
    in the API log group carries the same `trace_id` JSON field. Non-fatal:
    journald → CW agent is best-effort and can lag a few seconds on a fresh
    EC2; we wait up to 90 s before warning.
    """
    log("\n== CloudWatch trace_id join ==")
    if os.environ.get("SKIP_CHAT_CHECKS") == "1":
        log("skipped via SKIP_CHAT_CHECKS=1")
        return

    api_group = (resources.get("cloudwatch_api_log_group") or "").strip()
    if not api_group:
        if os.environ.get("SKIP_TERRAFORM_CHECKS") == "1":
            log("no cloudwatch_api_log_group in manifest and terraform checks skipped — skipping CW join")
            return
        try:
            api_group = run(["terraform", "output", "-raw", "cloudwatch_api_log_group"], cwd=TF_DIR)
        except SmokeFailure:
            log("cloudwatch_api_log_group output missing — skipping CW join")
            return

    region = str(resources.get("aws_region") or os.environ.get("AWS_REGION") or "us-east-1")
    # Use a routing prompt that forces orchestrator -> specialist hand-off so both
    # the API span AND the downstream AgentCore runtime emit logs carrying the
    # same trace_id. A bare greeting often short-circuits inside the orchestrator
    # without invoking any specialist runtime, leaving CloudWatch with API-only hits.
    _, x_trace = post_chat(api_url, token, "orchestrator", "Please look up the status of order ORD-1001.")
    require(
        isinstance(x_trace, str) and len(x_trace) == 32 and re.match(r"^[0-9a-f]{32}$", x_trace, re.I),
        f"POST /chat missing X-Trace-Id (got {x_trace!r})",
    )
    log(f"x_trace_id={x_trace}")
    log(f"log_group={api_group}")

    pattern = '{ $.trace_id = "' + str(x_trace) + '" }'
    start_ts = int(time.time() * 1000) - 5 * 60 * 1000

    found = 0
    deadline = time.time() + 90
    while time.time() < deadline:
        try:
            raw = run(
                [
                    "aws",
                    "logs",
                    "filter-log-events",
                    "--region",
                    region,
                    "--log-group-name",
                    api_group,
                    "--start-time",
                    str(start_ts),
                    "--filter-pattern",
                    pattern,
                    "--max-items",
                    "5",
                    "--output",
                    "json",
                ],
                timeout=30,
            )
        except SmokeFailure as exc:
            log(f"filter-log-events failed (will retry): {exc}")
            time.sleep(10)
            continue
        try:
            doc = json.loads(raw)
        except json.JSONDecodeError:
            time.sleep(5)
            continue
        events = doc.get("events") or []
        found = len(events)
        if found >= 1:
            break
        time.sleep(5)

    if found >= 1:
        log(f"PASS cloudwatch_trace_join (matched {found} log events for trace_id={x_trace})")
    else:
        log(
            f"WARN: 0 log events with trace_id={x_trace} in {api_group} within 90s — "
            "journald → CW agent may be lagging or agent unhealthy."
        )

    # AgentCore-managed log groups land under /aws/bedrock-agentcore/runtimes/<id>/.
    # The account commonly accumulates legacy groups from prior deployments, so
    # we scope the discovery prefix to the *current* deployment's project slug
    # derived from the API log group (e.g. `/mongodb-multiagent3/dev/api` ->
    # project_slug `mongodb_multiagent3`). Without this, alphabetic sort can hide
    # the current runtimes behind legacy groups when AWS caps the page size.
    project_slug: str | None = None
    parts = api_group.strip("/").split("/")
    if parts:
        project_slug = parts[0].replace("-", "_")
    if project_slug:
        agentcore_prefix = f"/aws/bedrock-agentcore/runtimes/{project_slug}_"
    else:
        agentcore_prefix = "/aws/bedrock-agentcore/runtimes/"
    try:
        groups_raw = run(
            [
                "aws",
                "logs",
                "describe-log-groups",
                "--region",
                region,
                "--log-group-name-prefix",
                agentcore_prefix,
                "--output",
                "json",
            ],
            timeout=30,
        )
    except SmokeFailure as exc:
        log(f"AgentCore log-group discovery skipped: {exc}")
        return

    try:
        agentcore_groups = [
            str(g.get("logGroupName") or "")
            for g in (json.loads(groups_raw).get("logGroups") or [])
            if g.get("logGroupName")
        ]
    except json.JSONDecodeError:
        agentcore_groups = []

    if not agentcore_groups:
        log(
            f"WARN: no AgentCore log groups under {agentcore_prefix!r} — "
            "AgentCore trace join skipped."
        )
        return
    log(f"agentcore_log_groups_scanned={len(agentcore_groups)} (prefix={agentcore_prefix})")

    # AgentCore-managed log delivery to CloudWatch can lag 30-90 s on cold
    # runtimes. Poll for up to ~120 s before giving up.
    agentcore_hits = 0
    matched_group: str | None = None
    deadline = time.time() + 120
    while time.time() < deadline and agentcore_hits == 0:
        for grp in agentcore_groups:
            try:
                raw = run(
                    [
                        "aws",
                        "logs",
                        "filter-log-events",
                        "--region",
                        region,
                        "--log-group-name",
                        grp,
                        "--start-time",
                        str(start_ts),
                        "--filter-pattern",
                        pattern,
                        "--max-items",
                        "3",
                        "--output",
                        "json",
                    ],
                    timeout=20,
                )
            except SmokeFailure:
                continue
            try:
                events = (json.loads(raw).get("events") or [])
            except json.JSONDecodeError:
                continue
            if events:
                agentcore_hits = len(events)
                matched_group = grp
                break
        if agentcore_hits == 0:
            time.sleep(10)

    if agentcore_hits >= 1:
        log(f"PASS agentcore_trace_join (matched {agentcore_hits} events in {matched_group} for trace_id={x_trace})")
    else:
        log(
            f"WARN: 0 AgentCore-runtime log events with trace_id={x_trace} across "
            f"{len(agentcore_groups)} group(s) — verify _trace propagation in adapters/agentcore-runtime.ts."
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        default=os.environ.get("DEPLOY_MANIFEST_PATH", str(DEFAULT_MANIFEST)),
        help="Path to deploy-manifest.json",
    )
    args = parser.parse_args()

    resources = manifest_resources(Path(args.manifest))
    full_manifest = manifest_doc(Path(args.manifest))
    api_url = str(resources.get("ec2_api_url", "")).rstrip("/")
    client_id = str(resources.get("cognito_client_id", ""))
    require(api_url, "deploy manifest missing ec2_api_url")
    require(client_id, "deploy manifest missing cognito_client_id")

    log(f"API={api_url}")
    log(f"UI={resources.get('ec2_ui_url')}")
    log(f"manifest={args.manifest}")
    log(f"network_mode={_network_mode_from_manifest(full_manifest)}  kb_connectivity_mode={_kb_connectivity_mode_from_manifest(full_manifest)}")

    check_health(api_url, resources)
    token = cognito_token(client_id)
    log(f"cognito_token_len={len(token)}")
    check_agents_endpoint(api_url, token)
    check_embedding_manifest_and_sagemaker(resources)
    check_terraform_outputs(resources, full_manifest)
    check_bedrock_kb(resources, full_manifest)
    # Verify every AgentCore Runtime has the Gateway MCP wiring vars BEFORE
    # the live chat checks. Missing AGENTCORE_GATEWAY_URL means mongodb_* tools cannot
    # reach Gateway, which the chat check would only catch after retries on
    # each agent.
    check_agentcore_runtime_env(resources)
    check_all_agents(api_url, token)
    check_long_term_memory_recall(api_url, token)
    check_cloudwatch_join(resources, api_url, token)

    log("\nALL_POST_DEPLOY_SMOKE_CHECKS_PASSED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SmokeFailure as exc:
        print(f"\nSMOKE_FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
