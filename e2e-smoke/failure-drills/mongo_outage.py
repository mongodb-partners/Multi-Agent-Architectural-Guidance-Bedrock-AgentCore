#!/usr/bin/env python3
"""MongoDB outage drill.

Temporarily points the EC2 API at an unreachable MongoDB URI, verifies /health
degrades, then restores the original /opt/multiagent/.env.live and restarts the
API. The restore step runs in a finally block.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from common import DrillFailure, load_manifest, log, require, ssm_run


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=None)
    args = parser.parse_args()

    resources = load_manifest(args.manifest)
    backup = "/opt/multiagent/.env.live.failuredrill.mongo.bak"
    break_commands = [
        "set -euo pipefail",
        f"cp /opt/multiagent/.env.live {backup}",
        """python3 - <<'EPY'
from pathlib import Path
p = Path('/opt/multiagent/.env.live')
out = []
for line in p.read_text().splitlines():
    if line.startswith('MONGODB_URI='):
        out.append('MONGODB_URI=mongodb://127.0.0.1:1/?serverSelectionTimeoutMS=1000')
    else:
        out.append(line)
p.write_text('\\n'.join(out) + '\\n')
EPY""",
        "systemctl restart multiagent-api",
        "sleep 12",
        "echo BROKEN_HEALTH_BEGIN",
        "curl -sS -m 20 http://127.0.0.1:3000/health || true",
        "echo",
        "echo BROKEN_HEALTH_END",
    ]
    restore_commands = [
        "set -euo pipefail",
        f"cp {backup} /opt/multiagent/.env.live",
        "chmod 600 /opt/multiagent/.env.live",
        "systemctl restart multiagent-api",
        "sleep 12",
        "echo RESTORED_HEALTH_BEGIN",
        "curl -sS -m 20 http://127.0.0.1:3000/health || true",
        "echo",
        "echo RESTORED_HEALTH_END",
    ]

    broken = ""
    restored = ""
    try:
        result = ssm_run(resources, "failure drill: break MONGODB_URI", break_commands, timeout=150)
        text = str(result["stdout"])
        broken = text.split("BROKEN_HEALTH_BEGIN", 1)[-1].split("BROKEN_HEALTH_END", 1)[0]
    finally:
        result = ssm_run(resources, "failure drill: restore MONGODB_URI", restore_commands, timeout=150)
        text = str(result["stdout"])
        restored = text.split("RESTORED_HEALTH_BEGIN", 1)[-1].split("RESTORED_HEALTH_END", 1)[0]

    log("BROKEN_HEALTH " + broken.strip())
    log("RESTORED_HEALTH " + restored.strip())
    require('"mongodb":"connected"' not in broken, "Mongo outage was not observed")
    require('"status":"ok"' in restored and '"mongodb":"connected"' in restored, "Mongo restore was not verified")
    log("PASS mongo_outage")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except DrillFailure as exc:
        log(f"FAIL mongo_outage: {exc}")
        raise SystemExit(1)
