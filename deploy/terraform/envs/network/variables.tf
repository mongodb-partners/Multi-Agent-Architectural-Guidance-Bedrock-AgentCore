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

# ── Connectivity mode ────────────────────────────────────────────────────────
variable "network_mode" {
  type        = string
  default     = "privatelink"
  description = "Connectivity mode for Atlas. 'privatelink' (default) provisions module.atlas_privatelink (Interface VPCE + Atlas-side endpoint binding); 'peering' provisions module.atlas_vpc_peering (network container + AWS-side accepter + route entries + IP access list). Mutually exclusive. Switching modes requires destroy + redeploy (the SSM /network_mode key guards against accidental flips)."

  validation {
    condition     = contains(["privatelink", "peering"], var.network_mode)
    error_message = "network_mode must be either 'privatelink' or 'peering'."
  }
}

variable "atlas_peering_cidr" {
  type        = string
  default     = "192.168.248.0/21"
  description = "CIDR block for the Atlas network container. Used ONLY when network_mode='peering'. Atlas default is 192.168.248.0/21. MUST NOT overlap var.vpc_cidr — see precondition on module.atlas_vpc_peering. Shell pre-flight in deploy-network.sh catches overlap before terraform plan; this default value is safe with the default vpc_cidr of 10.0.0.0/16."

  validation {
    condition     = can(cidrnetmask(var.atlas_peering_cidr))
    error_message = "atlas_peering_cidr must be a valid IPv4 CIDR."
  }
}

variable "operator_ip_cidr" {
  type        = string
  default     = ""
  description = "Operator/laptop public IP in CIDR form (e.g. 203.0.113.42/32). Used ONLY when network_mode='peering' to add the laptop to the Atlas project IP access list so local-exec provisioners that talk to Atlas (db-seeding, ensure-collection, KB ingestion-status polls) can connect. Pass via env.sh OPERATOR_IP_CIDR; when empty, deploy-network.sh auto-detects via `curl https://checkip.amazonaws.com` and exports it. PrivateLink mode doesn't need this — all Atlas traffic goes via the VPCE."

  validation {
    condition     = var.operator_ip_cidr == "" || can(cidrnetmask(var.operator_ip_cidr))
    error_message = "operator_ip_cidr must be empty or a valid IPv4 CIDR."
  }
}
