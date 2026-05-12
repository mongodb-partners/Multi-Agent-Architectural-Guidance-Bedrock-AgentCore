output "api_log_group_name" {
  value       = aws_cloudwatch_log_group.api.name
  description = "CloudWatch log group for the Hono/Bun API"
}

output "mcp_log_group_name" {
  value       = aws_cloudwatch_log_group.mcp.name
  description = "CloudWatch log group for the mongodb-mcp-server sidecar"
}

output "agentcore_log_group_name" {
  value       = aws_cloudwatch_log_group.agentcore.name
  description = "CloudWatch log group for AgentCore memory/gateway calls"
}
