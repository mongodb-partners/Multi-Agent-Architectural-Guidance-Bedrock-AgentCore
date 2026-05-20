#!/bin/bash
# user_data.sh — Application EC2 bootstrap (Docker mode)
# Runs ONCE on first boot. Installs Docker, creates systemd services, enables them.
#
# Topology:
#   - multiagent-api : Docker container, host network, listens :3000
#   - multiagent-ui  : Docker container, bridge network, publishes :8501
#   - MongoDB MCP    : AgentCore Runtime (not on EC2)
#
# Logging path:
#   - Each systemd unit writes container stdout/stderr to /var/log/multiagent-{api,ui}.log
#     via systemd's `StandardOutput=append:` directive.
#   - amazon-cloudwatch-agent tails those files and ships them to the per-project
#     CloudWatch Logs groups (file-based collection — documented + stable across agent
#     versions, unlike journald collection which is undocumented in the official AWS
#     CW agent config reference as of 2026-05).
#
# To update the app: re-run deploy.sh — it pushes new images and restarts services.

set -euo pipefail
exec > /var/log/multiagent-setup.log 2>&1

echo "=== Multi-Agent application bootstrap started $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ── App directory created FIRST so deploy.sh SSM .env.live copy never races ──
mkdir -p /opt/multiagent
touch /opt/multiagent/.env.live

# ── App log files pre-created so systemd `append:` works on first boot ────────
touch /var/log/multiagent-api.log /var/log/multiagent-ui.log
chmod 0644 /var/log/multiagent-api.log /var/log/multiagent-ui.log

# ── System deps ───────────────────────────────────────────────────────────────
dnf update -y
# bind-utils gives us `dig` + `nslookup`. Required by modules/bedrock-kb-peering
# scripts/discover-atlas-private-ips.sh, which the peering deploy invokes via
# SSM send-command from the operator host to resolve Atlas mongod -pri.mongodb.net
# SRV records into private peering IPs (used to back-fill NLB target groups).
# The discover script fails with `dig: command not found` if bind-utils is missing,
# which silently bricks Bedrock KB ingestion in peering mode.
dnf install -y docker git amazon-ssm-agent bind-utils

# Ensure SSM agent is up early so deploy.sh can use send-command reliably.
systemctl enable --now amazon-ssm-agent

# ── Docker ────────────────────────────────────────────────────────────────────
systemctl enable --now docker
echo "Docker: $(docker --version)"

# ── CloudWatch Agent: file-based log shipping for API + UI ───────────────────
# Use file collection (documented, stable) rather than journald (undocumented in
# the official AWS CW agent config reference as of 2026-05). systemd writes each
# unit's stdout/stderr to /var/log/multiagent-{api,ui}.log via StandardOutput=
# append:, and the agent tails those files.
CW_ARCH="amd64"
[[ "$(uname -m)" == "aarch64" ]] && CW_ARCH="arm64"
dnf install -y "https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/$${CW_ARCH}/latest/amazon-cloudwatch-agent.rpm"

mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWAGENTJSON
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root",
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/multiagent-api.log",
            "log_group_name": "${cw_log_group_api}",
            "log_stream_name": "{instance_id}",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S.%fZ",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/multiagent-ui.log",
            "log_group_name": "${cw_log_group_ui}",
            "log_stream_name": "{instance_id}",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S.%fZ",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
CWAGENTJSON

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json || true
systemctl enable amazon-cloudwatch-agent || true

# ── Logrotate so /var/log/multiagent-*.log never fills the disk ──────────────
cat > /etc/logrotate.d/multiagent << 'LR'
/var/log/multiagent-api.log
/var/log/multiagent-ui.log
/var/log/aws-otel-collector.log
{
  daily
  rotate 7
  size 100M
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
}
LR

