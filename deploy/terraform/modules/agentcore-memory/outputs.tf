output "memory_id" {
  value       = aws_bedrockagentcore_memory.this.id
  description = "AgentCore Memory Store ID"
}

output "memory_name" {
  value       = local.memory_name
  description = "AgentCore Memory Store name"
}

output "memory_arn" {
  value       = aws_bedrockagentcore_memory.this.arn
  description = "AgentCore Memory Store ARN"
}
