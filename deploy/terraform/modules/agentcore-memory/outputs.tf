# Read the state file written by create-memory.sh. The `depends_on` defers
# this read until after the null_resource has run, so the file is guaranteed
# to exist at apply time. Avoid the `fileexists()`/`file()` ternary pattern:
# Terraform's plan/apply consistency check fails when fileexists() returns
# different values across phases, and a fallback to "" would silently mask a
# missing or empty state file. If the file is absent, malformed, or any
# expected key is missing, we want a HARD failure here.
data "local_file" "state" {
  filename   = local.state_file
  depends_on = [null_resource.memory]
}

locals {
  _state = jsondecode(data.local_file.state.content)
}

output "memory_id" {
  value       = local._state.memory_id
  description = "AgentCore Memory Store ID (written by create-memory.sh)"
}

output "memory_name" {
  value       = local.memory_name
  description = "AgentCore Memory Store name"
}

output "memory_arn" {
  value       = local._state.memory_arn
  description = "AgentCore Memory Store ARN"
}
