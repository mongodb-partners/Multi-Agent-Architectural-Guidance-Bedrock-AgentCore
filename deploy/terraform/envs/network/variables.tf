variable "aws_region" {
  type        = string
  description = "AWS region the shared VPC + Atlas PrivateLink VPCE are deployed in. From env.sh AWS_REGION."
}

variable "project_name" {
  type        = string
  description = "Operator/team project name from env.sh PROJECT_NAME. Used for cost-allocation default tag and state bucket lookup. Resource names use shared_vpc_name instead."
}

variable "environment" {
  type        = string
  description = "Deployment environment (e.g. dev, staging, prod). From env.sh ENVIRONMENT. Used in module-derived resource names and state bucket lookup."
}

variable "shared_vpc_name" {
  type        = string
  description = "Shared network identity (e.g. \"shared-network\"). Drives the SSM parameter prefix, the network state key, and the resource Name tag prefix. Sourced from env.sh SHARED_VPC_NAME — intentionally has no default so the value can never accidentally come from a terraform default."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block for the shared VPC."
}

# ── MongoDB Atlas ─────────────────────────────────────────────────────────────
variable "atlas_project_id" {
  type        = string
  sensitive   = true
  description = "MongoDB Atlas project ID. The PrivateLink endpoint service is bound to this project; reused across all per-project envs in the same (Atlas project, region)."
}

variable "atlas_public_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "atlas_private_key" {
  type      = string
  sensitive = true
  default   = ""
}
