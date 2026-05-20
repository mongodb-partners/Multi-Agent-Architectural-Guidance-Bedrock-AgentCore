terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.27, < 7.0"
    }
    mongodbatlas = {
      source  = "mongodb/mongodbatlas"
      version = "~> 1.14"
    }
    null  = { source = "hashicorp/null", version = "~> 3.0" }
    local = { source = "hashicorp/local", version = "~> 2.0" }
  }
}

# =============================================================================
# Atlas VPC peering — discover-or-create Atlas network container + peering +
# AWS accepter + route entries + project IP access list.
#
# Atlas allows ONLY ONE network container per (project, providerName, AWS
# region). When multiple terraform deployments target the same Atlas project +
# region, they MUST share that single container — Atlas returns HTTP 409 on
# the second create. Mirrors the discover-or-create pattern used by
# modules/atlas-privatelink/.
#
# CRITICAL: this module has NO destroy provisioner for the container. The
# Atlas network container is intentionally NOT torn down by `terraform
# destroy` because other deployments in the same project + region may still
# depend on it. Use the Atlas console or a dedicated ops script to remove it
# once all bindings (peering, PrivateLink) are gone.
# =============================================================================

locals {
  container_state_file   = "${path.module}/.container-${var.atlas_project_id}-${replace(var.aws_region, "-", "_")}.json"
  private_dns_state_file = "${path.module}/.private-dns-${var.atlas_project_id}.json"
  atlas_region           = upper(replace(var.aws_region, "-", "_"))
}

# ── Discover or create the Atlas network container ───────────────────────────
resource "null_resource" "atlas_container_lookup" {
  triggers = {
    project_id         = var.atlas_project_id
    region             = local.atlas_region
    atlas_peering_cidr = var.atlas_peering_cidr
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/discover-or-create-container.sh"
    environment = {
      ATLAS_PROJECT_ID   = var.atlas_project_id
      ATLAS_REGION       = local.atlas_region
      ATLAS_PEERING_CIDR = var.atlas_peering_cidr
      STATE_FILE         = local.container_state_file
    }
  }
}

data "local_file" "container_state" {
  filename   = local.container_state_file
  depends_on = [null_resource.atlas_container_lookup]
}

locals {
  _container_state     = jsondecode(data.local_file.container_state.content)
  atlas_container_id   = local._container_state.container_id
  atlas_container_cidr = local._container_state.atlas_cidr_block
}

# Migration safety — if a previous deployment had the container managed directly
# via the mongodbatlas provider, this `removed` block lets Terraform drop it
# from state WITHOUT destroying the cloud resource (would break every other
# deployment that's also using it).
removed {
  from = mongodbatlas_network_container.atlas
  lifecycle {
    destroy = false
  }
}

# ── Atlas-side peering ───────────────────────────────────────────────────────
# Provider waits for transition to PENDING_ACCEPTANCE / AVAILABLE before
# returning. AWS accepter then flips it to ACTIVE.
resource "mongodbatlas_network_peering" "atlas" {
  project_id             = var.atlas_project_id
  container_id           = local.atlas_container_id
  provider_name          = "AWS"
  vpc_id                 = var.vpc_id
  aws_account_id         = var.aws_account_id
  route_table_cidr_block = var.vpc_cidr
  accepter_region_name   = var.aws_region
}

# ── AWS-side accepter ────────────────────────────────────────────────────────
resource "aws_vpc_peering_connection_accepter" "atlas" {
  vpc_peering_connection_id = mongodbatlas_network_peering.atlas.connection_id
  auto_accept               = true

  tags = {
    Name        = "${var.project_name}-atlas-peering-${var.environment}"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Role        = "atlas-vpc-peering"
  }

  depends_on = [mongodbatlas_network_peering.atlas]
}

# ── Route table entries ──────────────────────────────────────────────────────
# Confirmed via modules/networking/main.tf: the networking module creates ONLY
# a public route table; private subnets implicitly use the VPC's main route
# table. "main + public" RT coverage is complete (no separate private RT
# exists). depends_on the accepter so AWS waits for ACTIVE state.
resource "aws_route" "atlas_peering_main" {
  route_table_id            = var.vpc_main_route_table_id
  destination_cidr_block    = var.atlas_peering_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.atlas.vpc_peering_connection_id

  depends_on = [aws_vpc_peering_connection_accepter.atlas]
}

resource "aws_route" "atlas_peering_public" {
  route_table_id            = var.vpc_public_route_table_id
  destination_cidr_block    = var.atlas_peering_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.atlas.vpc_peering_connection_id

  depends_on = [aws_vpc_peering_connection_accepter.atlas]
}

# ── Atlas project IP access list ─────────────────────────────────────────────
# Peering-side entries. The original 0.0.0.0/0 entry in modules/mongodb-atlas
# is flipped to var.vpc_cidr in peering mode by that module — here we only
# add complementary entries (operator IP for laptop local-exec; the VPC CIDR
# entry is owned by the mongodb-atlas module).
resource "mongodbatlas_project_ip_access_list" "operator_laptop" {
  count      = var.operator_ip_cidr != "" ? 1 : 0
  project_id = var.atlas_project_id
  cidr_block = var.operator_ip_cidr
  comment    = "Operator laptop (peering mode) — required for local-exec provisioners"
}

# ── Atlas Private DNS for Peering — auto-enable for parity automation ────────
# Tries Atlas Admin API v2 first then falls back to v1. Idempotent (PATCH
# returns 200 even when already enabled). Non-200 prints a warning and
# continues — the runtime URI still works using the multi-host non-SRV
# fallback when the SRV form is unavailable. Runs once per project; trigger
# is project_id only so it's not re-run on unrelated changes.
resource "null_resource" "enable_atlas_private_dns_for_peering" {
  triggers = {
    project_id = var.atlas_project_id
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/enable-private-dns.sh"
    environment = {
      ATLAS_PROJECT_ID = var.atlas_project_id
      STATE_FILE       = local.private_dns_state_file
    }
  }

  depends_on = [mongodbatlas_network_peering.atlas]
}

data "local_file" "private_dns_state" {
  filename   = local.private_dns_state_file
  depends_on = [null_resource.enable_atlas_private_dns_for_peering]
}

locals {
  _private_dns_state        = jsondecode(data.local_file.private_dns_state.content)
  atlas_private_dns_enabled = lookup(local._private_dns_state, "enabled", false)
}
