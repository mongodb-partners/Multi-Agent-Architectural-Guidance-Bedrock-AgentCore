# Failure Drills

Live failure-mode drills for an already deployed EC2 stack. Run from the repo root after `./deploy/scripts/deploy-project.sh --auto-approve` has produced `deploy-manifest.json`.

```bash
source .env
python3 e2e-smoke/failure-drills/auth_edge_cases.py
python3 e2e-smoke/failure-drills/force_alarm_states.py
python3 e2e-smoke/failure-drills/mongo_outage.py
python3 e2e-smoke/failure-drills/agentcore_failure.py
python3 e2e-smoke/failure-drills/api_rollback.py
```

## Categories

- `auth_edge_cases.py` checks missing, malformed, fake, empty, and valid Cognito bearer tokens, plus cross-user session isolation.
- `force_alarm_states.py` forces every deployed project CloudWatch metric alarm into a requested state (`ALARM` by default) and verifies the transition.
- `bedrock_throttling_alarm.py` validates the Bedrock throttling alarm path without intentionally exhausting Bedrock quotas. It resets that alarm to `OK` by default.
- `mongo_outage.py` temporarily breaks `MONGODB_URI` on the EC2 API, verifies `/health` degrades, restores `.env.live`, restarts the API, and verifies recovery.
- `agentcore_failure.py` temporarily points one specialist AgentCore runtime ARN at a non-existent runtime, verifies chat returns `AGENTCORE_RUNTIME_ERROR`, restores `.env.live`, restarts the API, and verifies recovery.
- `api_rollback.py` retags ECR `latest` to the previous API image, restarts the API, verifies `/health`, then retags `latest` back to the original current image and verifies recovery.

## Convenience Runner

```bash
source .env
python3 e2e-smoke/failure-drills/run_all.py
```

For a non-disruptive subset:

```bash
python3 e2e-smoke/failure-drills/run_all.py --skip-disruptive
```

`run_all.py` resets all project alarms to `OK` after the suite. The outage and rollback drills also include their own `finally` restore paths.

## Notes

- These scripts use `deploy-manifest.json` by default. Override with `--manifest path/to/deploy-manifest.json` or `DEPLOY_MANIFEST_PATH`.
- They require AWS credentials with Cognito, SSM, CloudWatch, and ECR permissions matching the deployed stack.
- `bedrock_throttling_alarm.py` deliberately does not create real Bedrock throttling because quota exhaustion is noisy and can affect other users.