# ── ADOT Collector sidecar (Phase 2) ─────────────────────────────────────────
# Signs SigV4 outbound to xray/logs/monitoring AWS OTLP endpoints so the API,
# Streamlit UI, and (Phase 4) Atlas Prometheus scrape do not need their own
# AWS credentials for telemetry. Apps speak plain OTLP to 127.0.0.1:4318.
#
# Config is fetched fresh from S3 on every boot (and on every Terraform apply
# via user_data_replace_on_change in modules/ec2/main.tf). adot_config_etag is
# included in user_data so changes in the rendered YAML force a re-create.
#
# When adot_config_s3_bucket is empty (legacy/Phase 1 deploys) the sidecar
# unit is intentionally NOT created — the API + UI fall back to in-process
# OTel only and the existing file-based log shipping is unchanged.
ADOT_CONFIG_BUCKET="${adot_config_s3_bucket}"
ADOT_CONFIG_KEY="${adot_config_s3_key}"
ADOT_CONFIG_ETAG="${adot_config_etag}"
ADOT_COLLECTOR_IMAGE="${adot_collector_image}"

if [ -n "$ADOT_CONFIG_BUCKET" ] && [ -n "$ADOT_CONFIG_KEY" ]; then
  echo "=== Installing ADOT Collector sidecar (etag=$ADOT_CONFIG_ETAG) ==="
  mkdir -p /etc/aws-otel-collector
  touch /var/log/aws-otel-collector.log
  chmod 0644 /var/log/aws-otel-collector.log

  # awscli v2 is installed by SSM agent dependencies on AL2023; fall back to
  # dnf install just in case for older AMIs.
  if ! command -v aws >/dev/null 2>&1; then
    dnf install -y awscli
  fi

  # Initial config fetch — non-fatal so first boot does not block when SSM
  # has not yet uploaded credentials; the systemd unit will retry on each
  # restart via ExecStartPre.
  aws s3 cp "s3://$ADOT_CONFIG_BUCKET/$ADOT_CONFIG_KEY" \
    /etc/aws-otel-collector/config.yaml --region "${aws_region}" || \
    echo "WARN: initial ADOT config fetch failed; sidecar will retry"

  # Account id needed by the collector's resource processor (cloud.account.id).
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "${aws_region}" 2>/dev/null || echo "unknown")
  echo "AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID" > /etc/aws-otel-collector/env

  # Phase 4: when an Atlas Prometheus secret is wired, populate ATLAS_PROM_*
  # env vars from Secrets Manager. The collector reads $${env:...} substitutions
  # at startup, so we materialize the values once here.
  ATLAS_PROM_SECRET_ARN="${atlas_prom_secret_arn}"
  if [ -n "$ATLAS_PROM_SECRET_ARN" ]; then
    SECRET_JSON=$(aws secretsmanager get-secret-value \
      --secret-id "$ATLAS_PROM_SECRET_ARN" \
      --region "${aws_region}" \
      --query SecretString --output text 2>/dev/null || echo "")
    if [ -n "$SECRET_JSON" ]; then
      # Expect the secret to be JSON like {"username":"...","password":"...","host":"..."}.
      ATLAS_PROM_USER=$(echo "$SECRET_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("username",""))' || echo "")
      ATLAS_PROM_PASSWORD=$(echo "$SECRET_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("password",""))' || echo "")
      ATLAS_PROM_HOST=$(echo "$SECRET_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("host",""))' || echo "")
      {
        echo "ATLAS_PROM_USER=$ATLAS_PROM_USER"
        echo "ATLAS_PROM_PASSWORD=$ATLAS_PROM_PASSWORD"
        echo "ATLAS_PROM_HOST=$ATLAS_PROM_HOST"
      } >> /etc/aws-otel-collector/env
    fi
  fi

  cat > /etc/systemd/system/aws-otel-collector.service << EOF
[Unit]
Description=AWS Distro for OpenTelemetry Collector
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
EnvironmentFile=/etc/aws-otel-collector/env
ExecStartPre=-/usr/bin/aws s3 cp s3://$ADOT_CONFIG_BUCKET/$ADOT_CONFIG_KEY /etc/aws-otel-collector/config.yaml --region ${aws_region}
ExecStartPre=-/usr/bin/docker stop aws-otel-collector
ExecStartPre=-/usr/bin/docker rm aws-otel-collector
ExecStart=/usr/bin/docker run --rm \\
  --name aws-otel-collector \\
  --network=host \\
  --env-file /etc/aws-otel-collector/env \\
  -v /etc/aws-otel-collector/config.yaml:/etc/otel-config.yaml:ro \\
  $ADOT_COLLECTOR_IMAGE \\
  --config=/etc/otel-config.yaml
ExecStop=/usr/bin/docker stop aws-otel-collector
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/aws-otel-collector.log
StandardError=append:/var/log/aws-otel-collector.log
SyslogIdentifier=aws-otel-collector

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable aws-otel-collector
fi

# ── Systemd: API (Docker container on :3000) ──────────────────────────────────
# `After=aws-otel-collector.service` is harmless when the unit is absent (it
# becomes a no-op ordering dependency); when present, it guarantees the
# collector receiver is up before the API tries to emit OTLP.
cat > /etc/systemd/system/multiagent-api.service << EOF
[Unit]
Description=Multi-Agent API (Docker --network=host, :3000)
After=docker.service network-online.target aws-otel-collector.service
Wants=network-online.target aws-otel-collector.service
Requires=docker.service

[Service]
Type=simple
User=root
ExecStartPre=-/usr/bin/docker stop multiagent-api
ExecStartPre=-/usr/bin/docker rm multiagent-api
ExecStart=/usr/bin/docker run --rm \
  --name multiagent-api \
  --network=host \
  --env-file /opt/multiagent/.env.live \
  ${ecr_api_image}
ExecStop=/usr/bin/docker stop multiagent-api
Restart=on-failure
RestartSec=10
StandardOutput=append:/var/log/multiagent-api.log
StandardError=append:/var/log/multiagent-api.log
SyslogIdentifier=multiagent-api

[Install]
WantedBy=multi-user.target
EOF

# ── Systemd: UI (Docker container on :8501) ───────────────────────────────────
# --network=host so the UI can reach the ADOT sidecar on 127.0.0.1:4318.
# We deliberately do not override the Docker image entrypoint here — Phase 2
# bakes `opentelemetry-instrument streamlit run app.py` into ui/Dockerfile so
# the auto-instrumentation hook runs whether the container is launched on
# EC2 (via this systemd unit) or locally (via docker compose).
cat > /etc/systemd/system/multiagent-ui.service << EOF
[Unit]
Description=Multi-Agent UI (Docker :8501)
After=docker.service network-online.target multiagent-api.service aws-otel-collector.service
Wants=network-online.target aws-otel-collector.service
Requires=docker.service

[Service]
Type=simple
User=root
ExecStartPre=-/usr/bin/docker stop multiagent-ui
ExecStartPre=-/usr/bin/docker rm multiagent-ui
ExecStart=/usr/bin/docker run --rm \
  --name multiagent-ui \
  --network=host \
  --env-file /opt/multiagent/.env.live \
  ${ecr_ui_image}
ExecStop=/usr/bin/docker stop multiagent-ui
Restart=on-failure
RestartSec=10
StandardOutput=append:/var/log/multiagent-ui.log
StandardError=append:/var/log/multiagent-ui.log
SyslogIdentifier=multiagent-ui

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable multiagent-api multiagent-ui

# Explicit bootstrap marker used by deploy.sh readiness checks.
touch /opt/multiagent/.bootstrap-done

echo "=== Bootstrap complete $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "Services enabled (not started). deploy.sh Phase 8 will pull images and start them."
echo "After deploy: tail -f /var/log/multiagent-api.log (or use 'journalctl -u multiagent-api -f' for systemd-only output)"
