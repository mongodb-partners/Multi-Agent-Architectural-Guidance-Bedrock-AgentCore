# IAM policy for `peerislands-terraform`

This directory holds a single consolidated IAM policy that grants the Terraform
deploy user (`peerislands-terraform`) everything it needs to **create and destroy**
the full multi-agent stack — no juggling 12+ AWS-managed policies.

## What's in `policy.json`

| SID | Effect | Covers |
|---|---|---|
| `NetworkingAndCompute` | Allow | EC2 (VPC, subnets, EIP, ENI, instances, SGs, endpoints), ELB, autoscaling, Route 53 (private zone for Atlas PrivateLink) |
| `ContainersAndServerless` | Allow | ECR (image push/pull), ECS (kept for flexibility), Lambda |
| `IamRolesAndPolicies` | Allow | **Scoped IAM** — only role, role-policy, customer-managed-policy, instance-profile, and service-linked-role lifecycle actions. No `iam:*` wildcard. |
| `IdentityAndSecrets` | Allow | STS identity lookups, Cognito user pools, Secrets Manager, KMS (read + encrypt only — no key create/schedule-deletion) |
| `StorageAndState` | Allow | S3 (state bucket + KB docs), DynamoDB (optional state lock table) |
| `BedrockAndAgentCore` | Allow | `bedrock:*` (covers Foundation Models, Bedrock Runtime, Bedrock Agent, Bedrock Agent Runtime, Bedrock Knowledge Base — all one IAM namespace) + `bedrock-agentcore:*` (Memory + Gateway, both control and data plane) |
| `SageMakerAndMarketplace` | Allow | SageMaker endpoints (Voyage AI) + Marketplace subscribe flows + License Manager reads |
| `ObservabilityAndDelivery` | Allow | CloudWatch Logs, CloudWatch metrics, EventBridge, Scheduler, CloudFront |
| `XRayObservability` | Allow | X-Ray trace ingestion, Transaction Search indexing rules, groups, sampling rules, resource policies |
| `ApplicationSignalsForTransactionSearch` | Allow | `application-signals:StartDiscovery` (called internally by `xray:UpdateTraceSegmentDestination` when switching destination to CloudWatch Logs — required to enable Transaction Search) |
| `SystemsManager` | Allow | SSM Session Manager, SSM send-command (deploy.sh uses this to push env + restart services on EC2 without SSH) |
| `PassRoleToAwsServices` | Allow | Conditional `iam:PassRole` so EC2/Lambda/Bedrock/AgentCore/SageMaker can assume their execution roles during provisioning. The `Condition.StringEquals.iam:PassedToService` allow-list means the principal cannot pass a role to any service outside this list (blocks cross-service role hijacking). |

## Why no `iam:*` wildcard

Management review flagged `iam:*` as too broad. The `IamRolesAndPolicies` SID lists **only** the 44 IAM actions Terraform actually calls during plan/apply/destroy, covering:

- **Roles** — create, delete, get, list, update, update-assume-role-policy, tag/untag, list-tags
- **Role policies (inline)** — put, delete, get, list
- **Role policies (managed attachments)** — attach, detach, list-attached
- **Customer-managed policies** — create, delete, get, list, versions (create/delete/get/list/set-default), tag/untag, list-entities-for-policy
- **Instance profiles** — create, delete, get, list, list-for-role, list-tags, add-role, remove-role, tag/untag
- **Service-linked roles** — create, delete, get-deletion-status (Bedrock AgentCore, SageMaker, autoscaling all auto-create SLRs)
- **Read-only helpers** — SimulatePrincipalPolicy (some providers call this during plan)

Identity-escalation actions (creating users, access keys, login profiles, groups, federation providers, etc.) are **not in the Allow list**, so they're implicitly denied. No explicit Deny block is needed.

## What this policy can NOT do (by design)

The following are not possible with this policy (not in the Allow list → implicit deny):

- Create or delete IAM users, groups, or access keys
- Attach policies to IAM users or groups (only to roles)
- Create or update login profiles / passwords
- Create, delete, or modify SAML or OIDC federation providers
- Change the account password policy or account alias
- Pass an IAM role to any service outside the allow-listed set (EC2, Lambda, Bedrock, AgentCore, SageMaker, etc.)
- Touch KMS key material lifecycle (`CreateKey`, `ScheduleKeyDeletion`, `DisableKey` are all implicitly denied — only encrypt/decrypt/describe are allowed)

## What's intentionally broad

This is a **POC** account. The policy uses service-level wildcards (`ec2:*`, `lambda:*`, etc.) because:

