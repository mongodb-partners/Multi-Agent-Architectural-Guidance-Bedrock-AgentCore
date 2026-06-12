variable "atlas_project_id" {
  type        = string
  description = "MongoDB Atlas Project ID"
}

variable "cluster_name" {
  type        = string
  description = "Atlas cluster name"
}

variable "db_name" {
  type        = string
  description = "MongoDB database name. Caller must supply a project+env-scoped value, e.g. <PROJECT_NAME>_<ENVIRONMENT> (underscored), so multiple deployments don't collide on a shared Atlas project."
}

variable "db_username" {
  type        = string
  description = "Atlas database username"
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "Atlas database password"
}

variable "project_tag" {
  type        = string
  description = "Value for the Project tag on the Atlas cluster (mirrors AWS Project tag)"
  default     = "multiagent-mongodb-framework"
}

variable "privatelink_endpoint_id" {
  type        = string
  description = "Optional AWS VPCE id of the PrivateLink endpoint that the consumer VPC has into Atlas. When set, the `privatelink_connection_string` output emits the multi-host non-SRV PrivateLink URI for the matching endpoint (suitable for VPC-internal callers like Lambda MCP). When empty the output is \"\" and callers should fall back to the SRV `connection_string`."
  default     = ""
}

variable "network_mode" {
  type        = string
  default     = "privatelink"
  description = "Connectivity mode. 'privatelink' (default) scopes the Atlas IP access list to var.operator_ip_cidr (the deploy machine) — runtime reaches Atlas via the PrivateLink endpoint, which bypasses the IP access list. 'peering' scopes the IP access list to var.vpc_cidr — runtime + Bedrock KB both reach Atlas privately via VPC peering. Neither mode ever opens Atlas to 0.0.0.0/0."

  validation {
    condition     = contains(["privatelink", "peering"], var.network_mode)
    error_message = "network_mode must be either 'privatelink' or 'peering'."
  }
}

variable "vpc_cidr" {
  type        = string
  default     = ""
  description = "Customer VPC CIDR. REQUIRED when network_mode='peering' — used as the peering IP access list entry so only this VPC can reach Atlas in peering mode. Ignored when network_mode='privatelink'."
}

# WHY: This variable is the replacement for the old 0.0.0.0/0 IP access list
# entry. The security requirement is "Atlas reachable only from where it was
# created from, never the public internet". In privatelink mode the cluster's
# only public-SRV consumers are the operator-run local-exec provisioners on the
# deploy machine, so we scope the allowlist to that one /32 instead of opening
# it to the world. Empty default keeps the module usable when a caller has no
# operator IP (peering mode, or a PrivateLink-only setup with no local-exec).
variable "operator_ip_cidr" {
  type        = string
  default     = ""
  description = "Operator/deploy-machine public IP in CIDR /32 form (e.g. 203.0.113.42/32) — 'anywhere it was created from'. Used when network_mode='privatelink' as the ONLY public-SRV Atlas IP access list entry (replaces the former 0.0.0.0/0 open entry) so operator-run local-exec provisioners and post-deploy smoke can reach Atlas while the public internet cannot. Deploy scripts auto-detect this via checkip.amazonaws.com (override with OPERATOR_IP_CIDR). Ignored when network_mode='peering' (the peered VPC CIDR is used instead, and the operator laptop /32 is added by modules/atlas-vpc-peering)."

  validation {
    condition     = var.operator_ip_cidr == "" || can(cidrnetmask(var.operator_ip_cidr))
    error_message = "operator_ip_cidr must be empty or a valid IPv4 CIDR (e.g. 203.0.113.42/32)."
  }
}

