terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.27, < 7.0"
    }
  }
}

locals {
  # Endpoint name carries the model variant so swapping listings
  # (voyage-multimodal-3 vs voyage-multimodal-3.5) creates a new endpoint instead
  # of confusingly reusing the previous one. project_name is intentionally
  # NOT in the name — this module is instantiated by envs/shared once per
  # (account, region, environment) and consumed by multiple per-project
  # envs/ec2 stacks via SSM.
  endpoint_name_suffix = trim(replace(lower(var.endpoint_name_suffix), "/[^a-z0-9-]+/", "-"), "-")
  endpoint_name        = "${local.endpoint_name_suffix}-${var.environment}"
}

# =============================================================================
# IAM — SageMaker execution role
# =============================================================================

data "aws_iam_policy_document" "sagemaker_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker_exec" {
  # IAM role name is env-scoped to match the shared-stack ownership: one role
  # per (account, region, environment) regardless of how many per-project ec2
  # stacks share the resulting SageMaker endpoint.
  name               = "voyage-sagemaker-exec-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_assume.json

  tags = {
    Name = "voyage-sagemaker-exec-${var.environment}"
  }
}

resource "aws_iam_role_policy_attachment" "sagemaker_full" {
  role       = aws_iam_role.sagemaker_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

# Allow SageMaker to pull the Marketplace model package
resource "aws_iam_role_policy" "marketplace_model" {
  name = "VoyageMarketplaceModelAccess"
  role = aws_iam_role.sagemaker_exec.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sagemaker:DescribeModelPackage", "aws-marketplace:ViewSubscriptions"]
      Resource = "*"
    }]
  })
}

# =============================================================================
# SageMaker Model — Voyage AI from AWS Marketplace
# =============================================================================

resource "aws_sagemaker_model" "voyage" {
  name               = "${local.endpoint_name}-model"
  execution_role_arn = aws_iam_role.sagemaker_exec.arn

  # Required by AWS Marketplace model packages: container runs without
  # outbound network access. Voyage AI's container does inference locally
  # and doesn't need internet, so this is fine.
  enable_network_isolation = true

  primary_container {
    model_package_name = var.voyage_model_package_arn
  }

  tags = {
    Name = "${local.endpoint_name}-model"
  }
}

# =============================================================================
# SageMaker Endpoint Configuration
# =============================================================================

resource "aws_sagemaker_endpoint_configuration" "voyage" {
  name = "${local.endpoint_name}-config"

  production_variants {
    variant_name           = "Primary"
    model_name             = aws_sagemaker_model.voyage.name
    initial_instance_count = var.instance_count
    instance_type          = var.instance_type
  }

  tags = {
    Name = "${local.endpoint_name}-config"
  }
}

# =============================================================================
# SageMaker Endpoint
# =============================================================================

resource "aws_sagemaker_endpoint" "voyage" {
  name                 = local.endpoint_name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.voyage.name

  tags = {
    Name = local.endpoint_name
  }
}
