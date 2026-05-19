terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws          = { source = "hashicorp/aws", version = ">= 6.27, < 7.0" }
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

  # Forward-reference safe: returns the Voyage SageMaker endpoint ARN when the
  # voyage_sagemaker module was instantiated (var.voyage_model_package_arn != "")
  # and "" otherwise. Each agent runtime conditionally adds sagemaker:InvokeEndpoint
  # only when this is non-empty, so deployments without a Voyage Marketplace
  # subscription do not get extra SageMaker permissions.
  voyage_sagemaker_endpoint_arn = length(module.voyage_sagemaker) > 0 ? module.voyage_sagemaker[0].endpoint_arn : ""

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

data "aws_vpc" "shared" {
  id = local.shared_vpc_id
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

  atlas_project_id        = var.atlas_project_id
  cluster_name            = "${var.project_name}-${var.environment}"
  db_name                 = var.atlas_db_name
  db_username             = var.atlas_db_user
  db_password             = var.atlas_db_password
  project_tag             = var.project_name
  privatelink_endpoint_id = local.shared_atlas_pl_vpce_id
}

# Atlas Search indexes that belong to application data (`products`,
# `troubleshooting_docs`, `agent_memory_facts`, `chat_messages`) are reconciled
# through the idempotent db-seeding script. This keeps collection/index bootstraps
# together and avoids Terraform state drift for indexes also needed by local
# seed workflows.
resource "null_resource" "seed_mongodb_indexes" {
  triggers = {
    cluster_name      = module.mongodb_atlas.cluster_name
    db_name           = var.atlas_db_name
    seed_indexes_sha1 = filesha1("${path.module}/../../../../db-seeding/seed-indexes.ts")
  }

  provisioner "local-exec" {
    command = "bun ${path.module}/../../../../db-seeding/seed-indexes.ts"

    environment = {
      MONGODB_URI                   = module.mongodb_atlas.connection_string
      MONGODB_DB                    = var.atlas_db_name
      EMBEDDING_DIMENSIONS          = "1024"
      WAIT_FOR_ATLAS_SEARCH_INDEXES = "1"
    }
  }

  depends_on = [module.mongodb_atlas]
}

# ══════════════════════════════════════════════════════════════════════════════
# Bedrock KB PrivateLink (CLIENT_REVIEW P1-6 Option A — opt-in)
# Provisions an NLB + VPC Endpoint Service so Bedrock-managed ingestion
# connects to Atlas via AWS PrivateLink instead of the public SRV hostname.
# Disabled by default — see var.enable_kb_privatelink.
# ══════════════════════════════════════════════════════════════════════════════
module "bedrock_kb_privatelink" {
  count  = var.enable_kb_privatelink ? 1 : 0
  source = "../../modules/bedrock-kb-privatelink"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = local.shared_vpc_id
  private_subnet_ids = local.shared_private_subnet_ids
  atlas_vpce_id      = local.shared_atlas_pl_vpce_id
  atlas_ports        = module.mongodb_atlas.privatelink_ports
  tags               = local.common_tags
}

