terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws          = { source = "hashicorp/aws", version = ">= 6.27, < 7.0" }
    mongodbatlas = { source = "mongodb/mongodbatlas", version = "~> 1.14" }
    null         = { source = "hashicorp/null", version = "~> 3.0" }
    local        = { source = "hashicorp/local", version = "~> 2.0" }
  }

  backend "s3" {}
}

# ── Locals ────────────────────────────────────────────────────────────────────
# Single source of truth for the SSM prefix. Anything published here is
# discoverable by per-project envs (envs/ec2) at /<shared_vpc_name>/<region>/*.
locals {
  ssm_prefix = "/${var.shared_vpc_name}/${var.aws_region}"
}

# ── Providers ─────────────────────────────────────────────────────────────────
# Project = var.project_name (operator/team identity from env.sh) is set as a
# default tag for cost-allocation visibility. The networking + atlas_privatelink
# modules set their own explicit Project tag (= var.shared_vpc_name) which
# overrides the default on each resource — i.e. every shared-infra resource
# reports Project=<shared_vpc_name> in Cost Explorer, while the operator's
# project tag survives wherever a module didn't set one explicitly.
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Network = "${var.shared_vpc_name}-${var.aws_region}"
      Project = var.project_name
    }
  }
}

provider "mongodbatlas" {
  public_key  = var.atlas_public_key
  private_key = var.atlas_private_key
}

data "aws_caller_identity" "current" {}

# ══════════════════════════════════════════════════════════════════════════════
# Networking — VPC + 2x public + 2x private subnets + IGW + public RT
# Module project_name = shared_vpc_name so Name tags read shared-network-*.
# ══════════════════════════════════════════════════════════════════════════════
module "networking" {
  source = "../../modules/networking"

  aws_region   = var.aws_region
  project_name = var.shared_vpc_name
  environment  = var.environment
  vpc_cidr     = var.vpc_cidr
}

# ══════════════════════════════════════════════════════════════════════════════
# Atlas PrivateLink — Interface VPCE + Atlas-side endpoint binding + SG
# Provisioned only when network_mode='privatelink'. Atlas allows ONLY ONE
# endpoint service per (Atlas project, AWS region), so the discover-or-create
# script reuses an existing service when present. That makes this module
# idempotent across re-applies / multi-team setups.
#
# (Per-cluster Route 53 zone is NOT here; it lives with the cluster in
#  envs/ec2 via modules/atlas-privatelink-dns.)
# ══════════════════════════════════════════════════════════════════════════════
module "atlas_privatelink" {
  count  = var.network_mode == "privatelink" ? 1 : 0
  source = "../../modules/atlas-privatelink"

  project_name       = var.shared_vpc_name
  environment        = var.environment
  aws_region         = var.aws_region
  atlas_project_id   = var.atlas_project_id
  vpc_id             = module.networking.vpc_id
  vpc_cidr           = var.vpc_cidr
  private_subnet_ids = module.networking.private_subnet_ids
}

# ══════════════════════════════════════════════════════════════════════════════
# Atlas VPC peering — network container + AWS-side accepter + route entries
# Provisioned only when network_mode='peering'. Mutually exclusive with the
# atlas_privatelink module above. Hard precondition catches CIDR overlap with
# var.vpc_cidr before plan reaches the cloud (shell pre-flight in
# deploy-network.sh is the fast path; this is the second line of defense).
# ══════════════════════════════════════════════════════════════════════════════
module "atlas_vpc_peering" {
  count  = var.network_mode == "peering" ? 1 : 0
  source = "../../modules/atlas-vpc-peering"

  project_name              = var.shared_vpc_name
  environment               = var.environment
  aws_region                = var.aws_region
  atlas_project_id          = var.atlas_project_id
  vpc_id                    = module.networking.vpc_id
  vpc_cidr                  = var.vpc_cidr
  atlas_peering_cidr        = var.atlas_peering_cidr
  vpc_main_route_table_id   = module.networking.main_route_table_id
  vpc_public_route_table_id = module.networking.public_route_table_id
  aws_account_id            = data.aws_caller_identity.current.account_id
}

