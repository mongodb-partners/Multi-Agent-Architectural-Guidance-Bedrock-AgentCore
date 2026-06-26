variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "multiagent-mongodb-framework"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "shared_bucket_name" {
  type = string
}

variable "kb_docs_bucket_name" {
  type        = string
  default     = ""
  description = "Optional dedicated S3 bucket for KB source docs. Empty = use the shared bucket."
}

variable "kb_docs_bucket_create" {
  type        = bool
  default     = true
  description = "Whether Terraform creates/owns the dedicated KB bucket (true) or references an already-existing, externally-owned bucket of that name (false: no create, no settings change, no sample-doc upload). Auto-resolved by deploy-project.sh (existing-but-unmanaged bucket -> false)."
}

# ── Shared network (envs/network) ─────────────────────────────────────────────
variable "shared_vpc_name" {
  type        = string
  description = "Identity of the shared VPC + Atlas PrivateLink stack provisioned by envs/network. Drives the SSM prefix this env reads from (/<shared_vpc_name>/<aws_region>/...). Sourced from env.sh SHARED_VPC_NAME — no default on purpose so the value can never silently come from a terraform fallback."
}

# ── EC2 ───────────────────────────────────────────────────────────────────────
variable "ec2_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ec2_key_pair_name" {
  type        = string
  default     = ""
  description = "Leave empty to use SSM Session Manager (recommended)"
}

# ── Atlas ─────────────────────────────────────────────────────────────────────
variable "atlas_project_id" {
  type = string
}

variable "atlas_db_user" {
  type        = string
  description = "MongoDB Atlas database username. Caller (deploy.sh / terraform.tfvars) must supply a project+env-scoped value, e.g. <PROJECT_NAME>_<ENVIRONMENT>_user, so multiple deployments don't collide on a shared Atlas project."
}

variable "atlas_db_password" {
  type      = string
  sensitive = true
}

variable "atlas_db_name" {
  type        = string
  description = "MongoDB Atlas database name. Caller must supply a project+env-scoped value, e.g. <PROJECT_NAME>_<ENVIRONMENT> (underscored)."
}

# Voyage embedding output dimension. Default 1024 matches VOYAGE_DEFAULT_EMBEDDING_DIMS
# in api/src/adapters/voyage-embedding.ts (the SSOT). Terraform can't shell out to
# voyage-print.ts, so this default is pinned by the bun guard test
# `voyage SSOT — terraform <-> TS parity for embedding dim`. Deploy scripts
# derive this Terraform variable from VOYAGE_OUTPUT_DIM via voyage_embedding_dims.
# Only voyage-multimodal-3.5 supports non-1024 Matryoshka dims (256/512/1024/2048).
variable "voyage_output_dim" {
  type        = number
  default     = 1024
  description = "Voyage embedding output dimension passed to seed-indexes.ts (Atlas numDimensions). Derived from VOYAGE_OUTPUT_DIM by deploy scripts."
}

variable "mongodb_allow_write" {
  type        = bool
  description = "Allow the mongodb-mcp AgentCore Runtime to perform insertOne / updateOne. Default false — the handler is read-only unless this is explicitly flipped. Destructive ops (delete*, drop*, replaceOne, …) remain refused regardless."
  default     = false
}

variable "atlas_public_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "atlas_private_key" {
  type      = string
  sensitive = true
  default   = ""
}

# ── Bedrock KB ────────────────────────────────────────────────────────────────
variable "kb_iam_role_name" {
  type        = string
  default     = ""
  description = "Override for the Bedrock KB IAM role name. Leave empty (default) to auto-derive <project_name>-bedrock-kb-<environment>-role inside the bedrock-kb module so the role name is unique per (project, env) — required when running multiple deployments in the same AWS account."
}

variable "embed_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

