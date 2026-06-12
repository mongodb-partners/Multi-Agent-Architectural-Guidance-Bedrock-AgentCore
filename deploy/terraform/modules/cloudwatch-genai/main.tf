# =============================================================================
# CloudWatch Generative AI Observability — enables the managed AgentCore Agents
# tab + Model Invocations tab in the CloudWatch console, plus the underlying
# Transaction Search infrastructure that catches OTLP spans from the rest of
# the stack (ADOT sidecar from modules/adot-collector, Bun API, Streamlit UI,
# AgentCore-emitted spans).
#
# What this module does NOT cover:
#   - Bedrock model invocation logging (account-scoped; see
#     modules/bedrock-invocation-logging/).
#   - The ADOT Collector sidecar that signs SigV4 outbound to the X-Ray OTLP
#     endpoint (see modules/adot-collector/).
#   - Custom fleet dashboards + alarms (see modules/cloudwatch-fleet-dashboards/).
#
# Side effects (read carefully before flipping enable=false on an existing env):
#   - awscc_xray_transaction_search_config is account-scoped. Disabling it via
#     terraform destroy stops span ingestion for EVERY workload in this region
#     of this account, not just this project. If another team relies on it,
#     keep var.enable=true and only adjust span_sampling_percent down.
# =============================================================================

terraform {
  required_providers {
    aws  = { source = "hashicorp/aws", version = ">= 6.27, < 7.0" }
    null = { source = "hashicorp/null", version = "~> 3.0" }
  }
}

