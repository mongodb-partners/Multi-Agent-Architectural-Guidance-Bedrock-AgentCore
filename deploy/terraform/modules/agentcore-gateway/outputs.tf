# Read the state file written by create-gateway.sh. The `depends_on` defers
# the read until after the null_resource provisioner has run, so the file is
# guaranteed to exist at apply time. We deliberately avoid the
# `fileexists()`/`file()` ternary pattern: Terraform's plan/apply consistency
# check fails when fileexists() returns different values across phases, and a
# fallback to "" would silently mask a missing or empty state file. If the
# file is absent, malformed, or any expected key is missing, we want a HARD
# failure here so the operator notices immediately.
data "local_file" "state" {
  filename   = local.state_file
  depends_on = [null_resource.gateway]
}

locals {
  _state = jsondecode(data.local_file.state.content)
}

output "gateway_id" {
  value       = local._state.gateway_id
  description = "AgentCore Gateway ID"
}

output "gateway_mcp_url" {
  value       = local._state.mcp_url
  description = "MCP endpoint URL for Strands McpClient (Streamable HTTP)"
}

output "gateway_arn" {
  value       = local._state.gateway_arn
  description = "Gateway ARN"
}
