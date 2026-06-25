terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.27, < 7.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# =============================================================================
# CLIENT_REVIEW P1-6 — Option A: PrivateLink for Bedrock Knowledge Base ingestion
#
# Bedrock Knowledge Base ingestion runs in Bedrock's *managed* VPC (we cannot
# add ENIs there or attach a Route 53 zone), so the per-cluster Atlas Route 53
# zone the runtime uses is invisible to Bedrock. Bedrock supports PrivateLink
# to your account via the `endpointServiceName` field on
# `MongoDbAtlasConfiguration`: when set, Bedrock creates its own VPCE in
# Bedrock's VPC, connects to OUR VPCE Service, and the Atlas connection
# string is resolved through that path.
#
# Architecture this module wires up (operator must already have the Atlas
# Interface VPCE provisioned by modules/atlas-privatelink/):
#
#     Bedrock managed VPC
#         │  (Bedrock-managed VPCE)
#         ▼
#     OUR VPC Endpoint Service  ◄── this module
#         │
#         ▼
#     OUR Network Load Balancer  ◄── this module
#         │  (TCP per mongod listener port → IP target group)
#         ▼
#     Atlas Interface VPCE ENIs  ◄── discovered at apply time via AWS CLI
#         │
#         ▼
#     Atlas (cross-account, PrivateLink-enabled cluster)
#
# COST IMPLICATION: ~$22/mo per NLB plus per-LCU billing. The module is
# instantiated from envs/ec2 only when var.enable_kb_privatelink = true.
#
# OPERATIONAL CAVEAT: NLB IP targets reference the Atlas VPCE ENI private IPs.
# Those IPs are stable for the lifetime of the VPCE; if the operator destroys
# and recreates the VPCE in modules/atlas-privatelink/, re-running terraform
# apply re-registers the new ENIs via null_resource.register_targets.
# =============================================================================

locals {
  # var.atlas_ports is often `(known after apply)` when parsed from
  # mongodbatlas_cluster connection_strings. for_each KEYS must be plan-time
  # static — use fixed slot indices and resolve the real port number per slot
  # at apply time via var.atlas_ports[tonumber(slot)].
  atlas_port_slot_keys = toset([
    for i in range(var.atlas_port_slot_count) : tostring(i)
  ])

  # NLB names are capped at 32 chars. Keep a readable project prefix and hash
  # the full project/env identity so parallel demo environments don't collide.
  nlb_name = "kb-${substr(replace(var.project_name, "-", ""), 0, 17)}-${substr(md5("${var.project_name}-${var.environment}"), 0, 8)}"
}

# ── Network Load Balancer fronting the Atlas VPCE ENIs ────────────────────────
resource "aws_lb" "atlas_kb" {
  name                             = local.nlb_name
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.private_subnet_ids
  enable_cross_zone_load_balancing = true

  tags = merge(var.tags, {
    Name = local.nlb_name
    Role = "bedrock-kb-privatelink"
  })
}

resource "aws_lb_target_group" "atlas_kb" {
  for_each = local.atlas_port_slot_keys

  # `name_prefix` instead of `name` so any future rename-driven replacement does
  # not collide with the existing TG (whose ARN is still referenced by the
  # listener until the listener is updated to the replacement TG). With a fixed
  # `name`, the rename would attempt to destroy the old TG before the listener
  # update lands, and AWS rejects the delete with `ResourceInUse: Target group
  # … is currently in use by a listener or a rule` (observed 2026-05-22 when
  # the naming scheme changed in commit ba49832). `name_prefix` is capped at
  # 6 chars; ELBv2 appends a 26-char suffix, keeping us under the 32-char NLB
  # TG cap. Pair with `create_before_destroy` so TF sequences create → update
  # listener → delete.
  name_prefix = "pl${each.key}-"
  # try(..., 0) keeps destroy evaluable: on teardown the Atlas connection string
  # is gone, so var.atlas_ports refreshes to [] and a raw index would throw
  # `Invalid index` during the plan graph walk — before the precondition (which
  # is skipped for resources being destroyed) could run. The 0 fallback is inert
  # on apply because the precondition below still enforces real ports > 0.
  port        = try(var.atlas_ports[tonumber(each.key)], 0)
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    interval            = 30
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true

    precondition {
      condition = (
        var.atlas_vpce_id != "" &&
        length(var.atlas_ports) >= var.atlas_port_slot_count &&
        alltrue([for i in range(var.atlas_port_slot_count) : var.atlas_ports[i] > 0])
      )
      error_message = "bedrock-kb-privatelink: var.atlas_ports must expose at least ${var.atlas_port_slot_count} PrivateLink listener ports once the cluster is provisioned and atlas_vpce_id must be set. Ensure atlas-privatelink has been applied and mongodb_atlas has populated the private endpoint connection string."
    }
  }
}

