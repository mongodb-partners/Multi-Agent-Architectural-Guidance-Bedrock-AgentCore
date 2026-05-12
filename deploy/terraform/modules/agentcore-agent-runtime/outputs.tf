# Read the state file written by create-runtime.sh. The `depends_on` defers
# the read until after the null_resource provisioner has run, so the file is
# guaranteed to exist at apply time. Avoid the `fileexists()`/`file()`
# ternary pattern: Terraform's plan/apply consistency check fails when
# fileexists() returns different values across phases, and a fallback to ""
# would silently mask a missing or empty state file. If the file is absent,
# malformed, or any expected key is missing, we want a HARD failure here.
data "local_file" "state" {
  filename   = local.state_file
  depends_on = [null_resource.runtime]
}

locals {
  _state = jsondecode(data.local_file.state.content)
}

output "runtime_arn" {
  value       = local._state.runtime_arn
  description = "AgentCore Runtime ARN — use as orchestrator/specialist runtime target"
}

output "runtime_id" {
  value       = local._state.runtime_id
  description = "AgentCore Runtime ID"
}

output "endpoint_id" {
  value       = local._state.endpoint_id
  description = "AgentCore Runtime DEFAULT endpoint ID"
}

output "runtime_role_arn" {
  value       = aws_iam_role.runtime.arn
  description = "IAM role ARN assumed by the runtime container"
}
