# =============================================================================
# Bedrock model invocation logging — account-scoped resource that captures
# per-call metadata (modelId, token counts, latency, requestMetadata, error)
# and optionally the prompt/completion bodies. Required for the GenAI
# Observability "Model Invocations" tab to populate beyond the auto-discovered
# basics.
#
# PRIVACY POSTURE
# ---------------
# text_data_delivery_enabled defaults to FALSE. Raw user prompts and model
# completions are NOT delivered to CloudWatch by default. Token counts, model
# id, latency, error code, and requestMetadata (Phase 3 puts userId + agentId
# in here) are still captured — enough for the cost-attribution widget, the
# Model Invocations dashboard, and most ops debugging.
#
# Set var.log_prompt_bodies = true per-environment only when a regulator, an
# audit cycle, or a specific incident requires it. The Data Protection Policy
# (modules/cloudwatch-genai/... is one option, here we attach a per-log-group
# policy) still scrubs PII when bodies are on.
#
# ACCOUNT-SCOPED — only one model_invocation_logging_configuration per region
# per account. If another stack already created one, set
# var.enable_bedrock_invocation_logging = false to avoid the clash.
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
    Component   = "bedrock-invocation-logging"
  })
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# Log group — receives the invocation records from Bedrock. Name is
# /aws/bedrock/invocations to match the AWS-documented convention so AWS
# console "auto-discover" features (e.g. GenAI Observability) find it.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "invocations" {
  count = var.enable ? 1 : 0

  name              = var.log_group_name
  retention_in_days = var.retention_days
  # Uses the AWS-managed `aws/logs` key — encrypted at rest, no extra cost.

  tags = merge(local.common_tags, {
    Name = var.log_group_name
  })
}

# -----------------------------------------------------------------------------
# Audit findings log group — Data Protection Audit cannot publish findings to
# the SAME log group it's scanning (AWS returns "InvalidParameterException:
# The CloudWatchLogs LogGroup in Audit Operation cannot be the same as
# source LogGroup"). We use a dedicated `/aws/bedrock/invocations-audit`
# group instead. Alarms in modules/cloudwatch-fleet-dashboards point at
# this group via `audit_log_group_name`.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "invocations_audit" {
  count = var.enable ? 1 : 0

  name              = "${var.log_group_name}-audit"
  retention_in_days = var.retention_days

  tags = merge(local.common_tags, {
    Name = "${var.log_group_name}-audit"
  })
}

# -----------------------------------------------------------------------------
# Data Protection Policy — defense-in-depth.
#
# With log_prompt_bodies=false (default) this mainly catches accidental PII
# in requestMetadata or error messages. With log_prompt_bodies=true it
# scrubs prompt/completion bodies, so masked values appear as e.g.
# {EmailAddress} in Logs Insights and the raw value never reaches a human
# reader.
#
# Audit findings ship to the dedicated `*-audit` group above (see comment).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_data_protection_policy" "invocations" {
  count = var.enable ? 1 : 0

  log_group_name = aws_cloudwatch_log_group.invocations[0].name

  policy_document = jsonencode({
    Name        = "${var.project_name}-${var.environment}-bedrock-pii"
    Version     = "2021-06-01"
    Description = "Audit + Deidentify managed PII identifiers on Bedrock invocation logs."
    Statement = [
      {
        Sid            = "AuditPII"
        DataIdentifier = [for id in var.data_protection_identifiers : "arn:aws:dataprotection::aws:data-identifier/${id}"]
        Operation = {
          Audit = {
            FindingsDestination = {
              CloudWatchLogs = {
                LogGroup = aws_cloudwatch_log_group.invocations_audit[0].name
              }
            }
          }
        }
      },
      {
        Sid            = "MaskPII"
        DataIdentifier = [for id in var.data_protection_identifiers : "arn:aws:dataprotection::aws:data-identifier/${id}"]
        Operation = {
          Deidentify = {
            MaskConfig = {}
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# IAM role assumed by Bedrock to write into the log group.
# Trust policy includes the SourceArn / SourceAccount confused-deputy guards.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "trust" {
  count = var.enable ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "bedrock_logging" {
  count = var.enable ? 1 : 0

  name               = "${var.project_name}-bedrock-invocation-logging-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.trust[0].json

  tags = local.common_tags
}

resource "aws_iam_role_policy" "bedrock_logging" {
  count = var.enable ? 1 : 0

  name = "BedrockInvocationLogging"
  role = aws_iam_role.bedrock_logging[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.invocations[0].arn}:*",
          "${aws_cloudwatch_log_group.invocations_audit[0].arn}:*",
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# The actual account-scoped invocation logging toggle. Bedrock has exactly one
# of these per region per account — we either own it or we don't. Module
# consumers gate via var.enable to share the account with other stacks.
# -----------------------------------------------------------------------------
resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  count = var.enable ? 1 : 0

  logging_config {
    text_data_delivery_enabled      = var.log_prompt_bodies
    embedding_data_delivery_enabled = var.log_embedding_bodies
    image_data_delivery_enabled     = false
    video_data_delivery_enabled     = false

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.invocations[0].name
      role_arn       = aws_iam_role.bedrock_logging[0].arn
    }
  }

  depends_on = [
    aws_iam_role_policy.bedrock_logging,
    aws_cloudwatch_log_data_protection_policy.invocations,
  ]
}
