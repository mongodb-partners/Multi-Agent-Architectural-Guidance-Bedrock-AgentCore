# Infrastructure Setup Guide

This document describes the AWS + MongoDB Atlas infrastructure required to run the multi-agent framework in production, and what the client must provide before Terraform can be applied.

**Design principles:**

- No custom domains — use default AWS-provided URLs (ALB DNS, Cognito prefix, CloudFront `*.cloudfront.net`)
- PrivateLink for MongoDB Atlas connectivity (no public internet)
- Bedrock Titan Embeddings directly (no SageMaker)
- Minimal resource count (~65–75 AWS resources + ~10 Atlas resources)

Cross-references: [`../ACTION_PLAN.md`](../ACTION_PLAN.md) · [`terraform/TODO.md`](terraform/TODO.md) · [`../docs/architecture.md`](../docs/architecture.md)

---

## What the Client Must Provide

Everything below must be in place **before** running `terraform apply`. These items cannot be created by Terraform — they require manual console steps, account creation, or client decisions.

### 1. AWS Account Access

| What we need | Who provides it | Notes |
|-------------|----------------|-------|
| **AWS Account ID** | Client | The target account where all resources will live |
| **AWS Region** | Client (confirm) | Must be **`us-east-1`** or **`us-west-2`** — only these support both Bedrock and AgentCore today |
| **IAM User or Role for Terraform** | Client's AWS admin | Needs permissions for: VPC, ECS, ECR, IAM, Cognito, S3, Bedrock, Lambda, CloudFront, Secrets Manager, CloudWatch. Either provide an IAM user with programmatic access or an assumable role ARN. |
| **AWS CLI credentials** | Client's AWS admin | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (or SSO profile / role assumption) configured locally for the person running Terraform |

### 2. Bedrock Model Access

These are **manual console clicks** — Terraform cannot enable model access.

