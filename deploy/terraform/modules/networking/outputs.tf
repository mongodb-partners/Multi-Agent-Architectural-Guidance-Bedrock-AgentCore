output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs — EC2 instance deploys here"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs — reserved for Atlas PrivateLink VPC endpoint"
  value       = aws_subnet.private[*].id
}

# ── Route tables (used by atlas-vpc-peering for `aws_route` entries) ─────────
# This module creates only a public RT; private subnets implicitly use the
# VPC's main RT. Peering routes therefore land on main + public.
output "public_route_table_id" {
  description = "Public route table ID (the only explicit RT this module creates)."
  value       = aws_route_table.public.id
}

output "main_route_table_id" {
  description = "Main route table ID of the VPC. Private subnets (created without an explicit RT association) use this RT."
  value       = aws_vpc.main.main_route_table_id
}
