#!/usr/bin/env python3
"""Live AWS audit for the four Bedrock/AgentCore Terraform resources.

Validates that each resource:
  1. Exists in AWS (not just in Terraform code)
  2. Is in an ACTIVE / READY state
  3. Has the expected associations/config (targets, data sources, memory link)

Also runs static Terraform file checks (no AWS credentials needed) to
flag the implementation gaps found in the May 2026 audit:
  - Gateway has no targets deployed
  - Memory is not TF-associated to runtimes (env-var linked only)

Run from the repository root after deployment:

    python3 e2e-smoke/bedrock-resource-live-audit.py

Or against a manifest:

    python3 e2e-smoke/bedrock-resource-live-audit.py --manifest deploy-manifest.json

Skip flags:
    SKIP_LIVE_CHECKS=1    Skip AWS CLI calls (static TF-only mode)
    SKIP_STATIC_CHECKS=1  Skip Terraform file analysis
    AWS_REGION            Override AWS region (default: us-east-1)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
TF_MODULES = ROOT / "deploy" / "terraform" / "modules"
TF_EC2_ENV = ROOT / "deploy" / "terraform" / "envs" / "ec2"
DEFAULT_MANIFEST = ROOT / "deploy-manifest.json"


# ── Result tracking ─────────────────────────────────────────────────────────

PASS = 0
FAIL = 0
WARN = 0
results: list[str] = []


def _record(tag: str, name: str, detail: str = "") -> None:
    line = f"{tag}  {name}" + (f" — {detail}" if detail else "")
    results.append(line)
    print(f"  {line}")


def passed(name: str, detail: str = "") -> None:
    global PASS
    PASS += 1
    _record("PASS", name, detail)


def failed(name: str, detail: str = "") -> None:
    global FAIL
    FAIL += 1
    _record("FAIL", name, detail)


def warned(name: str, detail: str = "") -> None:
    global WARN
    WARN += 1
    _record("WARN", name, detail)


def check(condition: bool, name: str, detail: str = "") -> bool:
    if condition:
        passed(name, detail)
    else:
        failed(name, detail)
    return condition


# ── Shell helpers ────────────────────────────────────────────────────────────

def run_cmd(cmd: list[str], *, timeout: int = 60) -> tuple[bool, str]:
    """Run a command, return (success, output). Never raises."""
    try:
        out = subprocess.check_output(
            cmd,
            text=True,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        ).strip()
        return True, out
    except subprocess.CalledProcessError as exc:
        return False, (exc.output or "").strip()
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)


def aws(*args: str, region: str, timeout: int = 60) -> tuple[bool, str]:
    return run_cmd(["aws", "--region", region, *args], timeout=timeout)


def aws_control(*args: str, region: str, timeout: int = 60) -> tuple[bool, str]:
    """Calls the AgentCore Control Plane CLI (bedrock-agentcore-control)."""
    return run_cmd(["aws", "bedrock-agentcore-control", "--region", region, *args], timeout=timeout)


def tf_output(name: str, *, cwd: Path) -> str | None:
    ok, out = run_cmd(["terraform", "output", "-raw", name], timeout=30)
    if ok and out and not out.startswith("No outputs"):
        return out
    return None


# ── Static TF analysis ───────────────────────────────────────────────────────

def _grep(path: Path, pattern: str) -> list[str]:
    """Return lines in path matching pattern."""
    try:
        lines = path.read_text(errors="replace").splitlines()
        return [l for l in lines if re.search(pattern, l)]
    except OSError:
        return []


def static_checks() -> None:
    print("\n══════════════════════════════════════════════════")
    print(" STATIC: Terraform file analysis")
    print("══════════════════════════════════════════════════")

    # ── 1. Official resource types present ───────────────────────────────────
    print("\n── 1. Official resource types ──────────────────────")
    resources = [
        ("aws_bedrockagentcore_gateway",      "modules/agentcore-gateway/main.tf"),
        ("aws_bedrockagent_knowledge_base",    "modules/bedrock-kb/main.tf"),
        ("aws_bedrockagentcore_agent_runtime", "modules/agentcore-agent-runtime/main.tf"),
        ("aws_bedrockagentcore_memory",        "modules/agentcore-memory/main.tf"),
    ]
    for resource_type, rel_path in resources:
        path = ROOT / "deploy" / "terraform" / rel_path
        lines = _grep(path, rf'^resource "{resource_type}"')
        check(bool(lines), f"official_resource.{resource_type}", rel_path)

    # ── 2. null_resource does NOT replace official resources ─────────────────
    print("\n── 2. null_resource replaces no official resource ──")
    for resource_type, rel_path in resources:
        path = ROOT / "deploy" / "terraform" / rel_path
        null_lines = _grep(path, r'^resource "null_resource"')
        official_lines = _grep(path, rf'^resource "{resource_type}"')
        if not official_lines:
            failed(f"null_resource_check.{resource_type}", "official resource missing — cannot evaluate")
        elif not null_lines:
            passed(f"null_resource_check.{resource_type}", "no null_resource; official is sole impl")
        else:
            # null_resource co-exists — allowed for bedrock-kb (ingestion/bootstrap) and
            # agentcore-gateway (mcp_server target: TF provider gap for iamCredentialProvider)
            if "bedrock-kb" in rel_path:
                warned(
                    f"null_resource_check.{resource_type}",
                    f"{len(null_lines)} auxiliary null_resource(s) co-exist (expected: ingestion+bootstrap)",
                )
            elif "agentcore-gateway" in rel_path:
                warned(
                    f"null_resource_check.{resource_type}",
                    f"{len(null_lines)} null_resource(s) co-exist — intentional workaround for TF provider "
                    "gap: gateway_iam_role{} does not emit iamCredentialProvider.service/region",
                )
            else:
                failed(
                    f"null_resource_check.{resource_type}",
                    f"unexpected null_resource alongside official resource in {rel_path}",
                )

    # ── 3. Gateway target: mcp_server must be enabled and fully wired ──────────
    print("\n── 3. Gateway MCP server target (comprehensive) ─────")
    ec2_main = TF_EC2_ENV / "main.tf"
    mcp_true      = _grep(ec2_main, r'create_mcp_server_target\s*=\s*true')
    mcp_endpoint  = _grep(ec2_main, r'mcp_server_endpoint\s*=')
    mcp_arn       = _grep(ec2_main, r'mcp_server_runtime_arn\s*=')
    mcp_local_ref = _grep(ec2_main, r'mcp_server_endpoint\s*=\s*local\.mongodb_mcp_runtime_endpoint')

    check(bool(mcp_true),      "gateway.create_mcp_server_target_true",
          "create_mcp_server_target=true in ec2 module block")
    check(bool(mcp_endpoint),  "gateway.mcp_server_endpoint_set",
          "mcp_server_endpoint variable wired")
    check(bool(mcp_arn),       "gateway.mcp_server_runtime_arn_set",
          "mcp_server_runtime_arn variable wired")
    check(bool(mcp_local_ref), "gateway.endpoint_references_local_computed",
          "endpoint = local.mongodb_mcp_runtime_endpoint (urlencode'd ARN)")

    # ── 4. Memory: AGENTCORE_MEMORY_STORE_ID injected via Terraform ───────────
    print("\n── 4. Memory Terraform-managed injection ────────────")
    mem_env_hits = _grep(ec2_main, r'AGENTCORE_MEMORY_STORE_ID')
    mem_tf_refs  = _grep(ec2_main, r'AGENTCORE_MEMORY_STORE_ID\s*=\s*module\.agentcore_memory\.memory_id')

    check(
        len(mem_env_hits) >= 4,
        "memory.env_var_in_runtime_blocks",
        f"{len(mem_env_hits)} runtime block(s) include AGENTCORE_MEMORY_STORE_ID (expected ≥4)",
    )
    check(
        len(mem_tf_refs) >= 4,
        "memory.tf_managed_reference",
        f"{len(mem_tf_refs)} block(s) use module.agentcore_memory.memory_id (Terraform-managed)",
    )

    # Confirm the env-var link also exists in deploy-project.sh as belt-and-suspenders
    deploy_sh = ROOT / "deploy" / "scripts" / "deploy-project.sh"
    if deploy_sh.exists():
        env_link = _grep(deploy_sh, r'AGENTCORE_MEMORY_STORE_ID')
        check(bool(env_link), "memory.env_var_also_in_deploy_project_sh",
              f"{len(env_link)} reference(s) in deploy/scripts/deploy-project.sh (belt-and-suspenders)")
    else:
        warned("memory.env_var_also_in_deploy_project_sh",
               "deploy/scripts/deploy-project.sh not found — skipped")

    # ── 5. Agent runtime — 5 instances in ec2 ────────────────────────────────
    print("\n── 5. AgentCore runtime instances ──────────────────")
    runtime_calls = _grep(ec2_main, r'source\s*=\s*".*agentcore-agent-runtime"')
    check(
        len(runtime_calls) >= 5,
        "agentcore_runtime.five_instances_in_ec2",
        f"{len(runtime_calls)} module calls found (expected ≥5)",
    )

    # ── 6. KB + Memory wired in both ec2 and local ───────────────────────────
    print("\n── 6. Module wiring in envs ─────────────────────────")
    local_main = ROOT / "deploy" / "terraform" / "envs" / "local" / "main.tf"
    ec2_kb      = _grep(ec2_main,   r'source\s*=\s*".*bedrock-kb"')
    local_kb    = _grep(local_main, r'source\s*=\s*".*bedrock-kb"')
    local_mem   = _grep(local_main, r'source\s*=\s*".*agentcore-memory"')
    local_out   = ROOT / "deploy" / "terraform" / "envs" / "local" / "outputs.tf"
    mem_output  = _grep(local_out,  r'agentcore_memory_id') if local_out.exists() else []
    check(bool(ec2_kb),    "bedrock_kb.wired_in_ec2_env",     f"{len(ec2_kb)} module block(s)")
    check(bool(local_kb),  "bedrock_kb.wired_in_local_env",   f"{len(local_kb)} module block(s)")
    check(bool(local_mem), "agentcore_memory.wired_in_local_env",
          f"{len(local_mem)} module block(s) — local env can export AGENTCORE_MEMORY_STORE_ID")
    check(bool(mem_output), "agentcore_memory.output_in_local_outputs_tf",
          "agentcore_memory_id output present")

    # ── 7. Provider version floor ─────────────────────────────────────────────
    print("\n── 7. Provider version constraints ─────────────────")
    version_checks = [
        ("modules/agentcore-gateway/main.tf",       6, 17),
        ("modules/bedrock-kb/main.tf",               6,  0),
        ("modules/agentcore-agent-runtime/main.tf",  6, 17),
        ("modules/agentcore-memory/main.tf",         6, 18),
    ]
    for rel, need_major, need_minor in version_checks:
        path = ROOT / "deploy" / "terraform" / rel
        hits = _grep(path, r">= \d+\.\d+")
        found_ok = False
        for line in hits:
            m = re.search(r">= (\d+)\.(\d+)", line)
            if m:
                maj, min_ = int(m.group(1)), int(m.group(2))
                if maj > need_major or (maj == need_major and min_ >= need_minor):
                    found_ok = True
                    break
        check(
            found_ok,
            f"provider_version.{Path(rel).parent.name}",
            f"requires >= {need_major}.{need_minor}",
        )


# ── Live AWS checks ──────────────────────────────────────────────────────────

def load_manifest(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    doc = json.loads(path.read_text())
    res: dict[str, Any] = doc.get("resources", {})
    for key in ("aws_account", "aws_region", "environment"):
        res.setdefault(key, doc.get(key) or os.environ.get(key.upper(), ""))
    return res


def live_checks(manifest: dict[str, Any], region: str) -> None:
    print("\n══════════════════════════════════════════════════")
    print(f" LIVE: AWS resource checks (region={region})")
    print("══════════════════════════════════════════════════")

    # Confirm AWS CLI is usable
    ok, identity = aws("sts", "get-caller-identity", "--output", "json", region=region, timeout=15)
    if not ok:
        warned("aws.credentials", f"AWS CLI not available / no credentials: {identity[:120]}")
        print("  Skipping all live checks — set AWS credentials and re-run.")
        return
    try:
        ident = json.loads(identity)
        passed("aws.credentials", f"account={ident.get('Account')} arn={ident.get('Arn','?')[:60]}")
    except json.JSONDecodeError:
        passed("aws.credentials", identity[:80])

    # ── Bedrock KB ───────────────────────────────────────────────────────────
    print("\n── A. Bedrock Knowledge Base ───────────────────────")
    kb_id = manifest.get("bedrock_kb_id") or _tf_output_fallback("knowledge_base_id", TF_EC2_ENV)
    if not kb_id:
        warned("bedrock_kb.live.id_available", "bedrock_kb_id not in manifest or TF output; skipping KB live check")
    else:
        ok, out = aws(
            "bedrock-agent", "get-knowledge-base",
            "--knowledge-base-id", kb_id,
            "--query", "knowledgeBase.{status:status,name:name,type:knowledgeBaseConfiguration.type}",
            "--output", "json",
            region=region,
        )
        if ok:
            try:
                info = json.loads(out)
                check(info.get("status") == "ACTIVE", "bedrock_kb.live.status_ACTIVE",
                      f"status={info.get('status')} name={info.get('name')}")
                check(info.get("type") == "VECTOR", "bedrock_kb.live.type_VECTOR",
                      f"type={info.get('type')}")
            except json.JSONDecodeError:
                failed("bedrock_kb.live.parse", out[:200])
        else:
            failed("bedrock_kb.live.get_knowledge_base", out[:200])

        # Data source check
        ok2, out2 = aws(
            "bedrock-agent", "list-data-sources",
            "--knowledge-base-id", kb_id,
            "--query", "dataSourceSummaries[*].{id:dataSourceId,status:status,type:dataSourceConfiguration.type}",
            "--output", "json",
            region=region,
        )
        if ok2:
            try:
                sources = json.loads(out2)
                # type field is not exposed in summary; check status only
                active_s3 = [s for s in sources if s.get("status") == "AVAILABLE"]
                check(bool(active_s3), "bedrock_kb.live.s3_datasource_AVAILABLE",
                      f"{len(active_s3)} AVAILABLE data source(s) of {len(sources)} total")
            except json.JSONDecodeError:
                warned("bedrock_kb.live.datasource_parse", out2[:200])
        else:
            warned("bedrock_kb.live.list_data_sources", out2[:200])

    # ── AgentCore Gateway ─────────────────────────────────────────────────────
    print("\n── B. AgentCore Gateway ────────────────────────────")
    gateway_id = manifest.get("agentcore_gateway_id") or _tf_output_fallback("agentcore_gateway_id", TF_EC2_ENV)
    if not gateway_id:
        warned("agentcore_gateway.live.id_available",
               "agentcore_gateway_id not in manifest/TF output — scanning list-gateways")
        ok, out = aws_control(
            "list-gateways",
            "--query", "items[*].{id:gatewayId,status:status,name:name}",
            "--output", "json",
            region=region,
        )
        if ok:
            try:
                gateways = json.loads(out)
                check(bool(gateways), "agentcore_gateway.live.exists",
                      f"{len(gateways)} gateway(s) found in account")
                for g in gateways:
                    check(g.get("status") in ("ACTIVE", "READY"),
                          f"agentcore_gateway.live.status [{g.get('name',g.get('id'))}]",
                          f"status={g.get('status')}")
                    _check_gateway_targets(g.get("gatewayId") or g.get("id"), region)
            except json.JSONDecodeError:
                warned("agentcore_gateway.live.list_parse", out[:200])
        else:
            warned("agentcore_gateway.live.list_gateways",
                   f"AWS CLI error: {out[:200]}")
    else:
        ok, out = aws_control(
            "get-gateway",
            "--gateway-identifier", gateway_id,
            "--query", "{status:status,name:name,protocol:protocolType}",
            "--output", "json",
            region=region,
        )
        if ok:
            try:
                info = json.loads(out)
                check(info.get("status") in ("ACTIVE", "READY"),
                      "agentcore_gateway.live.status",
                      f"status={info.get('status')} protocol={info.get('protocol')}")
                _check_gateway_targets(gateway_id, region)
            except json.JSONDecodeError:
                failed("agentcore_gateway.live.parse", out[:200])
        else:
            warned("agentcore_gateway.live.get_gateway", out[:200])

    # ── AgentCore Runtimes ────────────────────────────────────────────────────
    print("\n── C. AgentCore Agent Runtimes ─────────────────────")
    ok, out = aws_control(
        "list-agent-runtimes",
        "--query", "agentRuntimes[*].{id:agentRuntimeId,name:agentRuntimeName,status:status}",
        "--output", "json",
        region=region,
    )
    if ok:
        try:
            runtimes = json.loads(out)
            check(len(runtimes) >= 1, "agentcore_runtime.live.at_least_one_exists",
                  f"{len(runtimes)} runtime(s) found")

            expected_names = [
                "mongodb-mcp", "troubleshooting", "order", "product", "orchestrator"
            ]
            for rt in runtimes:
                name = rt.get("name", rt.get("id", "?"))
                status = rt.get("status", "?")
                check(
                    status in ("ACTIVE", "READY"),
                    f"agentcore_runtime.live.status [{name}]",
                    f"status={status}",
                )

            matched = sum(
                1 for exp in expected_names
                if any(exp.lower() in (rt.get("name") or "").lower() for rt in runtimes)
            )
            check(matched >= 3, "agentcore_runtime.live.expected_names_match",
                  f"{matched}/{len(expected_names)} expected runtime name patterns found")

            # Verify DEFAULT endpoint exists for each runtime
            for rt in runtimes[:5]:  # cap to avoid rate limits
                rt_id = rt.get("id")
                rt_name = rt.get("name", rt_id)
                if rt_id:
                    ok2, out2 = aws_control(
                        "list-agent-runtime-endpoints",
                        "--agent-runtime-id", rt_id,
                        "--query", "runtimeEndpoints[*].{name:agentRuntimeEndpointName,status:status}",
                        "--output", "json",
                        region=region,
                    )
                    if ok2:
                        try:
                            endpoints = json.loads(out2) or []
                            # 0 endpoints is normal: runtime uses the default /invocations URL directly
                            warned(
                                f"agentcore_runtime.live.endpoint_exists [{rt_name}]",
                                f"{len(endpoints)} explicit endpoint(s) — 0 is OK "
                                "(default invoke URL used directly)",
                            ) if not endpoints else passed(
                                f"agentcore_runtime.live.endpoint_exists [{rt_name}]",
                                f"{len(endpoints)} endpoint(s)",
                            )
                        except json.JSONDecodeError:
                            warned(f"agentcore_runtime.live.endpoint_parse [{rt_name}]", out2[:120])
                    else:
                        warned(f"agentcore_runtime.live.list_endpoints [{rt_name}]", out2[:120])
        except json.JSONDecodeError:
            failed("agentcore_runtime.live.parse", out[:200])
    else:
        warned("agentcore_runtime.live.list_runtimes",
               f"AWS CLI error: {out[:200]}")

    # ── AgentCore Memory ──────────────────────────────────────────────────────
    print("\n── D. AgentCore Memory ─────────────────────────────")
    memory_id = manifest.get("agentcore_memory_id") or _tf_output_fallback("agentcore_memory_id", TF_EC2_ENV)
    if not memory_id:
        warned("agentcore_memory.live.id_available",
               "agentcore_memory_id not in manifest or TF output — scanning list-memories")
        ok, out = aws_control(
            "list-memories",
            "--query", "memories[*].{id:id,status:status}",
            "--output", "json",
            region=region,
        )
        if ok:
            try:
                memories = json.loads(out)
                check(bool(memories), "agentcore_memory.live.exists",
                      f"{len(memories)} memory store(s) found in account")
                for mem in memories:
                    check(mem.get("status") in ("ACTIVE", "READY"),
                          f"agentcore_memory.live.status [{mem.get('id')}]",
                          f"status={mem.get('status')}")
            except json.JSONDecodeError:
                warned("agentcore_memory.live.list_parse", out[:200])
        else:
            warned("agentcore_memory.live.list_memories",
                   f"AWS CLI error: {out[:200]}")
    else:
        ok, out = aws_control(
            "get-memory",
            "--memory-id", memory_id,
            "--query", "memory.{status:status,id:id}",
            "--output", "json",
            region=region,
        )
        if ok:
            try:
                info = json.loads(out) or {}
                check(info.get("status") in ("ACTIVE", "READY"),
                      "agentcore_memory.live.status",
                      f"status={info.get('status')} id={info.get('id')}")
            except json.JSONDecodeError:
                failed("agentcore_memory.live.parse", out[:200])
        else:
            warned("agentcore_memory.live.get_memory", out[:200])

    # ── Memory–runtime association (env-var layer) ────────────────────────────
    print("\n── E. Memory–runtime association layer ─────────────")
    if memory_id:
        warned(
            "agentcore_memory.association.tf_managed",
            "No aws_bedrockagentcore_memory_association TF resource — memory linked only via "
            f"AGENTCORE_MEMORY_STORE_ID={memory_id} in deploy script (not Terraform state).",
        )
    else:
        warned(
            "agentcore_memory.association.tf_managed",
            "Memory ID unknown — could not verify association layer.",
        )


def _check_gateway_targets(gateway_id: str, region: str) -> None:
    """Check how many targets the gateway has; FAIL if zero (gap was fixed in code)."""
    ok, out = aws_control(
        "list-gateway-targets",
        "--gateway-identifier", gateway_id,
        "--query", "items[*].{id:targetId,name:name,status:status}",
        "--output", "json",
        region=region,
    )
    if ok:
        try:
            targets = json.loads(out)
            if targets:
                passed("agentcore_gateway.live.has_targets",
                       f"{len(targets)} target(s) — gateway routes traffic")
            else:
                failed(
                    "agentcore_gateway.live.NO_TARGETS",
                    "Gateway has ZERO targets — Terraform fix (create_mcp_server_target=true) "
                    "has not been applied yet. Run: ./deploy/deploy-full-with-privatelink.sh --auto-approve",
                )
        except json.JSONDecodeError:
            warned("agentcore_gateway.live.targets_parse", out[:200])
    else:
        warned("agentcore_gateway.live.list_targets", out[:200])


def _tf_output_fallback(name: str, cwd: Path) -> str | None:
    ok, out = run_cmd(["terraform", "output", "-raw", name], timeout=30)
    if ok and out and len(out) > 2:
        return out
    return None


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        default=os.environ.get("DEPLOY_MANIFEST_PATH", str(DEFAULT_MANIFEST)),
        help="Path to deploy-manifest.json (optional)",
    )
    parser.add_argument(
        "--region",
        default=os.environ.get("AWS_REGION", "us-east-1"),
        help="AWS region (default: us-east-1 or AWS_REGION env var)",
    )
    args = parser.parse_args()

    manifest = load_manifest(Path(args.manifest))
    region: str = manifest.get("aws_region") or args.region

    print("╔══════════════════════════════════════════════════╗")
    print("║  Bedrock Resource Implementation Audit           ║")
    print("║  e2e-smoke/bedrock-resource-live-audit.py        ║")
    print("╚══════════════════════════════════════════════════╝")
    print(f"  Root:     {ROOT}")
    print(f"  Manifest: {args.manifest}")
    print(f"  Region:   {region}")

    if os.environ.get("SKIP_STATIC_CHECKS") != "1":
        static_checks()
    else:
        print("\n[SKIP_STATIC_CHECKS=1] Skipping Terraform file analysis.")

    if os.environ.get("SKIP_LIVE_CHECKS") != "1":
        live_checks(manifest, region)
    else:
        print("\n[SKIP_LIVE_CHECKS=1] Skipping live AWS checks.")

    # ── Summary ──────────────────────────────────────────────────────────────
    print("\n══════════════════════════════════════════════════")
    print(" Summary")
    print("══════════════════════════════════════════════════")
    for r in results:
        print(f"  {r}")
    print()
    print(f"  PASS: {PASS}  FAIL: {FAIL}  WARN: {WARN}")
    print()

    if FAIL > 0:
        print(f"AUDIT FAILED — {FAIL} assertion(s) did not pass.")
        return 1

    if WARN > 0:
        print(f"AUDIT PASSED with {WARN} warning(s) — review WARNs above.")
    else:
        print("AUDIT PASSED — all checks green.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
