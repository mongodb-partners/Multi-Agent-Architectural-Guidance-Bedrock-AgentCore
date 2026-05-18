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
#
# PROVIDER NOTE: aws_bedrockagentcore_gateway_target.credential_provider_configuration
# with gateway_iam_role {} does NOT produce the correct API shape for mcpServer
# targets. The AWS API requires credentialProvider.iamCredentialProvider.service
# and .region, which the current TF provider does not emit. Until the provider
# is fixed upstream, we use a null_resource + local-exec to call the AWS CLI
# directly (idempotent: checks for existing target by name before creating).
#
# Upstream bug:  https://github.com/hashicorp/terraform-provider-aws/issues/47628
# Fix PR (open): https://github.com/hashicorp/terraform-provider-aws/pull/47457
#   (adds optional `service` and `region` to gateway_iam_role {}; 1 approval,
#    clean, last updated 2026-05-15 — expected in provider ~6.43.x / 6.44.x)
# TODO: once that PR ships, replace this null_resource with
#   aws_bedrockagentcore_gateway_target + gateway_iam_role { service = "bedrock-agentcore" }
#   and import existing state. See docs/analysis-null-resource-agentcore-gateway.md.
# =============================================================================

resource "null_resource" "mcp_server_gateway_target" {
  count = local.has_mcp_server_target ? 1 : 0

  triggers = {
    gateway_id = aws_bedrockagentcore_gateway.this.gateway_id
    endpoint   = var.mcp_server_endpoint
    region     = var.aws_region
    name       = local.target_name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SHELL
      set -euo pipefail
      GW="${aws_bedrockagentcore_gateway.this.gateway_id}"
      NAME="${local.target_name}"
      ENDPOINT="${var.mcp_server_endpoint}"
      REGION="${var.aws_region}"

      # Idempotency: skip creation if a target with this name already exists
      EXISTING=$(aws bedrock-agentcore-control list-gateway-targets \
        --gateway-identifier "$GW" \
        --region "$REGION" \
        --query "items[?name=='$NAME'].targetId" \
        --output text 2>/dev/null || true)

      if [[ -n "$EXISTING" ]]; then
        echo "[agentcore-gateway] MCP target '$NAME' already exists (id=$EXISTING) — skipping create"
        exit 0
      fi

      echo "[agentcore-gateway] Creating MCP server target '$NAME' on gateway $GW …"
      aws bedrock-agentcore-control create-gateway-target \
        --region "$REGION" \
        --gateway-identifier "$GW" \
        --name "$NAME" \
        --description "MongoDB MCP tools (AgentCore Runtime mcp-runtimes/mongodb-mcp)" \
        --target-configuration "{\"mcp\":{\"mcpServer\":{\"endpoint\":\"$ENDPOINT\"}}}" \
        --credential-provider-configurations \
          "[{\"credentialProviderType\":\"GATEWAY_IAM_ROLE\",\"credentialProvider\":{\"iamCredentialProvider\":{\"service\":\"bedrock-agentcore\",\"region\":\"$REGION\"}}}]" \
        --output json
    SHELL
  }

  depends_on = [
    aws_bedrockagentcore_gateway.this,
    aws_iam_role_policy.gateway_invoke_mcp_runtime,
  ]
}
