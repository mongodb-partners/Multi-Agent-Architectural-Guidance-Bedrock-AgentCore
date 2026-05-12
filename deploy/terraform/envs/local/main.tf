terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws          = { source = "hashicorp/aws", version = "~> 5.0" }
    mongodbatlas = { source = "mongodb/mongodbatlas", version = "~> 1.14" }
    null         = { source = "hashicorp/null", version = "~> 3.0" }
    random       = { source = "hashicorp/random", version = "~> 3.0" }
  }

  backend "s3" {}
}

locals {
  common_tags = {
    Project = var.project_name
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

provider "mongodbatlas" {
  public_key  = var.atlas_public_key
  private_key = var.atlas_private_key
}

data "aws_caller_identity" "current" {}

data "aws_s3_bucket" "shared" {
  bucket = var.shared_bucket_name
}

# ══════════════════════════════════════════════════════════════════════════════
# MongoDB Atlas — M10 cluster (public endpoint; app runs on localhost)
# ══════════════════════════════════════════════════════════════════════════════
module "mongodb_atlas" {
  source = "../../modules/mongodb-atlas"

  atlas_project_id = var.atlas_project_id
  cluster_name     = "${var.project_name}-${var.environment}"
  db_name          = var.atlas_db_name
  db_username      = var.atlas_db_user
  db_password      = var.atlas_db_password
  project_tag      = var.project_name
}

# ══════════════════════════════════════════════════════════════════════════════
# Bedrock Knowledge Base — Titan embeddings, points at Atlas cluster
# ══════════════════════════════════════════════════════════════════════════════
module "bedrock_kb" {
  source = "../../modules/bedrock-kb"

  aws_region   = var.aws_region
  account_id   = data.aws_caller_identity.current.account_id
  project_name = var.project_name
  environment  = var.environment

  shared_bucket_name = data.aws_s3_bucket.shared.id
  shared_bucket_arn  = data.aws_s3_bucket.shared.arn

  atlas_project_id   = var.atlas_project_id
  atlas_cluster_name = module.mongodb_atlas.cluster_name
  atlas_srv_host     = module.mongodb_atlas.mongo_host
  atlas_db_user      = var.atlas_db_user
  atlas_db_password  = var.atlas_db_password
  atlas_db_name      = var.atlas_db_name

  kb_iam_role_name         = var.kb_iam_role_name
  embed_model_id           = var.embed_model_id
  kb_docs_path             = "${path.module}/../../../kb-docs"
  ensure_collection_script = "${path.module}/../../../../db-seeding/ensure-collection.ts"
}

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch — log groups for API + MCP (local processes stream here if configured)
# ══════════════════════════════════════════════════════════════════════════════
module "cloudwatch" {
  source         = "../../modules/cloudwatch"
  project_name   = var.project_name
  environment    = var.environment
  retention_days = var.log_retention_days
}
