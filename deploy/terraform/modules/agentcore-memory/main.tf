terraform {
  required_providers {
    null  = { source = "hashicorp/null", version = "~> 3.0" }
    local = { source = "hashicorp/local", version = "~> 2.0" }
  }
}

locals {
  memory_name = "${replace(var.project_name, "-", "_")}_memory_${var.environment}"
  state_file  = "${path.module}/.memory-state.json"
  # Serialize tags to "Key=Value,Key=Value" for AWS CLI shorthand.
  # AgentCore is created via CLI (no TF provider) so default_tags doesn't apply.
  tags_csv = join(",", [for k, v in var.tags : "${k}=${v}"])
}

# =============================================================================
# AgentCore Memory Store — created via AWS CLI (not yet in AWS TF provider).
# =============================================================================

resource "null_resource" "memory" {
  triggers = {
    memory_name       = local.memory_name
    event_expiry_days = var.event_expiry_days
    aws_region        = var.aws_region
    tags_csv          = local.tags_csv
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/create-memory.sh"
    environment = {
      AWS_REGION        = var.aws_region
      MEMORY_NAME       = local.memory_name
      EVENT_EXPIRY_DAYS = tostring(var.event_expiry_days)
      STATE_FILE        = local.state_file
      RESOURCE_TAGS     = local.tags_csv
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${path.module}/scripts/destroy-memory.sh"
    environment = {
      AWS_REGION = self.triggers.aws_region
      STATE_FILE = "${path.module}/.memory-state.json"
    }
  }
}
