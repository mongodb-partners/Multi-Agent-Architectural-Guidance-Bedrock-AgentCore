variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "account_id" {
  type        = string
  description = "AWS account ID (from data.aws_caller_identity)"
}

variable "project_name" {
  type        = string
  description = "Resource name prefix"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
}

# ── Atlas connection (used to build the Secrets Manager secret) ───────────────
variable "atlas_project_id" {
  type        = string
  description = "MongoDB Atlas Project ID — required for the vector search index resource"
}

variable "atlas_cluster_name" {
  type        = string
  description = "Atlas cluster name — required for the vector search index resource"
}

variable "atlas_srv_host" {
  type        = string
  description = "Atlas SRV hostname without scheme, e.g. troubleshooting-demo.9mtgg.mongodb.net"
}

variable "kb_endpoint_host" {
  type        = string
  default     = ""
  description = "Optional Atlas hostname for the Bedrock KB storage endpoint. Leave empty to use atlas_srv_host. When endpoint_service_name is set for PrivateLink, pass the Atlas -pl SRV hostname here while keeping atlas_srv_host on the normal SRV for local collection seeding."
}

variable "atlas_db_user" {
  type        = string
  description = "Atlas database username"
}

variable "atlas_db_password" {
  type        = string
  sensitive   = true
  description = "Atlas database password"
}

variable "atlas_db_name" {
  type        = string
  description = "MongoDB database name. Caller must supply; no default so multiple deployments don't collide on a shared Atlas project."
}

variable "atlas_collection" {
  type        = string
  default     = "troubleshooting_docs"
  description = "MongoDB collection used as the KB vector store"
}

variable "atlas_vector_index" {
  type        = string
  default     = "troubleshooting-vector-index"
  description = "Atlas Vector Search index name on the collection"
}

variable "embedding_dimensions" {
  type        = number
  default     = 1024
  description = "Dimensions of the embedding model output. Titan Embed Text v2 = 1024."
}

# Path to the helper script that ensures the database/collection exist.
# Must be a path relative to terraform CWD or absolute.
variable "ensure_collection_script" {
  type        = string
  description = "Path to db-seeding/ensure-collection.ts"
}

variable "ingestion_required" {
  type        = bool
  default     = true
  description = "Whether Bedrock KB ingestion failure should fail Terraform apply. Keep true for supported paths; peering-NLB can set false because the connector path is experimental and may time out even when the rest of the peering deployment is healthy."
}

# ── IAM ───────────────────────────────────────────────────────────────────────
variable "kb_iam_role_name" {
  type        = string
  default     = ""
  description = "Override for the Bedrock KB IAM role name. Leave empty (default) to auto-derive <project_name>-bedrock-kb-<environment>-role, which guarantees uniqueness across deployments in the same AWS account."
}

# ── Embedding ─────────────────────────────────────────────────────────────────
variable "embed_model_id" {
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
  description = "Bedrock foundation model ID used for KB ingestion embeddings"
}

# ── Shared S3 bucket (created by deploy/terraform/bootstrap) ─────────────────
variable "shared_bucket_name" {
  type        = string
  description = "Name of the shared S3 bucket. KB docs are uploaded to the kb-docs/docs/ prefix."
}

variable "shared_bucket_arn" {
  type        = string
  description = "ARN of the shared S3 bucket. Used in IAM policies and the Bedrock data source config."
}

variable "kb_docs_bucket_name" {
  type        = string
  default     = ""
  description = "Optional dedicated S3 bucket for KB source docs. Empty = use shared_bucket_name. Must be globally unique."

  validation {
    # Fast-fail at plan time on names AWS would reject at apply (S3 bucket
    # naming rules: 3-63 chars, lowercase letters/digits/hyphens/dots, must
    # start and end with a letter or digit). Empty = use the shared bucket.
    condition     = var.kb_docs_bucket_name == "" || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.kb_docs_bucket_name))
    error_message = "kb_docs_bucket_name must be a valid S3 bucket name (3-63 chars, lowercase letters/digits/hyphens/dots, start/end alphanumeric), or empty to use the shared bucket."
  }
}

# ── KB docs ───────────────────────────────────────────────────────────────────
variable "kb_docs_path" {
  type        = string
  description = "Absolute or relative path to the directory containing KB source .txt files"
}

variable "common_tags" {
  type        = map(string)
  default     = {}
  description = "Common tags applied to log groups and other taggable resources in this module."
}

# ── Optional: PrivateLink ingestion (CLIENT_REVIEW P1-6 Option A) ──────────────
variable "endpoint_service_name" {
  type        = string
  default     = ""
  description = <<-EOT
    Optional VPC Endpoint Service name (e.g. com.amazonaws.vpce.us-east-1.vpce-svc-XXXX) that fronts an
    NLB → Atlas VPCE path. When non-empty it is forwarded to the
    aws_bedrockagent_knowledge_base storage_configuration so Bedrock-managed
    ingestion connects to MongoDB Atlas via AWS PrivateLink instead of the
    public SRV hostname. Provisioned by the bedrock-kb-privatelink module
    (see envs/ec2/main.tf var.enable_kb_privatelink). Leave empty to keep
    the documented Option B fallback (public SRV; admin-only ingest traffic).
  EOT
}
