#!/bin/bash
# user_data.sh — POC EC2 bootstrap (Docker mode)
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

echo "=== Multi-Agent POC bootstrap started $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ── App directory created FIRST so deploy.sh SSM .env.live copy never races ──
mkdir -p /opt/multiagent
touch /opt/multiagent/.env.live

# ── App log files pre-created so systemd `append:` works on first boot ────────
touch /var/log/multiagent-api.log /var/log/multiagent-ui.log
chmod 0644 /var/log/multiagent-api.log /var/log/multiagent-ui.log

# ── System deps ───────────────────────────────────────────────────────────────
dnf update -y
dnf install -y docker git amazon-ssm-agent

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

# ── Systemd: API (Docker container on :3000) ──────────────────────────────────
cat > /etc/systemd/system/multiagent-api.service << EOF
[Unit]
Description=Multi-Agent API (Docker --network=host, :3000)
After=docker.service network-online.target
Wants=network-online.target
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
cat > /etc/systemd/system/multiagent-ui.service << EOF
[Unit]
Description=Multi-Agent UI (Docker :8501)
After=docker.service network-online.target multiagent-api.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
ExecStartPre=-/usr/bin/docker stop multiagent-ui
ExecStartPre=-/usr/bin/docker rm multiagent-ui
ExecStart=/usr/bin/docker run --rm \
  --name multiagent-ui \
  -p 8501:8501 \
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
