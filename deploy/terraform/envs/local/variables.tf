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

variable "kb_docs_bucket_name" {
  type        = string
  default     = ""
  description = "Optional dedicated S3 bucket for KB source docs. Empty = use the shared bucket."
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

# Voyage embedding output dimension. Default 1024 matches VOYAGE_DEFAULT_EMBEDDING_DIMS
# in api/src/adapters/voyage-embedding.ts (the SSOT). Terraform can't shell out to
# voyage-print.ts, so this default is pinned by the bun guard test
# `voyage SSOT — terraform <-> TS parity for embedding dim`. Deploy scripts
# derive this Terraform variable from VOYAGE_OUTPUT_DIM via voyage_embedding_dims.
# Only voyage-multimodal-3.5 supports non-1024 Matryoshka dims (256/512/1024/2048).
variable "voyage_output_dim" {
  type        = number
  default     = 1024
  description = "Voyage embedding output dimension passed to seed-indexes.ts (Atlas numDimensions). Derived from VOYAGE_OUTPUT_DIM by deploy scripts."
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

# WHY: local mode talks to Atlas over the public SRV endpoint from the laptop,
# so the laptop's /32 MUST be on the allowlist. Previously this worked only
# because the module defaulted to 0.0.0.0/0; now that the module is locked down,
# local mode has to supply the operator IP explicitly or the laptop locks
# itself out of its own cluster.
variable "operator_ip_cidr" {
  type        = string
  default     = ""
  description = "Operator/laptop public IP in CIDR /32 form. Local mode runs the mongodb-atlas module in its default 'privatelink' shape, so this is the ONLY Atlas IP access list entry created (replaces the former 0.0.0.0/0 open entry). Without it the local cluster has no public-SRV allowlist entry and your laptop cannot reach it. Auto-detected and written to terraform.tfvars by deploy-local.sh (override with OPERATOR_IP_CIDR / TF_VAR_my_ip in .env)."

  validation {
    condition     = var.operator_ip_cidr == "" || can(cidrnetmask(var.operator_ip_cidr))
    error_message = "operator_ip_cidr must be empty or a valid IPv4 CIDR (e.g. 203.0.113.42/32)."
  }
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
