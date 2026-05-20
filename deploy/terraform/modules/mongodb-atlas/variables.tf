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
  description = "Connectivity mode. 'privatelink' (default) keeps the existing 0.0.0.0/0 IP access list entry — Bedrock KB ingestion uses public SRV when enable_kb_privatelink=false. 'peering' replaces the open entry with var.vpc_cidr — runtime + Bedrock KB both reach Atlas privately via VPC peering."

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

