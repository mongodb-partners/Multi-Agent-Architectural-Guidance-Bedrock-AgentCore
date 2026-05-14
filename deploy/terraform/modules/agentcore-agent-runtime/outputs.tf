output "runtime_arn" {
  value       = aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn
  description = "AgentCore Runtime ARN — use as orchestrator/specialist runtime target"
}

output "runtime_id" {
  value       = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id
  description = "AgentCore Runtime ID"
}

output "runtime_role_arn" {
  value       = aws_iam_role.runtime.arn
  description = "IAM role ARN assumed by the runtime container"
}

output "runtime_version" {
  value       = aws_bedrockagentcore_agent_runtime.this.agent_runtime_version
  description = "AgentCore Runtime version"
}

output "workload_identity_arn" {
  value       = try(aws_bedrockagentcore_agent_runtime.this.workload_identity_details[0].workload_identity_arn, "")
  description = "Workload identity ARN exposed by the runtime"
}
