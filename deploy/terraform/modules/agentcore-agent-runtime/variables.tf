variable "aws_region" { type = string }
variable "project_name" { type = string }
variable "environment" { type = string }
variable "account_id" { type = string }

variable "runtime_name" {
  type        = string
  description = "Unique name for this runtime, e.g. 'bedrock-ma-use1-orchestrator-dev'. Used for the AgentCore runtime name, IAM role, and state file. Must be unique across all 4 runtimes."
}

variable "container_uri" {
  type        = string
  description = "ECR URI of the ARM64 agent-runtime image (required when deployment_mode=container)"
  default     = ""
}

variable "deployment_mode" {
  type        = string
  description = "Runtime artifact mode: container (ECR image) or code (S3 zip + NODE_22/Python runtime)"
  default     = "container"

  validation {
    condition     = contains(["container", "code"], var.deployment_mode)
    error_message = "deployment_mode must be one of: container, code"
  }
}

variable "code_artifact_bucket" {
  type        = string
  description = "S3 bucket containing direct-code deployment zip (required when deployment_mode=code)"
  default     = ""
}

variable "code_artifact_prefix" {
  type        = string
  description = "S3 object key for direct-code deployment zip (required when deployment_mode=code)"
  default     = ""
}

variable "code_artifact_version_id" {
  type        = string
  description = "Optional S3 object version for direct-code deployment zip"
  default     = ""
}

variable "code_runtime" {
  type        = string
  description = "Direct-code runtime identifier used by AgentCore (for example NODE_22)"
  default     = "NODE_22"
}

variable "code_entry_point" {
  type        = list(string)
  description = "Entry point path list for direct-code deployment (for example [\"agent-runtime-code.js\"])"
  default     = ["agent-runtime-code.js"]
}

variable "environment_variables" {
  type        = map(string)
  description = "Environment variables injected into the runtime container (MONGODB_URI, AGENTCORE_MEMORY_STORE_ID, etc.)"
  default     = {}
  sensitive   = true
}

variable "lambda_mcp_function_arn" {
  type        = string
  description = "Optional Lambda MCP function ARN. When set, runtime role gets lambda:InvokeFunction."
  default     = ""
}

variable "kb_secret_name_prefix" {
  type        = string
  description = "Secrets Manager secret-name prefix the runtime can read (typically the bedrock-kb module's atlas_secret_name output, e.g. <project_name>-bedrock-kb-creds-<environment>). The IAM policy grants secretsmanager:GetSecretValue on <prefix>-*. Leave empty to skip the SecretsManager statement."
  default     = ""
}

variable "network_mode" {
  type        = string
  description = "PUBLIC (shared AWS infra, no VPC) or VPC. Use PUBLIC for POC — no NAT gateway needed."
  default     = "PUBLIC"

  validation {
    condition     = contains(["PUBLIC", "VPC"], var.network_mode)
    error_message = "network_mode must be PUBLIC or VPC"
  }
}

variable "idle_timeout_seconds" {
  type        = number
  description = "Seconds of inactivity before a runtime session is terminated"
  default     = 900
}

variable "tags" {
  type    = map(string)
  default = {}
}
