terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.27, < 7.0" }
  }

  backend "s3" {}
}

# ── Locals ────────────────────────────────────────────────────────────────────
# Same SSM prefix the network stack uses so per-project envs/ec2 stacks read
# both network-published and shared-published values from a single namespace.
locals {
  ssm_prefix = "/${var.shared_vpc_name}/${var.aws_region}"

  # CloudWatch log group prefix — env-scoped (not project-scoped) so log group
  # names are stable per (account, region, environment) regardless of how many
  # per-project envs/ec2 stacks consume them. var.shared_resource_prefix is the
  # single knob that flows into module.cloudwatch + module.cloudwatch_fleet_dashboards
  # as well, so renaming "multiagent" → something else is one-variable change.
  log_group_prefix = "/${var.shared_resource_prefix}/${var.environment}"

  otel_log_group_name       = "${local.log_group_prefix}/otel"
  otel_atlas_log_group_name = "${local.log_group_prefix}/otel-atlas"

  common_tags = {
    Network     = "${var.shared_vpc_name}-${var.aws_region}"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Layer       = "shared"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}

data "aws_s3_bucket" "shared" {
  bucket = var.shared_bucket_name
}

# ══════════════════════════════════════════════════════════════════════════════
# Voyage AI SageMaker — optional; only when Marketplace ARN is set.
# Provisioned once per (account, region, env). Multiple per-project ec2 stacks
# share the resulting endpoint via SSM.
# ══════════════════════════════════════════════════════════════════════════════
module "voyage_sagemaker" {
  source = "../../modules/voyage-sagemaker"
  count  = var.voyage_model_package_arn != "" ? 1 : 0

  aws_region               = var.aws_region
  environment              = var.environment
  voyage_model_package_arn = var.voyage_model_package_arn
  instance_type            = var.voyage_instance_type
  endpoint_name_suffix     = var.voyage_endpoint_name_suffix
}

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch log groups — API + UI + MCP + AgentCore (shared across projects)
# ══════════════════════════════════════════════════════════════════════════════
module "cloudwatch" {
  source                 = "../../modules/cloudwatch"
  project_name           = var.project_name
  shared_resource_prefix = var.shared_resource_prefix
  environment            = var.environment
  api_retention_days     = var.log_retention_days
  aux_retention_days     = var.log_retention_days
}

# ── OTel log groups owned by the shared stack so the per-project ADOT sidecar
#    in envs/ec2 writes into them without duplicating retention/ownership.
#    Two groups intentional: the awscloudwatchlogs exporter targets `otel` and
#    the awsemf exporter targets `<otel>-atlas` (Phase 4 Atlas Prometheus
#    metrics). The ADOT collector template derives the `-atlas` name as
#    "${otel_log_group_name}-atlas" — we must own both.
resource "aws_cloudwatch_log_group" "otel" {
  name              = local.otel_log_group_name
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, {
    Name = local.otel_log_group_name
  })
}

resource "aws_cloudwatch_log_group" "otel_atlas" {
  name              = local.otel_atlas_log_group_name
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, {
    Name = local.otel_atlas_log_group_name
  })
}

# ══════════════════════════════════════════════════════════════════════════════
# Bedrock invocation logging — account-scoped singleton.
# Owns /aws/bedrock/invocations + /aws/bedrock/invocations-audit. Outputs feed
# directly into the fleet dashboards module below (same state, no SSM hop).
# ══════════════════════════════════════════════════════════════════════════════
module "bedrock_invocation_logging" {
  source = "../../modules/bedrock-invocation-logging"

  project_name                = var.project_name
  shared_resource_prefix      = var.shared_resource_prefix
  environment                 = var.environment
  enable                      = var.enable_bedrock_invocation_logging
  log_prompt_bodies           = var.log_prompt_bodies
  log_embedding_bodies        = var.log_embedding_bodies
  retention_days              = var.invocation_retention_days
  data_protection_identifiers = var.data_protection_identifiers
  tags                        = local.common_tags
}

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch Fleet Dashboards + Alarms — multiagent-fleet / -mongo / -cost.
# Reads from the shared log groups above; dashboard / alarm / metric-filter /
# query names drop the project_name prefix so they are stable per environment.
# ══════════════════════════════════════════════════════════════════════════════
module "cloudwatch_fleet_dashboards" {
  count  = var.enable_fleet_dashboards ? 1 : 0
  source = "../../modules/cloudwatch-fleet-dashboards"

