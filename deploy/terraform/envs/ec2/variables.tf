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
  description = "Allow the mongodb-mcp AgentCore Runtime to perform insertOne / updateOne. Default false — the handler is read-only unless this is explicitly flipped. Destructive ops (delete*, drop*, replaceOne, …) remain refused regardless."
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

variable "enable_kb_privatelink" {
  type        = bool
  description = <<-EOT
    SoW alignment for CLIENT_REVIEW P1-6 (Option A): provision an NLB + VPC
    Endpoint Service so Bedrock Knowledge Base ingestion connects to MongoDB
    Atlas via AWS PrivateLink instead of the public SRV hostname.

    Default `true` — the SoW requires PrivateLink end-to-end for Atlas access,
    including KB ingestion. Setting this to `false` is an explicit, written
    deviation from the SoW (admin-only ingestion still avoids runtime PII, but
    leaves the path on public Atlas SRV) — do not flip without sign-off.

    When true, an instance of modules/bedrock-kb-privatelink is created and
    its endpoint_service_name is forwarded into module.bedrock_kb. Cost:
    fixed NLB (~$22/mo) plus per-LCU billing.
  EOT
  default     = true
}

# ── Voyage AI (optional) ──────────────────────────────────────────────────────
variable "voyage_model_package_arn" {
  type        = string
  description = "AWS Marketplace SageMaker model package ARN for Voyage embeddings. Empty disables SageMaker; non-empty must point at a voyage-multimodal-3 package."
  default     = ""

  validation {
    condition = (
      var.voyage_model_package_arn == ""
      || can(regex("^arn:aws:sagemaker:[a-z0-9-]+:[0-9]{12}:model-package/voyage-multimodal-3($|-)", var.voyage_model_package_arn))
    )
    error_message = "voyage_model_package_arn must be empty or point at a voyage-multimodal-3 SageMaker Marketplace model package. Non-multimodal Voyage packages are not allowed."
  }
}

variable "voyage_instance_type" {
  type    = string
  default = "ml.g6.xlarge"
}

variable "voyage_endpoint_name_suffix" {
  type        = string
  description = "Identifier baked into the SageMaker endpoint name. Defaults to voyage-multimodal-3 (the SoW model). Set to voyage-3-5-lite if you intentionally subscribe to the older listing."
  default     = "voyage-multimodal-3"
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
