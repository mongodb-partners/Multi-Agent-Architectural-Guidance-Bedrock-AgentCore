# Terraform Modules — Reference

Every reusable module under [`deploy/terraform/modules/`](../../deploy/terraform/modules/) with its purpose, key inputs, key outputs, and the environments that consume it.

The four environments under [`deploy/terraform/envs/`](../../deploy/terraform/envs/) compose these modules:

| Env | Role | Singleton per | State backend |
|---|---|---|---|
| `network` | Shared VPC + Atlas connectivity (PrivateLink or peering) — publishes SSM under `/<SHARED_VPC_NAME>/<region>/` | (account, region) | S3 + DynamoDB lock |
| `shared` | SageMaker Voyage endpoint, shared CloudWatch log groups, fleet/mongo/cost/atlas dashboards, Bedrock invocation logging — publishes SSM under `/<SHARED_VPC_NAME>/<region>/<env>/` | (account, region, environment) | S3 + DynamoDB lock |
| `ec2` | Per-project app stack — EC2, ECR, Cognito, Bedrock KB, AgentCore Runtimes + Gateway, ADOT, GenAI observability | (account, region, environment, project) | S3 + DynamoDB lock |
| `local` | Laptop / non-AWS dev — Atlas + AgentCore Memory only | n/a | local file |

The first two are singletons that publish SSM; `envs/ec2` reads them with `data "aws_ssm_parameter"`. There is **no** `terraform_remote_state` chaining. The full SSM contract is in [`ssm-parameters.md`](ssm-parameters.md).

---

## 1. Networking & connectivity

