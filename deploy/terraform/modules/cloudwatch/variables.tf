variable "project_name" {
  type        = string
  description = "Project name prefix"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
}

variable "api_retention_days" {
  type        = number
  description = "Retention for the API log group (audit / compliance)"
  default     = 30
}

variable "aux_retention_days" {
  type        = number
  description = "Retention for UI, MCP, and AgentCore placeholder log groups"
  default     = 7
}
