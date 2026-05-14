# `bedrock-kb-privatelink/` — Bedrock KB ingestion via AWS PrivateLink

Implements **CLIENT_REVIEW P1-6 Option A**: NLB → VPC Endpoint Service →
Atlas VPCE → Atlas, so Bedrock Knowledge Base ingestion never traverses the
public Atlas SRV hostname.

> **Status:** Opt-in. The module is gated by `var.enable_kb_privatelink` in
> `envs/ec2` (default `false`). Flipping it on adds an NLB (~$22/mo) plus
> per-LCU usage. We ship the module so the SoW-aligned PrivateLink path is
> available without further code changes.

## When to enable

Turn the flag on when:

- You need to satisfy a contractual "no public Atlas hostname touched by AWS
  managed services" requirement, **or**
- Your AWS account-level VPC reachability policy blocks Bedrock-managed
  ingestion from reaching `*.mongodb.net` over the public internet.

Otherwise leave it off — runtime traffic (the Strands agents → MongoDB MCP
runtime path) is **already** PrivateLink today via the per-cluster Route 53
zone in `modules/atlas-cluster-dns/`. KB ingestion is admin-only traffic
(uploaded `*.txt` files → embedded → indexed) and carries no end-user PII.

## How it works

Bedrock Knowledge Base accepts an `endpointServiceName` field on
`MongoDbAtlasConfiguration`. When set, Bedrock creates a VPCE in its managed
VPC connected to the named VPC Endpoint Service. We expose an NLB-backed
endpoint service from this account that forwards TCP 27017 to the Atlas
Interface VPCE ENIs. Bedrock's connection thus never touches the public
internet.

```text
Bedrock managed VPC
    │  (Bedrock-managed VPCE)
    ▼
OUR VPC Endpoint Service ◄── this module
    │
    ▼
OUR Network Load Balancer (TCP 27017 → IP target group)
    │
    ▼
Atlas Interface VPCE ENIs (already provisioned by atlas-privatelink/)
    │
    ▼
Atlas (cross-account, PrivateLink-enabled cluster)
```

## Wiring

In `envs/ec2/main.tf`:

```hcl
module "bedrock_kb_privatelink" {
  count  = var.enable_kb_privatelink ? 1 : 0
  source = "../../modules/bedrock-kb-privatelink"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = local.shared_vpc_id
  private_subnet_ids = local.shared_private_subnet_ids
  atlas_vpce_id      = local.shared_atlas_pl_vpce_id
  tags               = local.common_tags
}

module "bedrock_kb" {
  source = "../../modules/bedrock-kb"
  # ...
  endpoint_service_name = (
    var.enable_kb_privatelink && length(module.bedrock_kb_privatelink) > 0
    ? module.bedrock_kb_privatelink[0].endpoint_service_name
    : ""
  )
}
```

## Operational notes

- The NLB target group references Atlas VPCE ENI **private IPs** (looked up
  via `data.aws_network_interfaces`). Those IPs are stable for the lifetime
  of the VPCE. If the operator re-creates the VPCE in
  `modules/atlas-privatelink/`, re-running `terraform apply` for this module
  refreshes the targets automatically.
- `aws_vpc_endpoint_service.acceptance_required` is `false` so Bedrock can
  auto-create its consumer-side VPCE during KB provisioning. Set to `true`
  if your security review requires manual approval of the connection
  request.
- `var.allowed_principals` defaults to `["*"]`. After the first successful
  KB ingestion you can read `aws_vpc_endpoint_connection_notification` (or
  the AWS Console) to find the exact consumer ARN and tighten the list.
