terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.27, < 7.0"
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
#         │  (TCP 27017 → IP target group)
#         ▼
#     Atlas Interface VPCE ENIs  ◄── data lookup (NOT created here)
#         │
#         ▼
#     Atlas (cross-account, PrivateLink-enabled cluster)
#
# COST IMPLICATION: ~$22/mo per NLB plus per-LCU billing. The module is
# instantiated from envs/ec2 only when var.enable_kb_privatelink = true.
#
# OPERATIONAL CAVEAT: NLB IP targets reference the Atlas VPCE ENI private IPs.
# Those IPs are stable for the lifetime of the VPCE; if the operator destroys
# and recreates the VPCE in modules/atlas-privatelink/, this module's NLB
# target group must be re-applied so the new ENIs become targets. terraform
# apply does this automatically because aws_network_interfaces re-runs on each
# plan.
# =============================================================================

# ── Lookup the Atlas Interface VPCE ENIs in our subnets ───────────────────────
data "aws_vpc_endpoint" "atlas" {
  id = var.atlas_vpce_id
}

# Read each ENI individually to get its private IP. for_each over the IDs
# returned by the endpoint data source keeps the target group stable across
# re-plans (vs. count-indexed which re-shuffles on order changes).
data "aws_network_interface" "atlas_vpce_eni" {
  for_each = toset(data.aws_vpc_endpoint.atlas.network_interface_ids)
  id       = each.value
}

locals {
  atlas_port_keys = toset([for port in var.atlas_ports : tostring(port)])

  atlas_vpce_eni_ips = [
    for eni in data.aws_network_interface.atlas_vpce_eni : eni.private_ip
  ]

  target_attachments = {
    for pair in setproduct(local.atlas_vpce_eni_ips, local.atlas_port_keys) :
    "${pair[0]}:${pair[1]}" => {
      ip   = pair[0]
      port = pair[1]
    }
  }
}

# ── Network Load Balancer fronting the Atlas VPCE ENIs ────────────────────────
resource "aws_lb" "atlas_kb" {
  name                             = "${var.project_name}-kb-pl-${var.environment}"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.private_subnet_ids
  enable_cross_zone_load_balancing = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-kb-pl-${var.environment}"
    Role = "bedrock-kb-privatelink"
  })
}

resource "aws_lb_target_group" "atlas_kb" {
  for_each = local.atlas_port_keys

  name        = "${substr(replace(var.project_name, "-", ""), 0, 12)}-${var.environment}-${each.value}"
  port        = tonumber(each.value)
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
    precondition {
      condition     = length(local.atlas_vpce_eni_ips) > 0 && length(var.atlas_ports) > 0
      error_message = "bedrock-kb-privatelink: Atlas VPCE ${var.atlas_vpce_id} must have ENIs and private listener ports. Ensure atlas-privatelink has been applied and the Atlas private endpoint connection string is available."
    }
  }
}

resource "aws_lb_target_group_attachment" "atlas_eni" {
  for_each = local.target_attachments

  target_group_arn = aws_lb_target_group.atlas_kb[each.value.port].arn
  target_id        = each.value.ip
  port             = tonumber(each.value.port)
}

resource "aws_lb_listener" "atlas_kb" {
  for_each = local.atlas_port_keys

  load_balancer_arn = aws_lb.atlas_kb.arn
  port              = tonumber(each.value)
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.atlas_kb[each.value].arn
  }

  tags = var.tags
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
