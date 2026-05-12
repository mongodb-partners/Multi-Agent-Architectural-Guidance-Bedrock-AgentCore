variable "project_name" {
  type        = string
  description = "Project name prefix"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
}

variable "retention_days" {
  type        = number
  description = "Log retention in days"
  default     = 30
}
