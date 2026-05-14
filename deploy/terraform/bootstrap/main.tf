# Bootstrap — run ONCE before the first `terraform init` in the parent directory.
#
# Creates the single shared S3 bucket and DynamoDB lock table used by all
# Terraform state and Bedrock KB docs.  State for this config is kept LOCAL
# (intentional — you can't use an S3 backend that doesn't exist yet).
#
# Bucket layout after provisioning:
#   s3://<bucket>/tfstate/   → Terraform remote state files (one key per workspace)
#   s3://<bucket>/kb-docs/   → Bedrock Knowledge Base source documents
#
# Usage (run from repo root):
#   source env.sh
#   cd deploy/terraform/bootstrap
#   terraform init
#   terraform apply -var="account_id=$(aws sts get-caller-identity --query Account --output text)"
#
# After apply:
#   1. Copy the printed backend.hcl snippet into deploy/terraform/backend.hcl
#   2. cd .. && terraform init -backend-config=backend.hcl

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.27, < 7.0"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "account_id" {
  type        = string
  description = "AWS account ID — appended to bucket name for global uniqueness"
}

variable "project_name" {
  type    = string
  default = "multiagent-mongodb-framework"
}

variable "environment" {
  type    = string
  default = "dev"
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  # Single shared bucket — all prefixes live here
  bucket_name = "${var.project_name}-${var.environment}-${var.account_id}"
}

# ── Provider ──────────────────────────────────────────────────────────────────

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = var.project_name
    }
  }
}

# ── Shared S3 Bucket ──────────────────────────────────────────────────────────
# One bucket, multiple prefixes:
#   tfstate/   → Terraform remote state
#   kb-docs/   → Bedrock KB source documents

resource "aws_s3_bucket" "shared" {
  bucket = local.bucket_name

  # Do NOT force_destroy — this bucket holds Terraform state.
  # Destroy manually only after all workspaces are migrated.
  force_destroy = false

  tags = { Name = local.bucket_name }
}

resource "aws_s3_bucket_versioning" "shared" {
  bucket = aws_s3_bucket.shared.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "shared" {
  bucket = aws_s3_bucket.shared.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "shared" {
  bucket                  = aws_s3_bucket.shared.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "shared_bucket_name" {
  value       = aws_s3_bucket.shared.id
  description = "Shared S3 bucket name — set as shared_bucket_name in terraform.tfvars"
}

output "backend_hcl_snippet" {
  value       = <<-EOT

    # Copy this to deploy/terraform/backend.hcl
    bucket  = "${aws_s3_bucket.shared.id}"
    key     = "${var.environment}/terraform.tfstate"
    region  = "${var.aws_region}"
    encrypt = true

    # Then run: terraform init -backend-config=backend.hcl
  EOT
  description = "Paste this into deploy/terraform/backend.hcl"
}
