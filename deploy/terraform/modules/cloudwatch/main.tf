# =============================================================================
# CloudWatch Log Groups — API, UI, MCP server, and AgentCore placeholder
# IAM permissions for logs:* already exist on the EC2 role (CloudWatchLogs sid).
# These groups are created here so they exist before the services start writing.
# =============================================================================

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Log group prefix — env-scoped so a single shared set of
  # /<shared_resource_prefix>/<env>/* groups serves every per-project envs/ec2
  # stack in the (account, region). The shared stack (envs/shared) creates
  # these once and publishes the names via SSM; per-project envs read them.
  #
  # envs/local also instantiates this module on its own to keep local dev
  # self-contained — that uses "local" as the environment, producing
  # /<shared_resource_prefix>/local/* (distinct from any deployed environment).
  log_group_prefix = "/${var.shared_resource_prefix}/${var.environment}"
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "${local.log_group_prefix}/api"
  retention_in_days = var.api_retention_days

  tags = merge(local.common_tags, {
    Name = "${local.log_group_prefix}/api"
  })
}

resource "aws_cloudwatch_log_group" "ui" {
  name              = "${local.log_group_prefix}/ui"
  retention_in_days = var.aux_retention_days

  tags = merge(local.common_tags, {
    Name = "${local.log_group_prefix}/ui"
  })
}

resource "aws_cloudwatch_log_group" "mcp" {
  name              = "${local.log_group_prefix}/mcp"
  retention_in_days = var.aux_retention_days

  tags = merge(local.common_tags, {
    Name = "${local.log_group_prefix}/mcp"
  })
}

resource "aws_cloudwatch_log_group" "agentcore" {
  name              = "${local.log_group_prefix}/agentcore"
  retention_in_days = var.aux_retention_days

  tags = merge(local.common_tags, {
    Name = "${local.log_group_prefix}/agentcore"
  })
}
