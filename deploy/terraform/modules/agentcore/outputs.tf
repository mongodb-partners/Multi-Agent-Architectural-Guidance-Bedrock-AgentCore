output "memory_store_id" {
  value       = aws_bedrockagentcore_memory_store.main.id
  description = "AgentCore Memory Store ID — set as AGENTCORE_MEMORY_STORE_ID in .env.live"
}

output "gateway_id" {
  value       = aws_bedrockagentcore_gateway.main.id
  description = "AgentCore Gateway ID"
}

output "gateway_endpoint" {
  value       = aws_bedrockagentcore_gateway.main.gateway_url
  description = "AgentCore Gateway endpoint URL — set as AGENTCORE_GATEWAY_ENDPOINT in .env.live"
}

output "gateway_target_id" {
  value       = aws_bedrockagentcore_gateway_target.mongodb_mcp.id
  description = "MongoDB MCP gateway target ID"
}
