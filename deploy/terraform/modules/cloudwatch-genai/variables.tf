variable "project_name" {
  type        = string
  description = "Project name prefix used for resource naming + Project tag."
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)."
}

variable "span_retention_days" {
  type        = number
  description = "Retention for the aws/spans Transaction Search log group. Spans are big; 14 days is the sweet spot between debugging window and cost."
  default     = 14
}

variable "span_sampling_percent" {
  type        = number
  description = "X-Ray Transaction Search indexing percentage (0-100). 100 keeps every span indexed (cheap in dev, costly in prod). 10 is a sensible prod default — the underlying spans land in /aws/spans either way, only the indexed-summary slice is sampled."
  default     = 100

  validation {
    condition     = var.span_sampling_percent >= 0 && var.span_sampling_percent <= 100
    error_message = "span_sampling_percent must be between 0 and 100."
  }
}

variable "agentcore_log_retention_days" {
  type        = number
  description = "Retention for AgentCore vended log groups (memory + gateway APPLICATION_LOGS). Defaults to 7 to mirror the existing /agentcore placeholder retention in modules/cloudwatch."
  default     = 7
}

variable "enable_transaction_search_toggle" {
  type        = bool
  default     = false
  description = "When true, the module runs `aws xray update-trace-segment-destination CloudWatchLogs` + `update-indexing-rule Default` to enable Transaction Search account-wide. Requires the caller's identity to hold xray:UpdateTraceSegmentDestination + xray:UpdateIndexingRule. Default is OFF because Transaction Search is an account-wide singleton — most prod accounts toggle it ONCE from the console by an admin and never re-toggle. See docs/observability-runbook.md §10 for the one-time manual step."
}

variable "agentcore_memories" {
  type        = map(string)
  default     = {}
  description = "Map of AgentCore Memory id -> full ARN. Preferred over agentcore_memory_ids — pass {(module.agentcore_memory.memory_id) = module.agentcore_memory.memory_arn} from envs/ec2 so the ARN is partition-safe (aws / aws-gov / aws-cn) and survives future ARN format changes."
}

variable "agentcore_gateways" {
  type        = map(string)
  default     = {}
  description = "Map of AgentCore Gateway id -> full ARN. Preferred over agentcore_gateway_ids — see agentcore_memories for rationale."
}

variable "agentcore_memory_ids" {
  type        = list(string)
  description = "AgentCore Memory IDs to wire vended log delivery for. Pass module.agentcore_memory.memory_id (wrapped in [...]) from envs/ec2; the module fans out a delivery source + destination + delivery per id."
  default     = []
}

variable "agentcore_gateway_ids" {
  type        = list(string)
  description = "AgentCore Gateway IDs to wire vended log delivery for. Pass module.agentcore_gateway.gateway_id (wrapped in [...]) from envs/ec2."
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged onto every resource (in addition to Project / Environment / ManagedBy / Component)."
  default     = {}
}
