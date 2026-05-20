variable "project_name" {
  type        = string
  description = "Operator/team project name. Used for the Project tag only — dashboard + alarm names use shared_resource_prefix so they are stable per (account, region, environment) across multiple per-project envs/ec2 stacks."
}

variable "shared_resource_prefix" {
  type        = string
  description = "Prefix used in the dashboard name ($${prefix}-atlas-<env>) and the connection-saturation + replication-lag alarm names. Passed in from envs/shared so renaming \"multiagent\" → anything else is one-variable change."
  default     = "multiagent"
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
  description = "SNS topic ARN to route alarms to. Both this module and module.cloudwatch_fleet_dashboards live in envs/shared, so pass module.cloudwatch_fleet_dashboards[0].sns_topic_arn directly (same state, no SSM hop) when fleet dashboards are also enabled. Empty disables alarm notifications (alarms still fire/render in the console)."
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
