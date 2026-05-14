variable "aws_region" {
  type        = string
  description = "AWS region (kept for backward compatibility with callers — the native aws_bedrockagentcore_memory resource takes its region from the provider)"
}

variable "project_name" {
  type        = string
  description = "Resource name prefix"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
}

variable "event_expiry_days" {
  type        = number
  description = "How many days to retain memory events (short-term memory TTL)"
  default     = 30
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the Memory Store"
  default     = {}
}
