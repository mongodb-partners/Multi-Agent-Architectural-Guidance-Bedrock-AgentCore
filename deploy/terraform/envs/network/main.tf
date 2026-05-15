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
# (Per-cluster Route 53 zone is NOT here; it lives with the cluster in
#  envs/ec2 via modules/atlas-privatelink-dns.)
#
# Atlas allows ONLY ONE endpoint service per (Atlas project, AWS region), so
# the discover-or-create script reuses an existing service when present.
# That makes this module idempotent across re-applies / multi-team setups.
# ══════════════════════════════════════════════════════════════════════════════
module "atlas_privatelink" {
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

resource "aws_ssm_parameter" "atlas_pl_vpce_id" {
  name  = "${local.ssm_prefix}/atlas_pl_vpce_id"
  type  = "String"
  value = module.atlas_privatelink.vpc_endpoint_id
}

resource "aws_ssm_parameter" "atlas_pl_vpce_dns_name" {
  name  = "${local.ssm_prefix}/atlas_pl_vpce_dns_name"
  type  = "String"
  value = module.atlas_privatelink.vpce_dns_name
}

resource "aws_ssm_parameter" "atlas_pl_security_group_id" {
  name  = "${local.ssm_prefix}/atlas_pl_security_group_id"
  type  = "String"
  value = module.atlas_privatelink.security_group_id
}

resource "aws_ssm_parameter" "atlas_endpoint_service_name" {
  name  = "${local.ssm_prefix}/atlas_endpoint_service_name"
  type  = "String"
  value = module.atlas_privatelink.endpoint_service_name
}

resource "aws_ssm_parameter" "atlas_private_link_id" {
  name  = "${local.ssm_prefix}/atlas_private_link_id"
  type  = "String"
  value = module.atlas_privatelink.private_link_id
}
