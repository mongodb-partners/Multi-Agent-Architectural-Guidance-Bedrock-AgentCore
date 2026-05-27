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
  type = map(object({
    id  = string
    arn = string
  }))
  default     = {}
  description = <<-EOT
    Map of static-key -> { id, arn } for AgentCore Memory resources.

    The KEY (e.g. "main") MUST be a static string known at plan time — NOT the
    memory_id from module.agentcore_memory. Terraform requires for_each keys
    to be known before apply, and memory_id is `(known after apply)` on a
    fresh deploy, which historically forced operators into a two-pass
    `-target` apply (see git log for the 2026-05 cloudwatch-genai refactor).

    Pass shape:
      agentcore_memories = {
        main = {
          id  = module.agentcore_memory.memory_id
          arn = module.agentcore_memory.memory_arn
        }
      }

    Values can be unknown-after-apply (Terraform 1.6+ handles this fine when
    only values, not keys, are unknown). The module uses each.value.id in the
    AWS-mandated log-group path /aws/vendedlogs/bedrock-agentcore/memory/
    APPLICATION_LOGS/<memory-id> so console auto-discovery still works.
  EOT
}

variable "agentcore_gateways" {
  type = map(object({
    id  = string
    arn = string
  }))
  default     = {}
  description = "Map of static-key -> { id, arn } for AgentCore Gateway resources. Same shape and rationale as agentcore_memories — keys must be static (e.g. \"main\") so for_each plans without a two-pass apply on fresh deploys."
}

variable "agentcore_runtimes" {
  type = map(object({
    id  = string
    arn = string
  }))
  default     = {}
  description = <<-EOT
    Map of static-key -> { id, arn } for AgentCore Runtime resources.

    Same shape + rationale as `agentcore_memories` / `agentcore_gateways`:
    the static map KEY (e.g. "orchestrator", "order_management",
    "mongodb_mcp") keeps for_each plan-able even when runtime_id is
    `(known after apply)` on a fresh deploy.

    AgentCore auto-creates `/aws/bedrock-agentcore/runtimes/<id>-DEFAULT`
    log groups for runtimes, BUT it does NOT wire up a delivery, so those
    log groups stay empty. This module fans out the same
    (source + destination + delivery) pipeline used for memory/gateway —
    container stdout/stderr from each runtime then flows to
    `/aws/vendedlogs/bedrock-agentcore/runtime/APPLICATION_LOGS/<id>` and
    the API's `trace_id` JSON field becomes queryable for end-to-end
    distributed-trace correlation (see e2e-smoke/post-deploy-smoke.py
    `agentcore_trace_join`).
  EOT
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