1. Terraform needs to both create and destroy — restricting to a subset almost always breaks teardown.
2. Narrow resource ARNs are impossible to predict up-front for resources that don't exist yet.
3. Root-account damage is prevented by the `PassRoleToAwsServices` allow-list (no arbitrary role assumption).

For a production account, replace each `service:*` with the explicit action list Terraform actually calls, scope `Resource: "*"` to ARN patterns, and add a `Condition` with `aws:RequestedRegion`.

## How to apply

**Option A — Attach as a customer-managed policy (recommended):**

```bash
aws iam create-policy \
  --policy-name PeerIslandsTerraformPoc \
  --policy-document file://deploy/iam/policy.json \
  --description "Full create+destroy permissions for the multi-agent POC stack"

aws iam attach-user-policy \
  --user-name peerislands-terraform \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/PeerIslandsTerraformPoc

# Then detach the 12 AWS-managed policies currently on the user (optional cleanup):
for p in AmazonEC2ContainerRegistryFullAccess AmazonCognitoPowerUser \
         CloudFrontFullAccess IAMFullAccess CloudWatchLogsFullAccess \
         SecretsManagerReadWrite AmazonECS_FullAccess \
         ElasticLoadBalancingFullAccess AmazonVPCFullAccess \
         AmazonS3FullAccess AmazonBedrockFullAccess AWSLambda_FullAccess; do
  aws iam detach-user-policy \
    --user-name peerislands-terraform \
    --policy-arn "arn:aws:iam::aws:policy/$p" 2>/dev/null
done
```

**Option B — Attach inline (no cleanup needed, but 2,048-char user inline limit applies — this policy is over that, so managed is safer):**

```bash
aws iam put-user-policy \
  --user-name peerislands-terraform \
  --policy-name PeerIslandsTerraformPoc \
  --policy-document file://deploy/iam/policy.json
```

## How to update

1. Edit `policy.json`.
2. Publish a new version (the managed policy keeps up to 5 versions, auto-prune the oldest):

```bash
POLICY_ARN="arn:aws:iam::<ACCOUNT_ID>:policy/PeerIslandsTerraformPoc"
aws iam create-policy-version \
  --policy-arn "$POLICY_ARN" \
  --policy-document file://deploy/iam/policy.json \
  --set-as-default
```

## Size check

AWS measures policy size **without whitespace** (quotes from the IAM quota page: "Maximum size of an IAM policy (without whitespace): 6,144 characters").

Run to check:

```bash
# Minified size (what AWS actually counts — whitespace stripped):
python3 -c "import json; d=json.load(open('deploy/iam/policy.json')); print(len(json.dumps(d)), 'chars (limit 6144)')"

# Raw file size (formatted, includes whitespace — higher than the AWS limit but that's fine):
wc -c deploy/iam/policy.json
```

## Iterative policy testing + resource tagging

Every AWS + Atlas resource created by this stack gets a single `Project` tag
(default value `multiagent-mongodb-framework`) so Finance can filter Cost
Explorer and you can enumerate/clean up after each policy-testing pass.

### The loop

```bash
# 1. attach current policy.json to peerislands-terraform (see "How to apply")
# 2. deploy
source .env && ./deploy/deploy-full-with-privatelink.sh --auto-approve

# 3. verify what was created (filters by Project tag)
./deploy/scripts/list-resources.sh

# 4. if a step failed with AccessDenied, read the exact action from the error,
#    add it to policy.json, publish a new version, and re-run deploy.sh.

# 5. tear down before the next iteration (scoped, idempotent)
./deploy/scripts/destroy.sh --mode ec2   # or --mode local
```

### Finance / billing

Activate the `Project` tag as a cost-allocation tag (one-time, account root
user required):

```
Billing → Cost Allocation Tags → User-defined → activate "Project"
```

Tags start showing in Cost Explorer ~24h after activation. Filter with
`Tag: Project = multiagent-mongodb-framework` to see POC spend only.

### What's tagged and how

| Layer | Mechanism |
|---|---|
| Every AWS resource created via the AWS Terraform provider | `default_tags` in `envs/{local,ec2}/main.tf` |
| AgentCore Memory + Gateway (no TF provider yet) | `--tags Project=...` passed into `aws bedrock-agentcore-control create-*` via `RESOURCE_TAGS` env var |
| Atlas cluster | `tags { key = "Project", value = … }` block on `mongodbatlas_cluster.main` |
| S3 bootstrap bucket (pre-state) | `default_tags` in `bootstrap/main.tf` |

To rename the tag value, set `PROJECT_NAME` in `.env` *before* the first
deploy. Renaming after resources exist requires either a re-tag pass (AWS
Tag Editor → Find resources → Edit tags) or a destroy + redeploy.