# Register Atlas VPCE ENI private IPs against each per-port target group via AWS
# CLI instead of data-source for_each + aws_lb_target_group_attachment.
# Reason: data.aws_vpc_endpoint.atlas.network_interface_ids is `(known after
# apply)` on fresh ec2 deploys, which breaks for_each KEYS at plan time.
# Static slot keys + apply-time discovery mirrors modules/bedrock-kb-peering/.
resource "null_resource" "register_targets" {
  for_each = local.atlas_port_slot_keys

  triggers = {
    target_group_arn = aws_lb_target_group.atlas_kb[each.key].arn
    slot             = each.key
    port             = try(var.atlas_ports[tonumber(each.key)], 0)
    atlas_vpce_id    = var.atlas_vpce_id
    aws_region       = var.aws_region
    atlas_ports_sha  = sha1(join(",", [for p in var.atlas_ports : tostring(p)]))
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      tg_arn="${self.triggers.target_group_arn}"
      port="${self.triggers.port}"
      region="${self.triggers.aws_region}"
      vpce_id="${self.triggers.atlas_vpce_id}"

      if [[ -z "$vpce_id" || "$port" == "0" ]]; then
        echo "[bedrock-kb-privatelink] register_targets: VPCE or port not ready — skipping slot ${self.triggers.slot} (will run once mongodb_atlas populates privatelink_ports)"
        exit 0
      fi

      eni_ids=$(aws ec2 describe-vpc-endpoints --region "$region" \
        --vpc-endpoint-ids "$vpce_id" \
        --query 'VpcEndpoints[0].NetworkInterfaceIds' --output text)
      if [[ -z "$eni_ids" || "$eni_ids" == "None" ]]; then
        echo "[bedrock-kb-privatelink] register_targets: no ENIs on VPCE $vpce_id"
        exit 1
      fi

      ips_csv=""
      for eni in $eni_ids; do
        ip=$(aws ec2 describe-network-interfaces --region "$region" \
          --network-interface-ids "$eni" \
          --query 'NetworkInterfaces[0].PrivateIpAddress' --output text)
        ips_csv="$${ips_csv:+$ips_csv,}$ip"
      done

      existing=$(aws elbv2 describe-target-health --region "$region" \
        --target-group-arn "$tg_arn" \
        --query 'TargetHealthDescriptions[].Target.Id' \
        --output text 2>/dev/null || echo "")
      if [[ -n "$existing" && "$existing" != "None" ]]; then
        targets=""
        for ip in $existing; do
          targets="$targets Id=$ip,Port=$port"
        done
        echo "[bedrock-kb-privatelink] deregistering existing targets for port $port: $existing"
        aws elbv2 deregister-targets --region "$region" \
          --target-group-arn "$tg_arn" --targets $targets >/dev/null
      fi

      targets=""
      IFS=,
      for ip in $ips_csv; do
        targets="$targets Id=$ip,Port=$port"
      done
      unset IFS
      echo "[bedrock-kb-privatelink] registering VPCE ENI targets for port $port: $ips_csv"
      aws elbv2 register-targets --region "$region" \
        --target-group-arn "$tg_arn" --targets $targets
    EOT
  }
}

resource "aws_lb_listener" "atlas_kb" {
  for_each = local.atlas_port_slot_keys

  load_balancer_arn = aws_lb.atlas_kb.arn
  port              = try(var.atlas_ports[tonumber(each.key)], 0)
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.atlas_kb[each.key].arn
  }

  tags = var.tags

  depends_on = [null_resource.register_targets]
}

# ── VPC Endpoint Service exposing the NLB to Bedrock ──────────────────────────
#
# allowed_principals scopes the consumer-side cross-account allow-list. Bedrock
# Knowledge Base ingestion connects via a service-linked role in the AWS-owned
# Bedrock account; the safest principal grant is the AWS Bedrock service
# principal (Bedrock injects the appropriate cross-account principal at
# connection time). When you want the strictest possible binding, replace the
# wildcard ARN with Bedrock's published service-linked role principal in your
# region — see https://docs.aws.amazon.com/IAM/latest/UserGuide/reference-arns.html.
#
# acceptance_required = false because Bedrock auto-creates the VPCE on its
# side when the KB is provisioned; if we required manual acceptance the
# Bedrock-side connection request would sit in PendingAcceptance forever.
resource "aws_vpc_endpoint_service" "atlas_kb" {
  acceptance_required        = false
  network_load_balancer_arns = [aws_lb.atlas_kb.arn]
  allowed_principals         = var.allowed_principals

  tags = merge(var.tags, {
    Name = "${var.project_name}-kb-pl-vpces-${var.environment}"
  })
}
