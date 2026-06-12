output "xray_cw_resource_policy_name" {
  value       = aws_cloudwatch_log_resource_policy.xray_spans.policy_name
  description = "Name of the CloudWatch Logs resource policy that grants xray.amazonaws.com write access to aws/spans."
}

output "spans_log_group_name" {
  # aws/spans is created and managed by AWS when Transaction Search is enabled.
  # We expose the well-known name so callers (dashboards, alarms, runbook) can
  # reference it without trying to look up a Terraform resource that doesn't
  # exist on our side of the API.
  value       = "aws/spans"
  description = "aws/spans — Transaction Search ingest log group (AWS-managed). All OTLP spans (ADOT sidecar + AgentCore service spans) land here."
}

output "spans_log_group_arn" {
  value       = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:aws/spans"
  description = "Well-known ARN of aws/spans (AWS-managed) for cross-account / cross-region policy authoring."
}

output "memory_log_group_names" {
  value       = { for k, lg in aws_cloudwatch_log_group.agentcore_memory : k => lg.name }
  description = "Map of AgentCore memory id -> vended log group name when enable_agentcore_vended_application_logs=true."
}

output "gateway_log_group_names" {
  value       = { for k, lg in aws_cloudwatch_log_group.agentcore_gateway : k => lg.name }
  description = "Map of AgentCore gateway id -> vended log group name when enable_agentcore_vended_application_logs=true."
}

output "transaction_search_indexing_percentage" {
  value       = var.span_sampling_percent
  description = "Configured Transaction Search indexing percentage (applied via aws logs put-transaction-search-config)."
}
