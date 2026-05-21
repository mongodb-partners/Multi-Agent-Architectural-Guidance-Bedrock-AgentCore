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
  # on Project=<project_name> to find/delete every resource.
  common_tags = {
    Project = var.project_name
  }
  agentcore_code_entrypoint  = ["agent-runtime-code.js"]
  agentcore_runtime_repo_url = var.agentcore_runtime_deployment_mode == "container" ? aws_ecr_repository.agent_runtime[0].repository_url : ""

  # SSM prefix mirrors the network env exactly. Single source of truth for
  # discovering the shared VPC + Atlas connectivity (published by envs/network)
  # AND the shared SageMaker endpoint + log groups + invocation logging targets
  # (published by envs/shared).
  ssm_prefix = "/${var.shared_vpc_name}/${var.aws_region}"

  # Mode booleans used throughout this file. privatelink and peering are
  # mutually exclusive per account — there is no hybrid path. To change modes
  # the operator must run destroy + redeploy.
  is_privatelink_mode = var.network_mode == "privatelink"
  is_peering_mode     = var.network_mode == "peering"
  use_kb_privatelink  = local.is_privatelink_mode && var.enable_kb_privatelink
  use_kb_peering_nlb  = local.is_peering_mode && var.enable_kb_peering

  # Single switch driving downstream wiring of bedrock-kb endpoint_service_name
  # and kb_endpoint_host. "public-srv" means KB ingestion uses Atlas public
  # SRV (still private at TLS+auth, just not at the network layer).
  kb_connectivity_mode = (
    local.use_kb_privatelink ? "privatelink" :
    local.use_kb_peering_nlb ? "peering-nlb" :
    "public-srv"
  )
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

# ── Mode canary — guards against silent mode mixing between deploys ─────────
# envs/network publishes /network_mode every apply. If this env's tfvars say
# 'privatelink' but the canary says 'peering' (or vice versa), the lifecycle
# precondition on local.shared_network_mode below fails the plan with a clear
# remediation message.
data "aws_ssm_parameter" "shared_network_mode" {
  name = "${local.ssm_prefix}/network_mode"
}

# ── PrivateLink-only SSM reads — gated to privatelink mode ──────────────────
# In peering mode the keys don't exist and `aws_ssm_parameter` would fail
# with ParameterNotFound. for_each on a mode-gated set keeps the read off
# when peering is active.
data "aws_ssm_parameter" "shared_atlas_pl_vpce_id" {
  for_each = local.is_privatelink_mode ? toset(["pl"]) : toset([])
  name     = "${local.ssm_prefix}/atlas_pl_vpce_id"
}

data "aws_ssm_parameter" "shared_atlas_pl_vpce_dns_name" {
  for_each = local.is_privatelink_mode ? toset(["pl"]) : toset([])
  name     = "${local.ssm_prefix}/atlas_pl_vpce_dns_name"
}

# ── Peering-only SSM reads — gated to peering mode ──────────────────────────
data "aws_ssm_parameter" "shared_atlas_peering_id" {
  for_each = local.is_peering_mode ? toset(["peering"]) : toset([])
  name     = "${local.ssm_prefix}/atlas_peering_id"
}

data "aws_ssm_parameter" "shared_atlas_container_id" {
  for_each = local.is_peering_mode ? toset(["peering"]) : toset([])
  name     = "${local.ssm_prefix}/atlas_container_id"
}

data "aws_ssm_parameter" "shared_atlas_peering_cidr" {
  for_each = local.is_peering_mode ? toset(["peering"]) : toset([])
  name     = "${local.ssm_prefix}/atlas_peering_cidr"
}

# ══════════════════════════════════════════════════════════════════════════════
# Shared-stack discovery — read SageMaker endpoint name/ARN, the five
# CloudWatch log group names, and the two Bedrock invocation-logging targets
# from SSM (published by envs/shared). If any of these parameters are missing,
# envs/shared has not been applied yet — run deploy-shared.sh first.
#
# Values are stored as "_empty_" sentinel when the corresponding feature is
# disabled (e.g. voyage_model_package_arn unset in the shared stack), so per-
# project logic can distinguish "feature off" from "shared stack not applied".
# ══════════════════════════════════════════════════════════════════════════════
data "aws_ssm_parameter" "shared_voyage_endpoint_name" {
  name = "${local.ssm_prefix}/voyage_sagemaker_endpoint_name"
}

