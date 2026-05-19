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
  description = "AWS region for dashboard widgets."
}

variable "sns_topic_arn" {
  type        = string
  description = "SNS topic ARN to route alarms to. Pass module.cloudwatch_fleet_dashboards.sns_topic_arn when Phase 3 is also active. Empty disables alarm notifications (alarms still fire/render in the console)."
  default     = ""
}

variable "replication_lag_threshold_ms" {
  type        = number
  description = "Alarm threshold for the worst secondary replication lag (ms)."
  default     = 5000
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged onto every resource."
  default     = {}
}
