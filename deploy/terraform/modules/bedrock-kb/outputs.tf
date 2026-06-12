output "kb_docs_bucket_name" {
  value       = local.kb_bucket_name
  description = "S3 bucket holding KB docs under the kb-docs/docs/ prefix (dedicated bucket when kb_docs_bucket_name is set, otherwise the shared bucket)"
}

output "kb_docs_bucket_arn" {
  value       = local.kb_bucket_arn
  description = "ARN of the S3 bucket holding KB docs (dedicated or shared)"
}

output "atlas_secret_arn" {
  value       = aws_secretsmanager_secret.atlas.arn
  description = "Secrets Manager secret ARN for Atlas credentials"
}

output "atlas_secret_name" {
  value       = local.secret_name
  description = "Secrets Manager secret name (project+env-scoped). Pass to consumers that need to scope secret ARN patterns in IAM policies."
}

output "knowledge_base_id" {
  value       = aws_bedrockagent_knowledge_base.this.id
  description = "Bedrock Knowledge Base ID"
}

output "knowledge_base_arn" {
  value       = aws_bedrockagent_knowledge_base.this.arn
  description = "Bedrock Knowledge Base ARN"
}

output "data_source_id" {
  value       = aws_bedrockagent_data_source.s3.data_source_id
  description = "Bedrock KB S3 data source ID"
}

output "kb_role_arn" {
  value       = aws_iam_role.kb_role.arn
  description = "ARN of the IAM role used by Bedrock KB"
}
