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
  description = "Identifier baked into the SageMaker endpoint name. Use voyage-multimodal-3 for the SoW model or voyage-3-5-lite for the supported legacy text-only listing."
  default     = "voyage-multimodal-3"
}

# ── AgentCore ─────────────────────────────────────────────────────────────────
variable "specialist_agents" {
  type        = list(object({ id = string, runtime_name = string }))
  description = "Specialist AgentCore Runtimes to provision. Populated from config/agents/*.agent.md (excluding the orchestrator) by deploy.sh / deploy-agents.sh via agents.auto.tfvars.json. Adding a new entry creates a new runtime; removing one destroys it on next apply."
  default     = []

  validation {
    condition     = alltrue([for a in var.specialist_agents : can(regex("^[a-z0-9-]+$", a.id))])
    error_message = "Each specialist_agents[].id must be lowercase-kebab-case (matches config/agents/<id>.agent.md)."
  }
}

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

variable "create_agentcore_runtime_vpc_endpoints" {
  type        = bool
  description = "Create ECR API, ECR Docker, CloudWatch Logs interface endpoints and the S3 gateway endpoint for VPC-mode AgentCore runtimes. Set false when the shared VPC already has these singleton endpoints."
  default     = true
}

# ── CloudWatch ────────────────────────────────────────────────────────────────
variable "log_retention_days" {
  type    = number
  default = 30
}

# ── CloudWatch GenAI Observability ────────────────────────────────────────────
variable "enable_genai_observability" {
  type        = bool
  description = "Provision modules/cloudwatch-genai (Transaction Search + AgentCore vended log delivery). Defaults to true; set false to skip in stacks that share an account with another team's GenAI Observability config."
  default     = true
}

variable "span_retention_days" {
  type        = number
  description = "Retention for the aws/spans Transaction Search log group."
  default     = 14
}

variable "enable_transaction_search_toggle" {
  type        = bool
  description = "Run the X-Ray CLI calls that switch span destination to CloudWatch Logs and set the indexing sampling rate. Safe to leave true after the first apply — the null_resource is idempotent."
  default     = true
}

variable "span_sampling_percent" {
  type        = number
  description = "X-Ray Transaction Search indexing percentage (0-100). 100 = every span indexed (best for dev), 10 = sample 10% (typical prod). Underlying spans always land in /aws/spans either way."
  default     = 100

  validation {
    condition     = var.span_sampling_percent >= 0 && var.span_sampling_percent <= 100
    error_message = "span_sampling_percent must be between 0 and 100."
  }
}

variable "agentcore_vended_log_retention_days" {
  type        = number
  description = "Retention for AgentCore memory + gateway vended APPLICATION_LOGS log groups."
  default     = 7
}

# ── Bedrock invocation logging ────────────────────────────────────────────────
variable "enable_bedrock_invocation_logging" {
  type        = bool
  description = "Provision modules/bedrock-invocation-logging. Account-scoped resource — set false when another stack in this AWS account already owns it."
  default     = true
}

variable "log_prompt_bodies" {
  type        = bool
  description = "Deliver raw prompt + completion bodies to /aws/bedrock/invocations. Defaults FALSE for privacy. Flip true per-environment only with security sign-off (the attached Data Protection Policy still masks PII, but the body still gets written before masking)."
  default     = false
}

variable "log_embedding_bodies" {
  type        = bool
  description = "Deliver raw embedding input text. Defaults FALSE — embeddings can encode user text and so leak semantically."
  default     = false
}

variable "invocation_retention_days" {
  type        = number
  description = "Retention for the Bedrock invocation log group. 7 dev / 30 prod typical; longer for regulated industries."
  default     = 7
}

variable "data_protection_identifiers" {
  type        = list(string)
  description = "Managed PII identifiers for the Data Protection Policy attached to the Bedrock invocation log group. Defaults cover language- + region-independent PII (always valid). Add country-scoped identifiers per environment as needed: e.g. PhoneNumber-US, PhoneNumber-GB, BankAccountNumber-US, Ssn. Full list: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL-managed-data-identifiers.html"
  default = [
    "EmailAddress",
    "CreditCardNumber",
    "AwsSecretKey",
    "IpAddress",
  ]
}

# ── ADOT Collector sidecar (Phase 2) ──────────────────────────────────────────
variable "enable_adot_collector" {
  type        = bool
  description = "Provision modules/adot-collector and install the sidecar systemd unit on EC2. When false the API and UI fall back to in-process OTel only (no /aws/spans / no GenAI Observability traces from the application). Default true."
  default     = true
}

variable "adot_collector_image" {
  type        = string
  description = "OCI image for the ADOT collector container. Default uses the public-ecr :latest tag; pin a digest in prod for repeatable builds."
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:latest"
}

variable "otel_sample_ratio" {
  type        = string
  description = "OTEL_TRACES_SAMPLER_ARG injected into the API container. 1.0 = sample everything (dev). 0.1 = 10% (typical prod)."
  default     = "1.0"
}

# ── MongoDB Atlas → CloudWatch metrics (Phase 4) ──────────────────────────────
variable "enable_atlas_metrics" {
  type        = bool
  description = "Phase 4 toggle. When true, provisions an Atlas Prometheus credentials secret and extends the ADOT collector config with a prometheus receiver + awsemf exporter pushing to the MongoDB/Atlas CloudWatch namespace. Default false."
  default     = false
}

variable "atlas_scrape_interval_sec" {
  type        = number
  description = "Atlas Prometheus scrape cadence. 60s is the recommended floor."
  default     = 60
}

variable "atlas_prom_username" {
  type        = string
  description = "Atlas Prometheus integration username (generated in Atlas UI → Project → Integrations → Prometheus). Stored in Secrets Manager when enable_atlas_metrics=true; unused otherwise."
  default     = ""
  sensitive   = true
}

variable "atlas_prom_password" {
  type        = string
  description = "Atlas Prometheus integration password."
  default     = ""
  sensitive   = true
}

variable "atlas_prom_host" {
  type        = string
  description = "Atlas Prometheus scrape host, e.g. <group-id>-prometheus.mongodb.com (from Atlas UI)."
  default     = ""
}

variable "atlas_replication_lag_threshold_ms" {
  type        = number
  description = "Alarm threshold for Atlas secondary replication lag (Phase 4)."
  default     = 5000
}

# ── Fleet dashboards + alarms (Phase 3) ───────────────────────────────────────
variable "enable_fleet_dashboards" {
  type        = bool
  description = "Provision modules/cloudwatch-fleet-dashboards (3 dashboards, 7 alarms, audit metric filter, query library). Default true."
  default     = true
}

variable "p99_latency_threshold_ms" {
  type        = number
  description = "P99 chat-turn latency alarm threshold (ms)."
  default     = 12000
}

variable "error_rate_threshold_pct" {
  type        = number
  description = "Error-rate alarm threshold as %."
  default     = 2
}

variable "throttle_burst_threshold" {
  type        = number
  description = "Bedrock throttle alarm threshold (count of ThrottlingException per 5 minutes)."
  default     = 5
}