locals {
  # Static-key map of { id, arn } pairs — see variables.tf for the rationale.
  # Keys must be known at plan time; values may be `(known after apply)`. The
  # legacy `agentcore_memory_ids` list is converted into the same shape so
  # downstream resources have one consistent path. When the list path is
  # used, each id becomes both the map key (string already known at plan
  # time) AND the static identifier inside the value.
  memory_map = length(var.agentcore_memories) > 0 ? var.agentcore_memories : {
    for id in var.agentcore_memory_ids :
    id => {
      id  = id
      arn = "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:memory/${id}"
    }
  }
  gateway_map = length(var.agentcore_gateways) > 0 ? var.agentcore_gateways : {
    for id in var.agentcore_gateway_ids :
    id => {
      id  = id
      arn = "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:gateway/${id}"
    }
  }
  # Runtime delivery is map-only (no ids-list fallback): runtime IDs include
  # an AWS-generated 10-char random suffix that is never known at the time
  # the operator writes tfvars, so a list-of-strings shape is impractical.
  runtime_map = var.agentcore_runtimes
  # AgentCore service-vended APPLICATION_LOGS include raw request_payload /
  # response_payload bodies. Keep Transaction Search + app-emitted sanitized
  # spans on by default, but require an explicit opt-in for these payload logs.
  vended_memory_map  = var.enable_agentcore_vended_application_logs ? local.memory_map : {}
  vended_gateway_map = var.enable_agentcore_vended_application_logs ? local.gateway_map : {}
  vended_runtime_map = var.enable_agentcore_vended_application_logs ? local.runtime_map : {}
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Component   = "cloudwatch-genai"
  })
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# Transaction Search account toggle.
#
# Two production constraints force the implementation below:
#
#   1. The `aws/spans` log group lives in AWS-reserved namespace and
#      `aws_cloudwatch_log_group` cannot create it (CreateLogGroup rejects
#      anything starting with `aws/` or `AWS/`). AWS auto-provisions the log
#      group when Transaction Search is first enabled. We don't manage it.
#
#   2. `awscc_xray_transaction_search_config` (the only Terraform resource
#      that exposes PutTransactionSearchConfig) routes through CloudFormation
#      Cloud Control API, which requires `cloudformation:CreateResource` on
#      the caller. Many tightening IAM policies (SCPs, dev-user least-priv)
#      block that action. We bypass CloudFormation entirely with a
#      `null_resource` + `aws logs put-transaction-search-config` (a single
#      account-scoped CloudWatch Logs API call that only needs
#      `logs:PutTransactionSearchConfig`).
#
# Triggers on `indexing_percentage` so re-tuning the var actually re-applies.
# Account-scoped: enabling it lights up Transaction Search for **every**
# workload in this region+account, not just this project. See the module
# header for the safety note on `enable=false`.
# -----------------------------------------------------------------------------
resource "null_resource" "transaction_search_toggle" {
  count = var.enable_transaction_search_toggle ? 1 : 0
  triggers = {
    indexing_percentage = tostring(var.span_sampling_percent)
    region              = data.aws_region.current.region
  }

  # Two AWS X-Ray API calls; both account-scoped and idempotent:
  #   1. update-trace-segment-destination → CloudWatchLogs : flips the
  #      account from "X-Ray classic ingest" to "Transaction Search ingest"
  #      so spans land in aws/spans and AWS auto-creates that log group.
  #   2. update-indexing-rule Default Probabilistic → controls what
  #      percentage of spans become indexed trace summaries (the rest are
  #      still stored, just not searchable). Default rule is the only one
  #      that exists today; tuning it == tuning the whole account.
  #
  # Required permissions: xray:UpdateTraceSegmentDestination,
  # xray:UpdateIndexingRule. logs:PutTransactionSearchConfig is NOT a real
  # action — the previous attempt used the wrong API name.
  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      REGION=${data.aws_region.current.region}
      # First-time API enable of CloudWatchLogs does NOT create the reserved
      # aws/spans log group (only console enable or XRay→CW toggle does).
      # When aws/spans is missing, toggle destination so AWS provisions it.
      if ! aws logs describe-log-groups --region "$REGION" \
          --log-group-name-prefix "aws/spans" \
          --query 'logGroups[?logGroupName==`aws/spans`]' --output text | grep -q .; then
        echo "transaction-search: aws/spans missing — toggling destination to create it"
        aws xray update-trace-segment-destination --region "$REGION" --destination XRay --output text >/dev/null || true
        for _ in $(seq 1 20); do
          STATUS=$(aws xray get-trace-segment-destination --region "$REGION" --query Status --output text 2>/dev/null || echo PENDING)
          [[ "$STATUS" == "ACTIVE" ]] && break
          sleep 15
        done
      fi
      DEST_OUT=$(aws xray update-trace-segment-destination \
        --region "$REGION" \
        --destination CloudWatchLogs \
        --output text 2>&1) || {
        echo "$DEST_OUT" | grep -q "already set to CloudWatchLogs" && \
          echo "transaction-search: destination already CloudWatchLogs (no-op)" || \
          { echo "$DEST_OUT" >&2; exit 1; }
      }
      aws xray update-indexing-rule \
        --region "$REGION" \
        --name Default \
        --rule "Probabilistic={DesiredSamplingPercentage=${var.span_sampling_percent}}" \
        --output text >/dev/null
      echo "transaction-search: dest=CloudWatchLogs, sampling=${var.span_sampling_percent}% in $REGION"
    EOT
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Logs resource policy — lets xray.amazonaws.com write to the
# aws/spans log group (auto-provisioned by AWS on first Transaction Search
# enable). This must exist BEFORE update-trace-segment-destination succeeds;
# we always create it (not gated on enable_transaction_search_toggle) so that
# manually-enabled Transaction Search also keeps working after terraform apply.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_resource_policy" "xray_spans" {
  policy_name = "XRayWriteToCloudWatchLogs"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AWSXRayWriteAccess"
      Effect    = "Allow"
      Principal = { Service = "xray.amazonaws.com" }
      Action = [
        "logs:PutLogEvents",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

# -----------------------------------------------------------------------------
# Optional AgentCore service-vended log delivery for Memory + Gateway + Runtime
# resources.
#
# Privacy note: APPLICATION_LOGS include raw request_payload / response_payload
# bodies for runtime invocations and Gateway tool calls. That can include user
# messages, memoryContext, MongoDB filters, and returned documents. The safe
# default is to leave these deliveries OFF and rely on app-emitted sanitized
# JSON logs plus OTLP spans instead. Operators can opt in with
# enable_agentcore_vended_application_logs=true when payload logs are explicitly
# approved for a short investigation window.
#
# Delivery model = source + destination + delivery edge per resource.
# Log group naming follows the AWS-documented convention:
#   /aws/vendedlogs/bedrock-agentcore/<resource-type>/APPLICATION_LOGS/<resource-id>
# Changing this name breaks the AWS console's auto-discovery of the dashboards.
# -----------------------------------------------------------------------------

# ----- Memory resources -----
#
# for_each iterates `local.memory_map` (static keys like "main"), so plan
# succeeds on fresh deploys when each.value.id / each.value.arn are still
# `(known after apply)`. Resource NAMES (log groups, delivery sources) must
# include the real memory_id so CloudWatch console auto-discovery works —
# those names resolve at apply time from each.value.id, after agentcore_memory
# has actually been created. The static map key is only used as a state
# address; never appears in any AWS-visible field.

resource "aws_cloudwatch_log_group" "agentcore_memory" {
  for_each = local.vended_memory_map

  name              = "/aws/vendedlogs/bedrock-agentcore/memory/APPLICATION_LOGS/${each.value.id}"
  retention_in_days = var.agentcore_log_retention_days

  tags = merge(local.common_tags, {
    Name        = "agentcore-memory-${each.value.id}"
    AgentCoreId = each.value.id
  })
}

resource "aws_cloudwatch_log_delivery_source" "agentcore_memory" {
  for_each = local.vended_memory_map

  # CloudWatch log-delivery source names are capped at 60 chars. AgentCore
  # memory ids already include the project name and an AWS-generated 10-char
  # random suffix, so they're globally unique on their own — no need to
  # re-prefix with project_name/environment. Project/env stay on the resource
  # tags instead.
  name         = substr("memory-${each.value.id}", 0, 60)
  log_type     = "APPLICATION_LOGS"
  resource_arn = each.value.arn
}

resource "aws_cloudwatch_log_delivery_destination" "agentcore_memory" {
  for_each = local.vended_memory_map

  name          = substr("memory-dst-${each.value.id}", 0, 60)
  output_format = "json"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.agentcore_memory[each.key].arn
  }
}

resource "aws_cloudwatch_log_delivery" "agentcore_memory" {
  for_each = local.vended_memory_map

  delivery_source_name     = aws_cloudwatch_log_delivery_source.agentcore_memory[each.key].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.agentcore_memory[each.key].arn
}

# ----- Gateway resources -----

resource "aws_cloudwatch_log_group" "agentcore_gateway" {
  for_each = local.vended_gateway_map

  name              = "/aws/vendedlogs/bedrock-agentcore/gateway/APPLICATION_LOGS/${each.value.id}"
  retention_in_days = var.agentcore_log_retention_days

  tags = merge(local.common_tags, {
    Name        = "agentcore-gateway-${each.value.id}"
    AgentCoreId = each.value.id
  })
}

resource "aws_cloudwatch_log_delivery_source" "agentcore_gateway" {
  for_each = local.vended_gateway_map

  # See agentcore_memory above for the 60-char rationale.
  name         = substr("gateway-${each.value.id}", 0, 60)
  log_type     = "APPLICATION_LOGS"
  resource_arn = each.value.arn
}

resource "aws_cloudwatch_log_delivery_destination" "agentcore_gateway" {
  for_each = local.vended_gateway_map

  name          = substr("gateway-dst-${each.value.id}", 0, 60)
  output_format = "json"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.agentcore_gateway[each.key].arn
  }
}

