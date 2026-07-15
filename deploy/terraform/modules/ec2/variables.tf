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

variable "vpc_id" {
  type        = string
  description = "VPC ID to launch the instance in"
}

variable "public_subnet_id" {
  type        = string
  description = "Public subnet ID — instance gets a public IP via Elastic IP"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type. t3.medium (2 vCPU / 4 GB) is the recommended minimum for running both API + UI."
  default     = "t3.medium"
}

variable "key_pair_name" {
  type        = string
  description = "Name of an existing EC2 key pair for SSH access. Leave empty to use SSM Session Manager instead (no key pair needed)."
  default     = ""
}

variable "ecr_api_image" {
  type        = string
  description = "Full ECR image URI for the API container (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com/project-api:latest)"
  default     = ""
}

variable "ecr_ui_image" {
  type        = string
  description = "Full ECR image URI for the UI container (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com/project-ui:latest)"
  default     = ""
}

variable "ecr_registry" {
  type        = string
  description = "ECR registry hostname for docker login (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com)"
  default     = ""
}

variable "cw_log_group_api" {
  type        = string
  description = "CloudWatch Logs group name for API journald → agent (must exist before first PutLogEvents)"
}

variable "cw_log_group_ui" {
  type        = string
  description = "CloudWatch Logs group name for UI journald → agent"
}

# ── ADOT Collector sidecar (Phase 2) ──────────────────────────────────────────
variable "adot_collector_image" {
  type        = string
  description = "OCI image for the AWS Distro for OpenTelemetry Collector. Default uses the public-ecr image; pin a digest for prod."
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:latest"
}

variable "adot_config_s3_bucket" {
  type        = string
  description = "S3 bucket containing the rendered ADOT collector config. Empty disables the sidecar (Phase 1 / legacy deployments)."
  default     = ""
}

variable "adot_config_s3_key" {
  type        = string
  description = "S3 key of the rendered ADOT collector config. Empty disables the sidecar."
  default     = ""
}

variable "adot_config_etag" {
  type        = string
  description = "Etag of the rendered ADOT config — included in user_data hash so the instance restarts the sidecar on config changes."
  default     = ""
}

variable "otel_sample_ratio" {
  type        = string
  description = "OTEL_TRACES_SAMPLER_ARG. 1.0 = sample everything (dev). 0.1 = 10% (typical prod). Quoted as string because env files want strings."
  default     = "1.0"
}

variable "atlas_prom_secret_arn" {
  type        = string
  description = "Secrets Manager ARN for the Atlas Prometheus integration credentials (Phase 4). Empty means no Atlas scraping — the EC2 fetches the secret only when this is set."
  default     = ""
}

# ── Connectivity mode ────────────────────────────────────────────────────────
variable "network_mode" {
  type        = string
  default     = "privatelink"
  description = "Connectivity mode. In 'peering' mode the EC2 host's Atlas egress is narrowed to var.atlas_peering_cidr for defense-in-depth (matches modules/bedrock-kb-peering NLB target subnet)."

  validation {
    condition     = contains(["privatelink", "peering"], var.network_mode)
    error_message = "network_mode must be either 'privatelink' or 'peering'."
  }
}

variable "atlas_peering_cidr" {
  type        = string
  default     = ""
  description = "Atlas-side peering CIDR (e.g. 192.168.248.0/21). Used to narrow Atlas-bound egress on the EC2 SG when network_mode='peering'. Ignored in privatelink mode."
}
