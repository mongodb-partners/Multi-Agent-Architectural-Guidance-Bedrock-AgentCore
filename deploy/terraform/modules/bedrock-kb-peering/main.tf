terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.27, < 7.0"
    }
    null     = { source = "hashicorp/null", version = "~> 3.0" }
    external = { source = "hashicorp/external", version = "~> 2.0" }
  }
}

# =============================================================================
# Bedrock KB peering — EXPERIMENTAL
#
# Bedrock Knowledge Base ingestion runs in Bedrock's *managed* VPC (we cannot
# add ENIs there or attach a Route 53 zone), so the peering routes the runtime
# uses are invisible to Bedrock. This module exposes Atlas private peering IPs
# (resolved via `dig` from an SSM-enabled EC2 host in the peered VPC) behind an
# NLB + VPC Endpoint Service so Bedrock can dial Atlas privately even in
# peering mode.
#
# ⚠ EXPERIMENTAL: This TLS path is NOT partner-validated by MongoDB or AWS.
#   Bedrock's MongoDB driver may reject the standard cluster certificate when
#   reached through the NLB-over-peering path. The existing ingestion job
#   provisioner in modules/bedrock-kb/main.tf will fail the apply with the
#   driver error in failureReasons; the one-flag fallback is to set
#   enable_kb_peering_fallback_to_privatelink = true in tfvars (envs/ec2 will
#   then additionally provision modules/atlas-privatelink +
#   modules/bedrock-kb-privatelink — runtime traffic still uses peering).
#
# ⚠ mongod IP DRIFT: null_resource.discover_ips resolves Atlas private IPs
#   once at deploy time. If Atlas rotates a replica set member (maintenance,
#   scaling, region failover), the NLB target becomes stale and ingestion
#   silently degrades. The trigger is atlas_connection_string_sha — re-run the
#   peering deploy (./deploy/deploy-full-with-vpc-peering.sh --skip-network
#   --skip-shared) to re-discover.
# =============================================================================

locals {
  # NLB names are capped at 32 chars. Keep readable project prefix + hash.
  nlb_name = "kbp-${substr(replace(var.project_name, "-", ""), 0, 16)}-${substr(md5("${var.project_name}-${var.environment}"), 0, 8)}"

  atlas_port_keys = toset([for port in var.atlas_ports : tostring(port)])
}

# ── Discover Atlas peering IPs via SSM dig from EC2 ──────────────────────────
# Replaces an earlier `null_resource.discover_ips` + `data "local_file"` pair
# that wrote a JSON file on disk and read it back. That pattern broke fresh
# deploys: `data "local_file"` is evaluated at plan time, fails with "no such
# file or directory" before the provisioner has had a chance to create the
# file, and forced a two-pass `-target` apply (terraform apply -target=module.ec2
# then a second full apply). The external data source runs at plan time so the
# IPs land in the same plan/apply cycle.
#
# The script handles the first-plan chicken-and-egg cleanly: when
# ec2_instance_id is empty (EC2 not yet created), the script returns an empty
# IP list. The NLB target_group precondition `length(local.atlas_ips) > 0`
# then fires AT APPLY TIME, after module.ec2 has been created by the same
# apply — by which point a re-evaluation of this data source on the second
# graph pass produces real IPs. See the script comment block for the protocol.
#
# Re-discovery is triggered by `query` content changes: a cluster reissue
# rotates atlas_connection_string (and atlas_srv_host), which invalidates the
# external data source. Replacing the EC2 (different ec2_instance_id) also
# re-runs discovery on the next plan. There is no other event that rotates
# Atlas peering IPs per the Atlas FAQ.
data "external" "atlas_ips" {
  program = ["bash", "${path.module}/scripts/discover-atlas-private-ips.sh"]

  query = {
    aws_region         = var.aws_region
    ec2_instance_id    = var.ec2_instance_id
    atlas_srv_host     = var.atlas_srv_host
    atlas_peering_cidr = var.atlas_peering_cidr

    # Force re-discovery on cluster reissue (the only Atlas event that
    # rotates peering IPs). atlas_connection_string is sensitive, so we hash
    # it — terraform external doesn't accept sensitive values in `query`.
    atlas_connection_string_sha = sha1(var.atlas_connection_string)
  }
}

locals {
  # The external data source returns ips as a comma-joined string (terraform
  # external protocol restricts result values to strings, no arrays). Empty
  # string means "EC2 not ready yet, defer to apply-time precondition".
  _ips_csv  = data.external.atlas_ips.result.ips
  atlas_ips = local._ips_csv == "" ? [] : split(",", local._ips_csv)
}