data "aws_ssm_parameter" "shared_voyage_endpoint_arn" {
  name = "${local.ssm_prefix}/voyage_sagemaker_endpoint_arn"
}

data "aws_ssm_parameter" "shared_cw_api_log_group" {
  name = "${local.ssm_prefix}/cw_api_log_group"
}

data "aws_ssm_parameter" "shared_cw_ui_log_group" {
  name = "${local.ssm_prefix}/cw_ui_log_group"
}

data "aws_ssm_parameter" "shared_cw_mcp_log_group" {
  name = "${local.ssm_prefix}/cw_mcp_log_group"
}

data "aws_ssm_parameter" "shared_cw_agentcore_log_group" {
  name = "${local.ssm_prefix}/cw_agentcore_log_group"
}

data "aws_ssm_parameter" "shared_cw_otel_log_group" {
  name = "${local.ssm_prefix}/cw_otel_log_group"
}

data "aws_ssm_parameter" "shared_cw_otel_atlas_log_group" {
  name = "${local.ssm_prefix}/cw_otel_atlas_log_group"
}

data "aws_ssm_parameter" "shared_bedrock_invocation_log_group" {
  name = "${local.ssm_prefix}/bedrock_invocation_log_group"
}

data "aws_ssm_parameter" "shared_bedrock_audit_log_group" {
  name = "${local.ssm_prefix}/bedrock_audit_log_group"
}

data "aws_vpc" "shared" {
  id = local.shared_vpc_id
}

locals {
  # SSM data sources mark `.value` sensitive by default (intended for secrets).
  # Our values are infrastructure identifiers (VPC ID, subnet IDs, VPCE DNS,
  # log-group names, SageMaker endpoint), not secrets, so we wrap with
  # nonsensitive() to keep them usable in tags, outputs, and downstream module
  # inputs.
  shared_vpc_id             = nonsensitive(data.aws_ssm_parameter.shared_vpc_id.value)
  shared_vpc_cidr           = nonsensitive(data.aws_ssm_parameter.shared_vpc_cidr.value)
  shared_public_subnet_ids  = split(",", nonsensitive(data.aws_ssm_parameter.shared_public_subnet_ids.value))
  shared_private_subnet_ids = split(",", nonsensitive(data.aws_ssm_parameter.shared_private_subnet_ids.value))
  shared_network_mode       = nonsensitive(data.aws_ssm_parameter.shared_network_mode.value)

  # Mode-gated reads: only populated in the matching mode (the data source is
  # for_each-gated so it doesn't try to read non-existent SSM keys in the
  # other mode).
  shared_atlas_pl_vpce_id   = local.is_privatelink_mode ? nonsensitive(data.aws_ssm_parameter.shared_atlas_pl_vpce_id["pl"].value) : ""
  shared_vpce_dns_name      = local.is_privatelink_mode ? nonsensitive(data.aws_ssm_parameter.shared_atlas_pl_vpce_dns_name["pl"].value) : ""
  shared_atlas_peering_id   = local.is_peering_mode ? nonsensitive(data.aws_ssm_parameter.shared_atlas_peering_id["peering"].value) : ""
  shared_atlas_container_id = local.is_peering_mode ? nonsensitive(data.aws_ssm_parameter.shared_atlas_container_id["peering"].value) : ""
  shared_atlas_peering_cidr = local.is_peering_mode ? nonsensitive(data.aws_ssm_parameter.shared_atlas_peering_cidr["peering"].value) : ""

  # Shared-stack lookups — see comment block above. Treat the "_empty_"
  # sentinel as a real empty value so consumers can keep using
  # `length(...) > 0` checks without special-casing.
  _voyage_endpoint_name_raw   = nonsensitive(data.aws_ssm_parameter.shared_voyage_endpoint_name.value)
  _voyage_endpoint_arn_raw    = nonsensitive(data.aws_ssm_parameter.shared_voyage_endpoint_arn.value)
  shared_voyage_endpoint_name = local._voyage_endpoint_name_raw == "_empty_" ? "" : local._voyage_endpoint_name_raw
  shared_voyage_endpoint_arn  = local._voyage_endpoint_arn_raw == "_empty_" ? "" : local._voyage_endpoint_arn_raw

  shared_cw_api_log_group        = nonsensitive(data.aws_ssm_parameter.shared_cw_api_log_group.value)
  shared_cw_ui_log_group         = nonsensitive(data.aws_ssm_parameter.shared_cw_ui_log_group.value)
  shared_cw_mcp_log_group        = nonsensitive(data.aws_ssm_parameter.shared_cw_mcp_log_group.value)
  shared_cw_agentcore_log_group  = nonsensitive(data.aws_ssm_parameter.shared_cw_agentcore_log_group.value)
  shared_cw_otel_log_group       = nonsensitive(data.aws_ssm_parameter.shared_cw_otel_log_group.value)
  shared_cw_otel_atlas_log_group = nonsensitive(data.aws_ssm_parameter.shared_cw_otel_atlas_log_group.value)

  _bedrock_invocation_log_group_raw   = nonsensitive(data.aws_ssm_parameter.shared_bedrock_invocation_log_group.value)
  _bedrock_audit_log_group_raw        = nonsensitive(data.aws_ssm_parameter.shared_bedrock_audit_log_group.value)
  shared_bedrock_invocation_log_group = local._bedrock_invocation_log_group_raw == "_empty_" ? "" : local._bedrock_invocation_log_group_raw
  shared_bedrock_audit_log_group      = local._bedrock_audit_log_group_raw == "_empty_" ? "" : local._bedrock_audit_log_group_raw

  # Each agent runtime conditionally adds sagemaker:InvokeEndpoint only when
  # this is non-empty, so deployments without a Voyage Marketplace subscription
  # do not get extra SageMaker permissions.
  voyage_sagemaker_endpoint_arn = local.shared_voyage_endpoint_arn
}

