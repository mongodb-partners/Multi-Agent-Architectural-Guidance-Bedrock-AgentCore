variable "project_name" {
  type        = string
  description = "Resource name prefix."
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)."
}

variable "aws_region" {
  type        = string
  description = "AWS region — passed to the SSM send-command call when discovering Atlas private IPs from EC2."
}

variable "vpc_id" {
  type        = string
  description = "Customer VPC ID where the NLB + VPC Endpoint Service live."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs where the NLB ENIs are placed. Should span ≥2 AZs."
}

variable "atlas_srv_host" {
  type        = string
  description = "Atlas cluster SRV hostname (e.g. cluster0.xxxxx.mongodb.net) — passed to `dig SRV _mongodb._tcp.<host>` from EC2."
}

variable "atlas_connection_string" {
  type        = string
  sensitive   = true
  description = "Atlas connection string with credentials. Only the SHA is stored as a trigger — it drives re-discovery when Atlas re-issues the cluster (the only event that changes peering IPs per the FAQ)."
}

variable "cluster_name" {
  type        = string
  description = "Atlas cluster name — used as part of the per-cluster IP discovery JSON file path."
}

variable "ec2_instance_id" {
  type        = string
  description = "EC2 instance ID (in the peered VPC, SSM-enabled) used to run `dig` against Atlas SRV hostnames. The discovered private IPs become NLB targets."
}

variable "atlas_peering_cidr" {
  type        = string
  description = "Atlas peering CIDR — used as a sanity guard: discovered IPs must fall inside this CIDR, else discovery script aborts."
}

variable "atlas_ports" {
  type        = list(number)
  default     = [27017]
  description = "Listener ports on the NLB. Standard cluster mongod listens on 27017 over peering; other ports added only when Atlas advertises them in the connection string."
}

variable "allowed_principals" {
  type        = list(string)
  default     = ["*"]
  description = "IAM principal ARNs allowed to connect to the VPC Endpoint Service. Default wildcard matches modules/bedrock-kb-privatelink (Bedrock auto-creates the VPCE in its managed account)."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources in this module."
}
