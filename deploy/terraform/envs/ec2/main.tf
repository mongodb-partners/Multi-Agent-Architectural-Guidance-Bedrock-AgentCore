terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws          = { source = "hashicorp/aws", version = "~> 5.0" }
    mongodbatlas = { source = "mongodb/mongodbatlas", version = "~> 1.14" }
    archive      = { source = "hashicorp/archive", version = "~> 2.0" }
    null         = { source = "hashicorp/null", version = "~> 3.0" }
    random       = { source = "hashicorp/random", version = "~> 3.0" }
  }

  backend "s3" {}
}

locals {
  # One tag, everywhere. Filter Cost Explorer / resourcegroupstaggingapi
  # on Project=multiagent-mongodb-framework to find/delete every resource.
  common_tags = {
    Project = var.project_name
  }
  agentcore_code_entrypoint  = ["agent-runtime-code.js"]
  agentcore_runtime_repo_url = var.agentcore_runtime_deployment_mode == "container" ? aws_ecr_repository.agent_runtime[0].repository_url : ""

  # SSM prefix mirrors the network env exactly. Single source of truth for
  # discovering the shared VPC + Atlas PrivateLink VPCE. envs/network publishes
  # under this same prefix.
  ssm_prefix = "/${var.shared_vpc_name}/${var.aws_region}"
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
# Shared network discovery — read VPC + Atlas PrivateLink details published by
# envs/network into SSM Parameter Store. This is the cross-state contract: per-
# project envs do NOT share state with envs/network, only SSM key/value reads.
#
# If any of these lookups fail with ParameterNotFound, run deploy-network.sh
# first (envs/network must be applied before envs/ec2).
# ══════════════════════════════════════════════════════════════════════════════
data "aws_ssm_parameter" "shared_vpc_id" {
  name = "${local.ssm_prefix}/vpc_id"
}

data "aws_ssm_parameter" "shared_vpc_cidr" {
  name = "${local.ssm_prefix}/vpc_cidr"
}

data "aws_ssm_parameter" "shared_public_subnet_ids" {
  name = "${local.ssm_prefix}/public_subnet_ids"
}

data "aws_ssm_parameter" "shared_private_subnet_ids" {
  name = "${local.ssm_prefix}/private_subnet_ids"
}

data "aws_ssm_parameter" "shared_atlas_pl_vpce_id" {
  name = "${local.ssm_prefix}/atlas_pl_vpce_id"
}

data "aws_ssm_parameter" "shared_atlas_pl_vpce_dns_name" {
  name = "${local.ssm_prefix}/atlas_pl_vpce_dns_name"
}

locals {
  # SSM data sources mark `.value` sensitive by default (intended for secrets).
  # Our values are infrastructure identifiers (VPC ID, subnet IDs, VPCE DNS),
  # not secrets, so we wrap with nonsensitive() to keep them usable in tags,
  # outputs, and downstream module inputs.
  shared_vpc_id             = nonsensitive(data.aws_ssm_parameter.shared_vpc_id.value)
  shared_vpc_cidr           = nonsensitive(data.aws_ssm_parameter.shared_vpc_cidr.value)
  shared_public_subnet_ids  = split(",", nonsensitive(data.aws_ssm_parameter.shared_public_subnet_ids.value))
  shared_private_subnet_ids = split(",", nonsensitive(data.aws_ssm_parameter.shared_private_subnet_ids.value))
  shared_atlas_pl_vpce_id   = nonsensitive(data.aws_ssm_parameter.shared_atlas_pl_vpce_id.value)
  shared_vpce_dns_name      = nonsensitive(data.aws_ssm_parameter.shared_atlas_pl_vpce_dns_name.value)
}

# ══════════════════════════════════════════════════════════════════════════════
# MongoDB Atlas — M10 cluster + database user
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
# Bedrock Knowledge Base (uses Atlas public SRV for ingestion configuration)
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

  # Explicit dep on the full Atlas module (not just cluster) so ensure_collection
  # runs AFTER the DB user is created — mongo_host alone only depends on the cluster.
  depends_on = [module.mongodb_atlas]
}

# ══════════════════════════════════════════════════════════════════════════════
# ECR — Docker repos for API + UI
# ══════════════════════════════════════════════════════════════════════════════
module "ecr" {
  source       = "../../modules/ecr"
  project_name = var.project_name
  environment  = var.environment
}