### `networking`
Shared VPC + 3 public + 3 private subnets across 3 AZs; NAT gateways for private egress; default route tables.
- **Inputs**: `aws_region`, `project_name`, `environment`, `vpc_cidr` (default `10.0.0.0/16`).
- **Outputs**: `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `main_route_table_id`, `public_route_table_id`.
- **Used by**: `envs/network`.

### `atlas-privatelink`
AWS Interface VPC Endpoint pointing at the Atlas-side endpoint service. Pre-provisions the Atlas private endpoint via the Atlas provider.
- **Inputs**: `atlas_project_id`, `vpc_id`, `vpc_cidr`, `private_subnet_ids`.
- **Outputs**: `vpc_endpoint_id`, `vpce_dns_name`, `endpoint_service_name`, `private_link_id`, `security_group_id`.
- **Used by**: `envs/network` when `NETWORK_MODE=privatelink`.

### `atlas-privatelink-dns`
Per-cluster Route 53 private hosted zone + alias records so the Atlas SRV resolves to the VPCE inside the VPC.
- **Inputs**: `vpc_id`, `atlas_srv_host`, `vpce_dns_name`, `project_name`, `environment`.
- **Outputs**: (creates Route 53 zone + records).
- **Used by**: `envs/ec2` when `NETWORK_MODE=privatelink`.

### `atlas-vpc-peering`
AWS VPC peering accepter + Atlas `network_peering` + Atlas Private DNS for Peering. CIDR pre-flight check is in `scripts/`.
- **Inputs**: `atlas_project_id`, `vpc_id`, `vpc_cidr`, `atlas_peering_cidr` (default `192.168.248.0/21`), `vpc_main_route_table_id`, `vpc_public_route_table_id`, `aws_account_id`, `operator_ip_cidr`.
- **Outputs**: `peering_connection_id`, `atlas_peering_id`, `atlas_network_container_id`, `atlas_cidr_block`, `peering_status`, `atlas_private_dns_enabled`.
- **Used by**: `envs/network` when `NETWORK_MODE=peering`.

### `bedrock-kb-privatelink`
Per-cluster NLB whose targets are the Atlas Interface VPCE ENIs, exposed back to Bedrock as an Endpoint Service that the KB role assumes for ingestion.
- **Inputs**: `vpc_id`, `private_subnet_ids`, `atlas_vpce_id`, `atlas_ports`, `allowed_principals`.
- **Outputs**: `endpoint_service_name`, `endpoint_service_id`, `nlb_arn`, `nlb_dns_name`, `atlas_vpce_eni_count`.
- **Used by**: `envs/ec2` when `NETWORK_MODE=privatelink` and `TF_VAR_enable_kb_privatelink=true` (default).

### `bedrock-kb-peering`
**EXPERIMENTAL** — NLB whose targets are Atlas peering-private IPs discovered with `dig` against the peering SRV. Bedrock KB ingestion through this path is not partner-validated for TLS; see [`modules/bedrock-kb-peering/README.md`](../../deploy/terraform/modules/bedrock-kb-peering/README.md) for the risk-managed alternative (`enable_kb_peering=false` degrades KB to public Atlas SRV — privacy regression, not a default).
- **Inputs**: `vpc_id`, `private_subnet_ids`, `atlas_srv_host`, `atlas_connection_string`, `cluster_name`, `atlas_peering_cidr`, `atlas_ports`, `allowed_principals`.
- **Outputs**: `endpoint_service_name`, `endpoint_service_id`, `nlb_arn`, `nlb_dns_name`, `discovered_atlas_ips`, `discovered_ip_count`.
- **Used by**: `envs/ec2` when `NETWORK_MODE=peering` and `TF_VAR_enable_kb_peering=true` (default).

---

## 2. MongoDB Atlas

### `mongodb-atlas`
Atlas cluster + DB user + DB. Emits mode-aware connection strings.
- **Inputs**: `atlas_project_id`, `cluster_name`, `db_name`, `db_username`, `db_password`, `privatelink_endpoint_id`, `network_mode`, `vpc_cidr`.
- **Outputs (mode-aware)**:
  - Always: `cluster_name`, `srv_address`, `connection_string`, `mongo_host`.
  - PrivateLink: `privatelink_connection_string`, `privatelink_srv_host`, `privatelink_ports`.
  - Peering: `peering_connection_string`, `peering_srv_host`, `peering_connection_srv_string`.
- **Used by**: `envs/ec2`, `envs/local`.

---

## 3. Bedrock Knowledge Base

### `bedrock-kb`
Bedrock Knowledge Base with MongoDB Atlas vector store, IAM role, KB S3 bucket, data source, ingestion job seeded with [`deploy/kb-docs/`](../../deploy/kb-docs/).
- **Inputs**: `aws_region`, `account_id`, `atlas_project_id`, `atlas_cluster_name`, `atlas_srv_host`, `kb_endpoint_host`, `atlas_db_user`, `atlas_db_password`, `atlas_db_name`, `atlas_collection`, `atlas_vector_index`, `embedding_dimensions`, `endpoint_service_name` (PL or peering NLB), `embed_model_id`, `shared_bucket_name`, `kb_docs_path`, `kb_iam_role_name`.
- **Outputs**: `kb_docs_bucket_name`, `kb_docs_bucket_arn`, `atlas_secret_arn`, `atlas_secret_name`, `knowledge_base_id`, `knowledge_base_arn`, `data_source_id`, `kb_role_arn`.
- **Used by**: `envs/ec2`, `envs/local`.

---

## 4. AgentCore (Bedrock AgentCore)

### `agentcore-agent-runtime`
One AgentCore Runtime per agent (orchestrator + 3 specialists) plus the dedicated `mongodb-mcp-runtime`. Reusable; called 5× from `envs/ec2`. Supports `container` and `code` deployment modes.
- **Inputs (selected)**: `runtime_name`, `deployment_mode` (`container` / `code`), `container_uri` (container mode), `code_artifact_bucket` + `code_artifact_prefix` + `code_artifact_version_id` + `code_runtime` + `code_entry_point` (code mode), `environment_variables`, `voyage_sagemaker_endpoint_arn`, `kb_secret_name_prefix`, `network_mode`, `vpc_subnet_ids`, `vpc_security_group_ids`, `idle_timeout_seconds`, `max_lifetime_seconds`, `server_protocol` (default `HTTP`, `MCP` for the MongoDB MCP runtime).
- **Outputs**: `runtime_arn`, `runtime_id`, `runtime_role_arn`, `runtime_version`, `workload_identity_arn`.
- **Used by**: `envs/ec2` — once per AgentCore Runtime (`mongodb_mcp_runtime`, `acr_specialists`, `acr_orchestrator`). The `mongodb_mcp_runtime.runtime_id` output is re-exported from `envs/ec2` as `mongodb_mcp_runtime_id` and consumed by `deploy-project.sh::force_mcp_runtime_image_sync` to bump the runtime version after every `docker push` (so `:latest` digest changes are actually pulled).
- **Lifecycle**: `environment_variables` is in `lifecycle.ignore_changes` because deploy scripts layer ~15 dynamic env vars onto the 4 TF-declared ones via `bedrock-agentcore-control update-agent-runtime` after apply (`_agents-common.sh::update_runtime_env_dynamic`). Removing this would let the next `terraform apply` reset the runtime back to the 4 declared vars, silently wiping `AGENTCORE_GATEWAY_URL` / `MONGODB_URI` / `BEDROCK_KB_ID` / `EMBEDDINGS_PROVIDER` until the next `deploy-agents.sh` run. See `docs/status/debugging.md` Known persistent pitfalls.

### `agentcore-gateway`
AgentCore Gateway with Cognito-authorized MCP target(s). **All MCP tool calls in deployed runtimes — including every Mongo tool — go through this Gateway**; the dedicated `mongodb-mcp-runtime` AgentCore Runtime is wired as a Gateway target, not invoked directly by application runtimes. `MCP_SERVER_URL` is a local-development override only.
- **Inputs**: `cognito_user_pool_id`, `cognito_app_client_id`, `lambda_function_arn` (back-compat — no longer wired in current code), `create_lambda_target`, `create_mcp_server_target`, `mcp_server_endpoint`, `mcp_server_runtime_arn`, `mcp_server_image_digest` (opaque change-tracker; when the upstream MCP image digest changes, this re-triggers the gateway-target `null_resource` so cached tool schemas are refreshed on the next apply — see `docs/status/debugging.md` "AgentCore Gateway target caches tool schemas").
- **Outputs**: `gateway_id`, `gateway_mcp_url`, `gateway_arn`.
- **Used by**: `envs/ec2` (the `mongodb_mcp_image_digest` envs/ec2 variable is forwarded here from `deploy-project.sh` Phase 4d after the MCP image is pushed).

### `agentcore-memory`
AgentCore Memory Store (short-term backend; LTM fallback).
- **Inputs**: `aws_region`, `project_name`, `environment`, `event_expiry_days`.
- **Outputs**: `memory_id`, `memory_name`, `memory_arn`.
- **Used by**: `envs/ec2`, `envs/local`.

---

## 5. EC2 application host

### `ec2`
T-class EC2 instance with SSM Session Manager access, ECR auth, systemd units for `multiagent-api`, `multiagent-ui`, `multiagent-adot` plus their CloudWatch agent. `user_data.sh` runs once at first boot.
- **Inputs (selected)**: `vpc_id`, `public_subnet_id`, `instance_type`, `key_pair_name` (optional — SSM is the primary path), `ecr_api_image`, `ecr_ui_image`, `ecr_registry`, `cw_log_group_api`, `cw_log_group_ui`, `adot_collector_image`, `adot_config_etag`, `otel_sample_ratio`, `atlas_prom_secret_arn`, `network_mode`, `atlas_peering_cidr`.
- **Outputs**: `public_ip`, `instance_id`, `api_url`, `ui_url`, `ssh_command`, `ssm_command`, `deploy_target`, `security_group_id`.
- **Used by**: `envs/ec2`.

### `ecr`
ECR repositories for the API + UI images.
- **Inputs**: `project_name`, `environment`.
- **Outputs**: `api_repository_url`, `ui_repository_url`, `registry_id`.
- **Used by**: `envs/ec2`.

### `cognito`
User pool + app + domain + test user for the Streamlit UI. Emits the JWKS URI consumed by the API as `AUTH_JWKS_URI`.
- **Inputs**: `project_name`, `environment`, `aws_region`.
- **Outputs**: `user_pool_id`, `user_pool_arn`, `user_pool_client_id`, `user_pool_endpoint`, `user_pool_domain`, `jwks_uri`.
- **Used by**: `envs/ec2`.

---

## 6. Voyage embeddings

### `voyage-sagemaker`
SageMaker real-time endpoint hosting the Voyage Marketplace model (`voyage-multimodal-3` on `ml.g6.xlarge` by default). Endpoint name is written to `.env.live` as `VOYAGE_SAGEMAKER_ENDPOINT`.
- **Inputs**: `aws_region`, `environment`, `voyage_model_package_arn`, `endpoint_name_suffix`, `instance_type` (default `ml.g6.xlarge`), `instance_count`.
- **Outputs**: `endpoint_name`, `endpoint_arn`, `execution_role_arn`.
- **Used by**: `envs/shared`.

---

## 7. Observability

### `cloudwatch`
Per-component CloudWatch log groups: `/<SHARED_RESOURCE_PREFIX>/<env>/{api,ui,mcp,agentcore}`. Retention is `api_retention_days` (long) vs `aux_retention_days` (short).
- **Inputs**: `project_name`, `shared_resource_prefix`, `environment`, `api_retention_days`, `aux_retention_days`.
- **Outputs**: `api_log_group_name`, `ui_log_group_name`, `mcp_log_group_name`, `agentcore_log_group_name`.
- **Used by**: `envs/shared`, `envs/local`.

### `adot-collector`
ECR-hosted AWS Distro for OpenTelemetry collector image + config (templated). Runs as a sidecar on EC2 and ships OTLP spans + Atlas Prometheus metrics. Outputs the matching CloudWatch log groups (`otel`, `otel-atlas`).
- **Inputs**: `project_name`, `environment`, `aws_region`, `shared_bucket_name`, `otel_log_group_name`, `enable_atlas_metrics`, `atlas_scrape_interval_sec`, `atlas_secret_arn`.
- **Outputs**: `config_etag`, `otel_log_group_name`, `otel_log_group_arn`, `otel_atlas_log_group_arn`.
- **Used by**: `envs/ec2` (via the `ec2` module wiring `adot_collector_image` + `adot_config_etag`).

### `cloudwatch-genai`
Bedrock GenAI observability — X-Ray CW resource policy, `gen_ai.*` span log group, AgentCore memory/gateway log groups, Transaction Search indexing toggle.
- **Inputs**: `project_name`, `environment`, `span_retention_days`, `span_sampling_percent`, `agentcore_log_retention_days`, `enable_transaction_search_toggle`, `agentcore_memories[]`, `agentcore_gateways[]`, `agentcore_memory_ids[]`, `agentcore_gateway_ids[]`.
- **Outputs**: `xray_cw_resource_policy_name`, `spans_log_group_name`, `spans_log_group_arn`, `memory_log_group_names`, `gateway_log_group_names`, `transaction_search_indexing_percentage`.
- **Used by**: `envs/ec2`.

### `bedrock-invocation-logging`
Bedrock invocation logging → CloudWatch (`/aws/bedrock/invocations`) with optional prompt-body / embedding-body capture and a Data Protection Policy that masks PII even when bodies are on.
- **Inputs**: `project_name`, `shared_resource_prefix`, `environment`, `enable`, `log_prompt_bodies` (default `false`), `log_embedding_bodies` (default `false`), `log_group_name`, `retention_days`, `data_protection_identifiers[]`.
- **Outputs**: `log_group_name`, `log_group_arn`, `audit_log_group_name`, `audit_log_group_arn`, `role_arn`, `log_prompt_bodies_enabled`.
- **Used by**: `envs/shared`.

### `cloudwatch-fleet-dashboards`
The three core dashboards: `<prefix>-fleet-<env>`, `<prefix>-mongo-<env>`, `<prefix>-cost-<env>`. Includes 7 fleet alarms + metric filters.
- **Inputs**: `project_name`, `shared_resource_prefix`, `environment`, `aws_region`, `api_log_group_name`, `ui_log_group_name`, `invocation_log_group_name`, `audit_findings_log_group_name`, `otel_log_group_name`, `error_rate_threshold_pct`, `throttle_burst_threshold`.
- **Outputs**: `fleet_dashboard_url`, `mongo_dashboard_url`, `cost_dashboard_url`.
- **Used by**: `envs/shared`.

### `cloudwatch-atlas-dashboard`
`<prefix>-atlas-<env>` dashboard + Atlas-side alarms (e.g. replication lag).
- **Inputs**: `project_name`, `shared_resource_prefix`, `environment`, `aws_region`, `sns_topic_arn`, `replication_lag_threshold_ms`.
- **Outputs**: `dashboard_name`.
- **Used by**: `envs/shared`.

---

## Environment composition matrix

| Module | `envs/network` | `envs/shared` | `envs/ec2` | `envs/local` |
|---|---|---|---|---|
| `networking` | ✅ | | | |
| `atlas-privatelink` | ✅ (PL only) | | | |
| `atlas-privatelink-dns` | | | ✅ (PL only) | |
| `atlas-vpc-peering` | ✅ (peering only) | | | |
| `mongodb-atlas` | | | ✅ | ✅ |
| `bedrock-kb-privatelink` | | | ✅ (PL only, gated by `TF_VAR_enable_kb_privatelink`) | |
| `bedrock-kb-peering` | | | ✅ (peering only, gated by `TF_VAR_enable_kb_peering`) | |
| `bedrock-kb` | | | ✅ | ✅ |
| `ecr` | | | ✅ | |
| `cognito` | | | ✅ | |
| `adot-collector` | | | ✅ | |
| `agentcore-memory` | | | ✅ | ✅ |
| `agentcore-agent-runtime` | | | ✅ (×5) | |
| `agentcore-gateway` | | | ✅ | |
| `cloudwatch-genai` | | | ✅ | |
| `ec2` | | | ✅ | |
| `voyage-sagemaker` | | ✅ | | |
| `cloudwatch` | | ✅ | | ✅ |
| `bedrock-invocation-logging` | | ✅ | | |
| `cloudwatch-fleet-dashboards` | | ✅ | | |
| `cloudwatch-atlas-dashboard` | | ✅ | | |

---

*Last verified: 2026-05-20 against `deploy/terraform/modules/*/variables.tf` + `outputs.tf` and the `module "…"` calls in `deploy/terraform/envs/{network,shared,ec2,local}/main.tf`.*
