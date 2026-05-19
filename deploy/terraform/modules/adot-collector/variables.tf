variable "project_name" {
  type        = string
  description = "Project name prefix used for resource naming + Project tag."
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)."
}

variable "aws_region" {
  type        = string
  description = "AWS region — written into the collector config so awsxray/awscloudwatchlogs sign against the right endpoint."
}

variable "shared_bucket_name" {
  type        = string
  description = "Shared S3 bucket that holds the rendered collector config. EC2 user_data fetches from here on boot."
}

variable "otel_log_group_name" {
  type        = string
  description = "Default CW Logs group for OTLP-shipped application logs (distinct from /api which receives file-tailed logs via amazon-cloudwatch-agent)."
  default     = ""
}

variable "otel_retention_days" {
  type        = number
  description = "Retention for the OTLP log group."
  default     = 14
}

variable "enable_atlas_metrics" {
  type        = bool
  description = "Phase 4 toggle. When true, adds a Prometheus receiver scraping MongoDB Atlas and an awsemf exporter publishing to the MongoDB/Atlas CloudWatch namespace."
  default     = false
}

variable "atlas_scrape_interval_sec" {
  type        = number
  description = "Atlas Prometheus scrape interval. 60s is the recommended cadence — faster bumps cost without proportional signal."
  default     = 60
}

variable "atlas_secret_arn" {
  type        = string
  description = "Secrets Manager ARN holding the Atlas Prometheus credentials. Populated when enable_atlas_metrics=true; otherwise the receiver block is omitted from the rendered config."
  default     = ""
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags merged onto every resource."
}
