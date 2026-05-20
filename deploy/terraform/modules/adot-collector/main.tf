# =============================================================================
# ADOT Collector sidecar — runs on the EC2 host as a Docker container, listens
# on 127.0.0.1:4318 for OTLP/HTTP from the Bun API + Streamlit UI, and signs
# SigV4 outbound to:
#   - X-Ray OTLP endpoint  (https://xray.<region>.amazonaws.com/v1/traces)
#   - CloudWatch Logs OTLP endpoint  (https://logs.<region>.amazonaws.com/v1/logs)
#
# Architectural intent: SigV4 is handled exactly once, in the sidecar, so no
# application code (Bun, Strands, Streamlit) needs AWS credentials for OTLP.
# Apps speak plain OTLP to localhost.
#
# Phase 4 extends the same collector with a Prometheus receiver that scrapes
# MongoDB Atlas and an awsemf exporter pushing to the MongoDB/Atlas CloudWatch
# namespace — see var.enable_atlas_metrics.
#
# Module responsibilities:
#   - Upload the collector config YAML to the shared S3 bucket (rendered from
#     the template under templates/, so var substitution is centralized).
#   - Output the S3 URI + a stable config etag so user_data.sh can fetch it
#     on first boot and refresh on `terraform apply` when the config changes.
#   - The systemd unit + Docker run incantation live in modules/ec2/user_data.sh
#     (added as part of this same Phase 2 change) — keeping them there avoids
#     two-place templating for one bootstrap script.
# =============================================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.27, < 7.0" }
  }
}

locals {
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "adot-collector"
  })

  config_yaml = templatefile("${path.module}/templates/adot-config.yaml.tpl", {
    project_name              = var.project_name
    environment               = var.environment
    aws_region                = var.aws_region
    otel_log_group_name       = var.otel_log_group_name
    enable_atlas_metrics      = var.enable_atlas_metrics
    atlas_scrape_interval_sec = var.atlas_scrape_interval_sec
    atlas_secret_arn          = var.atlas_secret_arn
  })

  config_s3_key = "observability/adot-collector/${var.environment}/config.yaml"
}

# -----------------------------------------------------------------------------
# Config object in the shared bucket. EC2 user_data fetches this at boot AND
# on every re-deploy; user_data_replace_on_change in modules/ec2 picks up
# whenever the template inputs change.
# -----------------------------------------------------------------------------
resource "aws_s3_object" "config" {
  bucket  = var.shared_bucket_name
  key     = local.config_s3_key
  content = local.config_yaml

  content_type = "application/x-yaml"
  etag         = md5(local.config_yaml)

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Default OTLP destination log group (used by the awscloudwatchlogs exporter
# for OTLP-shipped application logs, distinct from the existing /api log
# group that receives file-tailed logs via the amazon-cloudwatch-agent).
#
# Why a separate group: the OTLP path can carry richer structured fields
# than file-tailed JSON (resource attributes, span context per line). Mixing
# them in /api would make Logs Insights queries ambiguous.
#
# This module does NOT create the log group itself — the shared stack
# (envs/shared) owns /multiagent/<env>/otel and its `-atlas` sibling so the
# group is stable across multiple per-project envs/ec2 stacks. We look up
# both ARNs here so a caller that wants to attach tight IAM (e.g. the EC2
# instance role) can wire them in.
# -----------------------------------------------------------------------------
data "aws_cloudwatch_log_group" "otel" {
  count = var.otel_log_group_name != "" ? 1 : 0
  name  = var.otel_log_group_name
}

data "aws_cloudwatch_log_group" "otel_atlas" {
  count = var.otel_log_group_name != "" ? 1 : 0
  name  = "${var.otel_log_group_name}-atlas"
}
