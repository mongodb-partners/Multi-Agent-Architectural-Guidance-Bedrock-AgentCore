variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "multiagent-mongodb-framework"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "shared_bucket_name" {
  type = string
}

# ── Atlas ─────────────────────────────────────────────────────────────────────
variable "atlas_project_id" {
  type = string
}

variable "atlas_db_user" {
  type        = string
  description = "MongoDB Atlas database username. Caller must supply a project+env-scoped value, e.g. <PROJECT_NAME>_<ENVIRONMENT>_user."
}

variable "atlas_db_password" {
  type      = string
  sensitive = true
}

variable "atlas_db_name" {
  type        = string
  description = "MongoDB Atlas database name. Caller must supply a project+env-scoped value, e.g. <PROJECT_NAME>_<ENVIRONMENT> (underscored)."
}

variable "atlas_public_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "atlas_private_key" {
  type      = string
  sensitive = true
  default   = ""
}

# ── Bedrock KB ────────────────────────────────────────────────────────────────
variable "kb_iam_role_name" {
  type        = string
  default     = ""
  description = "Override for the Bedrock KB IAM role name. Leave empty (default) to auto-derive <project_name>-bedrock-kb-<environment>-role inside the bedrock-kb module."
}

variable "embed_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

# ── CloudWatch ────────────────────────────────────────────────────────────────
variable "log_retention_days" {
  type    = number
  default = 30
}