# ══════════════════════════════════════════════════════════════════════════════
# Cognito — User Pool + App Client (used by AgentCore Gateway JWT auth)
# ══════════════════════════════════════════════════════════════════════════════
module "cognito" {
  source       = "../../modules/cognito"
  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
}

# ══════════════════════════════════════════════════════════════════════════════
# EC2 — t3.medium + Elastic IP in shared public subnet, SSM enabled, no SSH
# ══════════════════════════════════════════════════════════════════════════════
module "ec2" {
  source = "../../modules/ec2"

  project_name     = var.project_name
  environment      = var.environment
  aws_region       = var.aws_region
  vpc_id           = local.shared_vpc_id
  public_subnet_id = local.shared_public_subnet_ids[0]
  instance_type    = var.ec2_instance_type
  key_pair_name    = var.ec2_key_pair_name
  ecr_api_image    = "${module.ecr.api_repository_url}:latest"
  ecr_ui_image     = "${module.ecr.ui_repository_url}:latest"
  ecr_registry     = "${module.ecr.registry_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

# ══════════════════════════════════════════════════════════════════════════════
# Atlas cluster DNS — per-cluster Route 53 private zone pointing at the
# shared Atlas Interface VPCE (envs/network owns the VPCE itself).
# ══════════════════════════════════════════════════════════════════════════════
module "atlas_cluster_dns" {
  source = "../../modules/atlas-cluster-dns"

  project_name   = var.project_name
  environment    = var.environment
  vpc_id         = local.shared_vpc_id
  atlas_srv_host = module.mongodb_atlas.mongo_host
  vpce_dns_name  = local.shared_vpce_dns_name
}

# ══════════════════════════════════════════════════════════════════════════════
# Lambda MongoDB MCP — enabled (SCP lifted on account 483874864688)
# Replaces the EC2 mongodb-mcp.service sidecar. Invoked by AgentCore Gateway.
# Runs in private subnets; reaches Atlas via PrivateLink Route53 zone.
# See Docs/adr/0001-mcp-on-ec2-not-lambda.md (updated).
# ══════════════════════════════════════════════════════════════════════════════
module "lambda_mcp" {
  source = "../../modules/lambda-mcp"

  aws_region           = var.aws_region
  project_name         = var.project_name
  environment          = var.environment
  vpc_id               = local.shared_vpc_id
  private_subnet_ids   = local.shared_private_subnet_ids
  mongodb_uri          = module.mongodb_atlas.connection_string
  mongodb_db           = var.atlas_db_name
  allow_write          = var.mongodb_allow_write
  lambda_source_dir    = "${path.module}/../../../../lambda/mongodb-mcp"
  artifact_bucket_name = data.aws_s3_bucket.shared.id
  artifact_key_prefix  = var.lambda_artifact_key_prefix

  # No explicit dep on shared Atlas-PL needed: it's resolved via SSM lookup,
  # and SSM ParameterNotFound surfaces immediately at plan-time if envs/network
  # hasn't been applied yet.
  depends_on = [module.atlas_cluster_dns]
}

# ══════════════════════════════════════════════════════════════════════════════
# AgentCore Memory — session + long-term memory store
# ══════════════════════════════════════════════════════════════════════════════
module "agentcore_memory" {
  source = "../../modules/agentcore-memory"

  aws_region        = var.aws_region
  project_name      = var.project_name
  environment       = var.environment
  event_expiry_days = var.agentcore_memory_expiry_days
  tags              = local.common_tags
}

# ══════════════════════════════════════════════════════════════════════════════
# AgentCore Gateway — MCP endpoint for agents (JWT auth via Cognito)
#
# Deployed WITHOUT a Lambda target for now (SCP blocks lambda:* — see ADR 0001).
# The Gateway itself is provisioned so agent code can still authenticate and
# discover tools; targets can be registered later (OpenAPI target pointing at
# the EC2 MCP over HTTPS, or the Lambda target once the SCP is lifted).
#
# Today, tool invocations don't go through the Gateway — the API talks to the
# mongodb-mcp.service on EC2 (loopback :8080) directly. See deploy.sh for
# how .env.live sets MCP_SERVER_URL.
# ══════════════════════════════════════════════════════════════════════════════
module "agentcore_gateway" {
  source = "../../modules/agentcore-gateway"

