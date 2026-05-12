output "kb_docs_bucket_name" {
  value       = var.shared_bucket_name
  description = "Shared S3 bucket name (KB docs live under kb-docs/docs/ prefix)"
}

output "kb_docs_bucket_arn" {
  value       = var.shared_bucket_arn
  description = "Shared S3 bucket ARN"
}

output "atlas_secret_arn" {
  value       = aws_secretsmanager_secret.atlas.arn
  description = "Secrets Manager secret ARN for Atlas credentials"
}

output "atlas_secret_name" {
  value       = local.secret_name
  description = "Secrets Manager secret name (project+env-scoped). Pass to consumers that need to scope secret ARN patterns in IAM policies."
}

output "kb_state_file" {
  value       = local.kb_id_file
  description = "Path to JSON file written by apply containing knowledge_base_id and data_source_id"
}

output "kb_role_arn" {
  value       = aws_iam_role.kb_role.arn
  description = "ARN of the IAM role used by Bedrock KB"
}
