terraform {
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    null  = { source = "hashicorp/null", version = "~> 3.0" }
    local = { source = "hashicorp/local", version = "~> 2.0" }
  }
}

locals {
  gateway_name = "${replace(var.project_name, "_", "-")}-gw-${var.environment}"
  target_name  = "mongodb-mcp"
  state_file   = "${path.module}/.gateway-state.json"

  jwt_issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${var.cognito_user_pool_id}"
  jwt_audience = var.cognito_app_client_id
  tags_csv     = join(",", [for k, v in var.tags : "${k}=${v}"])

  has_lambda_target = var.create_lambda_target
}

# =============================================================================
# IAM role — AgentCore Gateway assumes this to invoke the Lambda tool target
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
}

# Only attach the Lambda-invoke policy when we actually have a Lambda target to
# invoke. Without it, the Gateway is still fully usable for targets registered
# out-of-band (OpenAPI/Smithy) or attached later once the SCP is lifted.
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

# =============================================================================
# Gateway + Target — provisioned via AWS CLI (not yet in TF provider)
# =============================================================================

resource "null_resource" "gateway" {
  triggers = {
    gateway_name     = local.gateway_name
    lambda_arn       = var.lambda_function_arn
    gateway_role_arn = aws_iam_role.gateway.arn
    jwt_issuer       = local.jwt_issuer
    jwt_audience     = local.jwt_audience
    aws_region       = var.aws_region
    tags_csv         = local.tags_csv
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/create-gateway.sh"
    environment = {
      AWS_REGION       = var.aws_region
      GATEWAY_NAME     = local.gateway_name
      GATEWAY_ROLE_ARN = aws_iam_role.gateway.arn
      LAMBDA_ARN       = var.lambda_function_arn
      TARGET_NAME      = local.target_name
      JWT_ISSUER       = local.jwt_issuer
      JWT_AUDIENCE     = local.jwt_audience
      STATE_FILE       = local.state_file
      RESOURCE_TAGS    = local.tags_csv
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${path.module}/scripts/destroy-gateway.sh"
    environment = {
      AWS_REGION = self.triggers.aws_region
      STATE_FILE = "${path.module}/.gateway-state.json"
    }
  }

  depends_on = [aws_iam_role_policy.gateway_invoke_lambda]
}

# Module output lookup — gateway state is written by the script above.
# When has_lambda_target=false the script creates the Gateway only (no target).
