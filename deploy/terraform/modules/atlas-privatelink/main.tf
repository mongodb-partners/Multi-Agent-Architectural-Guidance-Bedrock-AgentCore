terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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
# Step 1 — Discover (or, on first deploy, create) the SHARED Atlas PrivateLink
# endpoint service for this (Atlas project, AWS region).
#
# Atlas allows ONLY ONE endpoint service per (project, region). When multiple
# terraform deployments target the same Atlas project + region, they MUST
# share that single service — Atlas returns HTTP 409 on the second create.
# This module therefore looks the service up via the Atlas Admin API and only
# creates it if it doesn't already exist.
#
# CRITICAL: this resource has NO destroy provisioner. The Atlas service is
# intentionally NOT torn down by `terraform destroy` because other deployments
# in the same project + region may still depend on it. Use the Atlas console
# or a dedicated ops script to remove it once all bindings are gone.
# =============================================================================

locals {
  # State file is keyed by (project, region) — NOT by deployment — so the
  # same physical service is referenced from any deployment that points at
  # this Atlas project + region.
  pl_state_file = "${path.module}/.pl-${var.atlas_project_id}-${replace(var.aws_region, "-", "_")}.json"
  atlas_region  = upper(replace(var.aws_region, "-", "_"))
}

resource "null_resource" "atlas_pl_lookup" {
  triggers = {
    project_id = var.atlas_project_id
    region     = local.atlas_region
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/discover-or-create-pl.sh"
    environment = {
      ATLAS_PROJECT_ID = var.atlas_project_id
      ATLAS_REGION     = local.atlas_region
      STATE_FILE       = local.pl_state_file
    }
  }
}

data "local_file" "pl_state" {
  filename   = local.pl_state_file
  depends_on = [null_resource.atlas_pl_lookup]
}

locals {
  _pl                    = jsondecode(data.local_file.pl_state.content)
  atlas_endpoint_service = local._pl.endpoint_service_name
  atlas_private_link_id  = local._pl.private_link_id
}

# =============================================================================
# Migration safety — if a previous deployment had the privatelink endpoint
# managed directly via the mongodbatlas provider, this `removed` block lets
# Terraform drop it from state WITHOUT destroying the cloud resource (which
# would break every other deployment that's also using it).
# =============================================================================

removed {
  from = mongodbatlas_privatelink_endpoint.atlas
  lifecycle {
    destroy = false
  }
}

# =============================================================================
# Step 2 — Create the AWS VPC Interface Endpoint pointing at the SHARED Atlas
# endpoint service. This IS per-deployment (one per VPC).
# =============================================================================

resource "aws_vpc_endpoint" "atlas" {
  vpc_id              = var.vpc_id
  service_name        = local.atlas_endpoint_service
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.atlas_pl.id]
  private_dns_enabled = false # Atlas uses its own DNS; we manage this via Route 53

  tags = {
    Name        = "${var.project_name}-vpce-atlas-${var.environment}"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  depends_on = [null_resource.atlas_pl_lookup]
}

# =============================================================================
# Step 3 — Register this deployment's AWS VPC endpoint with the SHARED Atlas
# service so Atlas authorizes the connection. This binding IS per-deployment
# (one per VPC endpoint).
# =============================================================================

resource "mongodbatlas_privatelink_endpoint_service" "atlas" {
  project_id          = var.atlas_project_id
  private_link_id     = local.atlas_private_link_id
  endpoint_service_id = aws_vpc_endpoint.atlas.id
  provider_name       = "AWS"

  depends_on = [aws_vpc_endpoint.atlas]
}

# =============================================================================
# Security group — allow MongoDB TLS + HTTPS from any workload inside the
# shared VPC. Ingress is CIDR-scoped (NOT SG-referenced) because this module
# now lives in envs/network and does not know about per-project app SGs.
# Per-project workloads (EC2, Lambda) just need to live inside var.vpc_cidr
# to reach the Atlas VPCE.
# =============================================================================

resource "aws_security_group" "atlas_pl" {
  name        = "${var.project_name}-sg-atlas-pl-${var.environment}"
  description = "Allow MongoDB TLS traffic from VPC workloads to Atlas via PrivateLink"
  vpc_id      = var.vpc_id

  ingress {
    description = "MongoDB TLS from VPC workloads"
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "HTTPS from VPC workloads"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    # Atlas dynamically assigns mongod listener ports per cluster (NOT a
    # fixed 1024-1026 range as previously assumed). For this cluster Atlas
    # picked 1039-1041; for other clusters it can be any port in 1024-65535.
    # The Atlas Terraform privatelink reference uses the same wide range.
    # Source is constrained to the VPC CIDR; the SG only protects the Atlas
    # VPCE ENIs, not user-facing workloads.
    description = "Atlas PrivateLink mongod listener ports from VPC workloads"
    from_port   = 1024
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-sg-atlas-pl-${var.environment}"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# NOTE: The per-cluster Route 53 private zone + wildcard CNAME (which used to
# live here) moved to modules/atlas-cluster-dns/. The DNS zone is named after
# the cluster's SRV host, so it is per-cluster — i.e. per-project — and lives
# alongside the cluster definition in envs/ec2 rather than in envs/network.
