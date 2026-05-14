output "aws_account_id" { value = data.aws_caller_identity.current.account_id }
output "aws_region" { value = var.aws_region }

output "atlas_cluster_name" { value = module.mongodb_atlas.cluster_name }
output "atlas_mongo_host" { value = module.mongodb_atlas.mongo_host }

output "atlas_connection_string" {
  value     = module.mongodb_atlas.connection_string
  sensitive = true
}

output "kb_docs_bucket" { value = module.bedrock_kb.kb_docs_bucket_name }
output "knowledge_base_id" { value = module.bedrock_kb.knowledge_base_id }
output "knowledge_base_arn" { value = module.bedrock_kb.knowledge_base_arn }
output "kb_data_source_id" { value = module.bedrock_kb.data_source_id }
output "atlas_secret_arn" { value = module.bedrock_kb.atlas_secret_arn }

output "cloudwatch_api_log_group" { value = module.cloudwatch.api_log_group_name }
output "cloudwatch_mcp_log_group" { value = module.cloudwatch.mcp_log_group_name }
