terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.27, < 7.0" }
  }
}

locals {
  memory_name = "${replace(var.project_name, "-", "_")}_memory_${var.environment}"
}

# =============================================================================
# AgentCore Memory Store — primary **short-term conversation event store**
# in production (per-turn replay keyed by (memoryId, actorId=userId, sessionId)),
# selected when SHORT_TERM_MEMORY_BACKEND=agentcore + AGENTCORE_MEMORY_STORE_ID.
# Also used as a best-effort **long-term fallback** when MongoDB writes to
# `agent_memory_facts` fail. Authoritative long-term persistence still lives
# in MongoDB Atlas — see docs/memory-architecture.md and the SoW.
#
# Native AWS provider resource — replaced the previous `null_resource` +
# AWS CLI shim once `aws_bedrockagentcore_memory` shipped in provider v6.18.0.
# =============================================================================

resource "aws_bedrockagentcore_memory" "this" {
  name                  = local.memory_name
  event_expiry_duration = var.event_expiry_days

  tags = var.tags
}
