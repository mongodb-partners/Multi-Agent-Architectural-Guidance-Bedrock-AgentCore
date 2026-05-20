# bedrock-kb-peering — EXPERIMENTAL

End-to-end private Bedrock KB ingestion over VPC peering. Mirrors
`modules/bedrock-kb-privatelink/` in shape (NLB → VPC Endpoint Service →
Atlas mongod) but discovers the Atlas backend IPs via `dig` from an
SSM-enabled EC2 host in the peered VPC instead of from PrivateLink ENIs.

## ⚠ Why this is experimental

MongoDB Atlas's official Bedrock KB integration pattern uses **PrivateLink**
with the Atlas `-pl` hostname so Bedrock's MongoDB driver receives a cert
whose SAN matches the dialed hostname. This module instead routes Bedrock to
the standard cluster hostname through a peering-fronting NLB. The cluster's
TLS certificate SAN list includes the standard hostname, so TLS validation
*should* succeed — but this exact path is **not partner-validated by MongoDB
or AWS**.

If Bedrock's driver rejects the cert when reached through the NLB-over-peering
path, the existing ingestion-job provisioner in
[`../bedrock-kb/main.tf`](../bedrock-kb/main.tf) will fail `terraform apply`
with the driver error in `failureReasons` (we also grep for `TLS|certificate|
SSL|handshake|hostname` keywords to print a remediation banner).

## Remediation if TLS validation fails

PrivateLink and VPC peering are **mutually exclusive per account** — there is
no hybrid mode where KB ingestion goes through a parallel PL VPCE while
runtime traffic uses peering. If this experimental path fails, the only
remediation is to switch the entire deployment back to PrivateLink:

```bash
# Tear down the peering deploy (network → shared → ec2)
./deploy/scripts/destroy.sh --mode ec2
./deploy/scripts/destroy.sh --mode shared      # optional
./deploy/scripts/destroy.sh --mode network

# Flip .env back to NETWORK_MODE=privatelink (or unset for default), then redeploy
./deploy/deploy-full-with-privatelink.sh
```

The cleaner alternative for risk-averse environments is to set
`enable_kb_peering=false` from day one — KB then uses the public Atlas SRV
(authenticated TLS, just not private at the network layer) while runtime
traffic still uses peering. This degrades KB privacy but avoids the
experimental path entirely.

## mongod IP drift — operational caveat

`null_resource.discover_ips` resolves Atlas private IPs **once at deploy
time** via:

```text
EC2 (peered VPC) ── dig SRV _mongodb._tcp.<srv_host>
                ── for each shard: dig A <shard>.<...>-pri.mongodb.net
                ── sanity-check each IP falls inside ATLAS_PEERING_CIDR
                ── write to .atlas-ips-<cluster>.json
```

If Atlas rotates a replica set member (maintenance, scaling, region failover),
the NLB target group becomes stale and KB ingestion silently degrades.

**Recovery (v1):** operator re-runs the peering deploy:

```bash
./deploy/deploy-full-with-vpc-peering.sh --skip-network --skip-shared
```

The trigger on `null_resource.discover_ips` is
`atlas_connection_string_sha = sha1(var.atlas_connection_string)` — Atlas
re-issues the cluster connection string whenever the underlying IPs change,
so a clean re-apply naturally re-discovers without forcing terraform taint.
This is documented in [`docs/observability-runbook.md`](../../../../docs/observability-runbook.md)
under "Bedrock KB peering: IP drift recovery".

**v1.1 enhancement (out of scope for this module):** EventBridge-scheduled
Lambda that re-runs the `dig` discovery and updates target group attachments
without operator action.

## Privacy posture

This module preserves end-to-end privacy in peering mode:

- Bedrock → our VPC Endpoint Service → NLB → Atlas peering IPs (all private)
- Atlas mongod listener is reached via the Atlas peering route, never the
  public internet.
- The SSM `dig` call runs from EC2 inside the peered VPC; the operator's
  laptop is not involved in IP resolution.

No new public-internet paths are introduced. This is **strictly better** than
the default PrivateLink mode of this repo today, which falls back to the
public SRV for KB ingestion unless `enable_kb_privatelink=true` is set
explicitly.

## Inputs / Outputs

See [`variables.tf`](variables.tf) and [`outputs.tf`](outputs.tf). Key
outputs:

- `endpoint_service_name` — pass straight into `module.bedrock_kb.endpoint_service_name`.
- `discovered_atlas_ips` — sanity-check after apply (should equal the number
  of replica set members, e.g. 3 for an M10).