# ══════════════════════════════════════════════════════════════════════════════
# Bedrock Knowledge Base
# Default: Atlas public SRV for ingestion (P1-6 Option B, documented exception).
# When var.enable_kb_privatelink = true, the bedrock-kb-privatelink module
# above produces an endpoint_service_name and Bedrock routes ingestion through
# the NLB → Atlas VPCE path (P1-6 Option A, SoW-aligned PrivateLink end-to-end).
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
  kb_endpoint_host   = var.enable_kb_privatelink ? module.mongodb_atlas.privatelink_srv_host : ""
  atlas_db_user      = var.atlas_db_user
  atlas_db_password  = var.atlas_db_password
  atlas_db_name      = var.atlas_db_name

  kb_iam_role_name         = var.kb_iam_role_name
  embed_model_id           = var.embed_model_id
  kb_docs_path             = "${path.module}/../../../kb-docs"
  ensure_collection_script = "${path.module}/../../../../db-seeding/ensure-collection.ts"

  endpoint_service_name = (
    var.enable_kb_privatelink && length(module.bedrock_kb_privatelink) > 0
    ? module.bedrock_kb_privatelink[0].endpoint_service_name
    : ""
  )

  common_tags = local.common_tags

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
# MongoDB Atlas Prometheus credentials (Phase 4) — only created when
# enable_atlas_metrics=true. Holds the username/password/host JSON that the
# ADOT collector reads at boot to scrape the Atlas Prometheus endpoint.
# ══════════════════════════════════════════════════════════════════════════════
resource "aws_secretsmanager_secret" "atlas_prometheus" {
  count                   = var.enable_atlas_metrics ? 1 : 0
  name                    = "${var.project_name}-atlas-prometheus-${var.environment}"
  description             = "MongoDB Atlas Prometheus scrape credentials for the ADOT collector"
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "atlas_prometheus" {
  count     = var.enable_atlas_metrics ? 1 : 0
  secret_id = aws_secretsmanager_secret.atlas_prometheus[0].id
  secret_string = jsonencode({
    username = var.atlas_prom_username
    password = var.atlas_prom_password
    host     = var.atlas_prom_host
  })
}

# ══════════════════════════════════════════════════════════════════════════════
# ADOT Collector sidecar (Phase 2) — runs on the EC2 box, signs SigV4 outbound
# to AWS OTLP endpoints. Apps speak plain OTLP to 127.0.0.1:4318.
#
# enable_atlas_metrics + atlas_secret_arn are wired in Phase 4; default off
# so Phase 2 can ship independently.
# ══════════════════════════════════════════════════════════════════════════════
module "adot_collector" {
  count  = var.enable_adot_collector ? 1 : 0
  source = "../../modules/adot-collector"

  project_name              = var.project_name
  environment               = var.environment
  aws_region                = var.aws_region
  shared_bucket_name        = data.aws_s3_bucket.shared.id
  otel_log_group_name       = "/${var.project_name}/${var.environment}/otel"
  otel_retention_days       = var.log_retention_days
  enable_atlas_metrics      = var.enable_atlas_metrics
  atlas_scrape_interval_sec = var.atlas_scrape_interval_sec
  atlas_secret_arn          = var.enable_atlas_metrics ? aws_secretsmanager_secret.atlas_prometheus[0].arn : ""
  tags                      = local.common_tags
}

# ══════════════════════════════════════════════════════════════════════════════
# EC2 — t3.medium + Elastic IP in shared public subnet, SSM enabled, no SSH
# ══════════════════════════════════════════════════════════════════════════════
module "ec2" {
  source = "../../modules/ec2"

  project_name          = var.project_name
  environment           = var.environment
  aws_region            = var.aws_region
  vpc_id                = local.shared_vpc_id
  public_subnet_id      = local.shared_public_subnet_ids[0]
  instance_type         = var.ec2_instance_type
  key_pair_name         = var.ec2_key_pair_name
  ecr_api_image         = "${module.ecr.api_repository_url}:latest"
  ecr_ui_image          = "${module.ecr.ui_repository_url}:latest"
  ecr_registry          = "${module.ecr.registry_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  cw_log_group_api      = module.cloudwatch.api_log_group_name
  cw_log_group_ui       = module.cloudwatch.ui_log_group_name
  adot_collector_image  = var.adot_collector_image
  adot_config_s3_bucket = var.enable_adot_collector ? module.adot_collector[0].config_s3_bucket : ""
  adot_config_s3_key    = var.enable_adot_collector ? module.adot_collector[0].config_s3_key : ""
  adot_config_etag      = var.enable_adot_collector ? module.adot_collector[0].config_etag : ""
  otel_sample_ratio     = var.otel_sample_ratio
  atlas_prom_secret_arn = var.enable_atlas_metrics ? aws_secretsmanager_secret.atlas_prometheus[0].arn : ""
}

# ══════════════════════════════════════════════════════════════════════════════
# Atlas PrivateLink DNS — per-cluster Route 53 private zone pointing at the
# shared Atlas Interface VPCE (envs/network owns the VPCE itself). This is
# the per-cluster DNS half of the Atlas PrivateLink setup; the regional VPCE
# half lives in modules/atlas-privatelink/.
# ══════════════════════════════════════════════════════════════════════════════
module "atlas_privatelink_dns" {
  source = "../../modules/atlas-privatelink-dns"

  project_name   = var.project_name
  environment    = var.environment
  vpc_id         = local.shared_vpc_id
  atlas_srv_host = module.mongodb_atlas.mongo_host
  vpce_dns_name  = local.shared_vpce_dns_name
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
# ECR — mongodb-mcp runtime repo (ARM64 image, separate from agent-runtime)
# Hosts the AgentCore-Runtime-resident MongoDB MCP server. After CLIENT_REVIEW
# Phase 7e the legacy Lambda host has been deleted; this runtime is the only
# tool host wired into the AgentCore Gateway (P1-1 + P1-2 satisfied).
# ══════════════════════════════════════════════════════════════════════════════
resource "aws_ecr_repository" "mongodb_mcp_runtime" {
  name                 = "${var.project_name}-mongodb-mcp-${var.environment}"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "mongodb_mcp_runtime" {
  repository = aws_ecr_repository.mongodb_mcp_runtime.name
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
# Security group for the mongodb-mcp AgentCore Runtime (VPC mode)
# Egress: TLS to Atlas mongos on 27017 plus the dynamic mongod listener range
# Atlas allocates per cluster (1024-65535).
# ══════════════════════════════════════════════════════════════════════════════
resource "aws_security_group" "mongodb_mcp_runtime" {
  name        = "${var.project_name}-sg-mcp-runtime-${var.environment}"
  description = "AgentCore Runtime: mongodb-mcp - outbound to Atlas PrivateLink"
  vpc_id      = local.shared_vpc_id

  egress {
    description = "MongoDB TLS to Atlas PrivateLink"
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTPS for AWS service calls (CloudWatch Logs, etc.)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Atlas PrivateLink mongod listener ports (Atlas allocates dynamically per cluster)"
    from_port   = 1024
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-mcp-runtime-${var.environment}"
  }
}

# AgentCore Runtime VPC-mode container agents periodically pull their image from
# ECR and emit logs to CloudWatch. The shared private subnets do not have NAT, so
# these endpoints are required for the mongodb-mcp runtime to cold-start and log.
#
# The Interface endpoints below set `private_dns_enabled = true`, which hijacks
# the public ECR/Logs hostnames for the WHOLE VPC. That means any client in the
# VPC — not just the mongodb-mcp runtime — that resolves
# `api.ecr.us-east-1.amazonaws.com` (etc.) is routed to these VPCE ENIs. The
# EC2 host in the public subnet is the most important other consumer: its
# `docker pull` calls must reach the VPCE on 443, otherwise they time out
# despite the IGW route. We therefore grant ingress from each known consumer
# SG (mongodb-mcp runtime + EC2) explicitly rather than opening the whole VPC
# CIDR — keeps the surface narrow and audit-friendly.
resource "aws_security_group" "agentcore_runtime_vpce" {
  name        = "${var.project_name}-sg-agentcore-vpce-${var.environment}"
  description = "Interface VPC endpoints used by AgentCore VPC runtimes"
  vpc_id      = local.shared_vpc_id

  ingress {
    description = "HTTPS from VPC clients that need ECR/Logs (mongodb-mcp runtime + EC2 host docker pulls)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    security_groups = [
      aws_security_group.mongodb_mcp_runtime.id,
      module.ec2.security_group_id,
    ]
  }

  egress {
    description = "Endpoint return traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-sg-agentcore-vpce-${var.environment}"
  })
}

resource "aws_vpc_endpoint" "agentcore_runtime_ecr_api" {
  count = var.create_agentcore_runtime_vpc_endpoints ? 1 : 0

  vpc_id              = local.shared_vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.shared_private_subnet_ids
  security_group_ids  = [aws_security_group.agentcore_runtime_vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpce-ecr-api-${var.environment}"
  })
}

resource "aws_vpc_endpoint" "agentcore_runtime_ecr_dkr" {
  count = var.create_agentcore_runtime_vpc_endpoints ? 1 : 0

  vpc_id              = local.shared_vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.shared_private_subnet_ids
  security_group_ids  = [aws_security_group.agentcore_runtime_vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpce-ecr-dkr-${var.environment}"
  })
}

