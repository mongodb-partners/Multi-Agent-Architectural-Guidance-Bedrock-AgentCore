# =============================================================================
# CloudWatch Atlas Dashboard + 2 alarms (Phase 4).
#
# Consumes metrics in the MongoDB/Atlas namespace, which the ADOT collector
# publishes via the awsemf exporter (modules/adot-collector/templates/...).
# Without the Phase 4 prom-scrape setup, the dashboard widgets render empty.
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
    Component   = "cloudwatch-atlas-dashboard"
  })

  dashboard_name = "${var.shared_resource_prefix}-atlas-${var.environment}"
}

resource "aws_cloudwatch_dashboard" "atlas" {
  dashboard_name = local.dashboard_name
  dashboard_body = templatefile("${path.module}/templates/atlas-dashboard.json.tpl", {
    project_name = var.project_name
    environment  = var.environment
    aws_region   = var.aws_region
  })
}

# -----------------------------------------------------------------------------
# Connection saturation — Atlas exposes `mongodbatlas_connections_current` and
# `mongodbatlas_connections_available`; we alarm when (current / total) > 80%.
# Math expression keeps the alarm self-contained (no need to remember to
# update a hardcoded ceiling when the cluster tier changes).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "connection_saturation" {
  alarm_name          = "${var.shared_resource_prefix}-${var.environment}-atlas-connection-saturation"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_description   = "Atlas connection saturation > 80% for 2 consecutive 5-minute windows."

  metric_query {
    id          = "sat"
    expression  = "100 * current / IF(total > 0, total, 1)"
    label       = "Connection saturation %"
    return_data = true
  }
  metric_query {
    id = "current"
    metric {
      namespace   = "MongoDB/Atlas"
      metric_name = "mongodbatlas_connections_current"
      period      = 300
      stat        = "Average"
    }
  }
  metric_query {
    id = "total"
    metric {
      namespace   = "MongoDB/Atlas"
      metric_name = "mongodbatlas_connections_available"
      period      = 300
      stat        = "Average"
    }
  }

  alarm_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  ok_actions    = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  tags          = local.common_tags
}

# -----------------------------------------------------------------------------
# Replication lag — Atlas exposes `mongodbatlas_replset_oplog_master_lag_ms`
# per secondary. Alarm if the worst secondary exceeds the configured threshold.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "replication_lag" {
  alarm_name          = "${var.shared_resource_prefix}-${var.environment}-atlas-replication-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = var.replication_lag_threshold_ms
  treat_missing_data  = "notBreaching"
  alarm_description   = "Atlas secondary replication lag > ${var.replication_lag_threshold_ms}ms for 2 of 3 5-minute windows."

  metric_query {
    id          = "lag"
    return_data = true
    metric {
      namespace   = "MongoDB/Atlas"
      metric_name = "mongodbatlas_replset_oplog_master_lag_ms"
      period      = 300
      stat        = "Maximum"
    }
  }

  alarm_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  ok_actions    = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  tags          = local.common_tags
}
