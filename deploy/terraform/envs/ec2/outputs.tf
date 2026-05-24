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
# Empty in peering mode.
output "atlas_privatelink_endpoint_id" {
  value = local.shared_atlas_pl_vpce_id
}

# ── Connectivity mode + peering visibility (mode-aware, empty in other mode) ─
output "network_mode" {
  value       = var.network_mode
  description = "Connectivity mode used by this ec2 env — 'privatelink' or 'peering'. Recorded in deploy-manifest.json by deploy-project.sh."
}

output "atlas_peering_connection_id" {
  value       = local.shared_atlas_peering_id
  description = "AWS VPC peering connection id (pcx-...). Empty in privatelink mode."
}

output "atlas_peering_cidr" {
  value       = local.shared_atlas_peering_cidr
  description = "Atlas-side CIDR. Empty in privatelink mode."
}

output "kb_connectivity_mode" {
  value       = local.kb_connectivity_mode
  description = "Which Bedrock KB ingestion path was provisioned. One of: 'privatelink' (PL NLB+VPCE), 'peering-nlb' (peering NLB+VPCE, experimental), 'public-srv' (no NLB; uses Atlas public SRV)."
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
output "knowledge_base_id" { value = module.bedrock_kb.knowledge_base_id }
output "knowledge_base_arn" { value = module.bedrock_kb.knowledge_base_arn }
output "kb_data_source_id" { value = module.bedrock_kb.data_source_id }
output "atlas_secret_arn" { value = module.bedrock_kb.atlas_secret_arn }

output "bedrock_kb_privatelink_enabled" {
  value       = local.use_kb_privatelink
  description = "True when CLIENT_REVIEW P1-6 Option A is active (PL NLB + VPC Endpoint Service in front of the Atlas VPCE). Always false in peering mode — see kb_connectivity_mode for peering-side KB path."
}

output "bedrock_kb_peering_enabled" {
  value       = local.use_kb_peering_nlb
  description = "True when peering-NLB KB ingestion is active (EXPERIMENTAL). See modules/bedrock-kb-peering/README.md."
}

output "bedrock_kb_endpoint_service_name" {
  value       = local.kb_endpoint_service_name
  description = "Endpoint Service name forwarded into the Bedrock KB MongoDB Atlas configuration. Populated for both privatelink and peering-nlb KB modes; empty for public-srv mode."
}

# ── AgentCore ─────────────────────────────────────────────────────────────────
output "agentcore_memory_id" { value = module.agentcore_memory.memory_id }
output "agentcore_memory_arn" { value = module.agentcore_memory.memory_arn }
# Gateway stays available for non-Mongo tool targets; MongoDB MCP is invoked
# directly through the dedicated AgentCore Runtime endpoint.
output "agentcore_gateway_id" { value = module.agentcore_gateway.gateway_id }
output "agentcore_gateway_url" { value = module.agentcore_gateway.gateway_mcp_url }
# Agent Runtimes — orchestrator (hardcoded) + specialists (for_each map)
output "acr_orchestrator_arn" { value = module.acr_orchestrator.runtime_arn }
output "acr_orchestrator_id" { value = module.acr_orchestrator.runtime_id }
output "acr_orchestrator_role_arn" { value = module.acr_orchestrator.runtime_role_arn }
# Map outputs (preferred by deploy-agents.sh and the refactored deploy.sh)
output "acr_specialist_arns" {
  value       = { for k, m in module.acr_specialists : k => m.runtime_arn }
  description = "Map of specialist agent id → AgentCore Runtime ARN. Consumed by deploy.sh / deploy-agents.sh to inject AGENTCORE_RUNTIME_ARN_<UPPER> env vars into the orchestrator runtime."
}
output "acr_specialist_ids" {
  value       = { for k, m in module.acr_specialists : k => m.runtime_id }
  description = "Map of specialist agent id → AgentCore Runtime ID. Consumed by deploy.sh / deploy-agents.sh to call update-agent-runtime per specialist."
}
# Legacy named outputs kept for backward compatibility — backed by the for_each map.
# Empty string when the specialist is not present in var.specialist_agents.
output "acr_troubleshooting_arn" { value = try(module.acr_specialists["troubleshooting"].runtime_arn, "") }
output "acr_troubleshooting_id" { value = try(module.acr_specialists["troubleshooting"].runtime_id, "") }
output "acr_order_management_arn" { value = try(module.acr_specialists["order-management"].runtime_arn, "") }
output "acr_order_management_id" { value = try(module.acr_specialists["order-management"].runtime_id, "") }
output "acr_product_recommendation_arn" { value = try(module.acr_specialists["product-recommendation"].runtime_arn, "") }
output "acr_product_recommendation_id" { value = try(module.acr_specialists["product-recommendation"].runtime_id, "") }
output "agentcore_runtime_deployment_mode" { value = var.agentcore_runtime_deployment_mode }
output "agentcore_code_artifact_prefix" { value = var.agentcore_code_artifact_prefix }
# Backward-compatible aliases (map old single-runtime outputs to orchestrator).
output "agentcore_runtime_arn" { value = module.acr_orchestrator.runtime_arn }
output "agentcore_runtime_id" { value = module.acr_orchestrator.runtime_id }
output "agentcore_runtime_role_arn" { value = module.acr_orchestrator.runtime_role_arn }
output "ecr_agent_runtime_repository_url" { value = length(aws_ecr_repository.agent_runtime) > 0 ? aws_ecr_repository.agent_runtime[0].repository_url : "" }

# ── mongodb-mcp AgentCore Runtime (sole tool host after Phase 7e) ─────────────
output "ecr_mongodb_mcp_runtime_repository_url" {
  value       = aws_ecr_repository.mongodb_mcp_runtime.repository_url
  description = "ECR repo URL for the mongodb-mcp AgentCore Runtime image (linux/arm64)."
}

output "mongodb_mcp_runtime_arn" {
  value       = module.mongodb_mcp_runtime.runtime_arn
  description = "AgentCore Runtime ARN of the mongodb-mcp MCP server."
}

output "mongodb_mcp_runtime_id" {
  value       = module.mongodb_mcp_runtime.runtime_id
  description = "AgentCore Runtime ID of the mongodb-mcp MCP server (consumed by deploy-project.sh force_mcp_runtime_image_sync)."
}

output "mongodb_mcp_runtime_endpoint" {
  value       = local.mongodb_mcp_runtime_endpoint
  description = "Direct Streamable-HTTP MCP endpoint for the mongodb-mcp AgentCore Runtime."
}

# ── Voyage AI (republished from envs/shared via SSM) ──────────────────────────
# Kept as a passthrough so deploy-project.sh + e2e smoke scripts that
# `terraform output -raw voyage_endpoint_name` keep working unchanged.
output "voyage_endpoint_name" {
  value       = local.shared_voyage_endpoint_name
  description = "Voyage SageMaker endpoint name. Sourced from envs/shared via SSM. Empty when voyage_model_package_arn was unset in the shared stack."
}

# ── CloudWatch (republished from envs/shared via SSM) ─────────────────────────
output "cloudwatch_api_log_group" { value = local.shared_cw_api_log_group }
output "cloudwatch_ui_log_group" { value = local.shared_cw_ui_log_group }
output "cloudwatch_mcp_log_group" { value = local.shared_cw_mcp_log_group }
output "cloudwatch_agentcore_log_group" { value = local.shared_cw_agentcore_log_group }
output "cloudwatch_otel_log_group" { value = local.shared_cw_otel_log_group }
output "cloudwatch_otel_atlas_log_group" { value = local.shared_cw_otel_atlas_log_group }
output "bedrock_invocation_log_group" {
  value       = local.shared_bedrock_invocation_log_group
  description = "Bedrock model-invocation log group (account-scoped). Sourced from envs/shared. Empty when invocation logging is disabled."
}
output "bedrock_audit_log_group" {
  value       = local.shared_bedrock_audit_log_group
  description = "Bedrock invocation audit-findings log group. Sourced from envs/shared. Empty when invocation logging is disabled."
}
