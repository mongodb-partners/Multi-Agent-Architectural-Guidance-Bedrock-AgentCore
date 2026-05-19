# =============================================================================
# ADOT Collector config (rendered by Terraform; do NOT edit on the EC2 box).
#
# Inputs (rendered by modules/adot-collector/main.tf):
#   project_name, environment, aws_region — for resource attributes
#   otel_log_group_name                   — destination CW Logs group for OTLP logs
#   enable_atlas_metrics                  — toggle MongoDB Atlas Prometheus scrape
#   atlas_scrape_interval_sec             — scrape cadence (60s default)
#   atlas_secret_arn                      — Secrets Manager ARN for Atlas creds
#
# Apps connect on:
#   - 127.0.0.1:4318  (OTLP HTTP, /v1/traces and /v1/logs)
#   - 127.0.0.1:13133 (health)
#
# Outbound (SigV4 signed by the awsxray/awscloudwatchlogs/awsemf exporters):
#   - https://xray.${aws_region}.amazonaws.com/v1/traces
#   - https://logs.${aws_region}.amazonaws.com/v1/logs
#   - https://monitoring.${aws_region}.amazonaws.com   (PutMetricData via awsemf)
# =============================================================================

extensions:
  health_check:
    endpoint: 127.0.0.1:13133

receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:4318
      grpc:
        endpoint: 127.0.0.1:4317
%{ if enable_atlas_metrics ~}
  prometheus:
    config:
      scrape_configs:
        - job_name: mongodb_atlas
          scrape_interval: ${atlas_scrape_interval_sec}s
          scrape_timeout: 30s
          metrics_path: /metrics/v2
          scheme: https
          basic_auth:
            username: $${env:ATLAS_PROM_USER}
            password: $${env:ATLAS_PROM_PASSWORD}
          static_configs:
            - targets:
                - $${env:ATLAS_PROM_HOST}
%{ endif ~}

processors:
  batch:
    timeout: 5s
    send_batch_size: 512
  resource:
    attributes:
      - key: cloud.account.id
        value: $${env:AWS_ACCOUNT_ID}
        action: upsert
      - key: cloud.region
        value: ${aws_region}
        action: upsert
      - key: deployment.environment
        value: ${environment}
        action: upsert

exporters:
  awsxray:
    region: ${aws_region}
  awscloudwatchlogs:
    region: ${aws_region}
    log_group_name: ${otel_log_group_name}
    log_stream_name: $${env:HOSTNAME}
%{ if enable_atlas_metrics ~}
  awsemf:
    region: ${aws_region}
    namespace: MongoDB/Atlas
    log_group_name: ${otel_log_group_name}-atlas
    dimension_rollup_option: NoDimensionRollup
%{ endif ~}

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [resource, batch]
      exporters: [awsxray]
    logs:
      receivers: [otlp]
      processors: [resource, batch]
      exporters: [awscloudwatchlogs]
%{ if enable_atlas_metrics ~}
    metrics:
      receivers: [prometheus]
      processors: [resource, batch]
      exporters: [awsemf]
%{ endif ~}
