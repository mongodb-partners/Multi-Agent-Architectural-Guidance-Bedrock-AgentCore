output "ssm_prefix" {
  value       = local.ssm_prefix
  description = "SSM parameter prefix under which all shared-network values are published. Per-project envs read here. Format: /<shared_vpc_name>/<aws_region>"
}

# ── VPC ──────────────────────────────────────────────────────────────────────
output "vpc_id" {
  value = module.networking.vpc_id
}

output "vpc_cidr" {
  value = var.vpc_cidr
}

output "public_subnet_ids" {
  value = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.networking.private_subnet_ids
}

# ── Atlas PrivateLink ─────────────────────────────────────────────────────────
output "atlas_pl_vpce_id" {
  value = module.atlas_privatelink.vpc_endpoint_id
}

output "atlas_pl_vpce_dns_name" {
  value       = module.atlas_privatelink.vpce_dns_name
  description = "Regional DNS name of the Atlas Interface VPCE — consumed by per-cluster Route 53 wildcard CNAMEs."
}

output "atlas_pl_security_group_id" {
  value = module.atlas_privatelink.security_group_id
}

output "atlas_endpoint_service_name" {
  value       = module.atlas_privatelink.endpoint_service_name
  description = "Atlas-provided endpoint service name (com.amazonaws.vpce.<region>.vpce-svc-...). Shared across all deployments in this (Atlas project, region)."
}

output "atlas_private_link_id" {
  value = module.atlas_privatelink.private_link_id
}