variable "enable_kb_privatelink" {
  type        = bool
  description = <<-EOT
    PrivateLink KB ingestion (CLIENT_REVIEW P1-6, Option A): provision an NLB + VPC
    Endpoint Service so Bedrock Knowledge Base ingestion connects to MongoDB
    Atlas via AWS PrivateLink instead of the public SRV hostname.

    Default `true` — PrivateLink end-to-end is required for Atlas access,
    including KB ingestion. Setting this to `false` is an explicit, written
    non-default configuration (admin-only ingestion still avoids runtime PII, but
    leaves the path on public Atlas SRV) — do not flip without sign-off.

    When true, an instance of modules/bedrock-kb-privatelink is created and
    its endpoint_service_name is forwarded into module.bedrock_kb. Cost:
    fixed NLB (~$22/mo) plus per-LCU billing.

    Only effective when var.network_mode='privatelink'. Ignored in peering
    mode — switching connectivity modes requires destroy + redeploy.
  EOT
  default     = true
}

# ── Connectivity mode ─────────────────────────────────────────────────────────
variable "network_mode" {
  type        = string
  default     = "privatelink"
  description = "Connectivity mode for Atlas. Must match the value baked into the network stack (envs/network) and the SSM canary at /<shared_vpc_name>/<region>/network_mode. Switching modes requires destroy + redeploy. 'privatelink'/'peering' are MUTUALLY EXCLUSIVE private paths; 'public' (BYO-only) reaches Atlas over the public internet — see var.cluster_source and var.allow_public_atlas."

  validation {
    condition     = contains(["privatelink", "peering", "public"], var.network_mode)
    error_message = "network_mode must be 'privatelink', 'peering', or 'public'."
  }
}

# ── Bring Your Own (BYO) Atlas cluster ────────────────────────────────────────
variable "cluster_source" {
  type        = string
  default     = "managed"
  description = "'managed' (Terraform creates the Atlas cluster) or 'byo' (use a pre-existing operator cluster). network_mode='public' requires 'byo'."

  validation {
    condition     = contains(["managed", "byo"], var.cluster_source)
    error_message = "cluster_source must be 'managed' or 'byo'."
  }
}

variable "byo_connection_string" {
  type        = string
  default     = ""
  sensitive   = true
  description = "BYO only: operator-supplied connection string WITH credentials (mongodb+srv://...). Forwarded to module.mongodb_atlas as the connection_string output."
}

variable "byo_srv_host" {
  type        = string
  default     = ""
  description = "BYO only: operator cluster SRV hostname without scheme (cluster.xxxxx.mongodb.net)."
}

variable "byo_cluster_name" {
  type        = string
  default     = ""
  description = "BYO only: real Atlas cluster name for the Admin API (vector-index create). Case-sensitive; the SRV host can't recover it. Empty falls back to the managed synthetic '<project>-<env>' name."
}

variable "allow_public_atlas" {
  type        = bool
  default     = false
  description = "Must be true to permit network_mode='public'. Explicit acknowledgement that the MCP runtime reaches Atlas over the public internet (PUBLIC AgentCore networking) — a privacy/latency regression vs PrivateLink/peering. Demo only."
}

variable "allow_network_mode_mismatch_on_destroy" {
  type        = bool
  default     = false
  description = "Destroy-only escape hatch used by deploy/scripts/destroy.sh. Normal deploy/plan keeps the SSM network_mode canary strict; destroy can proceed through stale or partially torn-down network-mode metadata."
}

variable "atlas_peering_cidr" {
  type        = string
  default     = ""
  description = "Destroy-only fallback Atlas peering CIDR. Normal deploy reads this from envs/network SSM; destroy can pass it directly when SSM peering keys are absent during partial cleanup."
}

