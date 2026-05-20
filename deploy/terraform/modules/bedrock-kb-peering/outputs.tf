output "endpoint_service_name" {
  value       = aws_vpc_endpoint_service.atlas_kb.service_name
  description = "Name of the VPC Endpoint Service exposing the NLB. Pass straight into module bedrock_kb's endpoint_service_name var so Bedrock-managed ingestion connects via the peering-NLB path."
}

output "endpoint_service_id" {
  value       = aws_vpc_endpoint_service.atlas_kb.id
  description = "AWS resource ID of the VPC Endpoint Service. Useful for inspecting Bedrock-side connection requests."
}

output "nlb_arn" {
  value       = aws_lb.atlas_kb.arn
  description = "NLB ARN — surface for log/diagnostic tooling."
}

output "nlb_dns_name" {
  value       = aws_lb.atlas_kb.dns_name
  description = "Internal DNS name of the NLB. Useful for in-VPC connectivity checks (`nc -zv <dns_name> 27017` from EC2)."
}

output "discovered_atlas_ips" {
  value       = local.atlas_ips
  description = "Atlas mongod private IPs (peering side) the NLB targets. Drift will silently break ingestion — see README."
}

output "discovered_ip_count" {
  value       = length(local.atlas_ips)
  description = "Sanity check — should equal the number of replica set members (3 for an M10)."
}