  aws_region            = var.aws_region
  project_name          = var.project_name
  environment           = var.environment
  lambda_function_arn   = module.lambda_mcp.function_arn
  create_lambda_target  = true
  cognito_user_pool_id  = module.cognito.user_pool_id
  cognito_app_client_id = module.cognito.user_pool_client_id
  tags                  = local.common_tags

  depends_on = [module.cognito, module.lambda_mcp]
}

# ══════════════════════════════════════════════════════════════════════════════
# ECR — agent-runtime repo (ARM64 image, separate from API/UI)
# ══════════════════════════════════════════════════════════════════════════════
resource "aws_ecr_repository" "agent_runtime" {
  count                = var.agentcore_runtime_deployment_mode == "container" ? 1 : 0
  name                 = "${var.project_name}-agent-runtime-${var.environment}"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "agent_runtime" {
  count      = var.agentcore_runtime_deployment_mode == "container" ? 1 : 0
  repository = aws_ecr_repository.agent_runtime[0].name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 }
      action       = { type = "expire" }
    }]
  })
}

# ══════════════════════════════════════════════════════════════════════════════
# AgentCore Agent Runtime — 4 runtimes (orchestrator + 3 specialists)
# All share one ARM64 image; AGENT_ID decides runtime behavior.
# Static env vars only; deploy.sh injects dynamic vars and specialist ARNs.
# ══════════════════════════════════════════════════════════════════════════════
module "acr_troubleshooting" {
  source = "../../modules/agentcore-agent-runtime"

  aws_region              = var.aws_region
  project_name            = var.project_name
  environment             = var.environment
  account_id              = data.aws_caller_identity.current.account_id
  network_mode            = "PUBLIC"
  runtime_name            = "${var.project_name}-troubleshooting-${var.environment}"
  deployment_mode         = var.agentcore_runtime_deployment_mode
  container_uri           = var.agentcore_runtime_deployment_mode == "container" ? "${local.agentcore_runtime_repo_url}:latest" : ""
  code_artifact_bucket    = data.aws_s3_bucket.shared.id
  code_artifact_prefix    = var.agentcore_code_artifact_prefix
  code_runtime            = "NODE_22"
  code_entry_point        = local.agentcore_code_entrypoint
  lambda_mcp_function_arn = module.lambda_mcp.function_arn
  kb_secret_name_prefix   = module.bedrock_kb.atlas_secret_name

  environment_variables = {
    AWS_REGION               = var.aws_region
    AGENT_ID                 = "troubleshooting"
    CHAT_MODE                = "live"
    TOOL_HOSTING_MODE        = "lambda"
    LAMBDA_MCP_FUNCTION_NAME = module.lambda_mcp.function_name
    LOG_LEVEL                = "info"
  }

  tags = local.common_tags

  depends_on = [
    aws_ecr_repository.agent_runtime,
    module.agentcore_gateway,
    module.agentcore_memory,
  ]
}

module "acr_order_management" {
  source = "../../modules/agentcore-agent-runtime"

  aws_region              = var.aws_region
  project_name            = var.project_name
  environment             = var.environment
  account_id              = data.aws_caller_identity.current.account_id
  network_mode            = "PUBLIC"
  runtime_name            = "${var.project_name}-order-management-${var.environment}"
  deployment_mode         = var.agentcore_runtime_deployment_mode
  container_uri           = var.agentcore_runtime_deployment_mode == "container" ? "${local.agentcore_runtime_repo_url}:latest" : ""
  code_artifact_bucket    = data.aws_s3_bucket.shared.id
  code_artifact_prefix    = var.agentcore_code_artifact_prefix
  code_runtime            = "NODE_22"
  code_entry_point        = local.agentcore_code_entrypoint
  lambda_mcp_function_arn = module.lambda_mcp.function_arn
  kb_secret_name_prefix   = module.bedrock_kb.atlas_secret_name

  environment_variables = {
    AWS_REGION               = var.aws_region
    AGENT_ID                 = "order-management"
    CHAT_MODE                = "live"
    TOOL_HOSTING_MODE        = "lambda"
    LAMBDA_MCP_FUNCTION_NAME = module.lambda_mcp.function_name
    LOG_LEVEL                = "info"
  }