# ── Step 2 — NLB fronting the discovered Atlas IPs ───────────────────────────
resource "aws_lb" "atlas_kb" {
  name                             = local.nlb_name
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.private_subnet_ids
  enable_cross_zone_load_balancing = true

  tags = merge(var.tags, {
    Name = local.nlb_name
    Role = "bedrock-kb-peering"
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
    create_before_destroy = true
    ignore_changes        = [name]

    precondition {
      condition     = length(local.atlas_ips) > 0
      error_message = "bedrock-kb-peering: discover_ips produced an empty IP list. Verify the EC2 instance ${var.ec2_instance_id} is SSM-reachable and can resolve _mongodb._tcp.${var.atlas_srv_host}. Check the discover-atlas-private-ips.sh output."
    }
  }
}

# Register Atlas peering IPs against each per-port target group via aws CLI
# instead of `aws_lb_target_group_attachment` for_each. Reason: a for_each
# whose KEYS depend on local.atlas_ips (one per IP×port pair) breaks fresh
# deploys — the IP set is `(known after apply)` because data.external.atlas_ips
# is deferred until apply time (after module.ec2 is created). for_each KEYS
# must be plan-time-known, so we can't use the native attachment resource.
#
# The per-port `null_resource` has a STATIC key (the port number) so the plan
# graph is fixed at plan time. The provisioner runs at apply time when
# local.atlas_ips is real:
#   1. Deregister whatever the target group currently has (idempotent: empty
#      on first apply, populated on re-applies after IP drift).
#   2. Register the freshly discovered IPs for this port.
#
# Triggers re-run the provisioner whenever the IP set or the target group
# arn changes (cluster reissue / NLB rebuild). Destroy is a no-op because
# `aws_lb_target_group` deletion auto-deregisters all targets — no orphans.
resource "null_resource" "register_targets" {
  for_each = local.atlas_port_keys

  triggers = {
    target_group_arn = aws_lb_target_group.atlas_kb[each.value].arn
    port             = each.value
    ips_csv          = local._ips_csv
    aws_region       = var.aws_region
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      tg_arn="${self.triggers.target_group_arn}"
      port="${self.triggers.port}"
      region="${self.triggers.aws_region}"
      ips_csv="${self.triggers.ips_csv}"

      if [[ -z "$ips_csv" ]]; then
        echo "[bedrock-kb-peering] register_targets: empty IP list — skipping (will run on next apply once data.external.atlas_ips returns real IPs)"
        exit 0
      fi

      # Deregister whatever the TG currently has (idempotent — first deploy
      # returns an empty list, re-runs cleanly drop old IPs after drift).
      existing=$(aws elbv2 describe-target-health --region "$region" \
        --target-group-arn "$tg_arn" \
        --query 'TargetHealthDescriptions[].Target.Id' \
        --output text 2>/dev/null || echo "")
      if [[ -n "$existing" ]]; then
        targets=""
        for ip in $existing; do
          targets="$targets Id=$ip,Port=$port"
        done
        echo "[bedrock-kb-peering] deregistering existing targets for port $port: $existing"
        aws elbv2 deregister-targets --region "$region" \
          --target-group-arn "$tg_arn" --targets $targets >/dev/null
      fi

      # Register the freshly discovered Atlas peering IPs. AvailabilityZone=all
      # is REQUIRED because the Atlas IPs are in the peer's CIDR (e.g.
      # 192.168.248.0/21), not the consumer VPC's CIDR. Without it, ELBv2
      # rejects with: "The Availability Zone is required for IP address
      # 'X.X.X.X' because it is not in the VPC". `all` enables cross-zone
      # routing — fine for NLB since enable_cross_zone_load_balancing=true
      # is set on the LB itself.
      targets=""
      IFS=,
      for ip in $ips_csv; do
        targets="$targets Id=$ip,Port=$port,AvailabilityZone=all"
      done
      unset IFS
      echo "[bedrock-kb-peering] registering targets for port $port: $ips_csv"
      aws elbv2 register-targets --region "$region" \
        --target-group-arn "$tg_arn" --targets $targets
    EOT
  }
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

  depends_on = [null_resource.register_targets]
}

# ── Step 3 — VPC Endpoint Service exposing the NLB to Bedrock ────────────────
# Same wildcard-principal pattern as bedrock-kb-privatelink — Bedrock auto-
# creates the consumer VPCE in its managed account when the KB is provisioned.
# acceptance_required = false so the connection request doesn't sit in
# PendingAcceptance forever.
resource "aws_vpc_endpoint_service" "atlas_kb" {
  acceptance_required        = false
  network_load_balancer_arns = [aws_lb.atlas_kb.arn]
  allowed_principals         = var.allowed_principals

  tags = merge(var.tags, {
    Name = "${var.project_name}-kb-peering-vpces-${var.environment}"
  })
}
