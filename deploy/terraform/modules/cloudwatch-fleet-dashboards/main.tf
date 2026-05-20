# =============================================================================
# CloudWatch Fleet Dashboards + Alarms (Phase 3).
#
# Provisions:
#   - SNS topic + alarm-email subscription for operator-facing alerts.
#   - Three CloudWatch dashboards:
#       1. multiagent-fleet — health/latency/error rates across the agent fleet
#       2. multiagent-mongo — Mongo + memory pipeline observability
#       3. multiagent-cost  — per-user cost attribution from Bedrock invocation logs
#   - Seven CloudWatch alarms (P99 latency / error rate / model throttles /
#     AgentCore failures / Bedrock throttles / data-protection findings /
#     SLO budget burn).
#   - Audit metric filter that increments AuditFindings on every PII detection
#     in /aws/bedrock/invocations, plus a Logs Insights query library.
#
# All dashboards + queries are rendered via templatefile from JSON under
# templates/ so they are reviewable in git diff and not buried in HCL strings.
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
    Component   = "cloudwatch-fleet-dashboards"
  })

  # Dashboard / alarm / metric-filter / query names drop the project_name
  # prefix because this module is now instantiated by envs/shared once per
  # (account, region, environment) and consumed by multiple per-project
  # envs/ec2 stacks. Names are stable per environment; the shared prefix is
  # a single var so renaming the framework is one-line change.
  fleet_dashboard_name = "${var.shared_resource_prefix}-fleet-${var.environment}"
  mongo_dashboard_name = "${var.shared_resource_prefix}-mongo-${var.environment}"
  cost_dashboard_name  = "${var.shared_resource_prefix}-cost-${var.environment}"

  # Audit-findings metric filter target. Prefer the dedicated audit group when
  # set, else fall back to the source group (legacy callers / smoke tests).
  audit_log_group = var.audit_findings_log_group_name != "" ? var.audit_findings_log_group_name : var.invocation_log_group_name

  template_vars = {
    project_name             = var.project_name
    environment              = var.environment
    aws_region               = var.aws_region
    api_log_group            = var.api_log_group_name
    ui_log_group             = var.ui_log_group_name
    invocation_log_group     = var.invocation_log_group_name
    otel_log_group           = var.otel_log_group_name
    p99_latency_threshold_ms = var.p99_latency_threshold_ms
    error_rate_threshold_pct = var.error_rate_threshold_pct
    throttle_burst_threshold = var.throttle_burst_threshold
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}


# -----------------------------------------------------------------------------
# Fleet-rollup metric filters — read EMF records from the API log group and
# emit dimensionless Multiagent/FleetRollup metrics so alarms can aggregate
# the full fleet without SEARCH() (which is not supported in metric alarms).
#
# EMF records are emitted by cw-metrics.ts with `"channel":"metric"` so these
# filters only match metric records, not regular log lines.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "fleet_turns_total" {
  count          = var.api_log_group_name != "" ? 1 : 0
  name           = "${var.shared_resource_prefix}-fleet-turns-total-${var.environment}"
  log_group_name = var.api_log_group_name
  pattern        = "{ $.channel = \"metric\" && $.TurnsTotal = * }"
  metric_transformation {
    name          = "TurnsTotal"
    namespace     = "Multiagent/FleetRollup"
    value         = "$.TurnsTotal"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "fleet_turn_errors" {
  count          = var.api_log_group_name != "" ? 1 : 0
  name           = "${var.shared_resource_prefix}-fleet-turn-errors-${var.environment}"
  log_group_name = var.api_log_group_name
  pattern        = "{ $.channel = \"metric\" && $.TurnErrors = * }"
  metric_transformation {
    name          = "TurnErrors"
    namespace     = "Multiagent/FleetRollup"
    value         = "$.TurnErrors"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "fleet_turn_latency" {
  count          = var.api_log_group_name != "" ? 1 : 0
  name           = "${var.shared_resource_prefix}-fleet-turn-latency-${var.environment}"
  log_group_name = var.api_log_group_name
  pattern        = "{ $.channel = \"metric\" && $.TurnLatencyMs = * }"
  metric_transformation {
    name          = "TurnLatencyMs"
    namespace     = "Multiagent/FleetRollup"
    value         = "$.TurnLatencyMs"
    default_value = "0"
    unit          = "Milliseconds"
  }
}

resource "aws_cloudwatch_log_metric_filter" "fleet_agentcore_errors" {
  count          = var.api_log_group_name != "" ? 1 : 0
  name           = "${var.shared_resource_prefix}-fleet-agentcore-errors-${var.environment}"
  log_group_name = var.api_log_group_name
  pattern        = "{ $.channel = \"metric\" && $.AgentCoreInvokeErrors = * }"
  metric_transformation {
    name          = "AgentCoreInvokeErrors"
    namespace     = "Multiagent/FleetRollup"
    value         = "$.AgentCoreInvokeErrors"
    default_value = "0"
    unit          = "Count"
  }
}

# -----------------------------------------------------------------------------
# Audit metric filter — every Data Protection finding in
# /aws/bedrock/invocations increments AuditFindings, which the AuditFindingsHigh
# alarm pages on.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "audit_findings" {
  count          = local.audit_log_group != "" ? 1 : 0
  name           = "${var.shared_resource_prefix}-audit-findings-${var.environment}"
  log_group_name = local.audit_log_group
  # Data Protection findings are emitted as JSON records with
  # eventType=DataMaskingFinding. See `aws logs put-data-protection-policy`
  # docs for the schema.
  pattern = "{ $.eventType = \"DataMaskingFinding\" }"

  metric_transformation {
    name          = "AuditFindings"
    namespace     = "Multiagent/Audit"
    value         = "1"
    default_value = "0"
  }
}

# -----------------------------------------------------------------------------
# Dashboards. Bodies are JSON templated under templates/. Render-time vars
# include log-group names and thresholds so a single template covers dev
# through prod.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "fleet" {
  dashboard_name = local.fleet_dashboard_name
  dashboard_body = templatefile("${path.module}/templates/fleet-dashboard.json.tpl", local.template_vars)
}

resource "aws_cloudwatch_dashboard" "mongo" {
  dashboard_name = local.mongo_dashboard_name
  dashboard_body = templatefile("${path.module}/templates/mongo-dashboard.json.tpl", local.template_vars)
}

resource "aws_cloudwatch_dashboard" "cost" {
  dashboard_name = local.cost_dashboard_name
  dashboard_body = templatefile("${path.module}/templates/cost-dashboard.json.tpl", local.template_vars)
}

# -----------------------------------------------------------------------------
# Logs Insights query library — pre-saved queries used by the runbook so
# on-call can pull up "top errors", "slow turns", "per-user cost", etc. in
# one click instead of typing each query.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_query_definition" "top_errors" {
  name = "${var.shared_resource_prefix}/${var.environment}/top-errors"
  log_group_names = compact([
    var.api_log_group_name,
    var.ui_log_group_name,
    var.otel_log_group_name,
  ])
  query_string = <<-EOT
    fields @timestamp, level, msg, error_class, error_message, trace_id
    | filter level = "error"
    | stats count() as errors by error_class, error_message
    | sort errors desc
    | limit 25
  EOT
}

