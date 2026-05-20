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

# ── Connectivity mode ────────────────────────────────────────────────────────
output "network_mode" {
  value       = var.network_mode
  description = "Connectivity mode applied to this network stack — 'privatelink' or 'peering'. Mirrored to SSM /<shared_vpc_name>/<region>/network_mode."
}

# ── Atlas PrivateLink (privatelink mode only — empty in peering mode) ────────
output "atlas_pl_vpce_id" {
  value       = var.network_mode == "privatelink" ? module.atlas_privatelink[0].vpc_endpoint_id : ""
  description = "AWS Interface VPCE id pointing at the Atlas PL endpoint service. Empty when network_mode='peering'."
}

output "atlas_pl_vpce_dns_name" {
  value       = var.network_mode == "privatelink" ? module.atlas_privatelink[0].vpce_dns_name : ""
  description = "Regional DNS name of the Atlas Interface VPCE — consumed by per-cluster Route 53 wildcard CNAMEs. Empty in peering mode."
}

output "atlas_pl_security_group_id" {
  value       = var.network_mode == "privatelink" ? module.atlas_privatelink[0].security_group_id : ""
  description = "Security group attached to the Atlas VPCE. Empty in peering mode."
}

output "atlas_endpoint_service_name" {
  value       = var.network_mode == "privatelink" ? module.atlas_privatelink[0].endpoint_service_name : ""
  description = "Atlas-provided endpoint service name (com.amazonaws.vpce.<region>.vpce-svc-...). Shared across all deployments in this (Atlas project, region). Empty in peering mode."
}

output "atlas_private_link_id" {
  value       = var.network_mode == "privatelink" ? module.atlas_privatelink[0].private_link_id : ""
  description = "Atlas private link id. Empty in peering mode."
}

# ── Atlas VPC peering (peering mode only — empty in privatelink mode) ────────
output "atlas_peering_connection_id" {
  value       = var.network_mode == "peering" ? module.atlas_vpc_peering[0].peering_connection_id : ""
  description = "AWS VPC peering connection ID (pcx-...). Empty when network_mode='privatelink'."
}

output "atlas_network_container_id" {
  value       = var.network_mode == "peering" ? module.atlas_vpc_peering[0].atlas_network_container_id : ""
  description = "Atlas network container ID. Empty in privatelink mode."
}

output "atlas_peering_cidr" {
  value       = var.network_mode == "peering" ? module.atlas_vpc_peering[0].atlas_cidr_block : ""
  description = "Atlas-side CIDR. Empty in privatelink mode."
}

output "atlas_private_dns_enabled" {
  value       = var.network_mode == "peering" ? module.atlas_vpc_peering[0].atlas_private_dns_enabled : false
  description = "True when Atlas Private DNS for Peering is enabled on the project. Determines whether peering_srv_host populates on the cluster output. Always false in privatelink mode."
}