  tags = local.common_tags

  depends_on = [
    aws_ecr_repository.agent_runtime,
    module.agentcore_gateway,
    module.agentcore_memory,
  ]
}

module "acr_product_recommendation" {
  source = "../../modules/agentcore-agent-runtime"

  aws_region              = var.aws_region
  project_name            = var.project_name
  environment             = var.environment
  account_id              = data.aws_caller_identity.current.account_id
  network_mode            = "PUBLIC"
  runtime_name            = "${var.project_name}-product-recommendation-${var.environment}"
  deployment_mode         = var.agentcore_runtime_deployment_mode
  container_uri           = var.agentcore_runtime_deployment_mode == "container" ? "${local.agentcore_runtime_repo_url}:latest" : ""
  code_artifact_bucket    = data.aws_s3_bucket.shared.id
  code_artifact_prefix    = var.agentcore_code_artifact_prefix
  code_runtime            = "NODE_22"
  code_entry_point        = local.agentcore_code_entrypoint
  lambda_mcp_function_arn = module.lambda_mcp.function_arn
  kb_secret_name_prefix   = module.bedrock_kb.atlas_secret_name

  environment_variables = {
    AWS_REGION               = var.aws_region
    AGENT_ID                 = "product-recommendation"
    CHAT_MODE                = "live"
    TOOL_HOSTING_MODE        = "lambda"
    LAMBDA_MCP_FUNCTION_NAME = module.lambda_mcp.function_name
    LOG_LEVEL                = "info"
  }

  tags = local.common_tags

  depends_on = [
    aws_ecr_repository.agent_runtime,
    module.agentcore_gateway,
    module.agentcore_memory,
  ]
}

module "acr_orchestrator" {
  source = "../../modules/agentcore-agent-runtime"

  aws_region              = var.aws_region
  project_name            = var.project_name
  environment             = var.environment
  account_id              = data.aws_caller_identity.current.account_id
  network_mode            = "PUBLIC"
  runtime_name            = "${var.project_name}-orchestrator-${var.environment}"
  deployment_mode         = var.agentcore_runtime_deployment_mode
  container_uri           = var.agentcore_runtime_deployment_mode == "container" ? "${local.agentcore_runtime_repo_url}:latest" : ""
  code_artifact_bucket    = data.aws_s3_bucket.shared.id
  code_artifact_prefix    = var.agentcore_code_artifact_prefix
  code_runtime            = "NODE_22"
  code_entry_point        = local.agentcore_code_entrypoint
  lambda_mcp_function_arn = module.lambda_mcp.function_arn
  kb_secret_name_prefix   = module.bedrock_kb.atlas_secret_name

  environment_variables = {
    AWS_REGION               = var.aws_region
    AGENT_ID                 = "orchestrator"
    CHAT_MODE                = "live"
    TOOL_HOSTING_MODE        = "lambda"
    LAMBDA_MCP_FUNCTION_NAME = module.lambda_mcp.function_name
    LOG_LEVEL                = "info"
  }

  tags = local.common_tags

  depends_on = [
    aws_ecr_repository.agent_runtime,
    module.agentcore_gateway,
    module.agentcore_memory,
    module.acr_troubleshooting,
    module.acr_order_management,
    module.acr_product_recommendation,
  ]
}

# ══════════════════════════════════════════════════════════════════════════════
# Voyage AI SageMaker — optional; only when Marketplace ARN is set
# ══════════════════════════════════════════════════════════════════════════════
module "voyage_sagemaker" {
  source = "../../modules/voyage-sagemaker"
  count  = var.voyage_model_package_arn != "" ? 1 : 0

  aws_region               = var.aws_region
  project_name             = var.project_name
  environment              = var.environment
  voyage_model_package_arn = var.voyage_model_package_arn
  instance_type            = var.voyage_instance_type
}

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch — log groups for API, MCP, AgentCore
# ══════════════════════════════════════════════════════════════════════════════
module "cloudwatch" {
  source         = "../../modules/cloudwatch"
  project_name   = var.project_name
  environment    = var.environment
  retention_days = var.log_retention_days
}
