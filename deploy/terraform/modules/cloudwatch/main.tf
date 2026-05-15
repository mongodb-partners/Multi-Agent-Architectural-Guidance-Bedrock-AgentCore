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

  # Log group prefix — project + env so multiple deployments in one account/region
  # do not collide. Resolves to e.g. "/mongodb-multiagent/dev".
  log_group_prefix = "/${var.project_name}/${var.environment}"
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
