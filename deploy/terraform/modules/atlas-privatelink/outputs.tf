output "vpc_endpoint_id" {
  value       = aws_vpc_endpoint.atlas.id
  description = "ID of the AWS VPC endpoint pointing at the Atlas PrivateLink endpoint service"
}

output "vpce_dns_name" {
  value       = aws_vpc_endpoint.atlas.dns_entry[0]["dns_name"]
  description = "Regional DNS name of the AWS VPCE — consumed by per-cluster Route 53 wildcard CNAMEs (modules/atlas-cluster-dns)"
}

output "endpoint_service_name" {
  value       = local.atlas_endpoint_service
  description = "Atlas-provided VPC endpoint service name (com.amazonaws.vpce.<region>.vpce-svc-xxx) — SHARED across deployments in this region"
}

output "private_link_id" {
  value       = local.atlas_private_link_id
  description = "Atlas PrivateLink endpoint ID — SHARED across deployments in this region"
}

output "security_group_id" {
  value       = aws_security_group.atlas_pl.id
  description = "Security group ID attached to the Atlas VPC endpoint"
}