  project_name                  = var.project_name
  shared_resource_prefix        = var.shared_resource_prefix
  environment                   = var.environment
  aws_region                    = var.aws_region
  api_log_group_name            = module.cloudwatch.api_log_group_name
  ui_log_group_name             = module.cloudwatch.ui_log_group_name
  invocation_log_group_name     = var.enable_bedrock_invocation_logging ? module.bedrock_invocation_logging.log_group_name : ""
  audit_findings_log_group_name = var.enable_bedrock_invocation_logging ? module.bedrock_invocation_logging.audit_log_group_name : ""
  otel_log_group_name           = aws_cloudwatch_log_group.otel.name
  p99_latency_threshold_ms      = var.p99_latency_threshold_ms
  error_rate_threshold_pct      = var.error_rate_threshold_pct
  throttle_burst_threshold      = var.throttle_burst_threshold
  tags                          = local.common_tags
}

# ══════════════════════════════════════════════════════════════════════════════
# Atlas dashboard + alarms — consumes the MongoDB/Atlas namespace published by
# the per-project ADOT collectors (prometheus → awsemf → otel-atlas log group).
# ══════════════════════════════════════════════════════════════════════════════
module "cloudwatch_atlas_dashboard" {
  count  = var.enable_atlas_metrics ? 1 : 0
  source = "../../modules/cloudwatch-atlas-dashboard"

  project_name                 = var.project_name
  shared_resource_prefix       = var.shared_resource_prefix
  environment                  = var.environment
  aws_region                   = var.aws_region
  replication_lag_threshold_ms = var.atlas_replication_lag_threshold_ms
  tags                         = local.common_tags
}

# ══════════════════════════════════════════════════════════════════════════════
# SSM Parameter Store — publish shared resource names under the network's SSM
# prefix so per-project envs/ec2 can discover them without cross-state reads.
# Always-publish (even when empty) so consumers can distinguish "shared stack
# was applied but voyage is disabled" from "shared stack not yet applied".
# ══════════════════════════════════════════════════════════════════════════════
resource "aws_ssm_parameter" "voyage_sagemaker_endpoint_name" {
  name  = "${local.ssm_prefix}/voyage_sagemaker_endpoint_name"
  type  = "String"
  value = length(module.voyage_sagemaker) > 0 ? module.voyage_sagemaker[0].endpoint_name : "_empty_"
}

resource "aws_ssm_parameter" "voyage_sagemaker_endpoint_arn" {
  name  = "${local.ssm_prefix}/voyage_sagemaker_endpoint_arn"
  type  = "String"
  value = length(module.voyage_sagemaker) > 0 ? module.voyage_sagemaker[0].endpoint_arn : "_empty_"
}

resource "aws_ssm_parameter" "cw_api_log_group" {
  name  = "${local.ssm_prefix}/cw_api_log_group"
  type  = "String"
  value = module.cloudwatch.api_log_group_name
}

resource "aws_ssm_parameter" "cw_ui_log_group" {
  name  = "${local.ssm_prefix}/cw_ui_log_group"
  type  = "String"
  value = module.cloudwatch.ui_log_group_name
}

resource "aws_ssm_parameter" "cw_mcp_log_group" {
  name  = "${local.ssm_prefix}/cw_mcp_log_group"
  type  = "String"
  value = module.cloudwatch.mcp_log_group_name
}

resource "aws_ssm_parameter" "cw_agentcore_log_group" {
  name  = "${local.ssm_prefix}/cw_agentcore_log_group"
  type  = "String"
  value = module.cloudwatch.agentcore_log_group_name
}

resource "aws_ssm_parameter" "cw_otel_log_group" {
  name  = "${local.ssm_prefix}/cw_otel_log_group"
  type  = "String"
  value = aws_cloudwatch_log_group.otel.name
}

resource "aws_ssm_parameter" "cw_otel_atlas_log_group" {
  name  = "${local.ssm_prefix}/cw_otel_atlas_log_group"
  type  = "String"
  value = aws_cloudwatch_log_group.otel_atlas.name
}

resource "aws_ssm_parameter" "bedrock_invocation_log_group" {
  name  = "${local.ssm_prefix}/bedrock_invocation_log_group"
  type  = "String"
  value = var.enable_bedrock_invocation_logging ? module.bedrock_invocation_logging.log_group_name : "_empty_"
}

resource "aws_ssm_parameter" "bedrock_audit_log_group" {
  name  = "${local.ssm_prefix}/bedrock_audit_log_group"
  type  = "String"
  value = var.enable_bedrock_invocation_logging ? module.bedrock_invocation_logging.audit_log_group_name : "_empty_"
}