# Second-line-of-defense CIDR overlap guard (shell pre-flight is the fast path).
check "peering_cidr_non_overlap" {
  assert {
    condition = (
      var.network_mode != "peering"
      || !(cidrhost(var.vpc_cidr, 0) == cidrhost(var.atlas_peering_cidr, 0))
    )
    error_message = "atlas_peering_cidr (${var.atlas_peering_cidr}) collides with vpc_cidr (${var.vpc_cidr}). Pick a non-overlapping ATLAS_PEERING_CIDR (Atlas default 192.168.248.0/21 is safe with vpc_cidr=10.0.0.0/16)."
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# SSM Parameter Store — publish the shared network's identifying values so
# per-project envs (envs/ec2) discover them via data.aws_ssm_parameter rather
# than via terraform_remote_state. This keeps the cross-state contract
# explicit and decoupled from state-file access permissions.
#
# StringList for subnet_ids: consumers split by "," — see envs/ec2/main.tf.
# ══════════════════════════════════════════════════════════════════════════════
resource "aws_ssm_parameter" "vpc_id" {
  name  = "${local.ssm_prefix}/vpc_id"
  type  = "String"
  value = module.networking.vpc_id
}

resource "aws_ssm_parameter" "vpc_cidr" {
  name  = "${local.ssm_prefix}/vpc_cidr"
  type  = "String"
  value = var.vpc_cidr
}

resource "aws_ssm_parameter" "public_subnet_ids" {
  name  = "${local.ssm_prefix}/public_subnet_ids"
  type  = "StringList"
  value = join(",", module.networking.public_subnet_ids)
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  name  = "${local.ssm_prefix}/private_subnet_ids"
  type  = "StringList"
  value = join(",", module.networking.private_subnet_ids)
}

# Always-published — guards against silent mode mixing between deploys.
resource "aws_ssm_parameter" "network_mode" {
  name  = "${local.ssm_prefix}/network_mode"
  type  = "String"
  value = var.network_mode
}

# ── PrivateLink-only SSM keys ────────────────────────────────────────────────
resource "aws_ssm_parameter" "atlas_pl_vpce_id" {
  count = var.network_mode == "privatelink" ? 1 : 0
  name  = "${local.ssm_prefix}/atlas_pl_vpce_id"
  type  = "String"
  value = module.atlas_privatelink[0].vpc_endpoint_id
}

resource "aws_ssm_parameter" "atlas_pl_vpce_dns_name" {
  count = var.network_mode == "privatelink" ? 1 : 0
  name  = "${local.ssm_prefix}/atlas_pl_vpce_dns_name"
  type  = "String"
  value = module.atlas_privatelink[0].vpce_dns_name
}

resource "aws_ssm_parameter" "atlas_pl_security_group_id" {
  count = var.network_mode == "privatelink" ? 1 : 0
  name  = "${local.ssm_prefix}/atlas_pl_security_group_id"
  type  = "String"
  value = module.atlas_privatelink[0].security_group_id
}

resource "aws_ssm_parameter" "atlas_endpoint_service_name" {
  count = var.network_mode == "privatelink" ? 1 : 0
  name  = "${local.ssm_prefix}/atlas_endpoint_service_name"
  type  = "String"
  value = module.atlas_privatelink[0].endpoint_service_name
}

resource "aws_ssm_parameter" "atlas_private_link_id" {
  count = var.network_mode == "privatelink" ? 1 : 0
  name  = "${local.ssm_prefix}/atlas_private_link_id"
  type  = "String"
  value = module.atlas_privatelink[0].private_link_id
}

# ── Peering-only SSM keys ────────────────────────────────────────────────────
resource "aws_ssm_parameter" "atlas_peering_id" {
  count = var.network_mode == "peering" ? 1 : 0
  name  = "${local.ssm_prefix}/atlas_peering_id"
  type  = "String"
  value = module.atlas_vpc_peering[0].peering_connection_id
}

resource "aws_ssm_parameter" "atlas_container_id" {
  count = var.network_mode == "peering" ? 1 : 0
  name  = "${local.ssm_prefix}/atlas_container_id"
  type  = "String"
  value = module.atlas_vpc_peering[0].atlas_network_container_id
}

resource "aws_ssm_parameter" "atlas_peering_cidr" {
  count = var.network_mode == "peering" ? 1 : 0
  name  = "${local.ssm_prefix}/atlas_peering_cidr"
  type  = "String"
  value = module.atlas_vpc_peering[0].atlas_cidr_block
}

resource "aws_ssm_parameter" "atlas_private_dns_enabled" {
  count = var.network_mode == "peering" ? 1 : 0
  name  = "${local.ssm_prefix}/atlas_private_dns_enabled"
  type  = "String"
  # Stored as string for SSM compatibility ("true"/"false"). Consumers compare to "true".
  value = module.atlas_vpc_peering[0].atlas_private_dns_enabled ? "true" : "false"
}