# ── Network mode canary — refuse to plan when modes disagree ────────────────
# Catches the case where deploy-project.sh stamps NETWORK_MODE=peering into
# tfvars but envs/network was applied with privatelink (or vice versa). Hard-
# fails at plan time with a remediation message.
check "network_mode_matches_shared" {
  assert {
    condition     = local.shared_network_mode == var.network_mode
    error_message = "NETWORK MODE MISMATCH — envs/ec2 tfvars say '${var.network_mode}' but the network stack at ${local.ssm_prefix}/network_mode says '${local.shared_network_mode}'. Switching connectivity modes requires destroy + redeploy: run ./deploy/scripts/destroy.sh --mode ec2, --mode shared (optional), --mode network in that order, then redeploy with the desired NETWORK_MODE."
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# MongoDB Atlas — M10 cluster + database user
# Mode-aware: PrivateLink mode forwards the shared PL VPCE id (so the
# mongodb-atlas module can emit the privatelink_* connection strings).
# Peering mode forwards the VPC CIDR + network_mode (so the IP access list is
# scoped to the peered VPC and the peering_* outputs are populated).
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
  network_mode            = var.network_mode
  vpc_cidr                = local.shared_vpc_cidr
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
# Only when network_mode='privatelink' AND var.enable_kb_privatelink=true —
# PrivateLink and peering are mutually exclusive at the account level.
# ══════════════════════════════════════════════════════════════════════════════
module "bedrock_kb_privatelink" {
  count  = local.use_kb_privatelink ? 1 : 0
  source = "../../modules/bedrock-kb-privatelink"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  vpc_id             = local.shared_vpc_id
  private_subnet_ids = local.shared_private_subnet_ids
  atlas_vpce_id      = local.shared_atlas_pl_vpce_id
  atlas_ports        = module.mongodb_atlas.privatelink_ports
  tags               = local.common_tags

  depends_on = [module.mongodb_atlas]
}

# ══════════════════════════════════════════════════════════════════════════════
# Bedrock KB peering (EXPERIMENTAL) — NLB-over-peering for KB ingestion
# Only when network_mode='peering' AND var.enable_kb_peering=true. Discovers
# Atlas mongod private peering IPs via SSM dig from the EC2 host, fronts them
# with an NLB and a VPC Endpoint Service so Bedrock can dial Atlas privately.
# See modules/bedrock-kb-peering/README.md — TLS validation is NOT partner-
# validated; if Bedrock's driver rejects the cert the only remediation is to
# destroy + redeploy in privatelink mode.
# ══════════════════════════════════════════════════════════════════════════════
module "bedrock_kb_peering" {
  count  = local.use_kb_peering_nlb ? 1 : 0
  source = "../../modules/bedrock-kb-peering"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  vpc_id             = local.shared_vpc_id
  private_subnet_ids = local.shared_private_subnet_ids

  # Derive the `-pri.mongodb.net` peering host from the standard host instead
  # of reading module.mongodb_atlas.peering_srv_host. That output is sourced
  # from `connection_strings.private_srv` which is `(known after apply)` AND
  # often empty on a fresh deploy until Atlas internally propagates the
  # peering + awsCustomDNS state to the cluster doc (race: cluster created
  # at T=0, DNS enabled at T=20s, Atlas populates private_srv at T=60-120s,
  # but terraform reads cluster state at T=0 and never re-refreshes during
  # the same apply). The naming pattern is contractual per Atlas docs:
  #   standard: <cluster-name>.<project-shard-id>.mongodb.net
  #   peering : <cluster-name>-pri.<project-shard-id>.mongodb.net
  # so we can safely inject `-pri` and avoid the apply-time race.
  atlas_srv_host = replace(module.mongodb_atlas.mongo_host, "/^([^.]+)\\.([^.]+\\.mongodb\\.net)$/", "$1-pri.$2")

  # Used ONLY as a SHA trigger for re-discovery on cluster reissue (see
  # bedrock-kb-peering/main.tf line 79). Use the standard string — always
  # populated. peering_connection_string is empty on fresh apply (same race
  # as peering_srv_host above) and would crash sha1() with an empty input
  # the first time it's evaluated.
  atlas_connection_string = module.mongodb_atlas.connection_string
  cluster_name            = module.mongodb_atlas.cluster_name
  ec2_instance_id         = module.ec2.instance_id
  atlas_peering_cidr      = local.shared_atlas_peering_cidr
  tags                    = local.common_tags

  # EC2 must be SSM-reachable, peering routes must be in place (envs/network
  # owns them), cluster must exist before the SRV lookup makes sense.
  depends_on = [
    module.ec2,
    module.mongodb_atlas,
  ]
}

# ══════════════════════════════════════════════════════════════════════════════
# Bedrock Knowledge Base — 3-arm endpoint switch (mutually exclusive arms)
#   1. privatelink + enable_kb_privatelink=true  → PL NLB endpoint service
#   2. peering     + enable_kb_peering=true       → peering-NLB endpoint service (experimental)
#   3. *           + *=false                      → public SRV (privacy regression)
# ══════════════════════════════════════════════════════════════════════════════
locals {
  kb_endpoint_service_name = (
    local.use_kb_privatelink ? module.bedrock_kb_privatelink[0].endpoint_service_name :
    local.use_kb_peering_nlb ? module.bedrock_kb_peering[0].endpoint_service_name :
    ""
  )

  # kb_endpoint_host: in PL mode we override with the cluster-specific PL SRV
  # so Bedrock's TLS SNI matches the PL cert. In peering mode we leave it
  # empty so Bedrock dials the standard cluster hostname (whose cert SAN
  # includes the standard hostname) through the NLB. In public-SRV mode we
  # also leave it empty so Bedrock uses the default cluster SRV.
  kb_endpoint_host = local.use_kb_privatelink ? module.mongodb_atlas.privatelink_srv_host : ""
}

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
  kb_endpoint_host   = local.kb_endpoint_host
  atlas_db_user      = var.atlas_db_user
  atlas_db_password  = var.atlas_db_password
  atlas_db_name      = var.atlas_db_name

  kb_iam_role_name         = var.kb_iam_role_name
  embed_model_id           = var.embed_model_id
  kb_docs_path             = "${path.module}/../../../kb-docs"
  ensure_collection_script = "${path.module}/../../../../db-seeding/ensure-collection.ts"

  endpoint_service_name = local.kb_endpoint_service_name

  common_tags = local.common_tags

  # Explicit dep on the full Atlas module (not just cluster) so ensure_collection
  # runs AFTER the DB user is created — mongo_host alone only depends on the cluster.
  # When KB PrivateLink is enabled, also wait for NLB target registration
  # (see bedrock-kb-privatelink output depends_on) before CreateKnowledgeBase.
  depends_on = [
    module.mongodb_atlas,
    module.bedrock_kb_privatelink,
  ]
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
  otel_log_group_name       = local.shared_cw_otel_log_group
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
  cw_log_group_api      = local.shared_cw_api_log_group
  cw_log_group_ui       = local.shared_cw_ui_log_group
  adot_collector_image  = var.adot_collector_image
  adot_config_s3_bucket = var.enable_adot_collector ? module.adot_collector[0].config_s3_bucket : ""
  adot_config_s3_key    = var.enable_adot_collector ? module.adot_collector[0].config_s3_key : ""
  adot_config_etag      = var.enable_adot_collector ? module.adot_collector[0].config_etag : ""
  otel_sample_ratio     = var.otel_sample_ratio
  atlas_prom_secret_arn = var.enable_atlas_metrics ? aws_secretsmanager_secret.atlas_prometheus[0].arn : ""
  network_mode          = var.network_mode
  atlas_peering_cidr    = local.shared_atlas_peering_cidr
}

# ══════════════════════════════════════════════════════════════════════════════
# Atlas PrivateLink DNS — per-cluster Route 53 private zone pointing at the
# shared Atlas Interface VPCE. PrivateLink mode only — in peering mode the
# cluster's <name>-pri.mongodb.net SRV resolves to private peering IPs
# natively (when Atlas Private DNS for Peering is enabled), so the per-cluster
# Route 53 zone is unnecessary.
# ══════════════════════════════════════════════════════════════════════════════
module "atlas_privatelink_dns" {
  count  = local.is_privatelink_mode ? 1 : 0
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
  description = "AgentCore Runtime: mongodb-mcp - outbound to Atlas (PrivateLink or peering, per network_mode)"
  vpc_id      = local.shared_vpc_id

  # MongoDB TLS to Atlas — narrowed to atlas_peering_cidr in peering mode for
  # defense-in-depth. In privatelink mode the Atlas VPCE ENIs sit on private
  # IPs that vary, so 0.0.0.0/0 (constrained by VPCE routing) is the only
  # workable option.
  egress {
    description = "MongoDB TLS to Atlas"
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = local.is_peering_mode ? [local.shared_atlas_peering_cidr] : ["0.0.0.0/0"]
  }

  egress {
    description = "HTTPS for AWS service calls (CloudWatch Logs, ECR, etc.)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Atlas allocates mongod listener ports dynamically per cluster in the
  # 1024-65535 range (e.g. 1051, 1052, 1053 for a 3-node M10). Same narrowing
  # logic as port 27017.
  egress {
    description = "Atlas mongod listener ports (dynamic per cluster)"
    from_port   = 1024
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = local.is_peering_mode ? [local.shared_atlas_peering_cidr] : ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-mcp-runtime-${var.environment}"
  }

  lifecycle {
    ignore_changes = [description]
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

# Static for_each keys — endpoint/source SG IDs can be unknown at plan time when
# module.ec2 is being created or replaced; resolve them in the provisioner instead.
locals {
  existing_agentcore_runtime_vpce_access_rules = var.create_agentcore_runtime_vpc_endpoints ? {} : {
    "ecr-api-ec2" = { endpoint = "ecr_api", source = "ec2" }
    "ecr-api-mcp" = { endpoint = "ecr_api", source = "mcp" }
    "ecr-dkr-ec2" = { endpoint = "ecr_dkr", source = "ec2" }
    "ecr-dkr-mcp" = { endpoint = "ecr_dkr", source = "mcp" }
    "logs-ec2"    = { endpoint = "logs", source = "ec2" }
    "logs-mcp"    = { endpoint = "logs", source = "mcp" }
  }
}

resource "null_resource" "existing_agentcore_vpce_access" {
  for_each = local.existing_agentcore_runtime_vpce_access_rules

  depends_on = [
    module.ec2,
    aws_security_group.mongodb_mcp_runtime,
    data.aws_vpc_endpoint.existing_agentcore_runtime_ecr_api,
    data.aws_vpc_endpoint.existing_agentcore_runtime_ecr_dkr,
    data.aws_vpc_endpoint.existing_agentcore_runtime_logs,
  ]

  triggers = {
    rule_key   = each.key
    endpoint   = each.value.endpoint
    source     = each.value.source
    ecr_api_sg = join(",", data.aws_vpc_endpoint.existing_agentcore_runtime_ecr_api[0].security_group_ids)
    ecr_dkr_sg = join(",", data.aws_vpc_endpoint.existing_agentcore_runtime_ecr_dkr[0].security_group_ids)
    logs_sg    = join(",", data.aws_vpc_endpoint.existing_agentcore_runtime_logs[0].security_group_ids)
    ec2_sg     = module.ec2.security_group_id
    mcp_sg     = aws_security_group.mongodb_mcp_runtime.id
    region     = var.aws_region
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      ENDPOINT="${each.value.endpoint}"
      SOURCE="${each.value.source}"
      case "$ENDPOINT" in
        ecr_api) ENDPOINT_SG='${join(",", data.aws_vpc_endpoint.existing_agentcore_runtime_ecr_api[0].security_group_ids)}' ;;
        ecr_dkr) ENDPOINT_SG='${join(",", data.aws_vpc_endpoint.existing_agentcore_runtime_ecr_dkr[0].security_group_ids)}' ;;
        logs)    ENDPOINT_SG='${join(",", data.aws_vpc_endpoint.existing_agentcore_runtime_logs[0].security_group_ids)}' ;;
        *) echo "unknown endpoint $ENDPOINT" >&2; exit 1 ;;
      esac
      case "$SOURCE" in
        ec2) SOURCE_SG='${module.ec2.security_group_id}' ;;
        mcp) SOURCE_SG='${aws_security_group.mongodb_mcp_runtime.id}' ;;
        *) echo "unknown source $SOURCE" >&2; exit 1 ;;
      esac
      # VPCEs attach one SG; take the first if comma-separated.
      ENDPOINT_SG="$${ENDPOINT_SG%%,*}"
      set +e
      OUT=$(aws ec2 authorize-security-group-ingress \
        --region '${var.aws_region}' \
        --group-id "$ENDPOINT_SG" \
        --protocol tcp \
        --port 443 \
        --source-group "$SOURCE_SG" 2>&1)
      RC=$?
      if [ "$RC" -eq 0 ] || echo "$OUT" | grep -q 'InvalidPermission.Duplicate'; then
        exit 0
      fi
      echo "$OUT" >&2
      exit "$RC"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      ENDPOINT="${self.triggers.endpoint}"
      SOURCE="${self.triggers.source}"
      case "$ENDPOINT" in
        ecr_api) ENDPOINT_SG='${self.triggers.ecr_api_sg}' ;;
        ecr_dkr) ENDPOINT_SG='${self.triggers.ecr_dkr_sg}' ;;
        logs)    ENDPOINT_SG='${self.triggers.logs_sg}' ;;
        *) echo "unknown endpoint $ENDPOINT" >&2; exit 1 ;;
      esac
      case "$SOURCE" in
        ec2) SOURCE_SG='${self.triggers.ec2_sg}' ;;
        mcp) SOURCE_SG='${self.triggers.mcp_sg}' ;;
        *) echo "unknown source $SOURCE" >&2; exit 1 ;;
      esac
      # VPCEs attach one SG; take the first if comma-separated.
      ENDPOINT_SG="$${ENDPOINT_SG%%,*}"
      set +e
      OUT=$(aws ec2 revoke-security-group-ingress \
        --region '${self.triggers.region}' \
        --group-id "$ENDPOINT_SG" \
        --protocol tcp \
        --port 443 \
        --source-group "$SOURCE_SG" 2>&1)
      RC=$?
      if [ "$RC" -eq 0 ] || echo "$OUT" | grep -q 'InvalidPermission.NotFound'; then
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
# Network mode = VPC so the runtime can reach Atlas privately:
#   * privatelink mode → through the Atlas Interface VPCE on the -pl hostname
#   * peering mode     → through the peering route on the -pri hostname
# serverProtocol is MCP per the AgentCore MCP runtime contract:
# https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-mcp.html
# ══════════════════════════════════════════════════════════════════════════════
locals {
  mongodb_mcp_runtime_image = "${aws_ecr_repository.mongodb_mcp_runtime.repository_url}:latest"

  # MONGODB_URI selection — mode-aware with NO public-SRV fallback in peering
  # mode (HARD privacy constraint). PrivateLink mode keeps its existing
  # behavior (privatelink_connection_string is always populated when envs/network
  # PL module is applied; the ternary is preserved for back-compat).
  # Peering mode: prefer the SRV form (when Atlas Private DNS for Peering is
  # on) and fall back to the multi-host non-SRV form. Both are -pri.mongodb.net
  # — see precondition below.
  _mcp_uri_peering = coalesce(
    module.mongodb_atlas.peering_connection_srv_string,
    module.mongodb_atlas.peering_connection_string,
    # Sentinel — caught by the precondition. Picked to be obviously broken.
    "PEERING_URI_UNAVAILABLE"
  )
  _mcp_uri_privatelink = module.mongodb_atlas.privatelink_connection_string != "" ? module.mongodb_atlas.privatelink_connection_string : module.mongodb_atlas.connection_string
  mcp_mongodb_uri      = local.is_peering_mode ? local._mcp_uri_peering : local._mcp_uri_privatelink
}

