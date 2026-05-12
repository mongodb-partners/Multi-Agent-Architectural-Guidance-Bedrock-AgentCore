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

# ── Shared network (envs/network) ─────────────────────────────────────────────
variable "shared_vpc_name" {
  type        = string
  description = "Identity of the shared VPC + Atlas PrivateLink stack provisioned by envs/network. Drives the SSM prefix this env reads from (/<shared_vpc_name>/<aws_region>/...). Sourced from env.sh SHARED_VPC_NAME — no default on purpose so the value can never silently come from a terraform fallback."
}

# ── EC2 ───────────────────────────────────────────────────────────────────────
variable "ec2_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ec2_key_pair_name" {
  type        = string
  default     = ""
  description = "Leave empty to use SSM Session Manager (recommended)"
}

# ── Atlas ─────────────────────────────────────────────────────────────────────
variable "atlas_project_id" {
  type = string
}

variable "atlas_db_user" {
  type        = string
  description = "MongoDB Atlas database username. Caller (deploy.sh / terraform.tfvars) must supply a project+env-scoped value, e.g. <PROJECT_NAME>_<ENVIRONMENT>_user, so multiple deployments don't collide on a shared Atlas project."
}

variable "atlas_db_password" {
  type      = string
  sensitive = true
}

variable "atlas_db_name" {
  type        = string
  description = "MongoDB Atlas database name. Caller must supply a project+env-scoped value, e.g. <PROJECT_NAME>_<ENVIRONMENT> (underscored)."
}

variable "mongodb_allow_write" {
  type        = bool
  description = "Allow the mongodb-mcp Lambda to perform insertOne / updateOne. Default false — the handler is read-only unless this is explicitly flipped. Destructive ops (delete*, drop*, replaceOne, …) remain refused regardless."
  default     = false
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
  description = "Override for the Bedrock KB IAM role name. Leave empty (default) to auto-derive <project_name>-bedrock-kb-<environment>-role inside the bedrock-kb module so the role name is unique per (project, env) — required when running multiple deployments in the same AWS account."
}

variable "embed_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

# ── Voyage AI (optional) ──────────────────────────────────────────────────────
variable "voyage_model_package_arn" {
  type    = string
  default = ""
}

variable "voyage_instance_type" {
  type    = string
  default = "ml.c5.4xlarge"
}

# ── AgentCore ─────────────────────────────────────────────────────────────────
variable "agentcore_memory_expiry_days" {
  type    = number
  default = 30
}

variable "agentcore_runtime_deployment_mode" {
  type        = string
  description = "AgentCore runtime artifact mode: container or code"
  default     = "code"
}

variable "agentcore_code_artifact_prefix" {
  type        = string
  description = "S3 key for AgentCore direct-code deployment zip"
  default     = "artifacts/agentcore-runtime/deployment_package.zip"
}

# ── CloudWatch ────────────────────────────────────────────────────────────────
variable "log_retention_days" {
  type    = number
  default = 30
}

variable "lambda_artifact_key_prefix" {
  type        = string
  description = "S3 key prefix used for Lambda MCP deployment artifacts"
  default     = "artifacts/lambda-mcp"
}
