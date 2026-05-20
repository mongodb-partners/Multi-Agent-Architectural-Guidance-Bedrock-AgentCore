variable "aws_region" {
  type        = string
  description = "AWS region the shared SageMaker endpoint, log groups, and dashboards are deployed in. From env.sh AWS_REGION."
}

variable "project_name" {
  type        = string
  description = "Operator/team project name from env.sh PROJECT_NAME. Used for cost-allocation default tag and state bucket lookup. Resource names use shared_vpc_name / env-derived identifiers instead."
}

variable "environment" {
  type        = string
  description = "Deployment environment (e.g. dev, staging, prod). From env.sh ENVIRONMENT. Used in module-derived resource names and state bucket lookup."
}

variable "shared_vpc_name" {
  type        = string
  description = "Shared network identity (e.g. \"shared-network\"). Drives the SSM parameter prefix that envs/network publishes under and envs/ec2 reads from. envs/shared publishes additional keys under the same prefix. Sourced from env.sh SHARED_VPC_NAME — intentionally has no default so the value can never accidentally come from a terraform default."
}

variable "shared_bucket_name" {
  type        = string
  description = "Shared S3 bucket used for Terraform state + ADOT collector config storage. Provisioned by the bootstrap stack."
}

variable "shared_resource_prefix" {
  type        = string
  description = "Single source of truth for the prefix used in env-scoped, shared-stack-owned resource names — log groups (/$${prefix}/<env>/api), dashboards ($${prefix}-fleet-<env>), alarms, metric filters, query definitions, and SageMaker IAM role. Drop the project_name from this — multiple per-project envs/ec2 stacks share the resulting resources, so the prefix must be stable per (account, region, environment)."
  default     = "multiagent"
}

# ── Voyage AI SageMaker (optional) ────────────────────────────────────────────
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
  type        = string
  description = "SageMaker endpoint instance type (must be GPU; Voyage AI model packages require ml.g6.xlarge or ml.g5.xlarge)."
  default     = "ml.g6.xlarge"
}

variable "voyage_endpoint_name_suffix" {
  type        = string
  description = "Identifier baked into the SageMaker endpoint name. Use voyage-multimodal-3 for the SoW model or voyage-3-5-lite for the supported legacy text-only listing."
  default     = "voyage-multimodal-3"
}

# ── CloudWatch retention ──────────────────────────────────────────────────────
variable "log_retention_days" {
  type        = number
  description = "Retention (days) applied to the shared API / UI / MCP / AgentCore / OTel log groups."
  default     = 30
}

# ── Fleet dashboards + alarms ─────────────────────────────────────────────────
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

# ── Atlas dashboard ───────────────────────────────────────────────────────────
variable "enable_atlas_metrics" {
  type        = bool
  description = "Provision modules/cloudwatch-atlas-dashboard. The Atlas Prometheus secret + ADOT scrape still live per-project in envs/ec2; this only governs the dashboard + alarms layer."
  default     = false
}

variable "atlas_replication_lag_threshold_ms" {
  type        = number
  description = "Alarm threshold for Atlas secondary replication lag."
  default     = 5000
}

# ── Bedrock invocation logging (account-scoped) ───────────────────────────────
variable "enable_bedrock_invocation_logging" {
  type        = bool
  description = "Provision modules/bedrock-invocation-logging. Account-scoped resource — set false when another stack in this AWS account already owns it."
  default     = true
}

variable "log_prompt_bodies" {
  type        = bool
  description = "Deliver raw prompt + completion bodies to /aws/bedrock/invocations. Defaults FALSE for privacy. Flip per-environment only with security sign-off (the attached Data Protection Policy still masks PII, but the body still gets written before masking)."
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
  description = "Managed PII identifiers for the Data Protection Policy attached to the Bedrock invocation log group. Defaults cover language- + region-independent PII (always valid). Add country-scoped identifiers per environment as needed: e.g. PhoneNumber-US, PhoneNumber-GB, BankAccountNumber-US, Ssn."
  default = [
    "EmailAddress",
    "CreditCardNumber",
    "AwsSecretKey",
    "IpAddress",
  ]
}
