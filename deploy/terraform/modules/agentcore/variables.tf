variable "project_name" {
  type        = string
  description = "Project name prefix for resource names and tags"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "mcp_server_url" {
  type        = string
  description = "HTTP URL of the mongodb-mcp-server. Local mode: http://localhost:8080/mcp — EC2 mode: same (same host)."
  default     = "http://localhost:8080/mcp"
}