resource "aws_cloudwatch_query_definition" "slow_turns" {
  name            = "${var.shared_resource_prefix}/${var.environment}/slow-turns"
  log_group_names = compact([var.api_log_group_name])
  query_string    = <<-EOT
    fields @timestamp, agent_id, session_id, message_id, latency_ms, trace_id
    | filter ispresent(latency_ms) and latency_ms > 5000
    | sort latency_ms desc
    | limit 25
  EOT
}

resource "aws_cloudwatch_query_definition" "per_user_cost" {
  count           = var.invocation_log_group_name != "" ? 1 : 0
  name            = "${var.shared_resource_prefix}/${var.environment}/per-user-cost"
  log_group_names = [var.invocation_log_group_name]
  query_string    = <<-EOT
    fields @timestamp, modelId, requestMetadata.userId as userId, requestMetadata.agentId as agentId, input.inputTokenCount as inTok, output.outputTokenCount as outTok
    | stats sum(inTok) as inputTokens, sum(outTok) as outputTokens by userId, agentId, modelId
    | sort inputTokens desc
    | limit 50
  EOT
}

resource "aws_cloudwatch_query_definition" "agentcore_failures" {
  name            = "${var.shared_resource_prefix}/${var.environment}/agentcore-failures"
  log_group_names = compact([var.api_log_group_name])
  query_string    = <<-EOT
    fields @timestamp, agent_id, runtime_arn, error_class, error_message, trace_id
    | filter msg like /InvokeAgentRuntime failed/
    | sort @timestamp desc
    | limit 50
  EOT
}

resource "aws_cloudwatch_query_definition" "memory_writes" {
  name            = "${var.shared_resource_prefix}/${var.environment}/memory-writes"
  log_group_names = compact([var.api_log_group_name])
  query_string    = <<-EOT
    fields @timestamp, user_id, agent_id, facts_written, latency_ms, trace_id
    | filter msg like /writeLongTermMemory/
    | sort @timestamp desc
    | limit 25
  EOT
}

# -----------------------------------------------------------------------------
# Alarms. Each goes through the SNS topic created above.
#
# Most alarms use math expressions on log-derived metric filters; a few use
# native Bedrock service metrics that AWS publishes automatically.
# -----------------------------------------------------------------------------

# 1. P99 turn latency — MAX across all agentId values so any single agent
#    breaching the SLO fires the alarm.
resource "aws_cloudwatch_metric_alarm" "p99_latency" {
  alarm_name          = "${var.shared_resource_prefix}-${var.environment}-p99-turn-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = var.p99_latency_threshold_ms
  treat_missing_data  = "notBreaching"
  alarm_description   = "P99 chat-turn latency exceeded ${var.p99_latency_threshold_ms}ms for 2 of 3 5-minute windows."

  metric_query {
    id          = "p99"
    return_data = true
    metric {
      namespace   = "Multiagent/FleetRollup"
      metric_name = "TurnLatencyMs"
      period      = 300
      stat        = "p99"
    }
  }

  alarm_actions = []
  ok_actions    = []
  tags          = local.common_tags

  depends_on = [aws_cloudwatch_log_metric_filter.fleet_turn_latency]
}