| What we need | How the client does it |
|-------------|----------------------|
| **Enable Claude Sonnet** | AWS Console → [Bedrock → Model Access](https://console.aws.amazon.com/bedrock/home#/modelaccess) → Request access for `anthropic.claude-3-sonnet` → Wait for approval (usually instant) |
| **Enable Titan Embeddings V2** | Same page → Request access for `amazon.titan-embed-text-v2:0` |
| **Verify AgentCore** | AWS Console → Bedrock → AgentCore → Confirm Runtime, Gateway, and Memory are available in the chosen region |

### 3. MongoDB Atlas Account

| What we need | How the client does it |
|-------------|----------------------|
| **Atlas Organization** | Sign up or use existing at [cloud.mongodb.com](https://cloud.mongodb.com) |
| **Atlas Project** | Create a project inside the org (or use existing) |
| **Organization ID** | Atlas console → Organization Settings → copy the Org ID |
| **Project ID** | Atlas console → Project Settings → copy the Project ID |
| **Programmatic API Key** | Atlas console → Organization → Access Manager → API Keys → Create API Key with **Project Owner** role → save the `public_key` and `private_key` |
| **Cluster tier: M10+** | Client confirms budget for M10+ tier. **M0 (free) will not work** — PrivateLink and vector search indexes both require M10 or higher. |

### 4. Decisions We Need From the Client

| Decision | Options | Default if not specified |
|----------|---------|------------------------|
| **Environment name** | `dev`, `staging`, `production` | `dev` |
| **Project name prefix** | Used for all resource naming | `bedrock-multi-agent` |
| **Cognito password policy** | Min length, require uppercase/lowercase/numbers/symbols | 8 chars, require all |
| **Cognito MFA** | `OFF`, `OPTIONAL`, `ON` | `OPTIONAL` |
| **API auto-scaling range** | Min/max ECS tasks | Min 1, max 4 |
| **UI auto-scaling range** | Min/max ECS tasks | Min 1, max 2 |

### 5. Values to Collect Into `terraform.tfvars`

Once the client provides the above, create `deploy/terraform/terraform.tfvars` (gitignored — never committed):

```hcl
# AWS
aws_region   = "us-east-1"
project_name = "bedrock-multi-agent"
environment  = "dev"

# MongoDB Atlas
mongodb_atlas_org_id      = "<from step 3>"
mongodb_atlas_project_id  = "<from step 3>"
mongodb_atlas_public_key  = "<from step 3>"
mongodb_atlas_private_key = "<from step 3>"
```

---

## Client Handoff Checklist

> **Send this section to the client.** Every item must be completed before we can deploy infrastructure. Estimated client effort: 1–2 hours.

---

### A. AWS Account Setup

We will deploy all infrastructure (containers, networking, AI services, CDN) into your AWS account. We need the following:

```
[ ] A1. AWS Account ID: _______________
        The 12-digit account number. Find it at:
        AWS Console → top-right dropdown → "Account" → Account ID

[ ] A2. AWS Region (pick one): _______________
        Must be one of these two — they are the only regions that support
        both Amazon Bedrock (AI models) and AgentCore (agent runtime):
          • us-east-1 (N. Virginia)
          • us-west-2 (Oregon)

[ ] A3. IAM User or Role for Terraform
        We need programmatic access (access key + secret key, or an
        assumable IAM role ARN) to create and manage AWS resources.

        Required permissions (attach these AWS managed policies or equivalent):
          • AmazonVPCFullAccess
          • AmazonECS_FullAccess
          • AmazonEC2ContainerRegistryFullAccess
          • IAMFullAccess
          • AmazonCognitoPowerUser
          • AmazonS3FullAccess
          • AmazonBedrockFullAccess (or custom Bedrock + BedrockAgent policy)
          • AWSLambda_FullAccess
          • CloudFrontFullAccess
          • SecretsManagerReadWrite
          • CloudWatchLogsFullAccess
          • ElasticLoadBalancingFullAccess

        How to create:
        AWS Console → IAM → Users → Create User → Attach policies above →
        Create Access Key (use case: "Third-party service") → share securely.

        ⚠️  Do NOT send credentials via email or chat. Use a secrets manager,
        encrypted file, or your organization's secure credential sharing method.
```

### B. Amazon Bedrock Model Access

AI model access must be enabled manually in the AWS console — it cannot be automated. This is a one-time step per model.

```
[ ] B1. Enable Claude Sonnet (primary chat model)
        AWS Console → Amazon Bedrock → Model access → Request access →
        Check "Anthropic Claude 3 Sonnet" → Submit
        (Approval is usually instant)

[ ] B2. Enable Titan Embeddings V2 (vector embeddings for search)
        Same page → Check "Amazon Titan Text Embeddings V2" → Submit

[ ] B3. Verify AgentCore availability
        AWS Console → Amazon Bedrock → AgentCore →
        Confirm that Runtime, Gateway, and Memory features are listed.
        If AgentCore is not visible, it may not yet be available in your
        region — contact AWS support or switch to the other supported region.
```

### C. MongoDB Atlas Account

We use MongoDB Atlas as the database (document storage, vector search, long-term memory). PrivateLink ensures traffic between AWS and Atlas never crosses the public internet.

```
[ ] C1. MongoDB Atlas organization exists
        Sign up or use an existing org at https://cloud.mongodb.com

[ ] C2. MongoDB Atlas project created
        Inside the org, create a project for this deployment
        (e.g. "bedrock-multi-agent-dev")

[ ] C3. Atlas Organization ID: _______________
        Find at: Atlas Console → Organization Settings → General →
        "Organization ID" (24-character hex string)

[ ] C4. Atlas Project ID: _______________
        Find at: Atlas Console → Project Settings →
        "Project ID" (24-character hex string)

[ ] C5. Programmatic API Key created
        Atlas Console → Organization → Access Manager → API Keys →
        "Create API Key" → Description: "Terraform" →
        Organization Permissions: "Organization Owner" →
        Project Permissions: "Project Owner" →
        Save both values securely:
          Public Key:  _______________
          Private Key: (share securely — same rules as AWS credentials)

        ⚠️  This API key is used only by Terraform to provision Atlas
        resources. It is NOT stored in the application or deployed to AWS.

[ ] C6. Cluster tier approved: M10+ (required)
        PrivateLink and Vector Search indexes require M10 or higher.
        The free tier (M0) does NOT support either feature.

        Estimated monthly cost for M10 (3-node replica set):
          • M10 (general purpose): ~$57/month
          • M20 (more RAM/storage): ~$200/month
          • M30 (production workloads): ~$500/month
        Choose based on expected data volume and query load.

        Tier: _______________  (e.g. M10, M20, M30)
```

### D. Configuration Decisions

These are choices that affect how the system behaves. If unsure, the defaults work fine for an initial deployment — they can be changed later.

```
[ ] D1. Environment name: _______________
        Used for naming all resources (e.g. "dev", "staging", "production").
        Default: dev

[ ] D2. Project name prefix: _______________
        Used in all AWS resource names and tags
        (e.g. "bedrock-multi-agent" → creates "bedrock-multi-agent-dev-api").
        Default: bedrock-multi-agent

[ ] D3. Cognito MFA preference (pick one): _______________
        Controls whether users need multi-factor authentication to log in.
          • OFF       — password only (simplest, fine for internal/dev use)
          • OPTIONAL  — users can enable MFA but it's not required
          • ON        — all users must set up MFA (recommended for production)
        Default: OPTIONAL

[ ] D4. Cognito password policy: _______________
        Minimum password requirements for user accounts.
        Default: 8 characters, require uppercase + lowercase + numbers + symbols.
        If you want different rules, specify here.

[ ] D5. API auto-scaling (min/max ECS tasks): _______________
        How many copies of the API server can run simultaneously.
          • Min: lowest number always running (cost floor)
          • Max: highest number during traffic spikes (cost ceiling)
        Default: min 1, max 4

[ ] D6. UI auto-scaling (min/max ECS tasks): _______________
        Same as above but for the Streamlit chat UI.
        Default: min 1, max 2
```

### E. Handoff Summary

Once all items above are complete, share the following with us securely:

```
AWS Account ID:           _______________
AWS Region:               _______________
AWS Access Key ID:        (share securely)
AWS Secret Access Key:    (share securely)
Atlas Organization ID:    _______________
Atlas Project ID:         _______________
Atlas API Public Key:     _______________
Atlas API Private Key:    (share securely)
Atlas Cluster Tier:       _______________
Environment Name:         _______________
Project Name Prefix:      _______________
Cognito MFA:              _______________
```

We will use these values to populate `terraform.tfvars` and run the deployment. No client-side installation or terminal access is required — we handle everything from here.

---

## Terraform Modules

### Module Dependency Graph

```
                    Networking
                        │
          ┌─────────────┼─────────────────┐
          │             │                 │
          ▼             ▼                 ▼
    MongoDB Atlas    Cognito        S3 + Bedrock KB
          │             │                 │
          └──────┬──────┘                 │
                 │                        │
                 ▼                        │
              Lambda ◄────────────────────┘
                 │
                 ▼
             AgentCore
                 │
                 ▼
     ECS + ECR + ALB + Auto-Scaling
                 │
                 ▼
            CloudFront
```

All modules live under `deploy/terraform/modules/`. Apply order follows the dependency graph above.

---

### Module 1 — Networking

VPC, subnets, gateways, security groups, PrivateLink to Atlas, and VPC endpoints for AWS services.

| Resource | Purpose |
|----------|---------|
| `aws_vpc` | Single VPC (`10.0.0.0/16`), DNS hostnames + resolution enabled |
| `aws_subnet` × 2 public | ALB placement across 2 AZs |
| `aws_subnet` × 2 private | ECS tasks + Lambda across 2 AZs |
| `aws_internet_gateway` | Public internet access for ALB |
| `aws_nat_gateway` × 1 | Single NAT for private subnet outbound (cost-saving) |
| `aws_security_group` — ALB | Ingress 80/443 from CloudFront managed prefix list |
| `aws_security_group` — API ECS | Ingress from ALB SG only; egress 443 |
| `aws_security_group` — UI ECS | Ingress from ALB SG only; egress 443 |
| `aws_security_group` — Lambda | Egress to MongoDB PrivateLink + Bedrock endpoints |
| **Atlas PrivateLink** | `aws_vpc_endpoint` ↔ `mongodbatlas_privatelink_endpoint` |
| `aws_vpc_endpoint` — Bedrock | Interface type (ECS + Lambda invoke models without NAT) |
| `aws_vpc_endpoint` — Secrets Manager | Interface type |
| `aws_vpc_endpoint` — S3 | Gateway type (ECR layer pulls, KB docs) |
| `aws_vpc_endpoint` — ECR API + DKR | Interface type (private image pulls) |
| `aws_vpc_endpoint` — CloudWatch Logs | Interface type |

**Key outputs:** `vpc_id`, `private_subnet_ids`, `public_subnet_ids`, security group IDs, `mongodb_privatelink_endpoint_id`

---

### Module 2 — MongoDB Atlas

Cluster, database user, PrivateLink wiring, indexes, and secrets.

| Resource | Purpose |
|----------|---------|
| `mongodbatlas_cluster` | M10+, MongoDB 7.0, 3-node replica set |
| `mongodbatlas_database_user` | `readWrite` on the project+env-derived DB (e.g. `mongodb_multiagent_dev`) |
| `mongodbatlas_privatelink_endpoint` | Atlas-side PrivateLink service |
| `mongodbatlas_privatelink_endpoint_service` | Links to AWS VPC endpoint |
| `mongodbatlas_search_index` (vector) × 4 | `products`, `troubleshooting_docs`, `agent_memory_facts`, `chat_messages` — 1024 dims, cosine similarity |
| `mongodbatlas_search_index` (BM25 / Atlas Search) × 4 | Same four collections — text fields used by the hybrid retriever's lexical leg |
| Standard indexes | `orders` (orderId, customerId+createdAt, status), `agent_memory_facts` (userId+ts, unique `{userId, factHash}`, TTL on ts), `chat_messages` (`sessionId+timestamp`, unique `messageId`, `userId+ts`, TTL on ts), `chat_sessions` (sessionId, userId+lastMessageAt, TTL on expiresAt), `support_tickets` (ticketId, userId+createdAt, status) |
| `aws_secretsmanager_secret` | Atlas connection URI (PrivateLink hostname) + credentials |

**Key outputs:** `mongodb_connection_string_secret_arn`, `mongodb_db_name`

---

### Module 3 — Cognito

User pool with default Cognito domain (no custom domain, no ACM cert).

| Resource | Purpose |
|----------|---------|
| `aws_cognito_user_pool` | Basic password policy, email verification |
| `aws_cognito_user_pool_domain` | Default Cognito prefix (e.g. `bedrock-agents-dev`) |
| `aws_cognito_user_pool_client` | Streamlit app — OAuth code flow, callback = CloudFront URL |
| `aws_secretsmanager_secret` | Pool ID, client ID, JWKS URI, issuer URL |

**Key outputs:** `user_pool_id`, `app_client_id`, `jwks_uri`, `issuer`, `cognito_secret_arn`

---

### Module 4 — S3 + Bedrock Knowledge Base

Document bucket and managed RAG store using Titan Embeddings.

| Resource | Purpose |
|----------|---------|
| `aws_s3_bucket` | KB docs — versioned, SSE encrypted, all public access blocked |
| `aws_s3_bucket_lifecycle_configuration` | Expire old doc versions after 90 days |
| `aws_iam_role` | Bedrock KB service role (trust `bedrock.amazonaws.com`) → S3 `GetObject` |
| `aws_bedrockagent_knowledge_base` | Vector type, `amazon.titan-embed-text-v2:0` |
| `aws_bedrockagent_data_source` | S3 source for document ingestion |

**Key outputs:** `knowledge_base_id`, `kb_docs_bucket_name`, `kb_docs_bucket_arn`

---

### Module 5 — Lambda Base-Tool Adapters

Five Lambda functions — thin adapters wrapping the same logic as the in-process tools, deployed for AgentCore Gateway invocation.

| Function | Backend |
|----------|---------|
| `mongodb-query` | MongoDB Atlas structured query via PrivateLink |
| `mongodb-vector-search` | Atlas `$vectorSearch` via PrivateLink |
| `bedrock-kb-retrieve` | Bedrock KB `RetrieveCommand` |
| `generate-embedding` | Bedrock Titan `InvokeModelCommand` |
| `read-skill-resource` | S3 / config skill resource read |

**Per function:**

| Resource | Purpose |
|----------|---------|
| `aws_lambda_function` | Node.js 20, VPC-attached (private subnets), env from Secrets Manager |
| `aws_lambda_function_url` | Auth type `AWS_IAM` (invoked only by AgentCore Gateway role) |
| `aws_iam_role` | Execution: CloudWatch logs, Secrets Manager read, VPC ENI attach |
| `aws_cloudwatch_log_group` | 30-day retention |

MongoDB-touching functions get the Lambda security group with egress to PrivateLink. Bedrock-touching functions get egress to the Bedrock VPC endpoint.

**Key outputs:** `tool_function_arns` (map), `tool_function_urls` (map)

---

### Module 6 — AgentCore

Runtime, Gateway (with Lambda tool targets), Memory, and Cognito-linked authorization.

| Resource | Purpose |
|----------|---------|
| AgentCore Runtime | Wraps the API ECS task; agent execution environment |
| AgentCore Gateway | MCP endpoint URL for tool invocation |
| AgentCore Gateway Targets × 5 | One per Lambda function URL from Module 5 |
| AgentCore Memory | Durable session and memory namespace |
| OAuth Authorizer | Links Gateway auth to Cognito user pool |
| `aws_iam_role` | AgentCore execution: Bedrock model invoke, Secrets Manager, CloudWatch |
| IAM resource policy | Allow Gateway role to invoke Lambda function URLs |
| `aws_secretsmanager_secret` | Memory namespace, Gateway endpoint URL |

> **Provider note:** As of `hashicorp/aws >= 6.27`, all four `aws_bedrockagentcore_*` resources used here (`memory`, `gateway`, `gateway_target`, `agent_runtime`) plus the native `aws_bedrockagent_knowledge_base` + `aws_bedrockagent_data_source` ship with full `MONGO_DB_ATLAS` storage support, so no `null_resource` shims are needed. The two remaining `null_resource` blocks in `deploy/terraform/modules/bedrock-kb/` only trigger actions (start ingestion job, bootstrap MongoDB collection) for which no native resource exists.

**Key outputs:** `agentcore_runtime_arn`, `agentcore_gateway_url`, `agentcore_memory_arn`

---

### Module 7 — ECS + ECR + ALB + Auto-Scaling

Container registry, Fargate cluster, load balancer, services, and scaling policies.

#### ECR

| Resource | Purpose |
|----------|---------|
| `aws_ecr_repository` — API | `multi-agent-api`, image scan on push |
| `aws_ecr_repository` — UI | `multi-agent-streamlit`, image scan on push |

#### ECS Cluster

| Resource | Purpose |
|----------|---------|
| `aws_ecs_cluster` | Fargate, Container Insights enabled |

#### ALB

| Resource | Purpose |
|----------|---------|
| `aws_lb` | Internet-facing, HTTP listener on port 80 |
| `aws_lb_target_group` — API | Port 3000, health check `/health` |
| `aws_lb_target_group` — UI | Port 8501, health check `/_stcore/health` |
| `aws_lb_listener` | Port 80, path routing: `/api/*` → API, `/*` → UI |

#### API Service

| Resource | Purpose |
|----------|---------|
| `aws_ecs_task_definition` | Fargate, 512 CPU / 1024 MB, secrets injection, awslogs |
| `aws_ecs_service` | Desired count 2, circuit breaker + rollback |
| IAM task execution role | ECR pull, Secrets Manager read, CloudWatch logs |
| IAM task role | Bedrock invoke, AgentCore APIs, S3 read |

#### UI Service

| Resource | Purpose |
|----------|---------|
| `aws_ecs_task_definition` | Fargate, 256 CPU / 512 MB, Streamlit env vars |
| `aws_ecs_service` | Desired count 1 |

#### Auto-Scaling

| Resource | Purpose |
|----------|---------|
| `aws_appautoscaling_target` — API | Min 1, max 4 tasks |
| `aws_appautoscaling_policy` — API CPU | Scale out at CPU > 70% |
| `aws_appautoscaling_policy` — API requests | Scale on ALB RequestCountPerTarget |
| `aws_appautoscaling_target` — UI | Min 1, max 2 tasks |
| `aws_appautoscaling_policy` — UI CPU | Scale out at CPU > 70% |

#### Logs

| Resource | Purpose |
|----------|---------|
| `aws_cloudwatch_log_group` × 2 | `/ecs/api`, `/ecs/ui` — 30-day retention |

**Key outputs:** `alb_dns_name`, `api_ecr_repo_url`, `ui_ecr_repo_url`, `ecs_cluster_arn`

---

### Module 8 — CloudFront

CDN in front of ALB. Uses the default `*.cloudfront.net` domain — no custom domain or ACM certificate needed. Provides HTTPS out of the box.

| Resource | Purpose |
|----------|---------|
| `aws_cloudfront_distribution` | Single origin → ALB DNS |
| Cache behavior — `/api/*` | **Caching disabled**, all headers forwarded, WebSocket/SSE pass-through |
| Cache behavior — `/*` (default) | UI path — cache static assets (CSS/JS/images), TTL 300s, gzip/brotli compression |
| Cache policy — API | AWS managed `CachingDisabled` |
| Cache policy — UI | AWS managed `CachingOptimized` |
| Origin request policy — API | `AllViewer` (pass Authorization header for auth) |

**Key outputs:** `cloudfront_domain_name`, `cloudfront_distribution_id`

---

## ECS Environment Variables

Wired from module outputs → Secrets Manager → ECS task definition `secrets` / `environment` blocks.

### API Container

| Variable | Value / Source |
|----------|---------------|
| `AGENTCORE_ORCHESTRATOR_ARN` | AgentCore Runtime module output (asserted at API startup) |
| `AGENTCORE_GATEWAY_URL` | AgentCore Gateway module output |
| `MONGODB_URI` | Secrets Manager ← Atlas module |
| `MONGODB_DB` | `<project>_<env>` (e.g. `mongodb_multiagent_dev`); project+env-derived (underscored) by `.env` |
| `MONGODB_ALLOW_WRITE` | `true` |
| `PERSIST_CHAT_SESSIONS` | `1` |
| `AUTH_JWKS_URI` | Cognito module output (**required** — `assertJwksAuthConfigured()` boot guard) |
| `AUTH_ISSUER` | Cognito module output |
| `AUTH_APP_CLIENT_ID` | Cognito module output |
| `BEDROCK_KB_ID` | Bedrock KB module output |
| `EMBEDDING_MODEL_ID` | `amazon.titan-embed-text-v2:0` |
| `AWS_REGION` | Terraform variable |
| `AGENTCORE_MEMORY_ID` | AgentCore module output |
| `LOG_LEVEL` | `info` |

### UI Container

| Variable | Value / Source |
|----------|---------------|
| `STREAMLIT_API_URL` | ALB internal URL (service discovery or `http://localhost:3000`) |
| `STREAMLIT_COGNITO_POOL_ID` | Cognito module output |
| `STREAMLIT_COGNITO_CLIENT_ID` | Cognito module output |
| `STREAMLIT_COGNITO_DOMAIN` | Cognito module output (default prefix) |
| `STREAMLIT_COGNITO_REDIRECT_URI` | CloudFront URL (`https://<id>.cloudfront.net`) |

---

## What Is NOT Included

These items are intentionally excluded to keep the setup minimal:

| Item | Reason |
|------|--------|
| Custom domain / Route53 / ACM | Not needed — ALB, Cognito, and CloudFront use default AWS URLs |
| SageMaker embedding endpoint | Using Bedrock Titan Embeddings directly — zero extra infra |
| CloudWatch dashboards / alarms / SNS | Nice-to-have for production hardening, not essential to run |
| Remote Terraform state (S3 + DynamoDB) | Can use local state initially; add when team collaboration requires it |
| CI/CD Terraform pipeline | Build separately once infra is stable; manual `terraform apply` is fine to start |
| Multiple NAT Gateways | Single NAT is sufficient; add per-AZ NAT for HA later |

---

## Apply Sequence

```bash
cd deploy/terraform

# 1. Initialize providers (AWS + MongoDB Atlas)
terraform init

# 2. Review the plan
terraform plan -var-file=terraform.tfvars

# 3. Apply
terraform apply -var-file=terraform.tfvars

# 4. After apply — build and push container images
export AWS_ACCOUNT_ID=$(terraform output -raw aws_account_id)
export AWS_REGION=$(terraform output -raw aws_region)
cd ../..
./deploy/scripts/docker-build.sh
./deploy/scripts/docker-push-ecr.sh

# 5. Force ECS to pick up the new images
aws ecs update-service --cluster $(terraform output -raw ecs_cluster_name) \
  --service $(terraform output -raw api_service_name) --force-new-deployment
aws ecs update-service --cluster $(terraform output -raw ecs_cluster_name) \
  --service $(terraform output -raw ui_service_name) --force-new-deployment

# 6. Verify
curl https://$(terraform output -raw cloudfront_domain_name)/api/health
```

---

## Post-Apply Steps

1. **Upload KB documents** to the S3 bucket output by Module 4, then trigger a Bedrock KB sync:
   ```bash
   aws s3 cp docs/kb/ s3://$(terraform output -raw kb_docs_bucket_name)/ --recursive
   aws bedrock-agent start-ingestion-job --knowledge-base-id $(terraform output -raw knowledge_base_id) \
     --data-source-id $(terraform output -raw kb_data_source_id)
   ```

2. **Seed MongoDB** with initial data (orders, products, troubleshooting docs):
   ```bash
   cd db-seeding
   export MONGODB_URI=$(aws secretsmanager get-secret-value \
     --secret-id $(terraform output -raw mongodb_secret_arn) --query SecretString --output text)
   bun run seed
   ```

3. **Create initial Cognito user** via the console or CLI:
   ```bash
   aws cognito-idp admin-create-user \
     --user-pool-id $(terraform output -raw cognito_user_pool_id) \
     --username testuser --temporary-password 'TempPass1!'
   ```

4. **Verify end-to-end:** Open `https://<cloudfront-domain>/` → Cognito login → chat with an agent.
