#!/usr/bin/env python3
"""Non-destructive Bedrock throttling alarm drill.

This intentionally does not try to exhaust Bedrock quotas. It forces only the
Bedrock throttling alarm into ALARM, verifies the state, then optionally resets
it to OK. Use force_alarm_states.py when you want every project alarm.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from common import DrillFailure, boto_client, list_project_alarms, load_manifest, log, require, wait


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=None)
    parser.add_argument("--leave-alarm", action="store_true", help="Do not reset the alarm to OK after verifying.")
    args = parser.parse_args()

    resources = load_manifest(args.manifest)
    cw = boto_client(resources, "cloudwatch")
    matches = [name for name in list_project_alarms(resources) if name.endswith("-bedrock-throttles")]
    require(len(matches) == 1, f"expected exactly one bedrock throttles alarm, found {matches}")
    alarm_name = matches[0]

    cw.set_alarm_state(
        AlarmName=alarm_name,
        StateValue="ALARM",
        StateReason="Manual Bedrock throttling alarm drill; no real quota exhaustion performed.",
    )
    wait(8)
    state = cw.describe_alarms(AlarmNames=[alarm_name])["MetricAlarms"][0]["StateValue"]
    log(json.dumps({"alarm": alarm_name, "state": state}))
    require(state == "ALARM", f"{alarm_name} did not enter ALARM")

    if not args.leave_alarm:
        cw.set_alarm_state(
            AlarmName=alarm_name,
            StateValue="OK",
            StateReason="Manual Bedrock throttling alarm drill complete; resetting state.",
        )
        wait(8)
        reset_state = cw.describe_alarms(AlarmNames=[alarm_name])["MetricAlarms"][0]["StateValue"]
        log(json.dumps({"alarm": alarm_name, "resetState": reset_state}))
        require(reset_state == "OK", f"{alarm_name} did not reset to OK")

    log("PASS bedrock_throttling_alarm")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except DrillFailure as exc:
        log(f"FAIL bedrock_throttling_alarm: {exc}")
        raise SystemExit(1)
