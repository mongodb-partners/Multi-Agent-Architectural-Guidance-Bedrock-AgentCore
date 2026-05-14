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

