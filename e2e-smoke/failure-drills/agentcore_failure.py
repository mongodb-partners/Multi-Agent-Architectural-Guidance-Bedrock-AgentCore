#!/usr/bin/env python3
"""AgentCore runtime failure drill.

Temporarily points one specialist runtime ARN at a non-existent AgentCore
runtime, verifies chat returns AGENTCORE_RUNTIME_ERROR, then restores the
original .env.live and verifies chat works again.
"""

from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

from common import DrillFailure, chat_order_status, cognito_token, load_manifest, log, require, ssm_run


def env_key_for_agent(agent_id: str) -> str:
    safe = "".join(ch if ch.isalnum() else "_" for ch in agent_id.upper())
    return f"AGENTCORE_{safe}_ARN"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=None)
    parser.add_argument("--agent-id", default="order-management")
    args = parser.parse_args()

    resources = load_manifest(args.manifest)
    account = resources.get("aws_account") or "000000000000"
    region = resources.get("aws_region") or "us-east-1"
    key = env_key_for_agent(args.agent_id)
    invalid_arn = f"arn:aws:bedrock-agentcore:{region}:{account}:runtime/does_not_exist_failure_drill"
    backup = "/opt/multiagent/.env.live.failuredrill.agentcore.bak"

    break_commands = [
        "set -euo pipefail",
        f"cp /opt/multiagent/.env.live {backup}",
        f"""python3 - <<'EPY'
from pathlib import Path
p = Path('/opt/multiagent/.env.live')
out = []
for line in p.read_text().splitlines():
    if line.startswith('{key}='):
        out.append('{key}={invalid_arn}')
    else:
        out.append(line)
p.write_text('\\n'.join(out) + '\\n')
EPY""",
        "systemctl restart multiagent-api",
        "sleep 10",
    ]
    restore_commands = [
        "set -euo pipefail",
        f"cp {backup} /opt/multiagent/.env.live",
        "chmod 600 /opt/multiagent/.env.live",
        "systemctl restart multiagent-api",
        "sleep 10",
    ]

    token = cognito_token(resources)
    failure_observed = False
    try:
        ssm_run(resources, f"failure drill: break {key}", break_commands, timeout=120)
        status, text = chat_order_status(resources, token, "agentcore-failure-" + uuid.uuid4().hex[:8])
        failure_observed = (
            status >= 400
            or "event: error" in text
            or "AGENTCORE_RUNTIME_ERROR" in text
            or "No endpoint or agent found" in text
        )
        log("BROKEN_CHAT " + json.dumps({"status": status, "failureObserved": failure_observed, "tail": text[-700:]}))
    finally:
        ssm_run(resources, f"failure drill: restore {key}", restore_commands, timeout=120)

    status, text = chat_order_status(resources, token, "agentcore-restored-" + uuid.uuid4().hex[:8])
    restored = status == 200 and "event: done" in text and "AGENTCORE_RUNTIME_ERROR" not in text
    log("RESTORED_CHAT " + json.dumps({"status": status, "restored": restored, "tail": text[-300:]}))

    require(failure_observed, "AgentCore failure was not observed")
    require(restored, "AgentCore restore was not verified")
    log("PASS agentcore_failure")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except DrillFailure as exc:
        log(f"FAIL agentcore_failure: {exc}")
        raise SystemExit(1)