resource "aws_cloudwatch_log_delivery" "agentcore_gateway" {
  for_each = local.vended_gateway_map

  delivery_source_name     = aws_cloudwatch_log_delivery_source.agentcore_gateway[each.key].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.agentcore_gateway[each.key].arn
}

# ----- Runtime resources -----
#
# AgentCore auto-provisions `/aws/bedrock-agentcore/runtimes/<id>-DEFAULT`
# (single `otel-rt-logs` stream) for every runtime, but with no delivery
# configured the stream stays empty — runtime container stdout/stderr is
# silently dropped. This block creates the missing
# (DeliverySource + DeliveryDestination + Delivery) edge per runtime,
# matching the memory/gateway pattern above, so the API's structured logs
# (with `trace_id` correlated to the upstream API span) actually land in
# CloudWatch. Without it, distributed-trace search by `trace_id` only
# resolves on the Hono API side and the orchestrator → specialist hop is
# invisible.
#
# Destination log-group naming mirrors the documented vended-logs path
# (`/aws/vendedlogs/bedrock-agentcore/runtime/APPLICATION_LOGS/<id>`)
# rather than the auto-provisioned `/aws/bedrock-agentcore/runtimes/...`
# group. This keeps three things working:
#   1. CloudWatch console auto-discovery for AgentCore runtime dashboards.
#   2. Vended-log retention controlled by `agentcore_log_retention_days`
#      (the auto-provisioned group has no retention by default).
#   3. The smoke test `agentcore_trace_join` discovery, which scans the
#      vended-logs hierarchy and is project-scoped via the runtime id.

resource "aws_cloudwatch_log_group" "agentcore_runtime" {
  for_each = local.vended_runtime_map

  name              = "/aws/vendedlogs/bedrock-agentcore/runtime/APPLICATION_LOGS/${each.value.id}"
  retention_in_days = var.agentcore_log_retention_days

  tags = merge(local.common_tags, {
    Name        = "agentcore-runtime-${each.value.id}"
    AgentCoreId = each.value.id
  })
}

resource "aws_cloudwatch_log_delivery_source" "agentcore_runtime" {
  for_each = local.vended_runtime_map

  # See agentcore_memory above for the 60-char rationale. Runtime ids
  # already include the project name + random suffix so they're globally
  # unique on their own.
  name         = substr("runtime-${each.value.id}", 0, 60)
  log_type     = "APPLICATION_LOGS"
  resource_arn = each.value.arn
}

resource "aws_cloudwatch_log_delivery_destination" "agentcore_runtime" {
  for_each = local.vended_runtime_map

  name          = substr("runtime-dst-${each.value.id}", 0, 60)
  output_format = "json"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.agentcore_runtime[each.key].arn
  }
}

resource "aws_cloudwatch_log_delivery" "agentcore_runtime" {
  for_each = local.vended_runtime_map

  delivery_source_name     = aws_cloudwatch_log_delivery_source.agentcore_runtime[each.key].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.agentcore_runtime[each.key].arn
}
