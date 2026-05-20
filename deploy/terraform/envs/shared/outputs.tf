output "ssm_prefix" {
  value       = local.ssm_prefix
  description = "SSM parameter prefix under which all shared (network + shared-stack) values are published. Per-project envs read here. Format: /<shared_vpc_name>/<aws_region>"
}

# ── Voyage SageMaker (optional) ───────────────────────────────────────────────
output "voyage_endpoint_name" {
  value       = length(module.voyage_sagemaker) > 0 ? module.voyage_sagemaker[0].endpoint_name : ""
  description = "SageMaker endpoint name running Voyage AI embeddings. Empty when var.voyage_model_package_arn was not set."
}

output "voyage_endpoint_arn" {
  value       = length(module.voyage_sagemaker) > 0 ? module.voyage_sagemaker[0].endpoint_arn : ""
  description = "SageMaker endpoint ARN — used by per-project agentcore-agent-runtime IAM for sagemaker:InvokeEndpoint."
}

# ── CloudWatch log groups ─────────────────────────────────────────────────────
output "cloudwatch_api_log_group" {
  value = module.cloudwatch.api_log_group_name
}

output "cloudwatch_ui_log_group" {
  value = module.cloudwatch.ui_log_group_name
}

output "cloudwatch_mcp_log_group" {
  value = module.cloudwatch.mcp_log_group_name
}

output "cloudwatch_agentcore_log_group" {
  value = module.cloudwatch.agentcore_log_group_name
}

output "cloudwatch_otel_log_group" {
  value = aws_cloudwatch_log_group.otel.name
}

output "cloudwatch_otel_atlas_log_group" {
  value = aws_cloudwatch_log_group.otel_atlas.name
}

# ── Bedrock invocation logging (account-scoped) ───────────────────────────────
output "bedrock_invocation_log_group" {
  value = var.enable_bedrock_invocation_logging ? module.bedrock_invocation_logging.log_group_name : ""
}

output "bedrock_audit_log_group" {
  value = var.enable_bedrock_invocation_logging ? module.bedrock_invocation_logging.audit_log_group_name : ""
}

# ── Dashboards ────────────────────────────────────────────────────────────────
output "fleet_dashboard_url" {
  value       = length(module.cloudwatch_fleet_dashboards) > 0 ? module.cloudwatch_fleet_dashboards[0].fleet_dashboard_url : ""
  description = "Direct console URL for the shared fleet dashboard."
}

output "mongo_dashboard_url" {
  value = length(module.cloudwatch_fleet_dashboards) > 0 ? module.cloudwatch_fleet_dashboards[0].mongo_dashboard_url : ""
}

output "cost_dashboard_url" {
  value = length(module.cloudwatch_fleet_dashboards) > 0 ? module.cloudwatch_fleet_dashboards[0].cost_dashboard_url : ""
}
