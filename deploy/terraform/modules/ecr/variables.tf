variable "project_name" {
  type        = string
  description = "Name prefix applied to all resources"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
  default     = "dev"
}
