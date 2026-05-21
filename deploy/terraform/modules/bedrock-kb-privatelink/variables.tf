variable "project_name" {
  type        = string
  description = "Resource name prefix"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
}

variable "aws_region" {
  type        = string
  description = "AWS region — passed to the local-exec target registration script when discovering Atlas VPCE ENI private IPs."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the NLB and VPC Endpoint Service live (must match the VPC that hosts the Atlas Interface VPCE)."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs the NLB places its ENIs in. Should be the same set the Atlas VPCE uses so cross-AZ traffic costs are minimised."
}

variable "atlas_vpce_id" {
  type        = string
  description = "Atlas Interface VPCE ID (output of modules/atlas-privatelink/aws_vpc_endpoint.atlas.id, surfaced via SSM as /<shared_vpc_name>/<region>/atlas_pl_vpce_id). Used to discover the per-AZ ENIs that become the NLB target IPs."
}

variable "atlas_ports" {
  type        = list(number)
  description = "Atlas PrivateLink listener ports advertised by the Atlas private endpoint connection string. For MONGOD private endpoints this is typically three high ports such as 1051, 1052, 1053. Values may be `(known after apply)` when sourced from mongodbatlas_cluster connection_strings — use atlas_port_slot_count for plan-time for_each keys."
}

variable "atlas_port_slot_count" {
  type        = number
  default     = 3
  description = "Number of NLB listener/target-group slots to provision. Each slot maps to var.atlas_ports[index] at apply time. Default 3 matches a typical 3-node M10 PrivateLink connection string."

  validation {
    condition     = var.atlas_port_slot_count >= 1 && var.atlas_port_slot_count <= 7
    error_message = "atlas_port_slot_count must be between 1 and 7."
  }
}

variable "allowed_principals" {
  type        = list(string)
  description = "IAM principal ARNs allowed to connect to the VPC Endpoint Service. Default uses the AWS-internal Bedrock service principal pattern; tighten to a specific Bedrock account ARN if your security policy requires it."
  default = [
    # Wildcard root principal of the AWS-managed Bedrock account is the
    # public-internet-safe default. Tighten by setting this variable from
    # envs/ec2 to the customer-known Bedrock account ARN once the KB is
    # registered and the connection ID has been observed.
    "*",
  ]
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources in this module."
  default     = {}
}
