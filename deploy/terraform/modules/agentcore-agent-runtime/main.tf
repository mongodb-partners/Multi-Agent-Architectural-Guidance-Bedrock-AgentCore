terraform {
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    null  = { source = "hashicorp/null", version = "~> 3.0" }
    local = { source = "hashicorp/local", version = "~> 2.0" }
  }
}

locals {
  # AgentCore runtime names must match [a-zA-Z][a-zA-Z0-9_]{0,47}.
  # Keep caller-provided uniqueness while normalizing unsupported characters.
  runtime_name = substr(replace(var.runtime_name, "-", "_"), 0, 48)
  # State file is keyed by runtime_name so each of the 4 instances has its own file
  state_file      = "${path.module}/.runtime-state-${var.runtime_name}.json"
  tags_csv        = join(",", [for k, v in var.tags : "${k}=${v}"])
  env_json        = jsonencode(var.environment_variables)
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
      ] : [], length(compact([var.lambda_mcp_function_arn])) > 0 ? [
      {
        Sid    = "LambdaMcpInvoke"
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction",
        ]
        Resource = compact([var.lambda_mcp_function_arn])
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
# Runtime + Endpoint — provisioned via AWS CLI (not yet in TF provider)
# =============================================================================

resource "null_resource" "runtime" {
  triggers = {
    runtime_name    = local.runtime_name
    deployment_mode = local.deployment_mode
    container_uri   = var.container_uri
    code_bucket     = var.code_artifact_bucket
    code_prefix     = var.code_artifact_prefix
    code_version    = var.code_artifact_version_id
    code_runtime    = var.code_runtime
    code_entrypoint = jsonencode(var.code_entry_point)
    role_arn        = aws_iam_role.runtime.arn
    network_mode    = var.network_mode
    idle_timeout    = var.idle_timeout_seconds
    env_hash        = sha256(local.env_json)
    aws_region      = var.aws_region
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/create-runtime.sh"
    environment = {
      AWS_REGION      = var.aws_region
      RUNTIME_NAME    = local.runtime_name
      DEPLOYMENT_MODE = local.deployment_mode
      CONTAINER_URI   = var.container_uri
      CODE_BUCKET     = var.code_artifact_bucket
      CODE_PREFIX     = var.code_artifact_prefix
      CODE_VERSION    = var.code_artifact_version_id
      CODE_RUNTIME    = var.code_runtime
      CODE_ENTRYPOINT = jsonencode(var.code_entry_point)
      ROLE_ARN        = aws_iam_role.runtime.arn
      NETWORK_MODE    = var.network_mode
      IDLE_TIMEOUT    = tostring(var.idle_timeout_seconds)
      ENV_JSON        = local.env_json
      RESOURCE_TAGS   = local.tags_csv
      STATE_FILE      = local.state_file
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${path.module}/scripts/destroy-runtime.sh"
    environment = {
      AWS_REGION = self.triggers.aws_region
      STATE_FILE = "${path.module}/.runtime-state-${self.triggers.runtime_name}.json"
    }
  }

  depends_on = [aws_iam_role_policy.runtime_permissions]
}
