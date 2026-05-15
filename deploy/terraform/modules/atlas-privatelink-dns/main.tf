terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.27, < 7.0"
    }
  }
}

# =============================================================================
# Per-cluster private Route 53 hosted zone — resolves <cluster>.<id>.mongodb.net
# to the Atlas Interface VPCE inside the shared VPC.
#
# This module is invoked from each per-project env (envs/ec2) once per Atlas
# cluster. The VPCE itself is shared (one per region per Atlas project, in
# envs/network); this zone is per-cluster because the SRV hostname differs.
#
# Atlas SRV format: <cluster>.<id>.mongodb.net
# Wildcard CNAME ensures all shard / mongos hostnames resolve via the VPCE.
#
# Full architectural rationale: docs/architecture.md §7.4 ("PrivateLink to
# Atlas → atlas-privatelink-dns per-cluster zone").
# =============================================================================

resource "aws_route53_zone" "atlas" {
  name = var.atlas_srv_host

  vpc {
    vpc_id = var.vpc_id
  }

  tags = {
    Name        = "${var.project_name}-atlas-zone-${var.environment}"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_route53_record" "atlas_wildcard" {
  zone_id = aws_route53_zone.atlas.zone_id
  name    = "*.${var.atlas_srv_host}"
  type    = "CNAME"
  ttl     = 60
  records = [var.vpce_dns_name]
}
