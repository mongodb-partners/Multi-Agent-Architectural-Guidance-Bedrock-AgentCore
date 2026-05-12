variable "project_name" {
  type        = string
  description = "Per-project name for resource tagging (Project tag + zone Name suffix)"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev/staging/prod)"
}

variable "vpc_id" {
  type        = string
  description = "Shared VPC ID — read from SSM by the calling env. The Route 53 private zone associates here."
}

variable "atlas_srv_host" {
  type        = string
  description = "Atlas SRV hostname without scheme (e.g. mycluster.9mtgg.mongodb.net). Used as the Route 53 private zone name."
}

variable "vpce_dns_name" {
  type        = string
  description = "Regional DNS name of the shared Atlas Interface VPCE (from envs/network SSM publish). The wildcard CNAME points here."
}
