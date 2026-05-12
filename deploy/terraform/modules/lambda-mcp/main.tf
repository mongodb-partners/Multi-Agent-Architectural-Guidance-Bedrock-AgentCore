terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

locals {
  function_name = "${var.project_name}-mongodb-mcp-${var.environment}"
  artifact_key  = "${trim(var.artifact_key_prefix, "/")}/${local.function_name}-${data.archive_file.lambda.output_md5}.zip"
}

# =============================================================================
# IAM — Lambda execution role
# =============================================================================

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project_name}-lambda-mcp-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# =============================================================================
# Security group — allow outbound MongoDB (27017) + HTTPS (443) within VPC
# =============================================================================

resource "aws_security_group" "lambda" {
  name        = "${var.project_name}-sg-lambda-mcp-${var.environment}"
  description = "Lambda MongoDB MCP - outbound to Atlas PrivateLink"
  vpc_id      = var.vpc_id

  egress {
    description = "MongoDB TLS to Atlas PrivateLink"
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTPS for any AWS service calls (Secrets Manager, etc.)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Atlas PrivateLink mongod listener ports"
    from_port   = 1024
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-lambda-mcp-${var.environment}"
  }
}

# =============================================================================
# Package Lambda code — zip the handler directory (must include node_modules)
# =============================================================================

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = var.lambda_source_dir
  output_path = "${path.module}/.build/mongodb-mcp.zip"
}

resource "aws_s3_object" "lambda_artifact" {
  bucket = var.artifact_bucket_name
  key    = local.artifact_key
  source = data.archive_file.lambda.output_path
}

# =============================================================================
# Lambda function
# =============================================================================

resource "aws_lambda_function" "mcp" {
  function_name     = local.function_name
  role              = aws_iam_role.lambda.arn
  handler           = "index.handler"
  runtime           = "nodejs20.x"
  s3_bucket         = aws_s3_object.lambda_artifact.bucket
  s3_key            = aws_s3_object.lambda_artifact.key
  s3_object_version = aws_s3_object.lambda_artifact.version_id
  source_code_hash  = data.archive_file.lambda.output_base64sha256
  timeout           = var.timeout_seconds
  memory_size       = var.memory_mb

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      MONGODB_URI         = var.mongodb_uri
      MONGODB_DB          = var.mongodb_db
      MONGODB_ALLOW_WRITE = var.allow_write ? "1" : "0"
      MONGODB_MAX_LIMIT   = tostring(var.max_limit)
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.vpc,
    aws_iam_role_policy_attachment.basic,
  ]
}

# Allow AgentCore Gateway to invoke the function
resource "aws_lambda_permission" "agentcore_invoke" {
  statement_id  = "AllowAgentCoreGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mcp.function_name
  principal     = "bedrock-agentcore.amazonaws.com"
}