# WHY: envs/ec2 owns the Atlas cluster + its IP access list (via the
# mongodb-atlas module), so it must accept the operator IP and forward it down.
# deploy-project.sh auto-detects the value and writes it into terraform.tfvars;
# without this variable the per-project stack could not scope the allowlist and
# would fall back to opening Atlas to the internet.
variable "operator_ip_cidr" {
  type        = string
  default     = ""
  description = "Operator/deploy-machine public IP in CIDR /32 form. In network_mode='privatelink' this is the ONLY Atlas IP access list entry the mongodb-atlas module creates (replaces the former 0.0.0.0/0 open entry) so Atlas is reachable from the deploy machine but not the public internet. Auto-detected and written to terraform.tfvars by deploy-project.sh (override with OPERATOR_IP_CIDR / TF_VAR_my_ip in .env). Ignored in peering mode."

  validation {
    condition     = var.operator_ip_cidr == "" || can(cidrnetmask(var.operator_ip_cidr))
    error_message = "operator_ip_cidr must be empty or a valid IPv4 CIDR (e.g. 203.0.113.42/32)."
  }
}

variable "enable_kb_peering" {
  type        = bool
  default     = true
  description = <<-EOT
    When network_mode='peering', provision modules/bedrock-kb-peering
    (NLB-over-peering exposing Atlas IPs via SSM dig). Default true so peering
    mode keeps KB ingestion private end-to-end.

    EXPERIMENTAL — see modules/bedrock-kb-peering/README.md. If Bedrock's
    MongoDB driver rejects the TLS cert when reached through this path, the
    only remediation is to destroy the peering stack and redeploy in
    privatelink mode (no hybrid PL+peering coexistence — those modes are
    mutually exclusive per account).

    Set false to leave KB on public SRV (privacy regression vs the default).
    Ignored when network_mode='privatelink'.
  EOT
}

# Note: voyage_* variables live in envs/shared/variables.tf — the SageMaker
# endpoint is a shared singleton per (account, region, environment). Per-
# project stacks read the endpoint name + ARN from SSM (see local.shared_voyage_*).

# ── AgentCore ─────────────────────────────────────────────────────────────────
variable "specialist_agents" {
  type        = list(object({ id = string, runtime_name = string }))
  description = "Specialist AgentCore Runtimes to provision. Populated from config/agents/*.agent.md (excluding the orchestrator) by deploy.sh / deploy-agents.sh via agents.auto.tfvars.json. Adding a new entry creates a new runtime; removing one destroys it on next apply."
  default     = []

  validation {
    condition     = alltrue([for a in var.specialist_agents : can(regex("^[a-z0-9-]+$", a.id))])
    error_message = "Each specialist_agents[].id must be lowercase-kebab-case (matches config/agents/<id>.agent.md)."
  }
}

variable "agentcore_memory_expiry_days" {
  type    = number
  default = 30
}

variable "agentcore_runtime_deployment_mode" {
  type        = string
  description = "AgentCore runtime artifact mode: container or code"
  default     = "code"
}

variable "agentcore_code_artifact_prefix" {
  type        = string
  description = "S3 key for AgentCore direct-code deployment zip"
  default     = "artifacts/agentcore-runtime/deployment_package.zip"
}

variable "create_agentcore_runtime_vpc_endpoints" {
  type        = bool
  description = "Create ECR API, ECR Docker, CloudWatch Logs interface endpoints and the S3 gateway endpoint for VPC-mode AgentCore runtimes. Set false when the shared VPC already has these singleton endpoints."
  default     = true
}

variable "mongodb_mcp_image_digest" {
  type        = string
  description = <<-EOT
    SHA256 digest of the mongodb-mcp ECR image (e.g. "sha256:abc123…"). Fed
    into module.agentcore_gateway as the gateway-target trigger for cached
    tool schemas. `deploy-project.sh` Phase 4d captures the digest after
    `docker push` and forwards it via `-var` so a `terraform apply` re-runs
    the gateway-target null_resource whenever the MCP image changes. Empty
    on first deploys / when the helper is skipped (no-op trigger).
  EOT
  default     = ""
}

# Note: shared log retention variables live in envs/shared/variables.tf — the
# API/UI/MCP/AgentCore/OTel log groups are shared singletons.

# ── CloudWatch GenAI Observability ────────────────────────────────────────────
variable "enable_genai_observability" {
  type        = bool
  description = "Provision modules/cloudwatch-genai (Transaction Search + AgentCore vended log delivery). Defaults to true; set false to skip in stacks that share an account with another team's GenAI Observability config."
  default     = true
}

