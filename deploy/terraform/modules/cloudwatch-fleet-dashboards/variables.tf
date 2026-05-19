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
  description = "AWS region — interpolated into dashboard JSON for region-pinned widgets."
}

variable "api_log_group_name" {
  type        = string
  description = "CloudWatch Logs group for the API container."
}

variable "ui_log_group_name" {
  type        = string
  description = "CloudWatch Logs group for the Streamlit UI."
}

variable "invocation_log_group_name" {
  type        = string
  description = "Bedrock invocation log group (/aws/bedrock/invocations). Empty disables PII / cost widgets + the AuditFindings alarm + the per-user-cost Logs Insights query."
  default     = ""
}

variable "audit_findings_log_group_name" {
  type        = string
  description = "Log group where the Data Protection Audit operation writes findings. AWS forbids the source log group from being its own audit destination, so this is a separate group (typically `<invocation>-audit`). Empty defaults back to invocation_log_group_name for backwards compatibility, but that will fail on real audit emissions."
  default     = ""
}

variable "otel_log_group_name" {
  type        = string
  description = "OTLP-shipped application log group (from modules/adot-collector). Used by the Top Errors query and the OTel-source dashboard widgets."
  default     = ""
}

variable "p99_latency_threshold_ms" {
  type        = number
  description = "P99 turn latency alarm threshold in milliseconds."
  default     = 12000
}

variable "error_rate_threshold_pct" {
  type        = number
  description = "Error-rate alarm threshold as a percentage (e.g. 2 = 2 errors per 100 turns)."
  default     = 2
}

variable "throttle_burst_threshold" {
  type        = number
  description = "Bedrock throttle alarm threshold (count of ThrottlingException per 5 minutes)."
  default     = 5
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged onto every resource."
  default     = {}
}