resource "aws_vpc_endpoint" "agentcore_runtime_logs" {
  count = var.create_agentcore_runtime_vpc_endpoints ? 1 : 0

  vpc_id              = local.shared_vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.shared_private_subnet_ids
  security_group_ids  = [aws_security_group.agentcore_runtime_vpce.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpce-logs-${var.environment}"
  })
}

resource "aws_vpc_endpoint" "agentcore_runtime_s3" {
  count = var.create_agentcore_runtime_vpc_endpoints ? 1 : 0

  vpc_id            = local.shared_vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_vpc.shared.main_route_table_id]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpce-s3-agentcore-${var.environment}"
  })
}

data "aws_vpc_endpoint" "existing_agentcore_runtime_ecr_api" {
  count = var.create_agentcore_runtime_vpc_endpoints ? 0 : 1

  vpc_id       = local.shared_vpc_id
  service_name = "com.amazonaws.${var.aws_region}.ecr.api"
}

data "aws_vpc_endpoint" "existing_agentcore_runtime_ecr_dkr" {
  count = var.create_agentcore_runtime_vpc_endpoints ? 0 : 1

  vpc_id       = local.shared_vpc_id
  service_name = "com.amazonaws.${var.aws_region}.ecr.dkr"
}

data "aws_vpc_endpoint" "existing_agentcore_runtime_logs" {
  count = var.create_agentcore_runtime_vpc_endpoints ? 0 : 1

  vpc_id       = local.shared_vpc_id
  service_name = "com.amazonaws.${var.aws_region}.logs"
}

