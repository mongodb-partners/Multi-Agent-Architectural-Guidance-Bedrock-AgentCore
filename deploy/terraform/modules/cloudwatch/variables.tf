variable "project_name" {
  type        = string
  description = "Operator/team project name. Used for the Project tag only — log group names use shared_resource_prefix so multiple per-project envs/ec2 stacks share one set of log groups."
}

variable "shared_resource_prefix" {
  type        = string
  description = "Prefix used in the log group path (/$${shared_resource_prefix}/<env>/api, .../ui, .../mcp, .../agentcore). Passed in from envs/shared so renaming \"multiagent\" → anything else is one-variable change. envs/local overrides to \"multiagent-local\" so its log groups never collide with the envs/shared singleton set."
  default     = "multiagent"
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
