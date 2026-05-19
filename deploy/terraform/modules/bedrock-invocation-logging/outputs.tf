output "log_group_name" {
  value       = var.enable ? aws_cloudwatch_log_group.invocations[0].name : ""
  description = "Bedrock invocation log group name (empty when enable=false)."
}

output "log_group_arn" {
  value       = var.enable ? aws_cloudwatch_log_group.invocations[0].arn : ""
  description = "Bedrock invocation log group ARN."
}

output "audit_log_group_name" {
  value       = var.enable ? aws_cloudwatch_log_group.invocations_audit[0].name : ""
  description = "Dedicated log group that receives Data Protection Audit findings (separate from the source group, per AWS Data Protection requirement)."
}

output "audit_log_group_arn" {
  value       = var.enable ? aws_cloudwatch_log_group.invocations_audit[0].arn : ""
  description = "ARN of the Audit findings log group."
}

output "role_arn" {
  value       = var.enable ? aws_iam_role.bedrock_logging[0].arn : ""
  description = "IAM role Bedrock assumes to write the invocation logs."
}

output "log_prompt_bodies_enabled" {
  value       = var.log_prompt_bodies
  description = "Echoes the effective body-logging posture so smoke tests can assert against it."
}