locals {
  existing_agentcore_runtime_vpce_security_group_ids = var.create_agentcore_runtime_vpc_endpoints ? [] : distinct(flatten([
    data.aws_vpc_endpoint.existing_agentcore_runtime_ecr_api[0].security_group_ids,
    data.aws_vpc_endpoint.existing_agentcore_runtime_ecr_dkr[0].security_group_ids,
    data.aws_vpc_endpoint.existing_agentcore_runtime_logs[0].security_group_ids,
  ]))
  existing_agentcore_runtime_vpce_access_pairs = var.create_agentcore_runtime_vpc_endpoints ? {} : merge([
    for endpoint_sg_id in local.existing_agentcore_runtime_vpce_security_group_ids : {
      for source_sg_id in [
        module.ec2.security_group_id,
        aws_security_group.mongodb_mcp_runtime.id,
        ] : "${endpoint_sg_id}-${source_sg_id}" => {
        endpoint_sg_id = endpoint_sg_id
        source_sg_id   = source_sg_id
      }
    }
  ]...)
}

resource "null_resource" "existing_agentcore_vpce_access" {
  for_each = local.existing_agentcore_runtime_vpce_access_pairs

  triggers = {
    endpoint_sg_id = each.value.endpoint_sg_id
    source_sg_id   = each.value.source_sg_id
    region         = var.aws_region
  }

  provisioner "local-exec" {
    command = <<-EOT
      set +e
      OUT=$(aws ec2 authorize-security-group-ingress \
        --region '${var.aws_region}' \
        --group-id '${each.value.endpoint_sg_id}' \
        --protocol tcp \
        --port 443 \
        --source-group '${each.value.source_sg_id}' 2>&1)
      RC=$?
      if [ "$RC" -eq 0 ] || echo "$OUT" | grep -q 'InvalidPermission.Duplicate'; then
        exit 0
      fi
      echo "$OUT" >&2
      exit "$RC"
    EOT
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# AgentCore Runtime — mongodb-mcp MCP server
#
# Hosts the Streamable-HTTP MCP server defined under mcp-runtimes/mongodb-mcp/.
# Network mode = VPC so the runtime can reach Atlas through the existing
# PrivateLink VPCE (preserves the runtime PrivateLink claim). serverProtocol
# is MCP per the AgentCore MCP runtime contract:
# https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-mcp.html
# ══════════════════════════════════════════════════════════════════════════════
locals {
  mongodb_mcp_runtime_image = "${aws_ecr_repository.mongodb_mcp_runtime.repository_url}:latest"
}

module "mongodb_mcp_runtime" {
  source = "../../modules/agentcore-agent-runtime"

  aws_region             = var.aws_region
  project_name           = var.project_name
  environment            = var.environment
  account_id             = data.aws_caller_identity.current.account_id
  network_mode           = "VPC"
  vpc_subnet_ids         = local.shared_private_subnet_ids
  vpc_security_group_ids = [aws_security_group.mongodb_mcp_runtime.id]
  runtime_name           = "${var.project_name}_mongodb_mcp_${var.environment}"
  deployment_mode        = "container"
  container_uri          = local.mongodb_mcp_runtime_image
  server_protocol        = "MCP"

  environment_variables = {
    AWS_REGION          = var.aws_region
    LOG_LEVEL           = "info"
    MONGODB_URI         = module.mongodb_atlas.privatelink_connection_string != "" ? module.mongodb_atlas.privatelink_connection_string : module.mongodb_atlas.connection_string
    MONGODB_DB          = var.atlas_db_name
    MONGODB_ALLOW_WRITE = var.mongodb_allow_write ? "1" : "0"
  }

  tags = local.common_tags

  depends_on = [
    aws_ecr_repository.mongodb_mcp_runtime,
    aws_vpc_endpoint.agentcore_runtime_ecr_api,
    aws_vpc_endpoint.agentcore_runtime_ecr_dkr,
    aws_vpc_endpoint.agentcore_runtime_logs,
    aws_vpc_endpoint.agentcore_runtime_s3,
    null_resource.existing_agentcore_vpce_access,
    module.atlas_privatelink_dns,
  ]
}

# Bedrock AgentCore Runtime invocation URL contract (used as the Gateway's
# mcpServer endpoint):
#   https://bedrock-agentcore.<region>.amazonaws.com/runtimes/<URL-encoded ARN>/invocations?qualifier=DEFAULT
# Terraform's urlencode() handles the slashes/colons in the ARN.
locals {
  mongodb_mcp_runtime_arn      = module.mongodb_mcp_runtime.runtime_arn
  mongodb_mcp_runtime_endpoint = "https://bedrock-agentcore.${var.aws_region}.amazonaws.com/runtimes/${urlencode(local.mongodb_mcp_runtime_arn)}/invocations?qualifier=DEFAULT"
}

# ══════════════════════════════════════════════════════════════════════════════
# AgentCore Gateway — Cognito-authenticated MCP endpoint
#
# Routes MCP tool calls (mongodb_query, mongodb_vector_search, etc.) through
# the gateway to the mongodb_mcp_runtime AgentCore Runtime via Streamable-HTTP.
# The gateway IAM role is granted bedrock-agentcore:InvokeAgentRuntime on the
# runtime ARN (see modules/agentcore-gateway/main.tf).
# Endpoint format: https://bedrock-agentcore.<region>.amazonaws.com/runtimes
#   /<url-encoded-arn>/invocations?qualifier=DEFAULT
# ══════════════════════════════════════════════════════════════════════════════
module "agentcore_gateway" {
  source = "../../modules/agentcore-gateway"

  aws_region               = var.aws_region
  project_name             = var.project_name
  environment              = var.environment
  create_lambda_target     = false
  create_mcp_server_target = true
  mcp_server_endpoint      = local.mongodb_mcp_runtime_endpoint
  mcp_server_runtime_arn   = local.mongodb_mcp_runtime_arn
  cognito_user_pool_id     = module.cognito.user_pool_id
  cognito_app_client_id    = module.cognito.user_pool_client_id
  tags                     = local.common_tags

  depends_on = [
    module.cognito,
    module.mongodb_mcp_runtime,
  ]
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
# AgentCore Agent Runtime — specialists (for_each) + orchestrator (hardcoded)
#
# Specialists are driven by var.specialist_agents, populated from
# config/agents/*.agent.md by deploy.sh / deploy-agents.sh via
# agents.auto.tfvars.json. Adding a new .agent.md + re-running
# deploy-agents.sh provisions a new runtime automatically. Removing one
# destroys it (requires --allow-destroy in deploy-agents.sh).
#
# The orchestrator is kept hardcoded because it has distinct env-var wiring
# (ORCHESTRATOR_MODE=runtime, AGENTCORE_RUNTIME_ARN_* for each specialist).
# All runtimes share one ARM64 code artifact in S3; AGENT_ID selects behavior.
# ══════════════════════════════════════════════════════════════════════════════
module "acr_specialists" {
  source   = "../../modules/agentcore-agent-runtime"
  for_each = { for a in var.specialist_agents : a.id => a }

  aws_region                    = var.aws_region
  project_name                  = var.project_name
  environment                   = var.environment
  account_id                    = data.aws_caller_identity.current.account_id
  network_mode                  = "PUBLIC"
  runtime_name                  = each.value.runtime_name
  deployment_mode               = var.agentcore_runtime_deployment_mode
  container_uri                 = var.agentcore_runtime_deployment_mode == "container" ? "${local.agentcore_runtime_repo_url}:latest" : ""
  code_artifact_bucket          = data.aws_s3_bucket.shared.id
  code_artifact_prefix          = var.agentcore_code_artifact_prefix
  code_runtime                  = "NODE_22"
  code_entry_point              = local.agentcore_code_entrypoint
  kb_secret_name_prefix         = module.bedrock_kb.atlas_secret_name
  voyage_sagemaker_endpoint_arn = local.voyage_sagemaker_endpoint_arn

  environment_variables = {
    AWS_REGION                = var.aws_region
    AGENT_ID                  = each.key
    LOG_LEVEL                 = "info"
    AGENTCORE_MEMORY_STORE_ID = module.agentcore_memory.memory_id
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

  aws_region                    = var.aws_region
  project_name                  = var.project_name
  environment                   = var.environment
  account_id                    = data.aws_caller_identity.current.account_id
  network_mode                  = "PUBLIC"
  runtime_name                  = "${var.project_name}-orchestrator-${var.environment}"
  deployment_mode               = var.agentcore_runtime_deployment_mode
  container_uri                 = var.agentcore_runtime_deployment_mode == "container" ? "${local.agentcore_runtime_repo_url}:latest" : ""
  code_artifact_bucket          = data.aws_s3_bucket.shared.id
  code_artifact_prefix          = var.agentcore_code_artifact_prefix
  code_runtime                  = "NODE_22"
  code_entry_point              = local.agentcore_code_entrypoint
  kb_secret_name_prefix         = module.bedrock_kb.atlas_secret_name
  voyage_sagemaker_endpoint_arn = local.voyage_sagemaker_endpoint_arn

  environment_variables = {
    AWS_REGION                = var.aws_region
    AGENT_ID                  = "orchestrator"
    LOG_LEVEL                 = "info"
    AGENTCORE_MEMORY_STORE_ID = module.agentcore_memory.memory_id
  }

  tags = local.common_tags

  depends_on = [
    aws_ecr_repository.agent_runtime,
    module.agentcore_gateway,
    module.agentcore_memory,
    module.acr_specialists,
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
  endpoint_name_suffix     = var.voyage_endpoint_name_suffix
}

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch — log groups for API, MCP, AgentCore
# ══════════════════════════════════════════════════════════════════════════════
module "cloudwatch" {
  source             = "../../modules/cloudwatch"
  project_name       = var.project_name
  environment        = var.environment
  api_retention_days = var.log_retention_days
}

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch Generative AI Observability — enables the managed AgentCore Agents
# tab + Model Invocations tab, plus the Transaction Search infrastructure that
# the ADOT sidecar (Phase 2) signs OTLP spans into.
#
# Pass AgentCore memory + gateway IDs so the module wires up service-vended
# log delivery (memory/gateway dashboards stay empty without this).
# ══════════════════════════════════════════════════════════════════════════════
module "cloudwatch_genai" {
  count  = var.enable_genai_observability ? 1 : 0
  source = "../../modules/cloudwatch-genai"

  project_name                    = var.project_name
  environment                     = var.environment
  span_retention_days             = var.span_retention_days
  span_sampling_percent           = var.span_sampling_percent
  enable_transaction_search_toggle = var.enable_transaction_search_toggle
  agentcore_log_retention_days    = var.agentcore_vended_log_retention_days
  # Pass the full ARNs (not ids) so log_delivery_source.resource_arn is
  # partition-aware (arn:aws / arn:aws-gov / arn:aws-cn) and not derived from
  # a hardcoded "arn:aws:bedrock-agentcore:..." prefix.
  agentcore_memories = {
    (module.agentcore_memory.memory_id) = module.agentcore_memory.memory_arn
  }
  agentcore_gateways = {
    (module.agentcore_gateway.gateway_id) = module.agentcore_gateway.gateway_arn
  }
  tags = local.common_tags

  depends_on = [
    module.agentcore_memory,
    module.agentcore_gateway,
  ]
}

# ══════════════════════════════════════════════════════════════════════════════
# Bedrock model invocation logging — account-scoped. Captures per-call
# metadata (modelId, token counts, latency, requestMetadata, error) by default;
# prompt + completion bodies are OFF unless var.log_prompt_bodies is true.
#
# Set var.enable_bedrock_invocation_logging = false when another stack in this
# AWS account already owns the singleton.
# ══════════════════════════════════════════════════════════════════════════════
module "bedrock_invocation_logging" {
  source = "../../modules/bedrock-invocation-logging"

  project_name                = var.project_name
  environment                 = var.environment
  enable                      = var.enable_bedrock_invocation_logging
  log_prompt_bodies           = var.log_prompt_bodies
  log_embedding_bodies        = var.log_embedding_bodies
  retention_days              = var.invocation_retention_days
  data_protection_identifiers = var.data_protection_identifiers
  tags                        = local.common_tags
}

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch Fleet Dashboards + Alarms (Phase 3) — SNS topic, 3 dashboards
# (fleet / mongo / cost), 7 alarms, audit metric filter, query library.
# Wires log groups from cloudwatch + adot-collector + bedrock-invocation-logging
# so a single apply produces a working ops console.
# ══════════════════════════════════════════════════════════════════════════════
module "cloudwatch_fleet_dashboards" {
  count  = var.enable_fleet_dashboards ? 1 : 0
  source = "../../modules/cloudwatch-fleet-dashboards"

  project_name              = var.project_name
  environment               = var.environment
  aws_region                = var.aws_region
  api_log_group_name        = module.cloudwatch.api_log_group_name
  ui_log_group_name         = module.cloudwatch.ui_log_group_name
  invocation_log_group_name     = var.enable_bedrock_invocation_logging ? module.bedrock_invocation_logging.log_group_name : ""
  audit_findings_log_group_name = var.enable_bedrock_invocation_logging ? module.bedrock_invocation_logging.audit_log_group_name : ""
  otel_log_group_name       = var.enable_adot_collector ? module.adot_collector[0].otel_log_group_name : ""
  p99_latency_threshold_ms  = var.p99_latency_threshold_ms
  error_rate_threshold_pct  = var.error_rate_threshold_pct
  throttle_burst_threshold  = var.throttle_burst_threshold
  tags                      = local.common_tags
}

# ══════════════════════════════════════════════════════════════════════════════
# Atlas dashboard + alarms (Phase 4) — consumes the MongoDB/Atlas CloudWatch
# namespace published by the ADOT collector's prometheus -> awsemf pipeline.
# ══════════════════════════════════════════════════════════════════════════════
module "cloudwatch_atlas_dashboard" {
  count  = var.enable_atlas_metrics ? 1 : 0
  source = "../../modules/cloudwatch-atlas-dashboard"

  project_name                 = var.project_name
  environment                  = var.environment
  aws_region                   = var.aws_region
  replication_lag_threshold_ms = var.atlas_replication_lag_threshold_ms
  tags                         = local.common_tags
}
