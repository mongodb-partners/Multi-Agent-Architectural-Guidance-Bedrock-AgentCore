#!/usr/bin/env python3
"""Force every deployed project alarm into a target state and verify it.

This uses CloudWatch `SetAlarmState`, so it validates alarm wiring without
generating costly or noisy production failures. Terraform currently disables
alarm actions, but verify that before using this in an account with actions.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from common import DrillFailure, boto_client, list_project_alarms, load_manifest, log, require, wait


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=None)
    parser.add_argument("--state", choices=("ALARM", "OK", "INSUFFICIENT_DATA"), default="ALARM")
    parser.add_argument(
        "--reason",
        default="Manual failure-drill test: verifying CloudWatch alarm state transitions.",
    )
    args = parser.parse_args()

    resources = load_manifest(args.manifest)
    cw = boto_client(resources, "cloudwatch")
    alarms = list_project_alarms(resources)
    require(bool(alarms), "no project CloudWatch alarms found")

    log("ALARMS_FOUND " + json.dumps(alarms))
    for name in alarms:
        cw.set_alarm_state(AlarmName=name, StateValue=args.state, StateReason=args.reason)
    log(f"SET_ALARM_REQUESTS_SENT {len(alarms)}")

    wait(8)
    states: dict[str, str] = {}
    for page in cw.get_paginator("describe_alarms").paginate(AlarmNames=alarms):
        for alarm in page.get("MetricAlarms", []):
            states[str(alarm["AlarmName"])] = str(alarm["StateValue"])

    log("ALARM_STATES_AFTER_SET")
    failed = []
    for name in alarms:
        state = states.get(name)
        log(json.dumps({"alarm": name, "state": state}))
        if state != args.state:
            failed.append(name)

    require(not failed, f"alarms did not enter {args.state}: {failed}")
    log(f"PASS force_alarm_states state={args.state}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except DrillFailure as exc:
        log(f"FAIL force_alarm_states: {exc}")
        raise SystemExit(1)
