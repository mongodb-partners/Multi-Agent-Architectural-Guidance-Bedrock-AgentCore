variable "project_name" {
  type        = string
  description = "Project name prefix for resource names and tags."
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)."
}

variable "aws_region" {
  type        = string
  description = "AWS region where the customer VPC + peering accepter live."
}

variable "atlas_project_id" {
  type        = string
  sensitive   = true
  description = "MongoDB Atlas project ID. The network container is per (project, AWS region) — shared across all deployments in that pair."
}

variable "vpc_id" {
  type        = string
  description = "Customer VPC ID participating in the peering."
}

variable "vpc_cidr" {
  type        = string
  description = "Customer VPC CIDR block — published to Atlas as route_table_cidr_block and added to the project IP access list."
}

variable "atlas_peering_cidr" {
  type        = string
  description = "CIDR block for the Atlas network container. MUST NOT overlap var.vpc_cidr. Atlas default is 192.168.248.0/21."

  validation {
    # cidrnetmask requires a valid CIDR — this catches malformed input early.
    condition     = can(cidrnetmask(var.atlas_peering_cidr))
    error_message = "atlas_peering_cidr must be a valid IPv4 CIDR (e.g. 192.168.248.0/21)."
  }
}

variable "vpc_main_route_table_id" {
  type        = string
  description = "Main route table ID of the customer VPC. Private subnets (created without explicit RT association by modules/networking) use this RT, so the peering route must land here."
}

variable "vpc_public_route_table_id" {
  type        = string
  description = "Public route table ID of the customer VPC. Peering route must also land here so the EC2 host in the public subnet reaches Atlas via the peering connection."
}

variable "operator_ip_cidr" {
  type        = string
  default     = ""
  description = "Optional operator/developer laptop CIDR (e.g. 203.0.113.5/32) added to the Atlas project IP access list so `local-exec` provisioners (seed-indexes, ensure-collection) succeed. Empty disables."
}

variable "aws_account_id" {
  type        = string
  description = "AWS account ID owning the customer VPC — required by mongodbatlas_network_peering."
}
