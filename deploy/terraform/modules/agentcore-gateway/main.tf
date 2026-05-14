terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.27, < 7.0" }
  }
}

locals {
  gateway_name = "${replace(var.project_name, "_", "-")}-gw-${var.environment}"
  target_name  = "mongodb-mcp"

  jwt_issuer = "https://cognito-idp.${var.aws_region}.amazonaws.com/${var.cognito_user_pool_id}"

  has_lambda_target     = var.create_lambda_target
  has_mcp_server_target = var.create_mcp_server_target
}

# =============================================================================
# IAM role — AgentCore Gateway assumes this to invoke the configured target
# (Lambda or AgentCore Runtime hosting an MCP server).
# =============================================================================

data "aws_iam_policy_document" "gateway_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gateway" {
  name               = "${var.project_name}-agentcore-gw-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.gateway_assume.json
  # tags inherited from provider default_tags

  lifecycle {
    precondition {
      condition     = !(var.create_lambda_target && var.create_mcp_server_target)
      error_message = "agentcore-gateway: create_lambda_target and create_mcp_server_target are mutually exclusive — pick one."
    }
    precondition {
      condition     = !var.create_mcp_server_target || (length(trimspace(var.mcp_server_endpoint)) > 0 && length(trimspace(var.mcp_server_runtime_arn)) > 0)
      error_message = "agentcore-gateway: when create_mcp_server_target=true, both mcp_server_endpoint and mcp_server_runtime_arn must be set."
    }
  }
}

# Attach the Lambda-invoke policy only when we actually have a Lambda target to
# invoke. Without it the Gateway is still fully usable for targets registered
# out-of-band (OpenAPI / Smithy / mcp_server).
resource "aws_iam_role_policy" "gateway_invoke_lambda" {
  count = local.has_lambda_target ? 1 : 0

  name = "InvokeMcpLambda"
  role = aws_iam_role.gateway.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = var.lambda_function_arn
    }]
  })
}

# When the Gateway target is an AgentCore Runtime hosting an MCP server (P1-1
# / P1-2 alignment), grant the gateway role bedrock-agentcore:InvokeAgentRuntime
# on the runtime ARN. The Gateway forwards each MCP `tools/call` to the runtime
# over Streamable-HTTP, signing the request with this IAM role.
resource "aws_iam_role_policy" "gateway_invoke_mcp_runtime" {
  count = local.has_mcp_server_target ? 1 : 0

  name = "InvokeMcpRuntime"
  role = aws_iam_role.gateway.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock-agentcore:InvokeAgentRuntime"]
      # Grant on both the runtime ARN and any /runtime-endpoint/* under it so
      # the Gateway can target the DEFAULT endpoint (and any future ones).
      Resource = [
        var.mcp_server_runtime_arn,
        "${var.mcp_server_runtime_arn}/*",
      ]
    }]
  })
}

# =============================================================================
# AgentCore Gateway — native resource (provider 6.17+).
# Cognito JWKS authorizer; protocol_type MCP. The target itself is a separate
# resource further down so we can flip lambda <-> mcp_server with `count`.
# =============================================================================

resource "aws_bedrockagentcore_gateway" "this" {
  name            = local.gateway_name
  role_arn        = aws_iam_role.gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "CUSTOM_JWT"

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url    = "${local.jwt_issuer}/.well-known/openid-configuration"
      allowed_audience = [var.cognito_app_client_id]
    }
  }

  tags = var.tags
}

# =============================================================================
# Gateway target — Lambda variant.
# Only created while we still need the Lambda host as a rollback path for the
# MongoDB MCP cutover (Phase 7e). Once the runtime path is smoke-green we set
# var.create_lambda_target=false and this resource (plus its IAM policy above)
# is destroyed cleanly.
# =============================================================================

resource "aws_bedrockagentcore_gateway_target" "lambda" {
  count = local.has_lambda_target ? 1 : 0

  name               = local.target_name
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  description        = "MongoDB MCP tools (Lambda host) — fallback target"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = var.lambda_function_arn

        tool_schema {
          inline_payload {
            name        = "mongodb_query"
            description = "Find documents matching a BSON filter."
            input_schema {
              type = "object"
              property {
                name     = "collection"
                type     = "string"
                required = true
              }
              property {
                name = "filter"
                type = "object"
              }
              property {
                name = "limit"
                type = "integer"
              }
            }
          }

          inline_payload {
            name        = "mongodb_vector_search"
            description = "Run an Atlas $vectorSearch aggregation."
            input_schema {
              type = "object"
              property {
                name     = "collection"
                type     = "string"
                required = true
              }
              property {
                name     = "index"
                type     = "string"
                required = true
              }
              property {
                name     = "queryVector"
                type     = "array"
                required = true
                items {
                  type = "number"
                }
              }
              property {
                name = "limit"
                type = "integer"
              }
            }
          }

          inline_payload {
            name        = "mongodb_aggregate"
            description = "Run an arbitrary MongoDB aggregation pipeline."
            input_schema {
              type = "object"
              property {
                name     = "collection"
                type     = "string"
                required = true
              }
              property {
                name     = "pipeline"
                type     = "array"
                required = true
                items {
                  type = "object"
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [aws_iam_role_policy.gateway_invoke_lambda]
}

# =============================================================================
# Gateway target — AgentCore Runtime MCP server variant (P1-1 active path).
# The runtime advertises its own tools via `tools/list`, so we don't supply a
# tool schema here — Gateway just proxies MCP requests to the runtime endpoint
# using the gateway's IAM role (granted bedrock-agentcore:InvokeAgentRuntime
# above).
# =============================================================================

resource "aws_bedrockagentcore_gateway_target" "mcp_server" {
  count = local.has_mcp_server_target ? 1 : 0

  name               = local.target_name
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  description        = "MongoDB MCP tools (AgentCore Runtime mcp-runtimes/mongodb-mcp)"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      mcp_server {
        endpoint = var.mcp_server_endpoint
      }
    }
  }

  depends_on = [aws_iam_role_policy.gateway_invoke_mcp_runtime]
}
