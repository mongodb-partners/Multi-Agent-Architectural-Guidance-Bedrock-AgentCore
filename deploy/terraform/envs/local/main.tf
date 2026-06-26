terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws          = { source = "hashicorp/aws", version = ">= 6.27, < 7.0" }
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
# MongoDB Atlas — M10 cluster (public SRV endpoint, but the IP access list is
# scoped to the operator laptop /32 via var.operator_ip_cidr — NOT 0.0.0.0/0)
# ══════════════════════════════════════════════════════════════════════════════
module "mongodb_atlas" {
  source = "../../modules/mongodb-atlas"

  atlas_project_id = var.atlas_project_id
  cluster_name     = "${var.project_name}-${var.environment}"
  db_name          = var.atlas_db_name
  db_username      = var.atlas_db_user
  db_password      = var.atlas_db_password
  project_tag      = var.project_name
  # WHY: local mode reaches Atlas over public SRV from the laptop, so the
  # laptop /32 is the only allowlist entry. Forward it here so the module never
  # has to fall back to 0.0.0.0/0.
  operator_ip_cidr = var.operator_ip_cidr

  # BYO passthrough (local mode just proxies the operator URI through).
  cluster_source        = var.cluster_source
  byo_connection_string = var.byo_connection_string
  byo_srv_host          = var.byo_srv_host
}

# Atlas Search indexes that belong to application data are reconciled through
# the idempotent db-seeding script so local and EC2 environments use the same
# index definitions.
resource "null_resource" "seed_mongodb_indexes" {
  triggers = {
    cluster_name      = module.mongodb_atlas.cluster_name
    db_name           = var.atlas_db_name
    seed_indexes_sha1 = filesha1("${path.module}/../../../../db-seeding/seed-indexes.ts")
  }

  provisioner "local-exec" {
    command = "bun ${path.module}/../../../../db-seeding/seed-indexes.ts"

    environment = {
      MONGODB_URI = module.mongodb_atlas.connection_string
      MONGODB_DB  = var.atlas_db_name
      # Embedding dim is driven by VOYAGE_OUTPUT_DIM (default 1024 ==
      # VOYAGE_DEFAULT_EMBEDDING_DIMS in api/src/adapters/voyage-embedding.ts).
      # seed-indexes.ts reads VOYAGE_OUTPUT_DIM via getVoyageEmbeddingDims().
      # Terraform can't shell out to voyage-print.ts, so var.voyage_output_dim's
      # default is pinned by the bun guard test
      # `voyage SSOT — terraform <-> TS parity for embedding dim`.
      VOYAGE_OUTPUT_DIM             = tostring(var.voyage_output_dim)
      EMBEDDING_DIMENSIONS          = tostring(var.voyage_output_dim)
      WAIT_FOR_ATLAS_SEARCH_INDEXES = "1"
    }
  }

  depends_on = [module.mongodb_atlas]
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

  shared_bucket_name  = data.aws_s3_bucket.shared.id
  shared_bucket_arn   = data.aws_s3_bucket.shared.arn
  kb_docs_bucket_name = var.kb_docs_bucket_name

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
# AgentCore Memory — short-term conversation event store
# Provisioned in the local env so that AGENTCORE_MEMORY_STORE_ID is available
# to locally-run API processes (set SHORT_TERM_MEMORY_BACKEND=agentcore).
# AgentCore runtimes and gateway are ec2-only; memory is lightweight and
# has no VPC/runtime dependency.
# ══════════════════════════════════════════════════════════════════════════════
module "agentcore_memory" {
  source       = "../../modules/agentcore-memory"
  aws_region   = var.aws_region
  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags
}

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch — log groups for API + MCP (local processes stream here if configured)
# ══════════════════════════════════════════════════════════════════════════════
module "cloudwatch" {
  source = "../../modules/cloudwatch"
  # Distinct prefix so envs/local log groups (/multiagent-local/<env>/api …)
  # never collide with the envs/shared log groups (/multiagent/<env>/api …)
  # if both happen to run in the same AWS account + region + env.
  shared_resource_prefix = "multiagent-local"
  project_name           = var.project_name
  environment            = var.environment
  api_retention_days     = var.log_retention_days
}