# Privacy guardrail — fail-loud if peering mode somehow lands on a public-SRV
# URI (Atlas hostname without the -pri token). Catches API regressions in the
# mongodb-atlas module outputs before they ship to runtime env vars.
check "mcp_uri_is_private_in_peering_mode" {
  assert {
    condition = (
      !local.is_peering_mode ||
      (
        local.mcp_mongodb_uri != "PEERING_URI_UNAVAILABLE"
        && can(regex("-pri\\.", local.mcp_mongodb_uri))
      )
    )
    error_message = "Peering-mode MONGODB_URI does not look private (missing '-pri.' peering host token). Check that module.mongodb_atlas.peering_connection_string or peering_connection_srv_string is populated — the cluster's connection_strings[0].private should be populated whenever a mongodbatlas_network_peering exists for this project+region."
  }
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
    MONGODB_URI         = local.mcp_mongodb_uri
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
# Voyage AI SageMaker, CloudWatch log groups, fleet/mongo/cost/atlas dashboards,
# and Bedrock invocation logging now live in envs/shared (single instance per
# account+region+environment). Per-project resources here read their names
# from the SSM data sources at the top of this file.
# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch Generative AI Observability — STAYS PER-PROJECT.
# Wires AgentCore Memory + Gateway service-vended log delivery (memory/gateway
# dashboards stay empty without this), which references per-project AgentCore
# IDs (module.agentcore_memory + module.agentcore_gateway) — so this module
# cannot live in envs/shared where those resources are out of scope.
#
# Singleton-conflict safety valve: when two per-project ec2 stacks coexist in
# the same account+region, only one of them should have
# var.enable_genai_observability=true (the /aws/spans Transaction Search
# toggle is account-scoped). Set false on the loser.
# ══════════════════════════════════════════════════════════════════════════════
module "cloudwatch_genai" {
  count  = var.enable_genai_observability ? 1 : 0
  source = "../../modules/cloudwatch-genai"

  project_name                     = var.project_name
  environment                      = var.environment
  span_retention_days              = var.span_retention_days
  span_sampling_percent            = var.span_sampling_percent
  enable_transaction_search_toggle = var.enable_transaction_search_toggle
  agentcore_log_retention_days     = var.agentcore_vended_log_retention_days
  # Pass { id, arn } via STATIC keys ("main"). The id is used inside the
  # AWS-mandated log-group path (/aws/vendedlogs/bedrock-agentcore/memory/
  # APPLICATION_LOGS/<memory-id>) so console auto-discovery still works;
  # the static key keeps for_each plan-able on fresh deploys without a
  # two-pass apply (memory_id / gateway_id are `known after apply` and
  # used to be the map key, which broke the first `terraform apply`).
  # ARN stays in the value so log_delivery_source.resource_arn is
  # partition-aware (arn:aws / arn:aws-gov / arn:aws-cn) without hardcoding.
  agentcore_memories = {
    main = {
      id  = module.agentcore_memory.memory_id
      arn = module.agentcore_memory.memory_arn
    }
  }
  agentcore_gateways = {
    main = {
      id  = module.agentcore_gateway.gateway_id
      arn = module.agentcore_gateway.gateway_arn
    }
  }
  tags = local.common_tags

  depends_on = [
    module.agentcore_memory,
    module.agentcore_gateway,
  ]
}

# Note: module.bedrock_invocation_logging (account-scoped), module.cloudwatch_fleet_dashboards,
# and module.cloudwatch_atlas_dashboard all moved to envs/shared. Their outputs are
# now consumed via the SSM lookups at the top of this file (republished in
# envs/ec2/outputs.tf so smoke scripts that `terraform output -raw <name>`
# keep working unchanged).
