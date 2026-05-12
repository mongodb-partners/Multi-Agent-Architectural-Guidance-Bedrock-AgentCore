#!/bin/bash
# user_data.sh — POC EC2 bootstrap (Docker mode)
# Runs ONCE on first boot. Installs Docker, creates systemd services, enables them.
#
# Topology:
#   - multiagent-api : Docker container, host network, listens :3000
#   - multiagent-ui  : Docker container, bridge network, publishes :8501
#   - MongoDB MCP    : Lambda function invoked by AgentCore Gateway (not on EC2)
#
# NOTE: Images are NOT pulled here. deploy.sh Phase 6 pushes images AFTER Terraform
# apply completes, so they don't exist yet when this script runs. Phase 8 pulls them
# via SSM and starts the services. This script only installs Docker and registers
# the systemd units (enabled but not started).
#
# To update the app: re-run deploy.sh — it pushes new images and restarts services.

set -euo pipefail
exec > /var/log/multiagent-setup.log 2>&1

echo "=== Multi-Agent POC bootstrap started $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ── App directory created FIRST so deploy.sh SSM .env.live copy never races ──
mkdir -p /opt/multiagent
touch /opt/multiagent/.env.live

# ── System deps ───────────────────────────────────────────────────────────────
dnf update -y
dnf install -y docker git amazon-ssm-agent

# Ensure SSM agent is up early so deploy.sh can use send-command reliably.
systemctl enable --now amazon-ssm-agent

# ── Docker ────────────────────────────────────────────────────────────────────
systemctl enable --now docker
echo "Docker: $(docker --version)"

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
StandardOutput=journal
StandardError=journal
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
StandardOutput=journal
StandardError=journal
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
echo "After deploy: journalctl -u multiagent-api -f"
