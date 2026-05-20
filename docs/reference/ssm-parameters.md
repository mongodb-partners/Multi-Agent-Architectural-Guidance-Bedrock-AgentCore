# SSM Parameter Contract — Reference

Cross-stack communication between Terraform environments goes through **AWS Systems Manager Parameter Store**, not `terraform_remote_state`. Two stacks publish; one stack consumes; values are looked up at apply time via `data "aws_ssm_parameter"`.

## Prefix

All shared values live under:

```
/<SHARED_VPC_NAME>/<AWS_REGION>/<key>
```

`SHARED_VPC_NAME` is the env-var that drives both the resource Name tag prefix and this SSM namespace. Per-project `envs/ec2` deployments in the same `(account, region)` point at the same `SHARED_VPC_NAME` and therefore read the same set of values.

> The prefix has **no environment segment** by design — `envs/shared` is a singleton per `(account, region, environment)` but the SSM namespace it writes is per `(account, region)`. If you run two environments (e.g. `dev` and `prod`) in the same account and region, give each its own `SHARED_VPC_NAME` so their SSM keys do not collide.

The full prefix is exposed back to callers via `output "ssm_prefix"` from both `envs/network` and `envs/shared`. `envs/ec2` recomputes it as `/${var.shared_vpc_name}/${var.aws_region}`.

## Sentinel value

Always-on parameters that may be empty (e.g. Voyage endpoint when `EMBEDDINGS_PROVIDER=titan`) publish the literal string `_empty_`. Consumers in `envs/ec2` translate `_empty_` back to `""` so a never-applied vs. applied-but-disabled state is distinguishable.

---

## 1. Published by `envs/network`

Mode-independent values (always written):

| Key | Type | Producer | Description |
|---|---|---|---|
| `vpc_id` | String | `module.networking.vpc_id` | Shared VPC ID |
| `vpc_cidr` | String | `module.networking.vpc_cidr` | VPC CIDR block |
| `public_subnet_ids` | StringList | `module.networking.public_subnet_ids` | Comma-delimited list |
| `private_subnet_ids` | StringList | `module.networking.private_subnet_ids` | Comma-delimited list |
| `network_mode` | String | `var.network_mode` | `privatelink` or `peering`. **The mode canary** — `envs/ec2` aborts when its `var.network_mode` disagrees |

PrivateLink-mode-only (`count = var.network_mode == "privatelink" ? 1 : 0`):

| Key | Producer |
|---|---|
| `atlas_pl_vpce_id` | `module.atlas_privatelink.vpc_endpoint_id` |
| `atlas_pl_vpce_dns_name` | `module.atlas_privatelink.vpce_dns_name` |
| `atlas_pl_security_group_id` | `module.atlas_privatelink.security_group_id` |
| `atlas_endpoint_service_name` | `module.atlas_privatelink.endpoint_service_name` |
| `atlas_private_link_id` | `module.atlas_privatelink.private_link_id` |

Peering-mode-only (`count = var.network_mode == "peering" ? 1 : 0`):

| Key | Producer |
|---|---|
| `atlas_peering_id` | `module.atlas_vpc_peering.atlas_peering_id` |
| `atlas_container_id` | `module.atlas_vpc_peering.atlas_network_container_id` |
| `atlas_peering_cidr` | `module.atlas_vpc_peering.atlas_cidr_block` |
| `atlas_private_dns_enabled` | `module.atlas_vpc_peering.atlas_private_dns_enabled` |

> In `envs/ec2`, mode-gated reads use `for_each = local.is_privatelink_mode ? toset(["pl"]) : toset([])` (and the mirror for peering) so a `ParameterNotFound` cannot happen — the data source is simply not instantiated in the wrong mode.

---

## 2. Published by `envs/shared`

All keys are always written. Optional values use the `_empty_` sentinel.

