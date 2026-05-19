#!/usr/bin/env python3
"""Run the failure-drill suite in a safe order.

By default this leaves the stack restored: alarms are reset to OK at the end,
Mongo/AgentCore env files are restored by their own scripts, and API latest is
restored by the rollback drill.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent


DEFAULT_DRILLS = [
    "auth_edge_cases.py",
    "bedrock_throttling_alarm.py",
    "force_alarm_states.py",
    "mongo_outage.py",
    "agentcore_failure.py",
    "api_rollback.py",
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default="")
    parser.add_argument(
        "--skip-disruptive",
        action="store_true",
        help="Run only auth + alarm-state drills; skip Mongo/AgentCore/rollback service restarts.",
    )
    args = parser.parse_args()

    drills = DEFAULT_DRILLS
    if args.skip_disruptive:
        drills = ["auth_edge_cases.py", "bedrock_throttling_alarm.py", "force_alarm_states.py"]

    try:
        for drill in drills:
            cmd = [sys.executable, str(HERE / drill)]
            if args.manifest:
                cmd.extend(["--manifest", args.manifest])
            print(f"\n== Running {drill} ==", flush=True)
            subprocess.check_call(cmd)
    finally:
        print("\n== Resetting all project alarms to OK ==", flush=True)
        cmd = [
            sys.executable,
            str(HERE / "force_alarm_states.py"),
            "--state",
            "OK",
            "--reason",
            "Failure-drill suite complete; resetting alarm state.",
        ]
        if args.manifest:
            cmd.extend(["--manifest", args.manifest])
        subprocess.call(cmd)
    print("\nALL_FAILURE_DRILLS_PASSED", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
