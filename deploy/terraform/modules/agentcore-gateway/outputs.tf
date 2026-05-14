output "gateway_id" {
  value       = aws_bedrockagentcore_gateway.this.gateway_id
  description = "AgentCore Gateway ID"
}

output "gateway_mcp_url" {
  value       = aws_bedrockagentcore_gateway.this.gateway_url
  description = "MCP endpoint URL for Strands McpClient (Streamable HTTP)"
}

output "gateway_arn" {
  value       = aws_bedrockagentcore_gateway.this.gateway_arn
  description = "Gateway ARN"
}
