output "peering_connection_id" {
  value       = mongodbatlas_network_peering.atlas.connection_id
  description = "AWS VPC peering connection ID (pcx-...). Same value reported by the AWS accepter."
}

output "atlas_peering_id" {
  value       = mongodbatlas_network_peering.atlas.peer_id
  description = "Atlas-side peering identifier. Useful for Atlas Admin API troubleshooting."
}

output "atlas_network_container_id" {
  value       = local.atlas_container_id
  description = "Atlas network container ID (per Atlas project + AWS region, shared across deployments). Intentionally NOT destroyed by terraform destroy."
}

output "atlas_cidr_block" {
  value       = local.atlas_container_cidr
  description = "Atlas-side CIDR block (matches var.atlas_peering_cidr unless an existing container was reused)."
}

output "peering_status" {
  value       = mongodbatlas_network_peering.atlas.status_name
  description = "Atlas-reported peering status (AVAILABLE | PENDING_ACCEPTANCE | INITIATING | FAILED). Should be AVAILABLE after a successful apply."
}

output "atlas_private_dns_enabled" {
  value       = local.atlas_private_dns_enabled
  description = "True when Atlas Private DNS for Peering is enabled on the project. When true, the cluster's connection_strings[0].private_srv is populated and the SRV-form peering URI is available; when false, callers must use the multi-host non-SRV form (connection_strings[0].private)."
}