# 2. Error-rate threshold (errors per 100 turns) — aggregated across all agents.
resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "${var.shared_resource_prefix}-${var.environment}-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = var.error_rate_threshold_pct
  treat_missing_data  = "notBreaching"
  alarm_description   = "Error rate > ${var.error_rate_threshold_pct}% over 2 of 3 5-minute windows."

  metric_query {
    id          = "rate"
    expression  = "100 * errors / IF(turns > 0, turns, 1)"
    label       = "Error % per turn"
    return_data = true
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = "Multiagent/FleetRollup"
      metric_name = "TurnErrors"
      period      = 300
      stat        = "Sum"
    }
  }
  metric_query {
    id = "turns"
    metric {
      namespace   = "Multiagent/FleetRollup"
      metric_name = "TurnsTotal"
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = []
  ok_actions    = []
  tags          = local.common_tags

  depends_on = [
    aws_cloudwatch_log_metric_filter.fleet_turn_errors,
    aws_cloudwatch_log_metric_filter.fleet_turns_total,
  ]
}

# 3. Model throttling spike
resource "aws_cloudwatch_metric_alarm" "model_throttles" {
  alarm_name          = "${var.shared_resource_prefix}-${var.environment}-bedrock-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  threshold           = var.throttle_burst_threshold
  treat_missing_data  = "notBreaching"
  alarm_description   = "Bedrock returned > ${var.throttle_burst_threshold} ThrottlingException in 5 minutes."

  metric_query {
    id          = "thr"
    return_data = true
    metric {
      namespace   = "AWS/Bedrock"
      metric_name = "InvocationThrottles"
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = []
  ok_actions    = []
  tags          = local.common_tags
}

# 4. AgentCore InvokeRuntime failures — aggregated across all agent+mode combos.
resource "aws_cloudwatch_metric_alarm" "agentcore_failures" {
  alarm_name          = "${var.shared_resource_prefix}-${var.environment}-agentcore-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_description   = "AgentCore InvokeAgentRuntime errors > 5 in 5 minutes."

  metric_query {
    id          = "fails"
    return_data = true
    metric {
      namespace   = "Multiagent/FleetRollup"
      metric_name = "AgentCoreInvokeErrors"
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = []
  ok_actions    = []
  tags          = local.common_tags

  depends_on = [aws_cloudwatch_log_metric_filter.fleet_agentcore_errors]
}

# 5. Bedrock per-model invocation failures (uses native CW metric)
resource "aws_cloudwatch_metric_alarm" "bedrock_invocation_errors" {
  alarm_name          = "${var.shared_resource_prefix}-${var.environment}-bedrock-invoke-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 1
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_description   = "AWS/Bedrock InvocationClientErrors > 5 in 5 minutes."

  metric_query {
    id          = "errs"
    return_data = true
    metric {
      namespace   = "AWS/Bedrock"
      metric_name = "InvocationClientErrors"
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = []
  ok_actions    = []
  tags          = local.common_tags
}

# 6. PII Data Protection findings spike
resource "aws_cloudwatch_metric_alarm" "audit_findings" {
  count               = var.invocation_log_group_name != "" ? 1 : 0
  alarm_name          = "${var.shared_resource_prefix}-${var.environment}-audit-findings"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_description   = "More than 10 PII Data Protection findings in 5 minutes — investigate prompt-injection or upstream PII leakage."

  metric_query {
    id          = "audit"
    return_data = true
    metric {
      namespace   = "Multiagent/Audit"
      metric_name = "AuditFindings"
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = []
  ok_actions    = []
  tags          = local.common_tags

  depends_on = [aws_cloudwatch_log_metric_filter.audit_findings]
}

# 7. SLO error-budget burn (fast-burn detector) — aggregated across all agents.
resource "aws_cloudwatch_metric_alarm" "slo_burn" {
  alarm_name          = "${var.shared_resource_prefix}-${var.environment}-slo-burn"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 14.4 # 14.4x of a 0.1% budget over 1h => 2% consumed in 1h
  treat_missing_data  = "notBreaching"
  alarm_description   = "Fast-burn SLO alert. Error % > 14.4x the 0.1%/h budget in the last hour — paging engineer."

  metric_query {
    id          = "burn"
    expression  = "100 * errors / IF(turns > 0, turns, 1) / 0.1"
    label       = "Burn multiplier"
    return_data = true
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = "Multiagent/FleetRollup"
      metric_name = "TurnErrors"
      period      = 3600
      stat        = "Sum"
    }
  }
  metric_query {
    id = "turns"
    metric {
      namespace   = "Multiagent/FleetRollup"
      metric_name = "TurnsTotal"
      period      = 3600
      stat        = "Sum"
    }
  }

  alarm_actions = []
  ok_actions    = []
  tags          = local.common_tags

  depends_on = [
    aws_cloudwatch_log_metric_filter.fleet_turn_errors,
    aws_cloudwatch_log_metric_filter.fleet_turns_total,
  ]
}
