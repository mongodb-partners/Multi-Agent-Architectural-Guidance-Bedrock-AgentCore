# =============================================================================
# AgentCore Module — Memory Store + Gateway
#
# Memory Store: replaces the MongoDB agent_memory collection for long-term
#   per-user conversation history. AWS-managed retention and encryption.
#
# Gateway: routes MCP tool calls from specialist agents through to the
#   mongodb-mcp-server sidecar. Registered as a target on the gateway.
#
# AWS provider ~5.0 is required for aws_bedrockagentcore_* resources.
# =============================================================================

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  name_prefix = "${var.project_name}-${var.environment}"
}

# =============================================================================
# IAM Role — AgentCore Gateway execution role
# The gateway needs bedrock:InvokeModel (for tool routing) and logs access.
# =============================================================================

data "aws_iam_policy_document" "agentcore_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agentcore_gateway" {
  name               = "${local.name_prefix}-agentcore-gateway-role"
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-agentcore-gateway-role"
  })
}

resource "aws_iam_role_policy" "agentcore_gateway" {
  name = "AgentCoreGatewayPermissions"
  role = aws_iam_role.agentcore_gateway.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
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
        ]
        Resource = "*"
      }
    ]
  })
}

# =============================================================================
# AgentCore Memory Store
# Stores per-user, per-agent conversation turns with AWS-managed TTL.
# The app reads/writes via BedrockAgentCoreClient (AGENTCORE_MEMORY_STORE_ID).
# =============================================================================

resource "aws_bedrockagentcore_memory_store" "main" {
  name        = "${local.name_prefix}-memory"
  description = "Long-term conversation memory for multi-agent POC"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-memory"
  })
}

# =============================================================================
# AgentCore Gateway
# Exposes MCP tools to specialist agents.  The mongodb-mcp-server sidecar
# (EC2) or local process is registered as a target below.
# =============================================================================

resource "aws_bedrockagentcore_gateway" "main" {
  name        = "${local.name_prefix}-gateway"
  description = "MCP tool gateway for multi-agent POC"
  role_arn    = aws_iam_role.agentcore_gateway.arn

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-gateway"
  })
}

# =============================================================================
# Gateway Target — mongodb-mcp-server
# In EC2 mode: the MCP server listens on localhost:8080 (HTTP) on the EC2
# instance, reachable from the API on the same host.
# In local mode: MCP server runs as a stdio process; the gateway target URL
# is set to localhost for consistent env var injection.
# =============================================================================

resource "aws_bedrockagentcore_gateway_target" "mongodb_mcp" {
  gateway_id  = aws_bedrockagentcore_gateway.main.id
  name        = "mongodb-mcp-server"
  description = "MongoDB MCP server — handles find_documents, aggregate, vector_search, upsert_document"

  endpoint_configuration {
    # HTTP endpoint — the MCP server exposes /mcp over HTTP on the host
    url = var.mcp_server_url
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-gateway-target-mongodb-mcp"
  })
}
