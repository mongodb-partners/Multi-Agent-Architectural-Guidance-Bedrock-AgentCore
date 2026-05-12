output "aws_account_id" { value = data.aws_caller_identity.current.account_id }
output "aws_region" { value = var.aws_region }

# ── Networking (shared, sourced from SSM published by envs/network) ──────────
output "vpc_id" { value = local.shared_vpc_id }
output "public_subnet_ids" { value = local.shared_public_subnet_ids }
output "private_subnet_ids" { value = local.shared_private_subnet_ids }

# ── Atlas ─────────────────────────────────────────────────────────────────────
output "atlas_cluster_name" { value = module.mongodb_atlas.cluster_name }
output "atlas_mongo_host" { value = module.mongodb_atlas.mongo_host }

output "atlas_connection_string" {
  value     = module.mongodb_atlas.connection_string
  sensitive = true
}

# Shared Atlas Interface VPCE id (from envs/network via SSM). deploy.sh
# Phase 5c uses this to look up the cluster's awsPrivateLink direct URI.
output "atlas_privatelink_endpoint_id" {
  value = local.shared_atlas_pl_vpce_id
}

# ── EC2 ───────────────────────────────────────────────────────────────────────
output "ec2_public_ip" { value = module.ec2.public_ip }
output "ec2_instance_id" { value = module.ec2.instance_id }
output "ec2_api_url" { value = module.ec2.api_url }
output "ec2_ui_url" { value = module.ec2.ui_url }
output "ec2_ssm_command" { value = module.ec2.ssm_command }
output "ec2_deploy_target" { value = module.ec2.deploy_target }

# ── ECR ───────────────────────────────────────────────────────────────────────
output "ecr_api_repository_url" { value = module.ecr.api_repository_url }
output "ecr_ui_repository_url" { value = module.ecr.ui_repository_url }

# ── Cognito ───────────────────────────────────────────────────────────────────
output "cognito_user_pool_id" { value = module.cognito.user_pool_id }
output "cognito_app_client_id" { value = module.cognito.user_pool_client_id }
output "cognito_jwks_uri" { value = module.cognito.jwks_uri }

# ── Bedrock KB ────────────────────────────────────────────────────────────────
output "kb_docs_bucket" { value = module.bedrock_kb.kb_docs_bucket_name }
output "kb_state_file" { value = module.bedrock_kb.kb_state_file }
output "atlas_secret_arn" { value = module.bedrock_kb.atlas_secret_arn }

# ── Lambda MCP ───────────────────────────────────────────────────────────────
output "lambda_mcp_arn" { value = module.lambda_mcp.function_arn }
output "lambda_mcp_function_name" { value = module.lambda_mcp.function_name }
output "lambda_mcp_artifact_bucket" { value = module.lambda_mcp.artifact_bucket_name }
output "lambda_mcp_artifact_key" { value = module.lambda_mcp.artifact_key }

# ── AgentCore ─────────────────────────────────────────────────────────────────
output "agentcore_memory_id" { value = module.agentcore_memory.memory_id }
output "agentcore_memory_arn" { value = module.agentcore_memory.memory_arn }
# Gateway routes tool calls to Lambda MCP (ADR 0001 updated).
output "agentcore_gateway_id" { value = module.agentcore_gateway.gateway_id }
output "agentcore_gateway_url" { value = module.agentcore_gateway.gateway_mcp_url }
# Agent Runtimes — orchestrator + 3 specialists
output "acr_orchestrator_arn" { value = module.acr_orchestrator.runtime_arn }
output "acr_orchestrator_id" { value = module.acr_orchestrator.runtime_id }
output "acr_orchestrator_role_arn" { value = module.acr_orchestrator.runtime_role_arn }
output "acr_troubleshooting_arn" { value = module.acr_troubleshooting.runtime_arn }
output "acr_troubleshooting_id" { value = module.acr_troubleshooting.runtime_id }
output "acr_order_management_arn" { value = module.acr_order_management.runtime_arn }
output "acr_order_management_id" { value = module.acr_order_management.runtime_id }
output "acr_product_recommendation_arn" { value = module.acr_product_recommendation.runtime_arn }
output "acr_product_recommendation_id" { value = module.acr_product_recommendation.runtime_id }
output "agentcore_runtime_deployment_mode" { value = var.agentcore_runtime_deployment_mode }
output "agentcore_code_artifact_prefix" { value = var.agentcore_code_artifact_prefix }
# Backward-compatible aliases (map old single-runtime outputs to orchestrator).
output "agentcore_runtime_arn" { value = module.acr_orchestrator.runtime_arn }
output "agentcore_runtime_id" { value = module.acr_orchestrator.runtime_id }
output "agentcore_runtime_role_arn" { value = module.acr_orchestrator.runtime_role_arn }
output "ecr_agent_runtime_repository_url" { value = length(aws_ecr_repository.agent_runtime) > 0 ? aws_ecr_repository.agent_runtime[0].repository_url : "" }

# ── Voyage AI ─────────────────────────────────────────────────────────────────
output "voyage_endpoint_name" {
  value = length(module.voyage_sagemaker) > 0 ? module.voyage_sagemaker[0].endpoint_name : ""
}

# ── CloudWatch ────────────────────────────────────────────────────────────────
output "cloudwatch_api_log_group" { value = module.cloudwatch.api_log_group_name }
output "cloudwatch_mcp_log_group" { value = module.cloudwatch.mcp_log_group_name }
