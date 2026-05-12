variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "project_name" {
  type        = string
  description = "Resource name prefix"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the Lambda ENIs will be attached"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the Lambda ENIs (PrivateLink access to Atlas)"
}

variable "mongodb_uri" {
  type        = string
  sensitive   = true
  description = "MongoDB connection string (uses PrivateLink private hostname when available)"
}

variable "mongodb_db" {
  type        = string
  description = "Default MongoDB database name. Caller must supply a project+env-scoped value (no default) so multiple deployments don't collide on a shared Atlas project."
}

variable "lambda_source_dir" {
  type        = string
  description = "Absolute path to the Lambda handler source directory (contains index.mjs + node_modules)"
}

variable "artifact_bucket_name" {
  type        = string
  description = "S3 bucket name used to store Lambda deployment artifacts"
}

variable "artifact_key_prefix" {
  type        = string
  description = "S3 key prefix for Lambda deployment artifacts"
  default     = "artifacts/lambda-mcp"
}

variable "timeout_seconds" {
  type        = number
  description = "Lambda timeout in seconds"
  default     = 30
}

variable "memory_mb" {
  type        = number
  description = "Lambda memory (MB). Higher = more CPU."
  default     = 512
}

variable "allow_write" {
  type        = bool
  description = "Allow insertOne / updateOne via the MCP handler. When false (default), the handler refuses write operations even though the Atlas DB user might have permission. Mirrors api/src/adapters/mongo-data.ts MONGODB_ALLOW_WRITE."
  default     = false
}

variable "max_limit" {
  type        = number
  description = "Maximum number of documents the handler will return from find/aggregate, regardless of the caller's limit. Defense in depth so one bad agent call can't exfiltrate a whole collection."
  default     = 200
}
