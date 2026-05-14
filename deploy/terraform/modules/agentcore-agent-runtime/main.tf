terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.27, < 7.0" }
  }
}

locals {
  # AgentCore runtime names must match [a-zA-Z][a-zA-Z0-9_]{0,47}.
  # Keep caller-provided uniqueness while normalizing unsupported characters.
  runtime_name    = substr(replace(var.runtime_name, "-", "_"), 0, 48)
  deployment_mode = lower(trimspace(var.deployment_mode))
}

# =============================================================================
# IAM — execution role that AgentCore Runtime assumes to run the container
# =============================================================================

data "aws_iam_policy_document" "runtime_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "runtime" {
  name               = "${var.runtime_name}-role"
  assume_role_policy = data.aws_iam_policy_document.runtime_assume.json
}

resource "aws_iam_role_policy" "runtime_permissions" {
  name = "AgentCoreRuntimePermissions"
  role = aws_iam_role.runtime.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "ECRPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock-agent-runtime:Retrieve",
        ]
        Resource = "*"
      },
      {
        Sid    = "AgentCoreServices"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:CreateEvent",
          "bedrock-agentcore:GetEvent",
          "bedrock-agentcore:ListEvents",
          "bedrock-agentcore:ListSessions",
          "bedrock-agentcore:InvokeGateway",
          "bedrock-agentcore:GetWorkloadAccessToken",
          "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
          "bedrock-agentcore:InvokeAgentRuntime",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*"
      },
      {
        Sid      = "XRay"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
      ], length(compact([var.kb_secret_name_prefix])) > 0 ? [
      {
        Sid      = "SecretsManager"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:${var.kb_secret_name_prefix}-*"
      }
      ] : [], length(compact([var.voyage_sagemaker_endpoint_arn])) > 0 ? [
      {
        Sid    = "SageMakerInvoke"
        Effect = "Allow"
        Action = [
          "sagemaker:InvokeEndpoint",
          "sagemaker:InvokeEndpointWithResponseStream",
        ]
        Resource = compact([var.voyage_sagemaker_endpoint_arn])
      }
      ] : [], local.deployment_mode == "code" ? [
      {
        Sid    = "S3CodeArtifactRead"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::${var.code_artifact_bucket}",
          "arn:aws:s3:::${var.code_artifact_bucket}/*",
        ]
      }
    ] : [])
  })
}

# =============================================================================
# AgentCore Agent Runtime — native resource (provider 6.17+).
# Replaces the previous null_resource + create-runtime.sh shim. AgentCore
# auto-creates the DEFAULT endpoint on the runtime, so we don't manage one
# explicitly. Container vs S3-code artifact is dispatched by deployment_mode.
# =============================================================================

resource "aws_bedrockagentcore_agent_runtime" "this" {
  agent_runtime_name = local.runtime_name
  role_arn           = aws_iam_role.runtime.arn

  agent_runtime_artifact {
    dynamic "container_configuration" {
      for_each = local.deployment_mode == "container" ? [1] : []
      content {
        container_uri = var.container_uri
      }
    }

    dynamic "code_configuration" {
      for_each = local.deployment_mode == "code" ? [1] : []
      content {
        entry_point = var.code_entry_point
        runtime     = var.code_runtime
        code {
          s3 {
            bucket     = var.code_artifact_bucket
            prefix     = var.code_artifact_prefix
            version_id = trimspace(var.code_artifact_version_id) == "" ? null : var.code_artifact_version_id
          }
        }
      }
    }
  }

  network_configuration {
    network_mode = var.network_mode

    dynamic "network_mode_config" {
      for_each = var.network_mode == "VPC" ? [1] : []
      content {
        subnets         = var.vpc_subnet_ids
        security_groups = var.vpc_security_group_ids
      }
    }
  }

  protocol_configuration {
    server_protocol = var.server_protocol
  }

  lifecycle_configuration {
    idle_runtime_session_timeout = var.idle_timeout_seconds
    max_lifetime                 = var.max_lifetime_seconds
  }

  environment_variables = var.environment_variables

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.network_mode != "VPC" || (length(var.vpc_subnet_ids) > 0 && length(var.vpc_security_group_ids) > 0)
      error_message = "agentcore-agent-runtime: network_mode=VPC requires non-empty vpc_subnet_ids and vpc_security_group_ids."
    }
    precondition {
      condition     = local.deployment_mode != "container" || length(trimspace(var.container_uri)) > 0
      error_message = "agentcore-agent-runtime: deployment_mode=container requires a non-empty container_uri."
    }
    precondition {
      condition     = local.deployment_mode != "code" || (length(trimspace(var.code_artifact_bucket)) > 0 && length(trimspace(var.code_artifact_prefix)) > 0)
      error_message = "agentcore-agent-runtime: deployment_mode=code requires non-empty code_artifact_bucket and code_artifact_prefix."
    }
  }

  depends_on = [aws_iam_role_policy.runtime_permissions]

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}