| Key | Type | Producer | Notes |
|---|---|---|---|
| `voyage_sagemaker_endpoint_name` | String | `module.voyage_sagemaker[0].endpoint_name` | `_empty_` when `VOYAGE_MODEL_PACKAGE_ARN` is unset |
| `voyage_sagemaker_endpoint_arn` | String | `module.voyage_sagemaker[0].endpoint_arn` | Same |
| `cw_api_log_group` | String | `module.cloudwatch.api_log_group_name` | `/<SHARED_RESOURCE_PREFIX>/<env>/api` |
| `cw_ui_log_group` | String | `module.cloudwatch.ui_log_group_name` | `/<SHARED_RESOURCE_PREFIX>/<env>/ui` |
| `cw_mcp_log_group` | String | `module.cloudwatch.mcp_log_group_name` | `/<SHARED_RESOURCE_PREFIX>/<env>/mcp` |
| `cw_agentcore_log_group` | String | `module.cloudwatch.agentcore_log_group_name` | `/<SHARED_RESOURCE_PREFIX>/<env>/agentcore` |
| `cw_otel_log_group` | String | `aws_cloudwatch_log_group.otel.name` | `/<SHARED_RESOURCE_PREFIX>/<env>/otel` |
| `cw_otel_atlas_log_group` | String | `aws_cloudwatch_log_group.otel_atlas.name` | `/<SHARED_RESOURCE_PREFIX>/<env>/otel-atlas` |
| `bedrock_invocation_log_group` | String | `module.bedrock_invocation_logging.log_group_name` | `_empty_` when `enable_bedrock_invocation_logging=false` |
| `bedrock_audit_log_group` | String | `module.bedrock_invocation_logging.audit_log_group_name` | Same |

---

## 3. Consumed by `envs/ec2`

`envs/ec2` reads every key listed above via `data "aws_ssm_parameter"`. Specifically:

- The `network_mode` parameter is read and compared to `var.network_mode`. A `check "network_mode_matches_shared"` block fails the plan when they disagree — this catches `deploy-project.sh` being invoked in the wrong mode after a `deploy-network.sh --allow-mode-switch`.
- Mode-gated reads (`atlas_pl_*` for privatelink, `atlas_peering_*` and `atlas_container_id` for peering) use `for_each` so the data source is not instantiated when the mode doesn't match.
- `voyage_sagemaker_endpoint_*` and `bedrock_*_log_group` parameters are stripped of the `_empty_` sentinel and re-emitted as `""` in `local.shared_*` so module callers see clean strings.

---

## 4. Published by `envs/ec2` (for downstream consumers)

`envs/ec2` does **not** publish back into the cross-stack SSM namespace — its outputs are consumed by `deploy-api.sh` / `deploy-agents.sh` via `terraform output` directly.

However, the per-project deployment writes a small set of project-scoped SSM parameters used by the EC2 systemd units and CloudWatch agent. These live under `/${PROJECT_NAME}/${ENVIRONMENT}/…` (not the shared namespace) and are documented inline in [`modules/ec2/main.tf`](../../deploy/terraform/modules/ec2/main.tf) and [`modules/ec2/user_data.sh`](../../deploy/terraform/modules/ec2/user_data.sh). They are an implementation detail and not part of the cross-stack contract.

---

## 5. Inspection

```bash
# All shared parameters for an account+region+SHARED_VPC_NAME:
aws ssm get-parameters-by-path \
  --path "/${SHARED_VPC_NAME}/${AWS_REGION}/" \
  --recursive \
  --query 'Parameters[].{Name:Name,Value:Value}' \
  --output table

# Confirm the network mode canary:
aws ssm get-parameter \
  --name "/${SHARED_VPC_NAME}/${AWS_REGION}/network_mode" \
  --query 'Parameter.Value' --output text
```

If `network_mode` returns `ParameterNotFound`, the shared network stack has never been applied for this `(account, region, SHARED_VPC_NAME)`. Run [`deploy/scripts/deploy-network.sh`](../../deploy/scripts/deploy-network.sh) (or the matching orchestrator) first.

---

## 6. Mode-switch protocol

To switch a `(account, region, SHARED_VPC_NAME)` from one connectivity mode to another:

1. Tear down every consumer: `./deploy/scripts/destroy.sh --mode ec2` (per project), then `--mode shared`.
2. Tear down the network: `./deploy/scripts/destroy.sh --mode network`. This deletes the `network_mode` canary and all mode-specific SSM keys.
3. Update `.env` (`NETWORK_MODE=…`, `ATLAS_PEERING_CIDR=…` if switching to peering).
4. Re-run the matching orchestrator (`deploy-full-with-privatelink.sh` or `deploy-full-with-vpc-peering.sh`).

The `--allow-mode-switch` flag on `deploy-network.sh` is an escape hatch for forced re-applies; the `check` block in `envs/ec2` will still refuse to plan against the new mode until the per-project consumers are destroyed and re-applied.

---

*Last verified: 2026-05-20 against `deploy/terraform/envs/{network,shared,ec2}/main.tf`.*