variable "span_retention_days" {
  type        = number
  description = "Retention for the aws/spans Transaction Search log group."
  default     = 14
}

variable "enable_transaction_search_toggle" {
  type        = bool
  description = "Run the X-Ray CLI calls that switch span destination to CloudWatch Logs and set the indexing sampling rate. Safe to leave true after the first apply — the null_resource is idempotent."
  default     = true
}

variable "span_sampling_percent" {
  type        = number
  description = "X-Ray Transaction Search indexing percentage (0-100). 100 = every span indexed (best for dev), 10 = sample 10% (typical prod). Underlying spans always land in /aws/spans either way."
  default     = 100

  validation {
    condition     = var.span_sampling_percent >= 0 && var.span_sampling_percent <= 100
    error_message = "span_sampling_percent must be between 0 and 100."
  }
}

variable "agentcore_vended_log_retention_days" {
  type        = number
  description = "Retention for AgentCore vended APPLICATION_LOGS log groups when enable_agentcore_vended_application_logs=true."
  default     = 7
}

variable "enable_agentcore_vended_application_logs" {
  type        = bool
  description = "Opt in to AgentCore service-vended APPLICATION_LOGS for Memory, Gateway, and Runtime resources. These logs include raw request_payload / response_payload bodies, so the privacy-safe default is false."
  default     = false
}

# Note: Bedrock invocation logging variables (enable_bedrock_invocation_logging,
# log_prompt_bodies, log_embedding_bodies, invocation_retention_days,
# data_protection_identifiers) live in envs/shared/variables.tf — Bedrock
# invocation logging is account-scoped, owned by the shared stack.

# ── ADOT Collector sidecar (Phase 2) ──────────────────────────────────────────
variable "enable_adot_collector" {
  type        = bool
  description = "Provision modules/adot-collector and install the sidecar systemd unit on EC2. When false the API and UI fall back to in-process OTel only (no /aws/spans / no GenAI Observability traces from the application). Default true."
  default     = true
}

variable "adot_collector_image" {
  type        = string
  description = "OCI image for the ADOT collector container. Default uses the public-ecr :latest tag; pin a digest in prod for repeatable builds."
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:latest"
}

variable "otel_sample_ratio" {
  type        = string
  description = "OTEL_TRACES_SAMPLER_ARG injected into the API container. 1.0 = sample everything (dev). 0.1 = 10% (typical prod)."
  default     = "1.0"
}

# ── MongoDB Atlas → CloudWatch metrics (Phase 4) ──────────────────────────────
variable "enable_atlas_metrics" {
  type        = bool
  description = "Phase 4 toggle. When true, provisions an Atlas Prometheus credentials secret and extends the ADOT collector config with a prometheus receiver + awsemf exporter pushing to the MongoDB/Atlas CloudWatch namespace. Default false."
  default     = false
}

variable "atlas_scrape_interval_sec" {
  type        = number
  description = "Atlas Prometheus scrape cadence. 60s is the recommended floor."
  default     = 60
}

variable "atlas_prom_username" {
  type        = string
  description = "Atlas Prometheus integration username (generated in Atlas UI → Project → Integrations → Prometheus). Stored in Secrets Manager when enable_atlas_metrics=true; unused otherwise."
  default     = ""
  sensitive   = true
}

variable "atlas_prom_password" {
  type        = string
  description = "Atlas Prometheus integration password."
  default     = ""
  sensitive   = true
}

variable "atlas_prom_host" {
  type        = string
  description = "Atlas Prometheus scrape host, e.g. <group-id>-prometheus.mongodb.com (from Atlas UI)."
  default     = ""
}

# Note: atlas_replication_lag_threshold_ms + fleet dashboards variables
# (enable_fleet_dashboards, p99_latency_threshold_ms, error_rate_threshold_pct,
# throttle_burst_threshold) live in envs/shared/variables.tf — the fleet,
# mongo, cost, and atlas dashboards are all shared singletons.
