output "endpoint_service_name" {
  value       = aws_vpc_endpoint_service.atlas_kb.service_name
  description = "Name of the VPC Endpoint Service exposing the NLB. Pass this straight into module bedrock_kb's endpoint_service_name var so Bedrock-managed ingestion connects via PrivateLink."

  # Bedrock validates MongoDB reachability at KB *create* time. If this
  # output is consumed before NLB listeners + VPCE ENI targets are registered,
  # CreateKnowledgeBase lands in FAILED even though the endpoint service exists.
  depends_on = [
    aws_lb_listener.atlas_kb,
    null_resource.register_targets,
  ]
}

output "endpoint_service_id" {
  value       = aws_vpc_endpoint_service.atlas_kb.id
  description = "AWS resource ID of the VPC Endpoint Service. Useful for manually inspecting Bedrock-side connection requests."
}

output "nlb_arn" {
  value       = aws_lb.atlas_kb.arn
  description = "NLB ARN; surface for log/diagnostic tooling."
}

output "nlb_dns_name" {
  value       = aws_lb.atlas_kb.dns_name
  description = "Internal DNS name of the NLB. Useful for in-VPC connectivity checks (`nc -zv <dns_name> 27017`)."
}

output "atlas_vpce_eni_count" {
  value       = length(var.private_subnet_ids)
  description = "Expected number of Atlas VPCE ENIs (one per private subnet/AZ). Actual ENIs are discovered at apply time by register_targets."
}
