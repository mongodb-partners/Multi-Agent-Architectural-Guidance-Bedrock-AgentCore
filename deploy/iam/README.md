# IAM artefacts for the Terraform deploy principal

This directory holds the two IAM JSON documents the deploy principal needs:

| File | Type | Answers | Attached to |
|---|---|---|---|
| [`policy.json`](policy.json) | **Identity / permissions policy** | "What can this principal do once authenticated?" | The IAM user / role as a managed or inline policy |
| [`sts-trust-policy.json`](sts-trust-policy.json) | **Trust policy** (`AssumeRolePolicyDocument`) | "Who is allowed to assume this role via STS?" | An IAM Role's trust relationship (role-only, not used by IAM users) |

The two are **not interchangeable** — `policy.json` has no `Principal` field and no `sts:AssumeRole` action; it cannot serve as a trust policy. `sts-trust-policy.json` only grants `sts:AssumeRole` / `sts:AssumeRoleWithWebIdentity` to specified principals; it grants no service permissions on its own.

**Pick a mode:**

- **IAM user (static long-lived keys)** → attach `policy.json` only. No trust policy applies.
- **IAM Role assumed via STS** (required when the account prohibits IAM users) → create the role with `sts-trust-policy.json` as its trust relationship **and** attach `policy.json` as a permissions policy. See [§ STS-assumed role setup](#sts-assumed-role-setup) below.

## What's in `policy.json`

| SID | Effect | Covers |
|---|---|---|
| `NetworkingAndCompute` | Allow | EC2 (VPC, subnets, EIP, ENI, instances, SGs, endpoints), ELB, autoscaling, Route 53 (private zone for Atlas PrivateLink) |
| `ContainersAndServerless` | Allow | ECR (image push/pull), ECS (kept for flexibility), Lambda |
| `IamRolesAndPolicies` | Allow | **Scoped IAM** — only role, role-policy, customer-managed-policy, instance-profile, and service-linked-role lifecycle actions. No `iam:*` wildcard. |
| `IdentityAndSecrets` | Allow | STS identity lookups, Cognito user pools, Secrets Manager, KMS (read + encrypt only — no key create/schedule-deletion) |
| `StorageAndState` | Allow | S3 (state bucket + KB docs), DynamoDB (optional state lock table) |
| `BedrockAndAgentCore` | Allow | `bedrock:*` (foundation models, Runtime, Knowledge Base / data-source / ingestion — IAM prefix `bedrock:` even though CLI is `aws bedrock-agent`) **plus** `bedrock-agentcore:*` (Memory, Gateway, Agent Runtime — separate namespace; required for `bedrock-agentcore:GetGateway`). `bedrock:*` alone does not grant AgentCore. |
| `BedrockKnowledgeBaseRetrieve` | Allow | `bedrock:Retrieve` + `bedrock-agent-runtime:Retrieve` — explicit KB query path used by `bedrock_kb_retrieve` and `GET /health` (`bedrockKnowledgeBase`). The EC2 app role also needs these via `modules/ec2` `BedrockKBRetrieve`; updating only this deploy principal policy does not change the running instance role until Terraform apply or a manual inline-policy edit on `*-ec2-role-*`. |
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

## STS-assumed role setup

Use this path when the account policy prohibits IAM users (e.g. enterprise SSO / federated identity / cross-account assume-role).

### 1. Pick the trust statements that apply to you

`sts-trust-policy.json` ships with four SIDs covering the common patterns. **Delete the ones that do not apply** before creating the role — IAM trust policies have a 2,048-character limit and unused principals expand the role's attack surface:

| SID | Use when | Placeholder(s) to fill |
|---|---|---|
| `AllowSameAccountIamPrincipalsWithMfa` | Any IAM principal in the same account can assume the role, provided MFA is present in the session and ≤ 12h old. Good general fallback. | `ACCOUNT_ID` |
| `AllowAwsIdentityCenterSsoUsers` | The deploy is run by a user signed in through AWS IAM Identity Center (formerly AWS SSO) with a specific permission set. | `ACCOUNT_ID`, `PERMISSION_SET_NAME` |
| `AllowCrossAccountTrustedPrincipal` | The deploy is run from a role in a different AWS account (e.g. a central tooling account assuming into the UAT workload account). The `sts:ExternalId` condition prevents the confused-deputy attack and must be a high-entropy value the trusted caller will pass on every `AssumeRole`. | `TRUSTED_ACCOUNT_ID`, `TRUSTED_ROLE_NAME`, `REPLACE_WITH_GENERATED_EXTERNAL_ID` (use `aws secretsmanager get-random-password --password-length 32 --no-include-space` or `openssl rand -hex 16`) |
| `AllowGitHubActionsOidcFederation` | The deploy is run from GitHub Actions via OIDC federation. Requires the GitHub OIDC provider to already exist in the account. | `ACCOUNT_ID`, `GITHUB_ORG`, `GITHUB_REPO` (and adjust the `sub` claim glob if you deploy from non-`main` branches or tags) |

### 2. Create the role with both documents

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="PeerIslandsTerraformDeploy"

# Replace ACCOUNT_ID / SSO permission-set / external ID placeholders first.
sed -i.bak "s/ACCOUNT_ID/${ACCOUNT_ID}/g" deploy/iam/sts-trust-policy.json
# Manually edit the remaining placeholders (PERMISSION_SET_NAME, TRUSTED_ACCOUNT_ID, ...).

# Create the role with the trust policy.
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://deploy/iam/sts-trust-policy.json \
  --max-session-duration 14400 \
  --description "Terraform deploy role for the multi-agent stack (STS-assumed)"

# Create the permissions policy (or reuse if already published).
POLICY_ARN=$(aws iam create-policy \
  --policy-name "${ROLE_NAME}Permissions" \
  --policy-document file://deploy/iam/policy.json \
  --query 'Policy.Arn' --output text)

# Attach the permissions policy to the role.
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN"
```

`--max-session-duration 14400` requests a 4-hour ceiling on `AssumeRole` sessions (default is 1h). The deploy's longest single phase is `terraform apply` at ~20-25 min — 4 hours is a safe headroom for end-to-end runs without re-authenticating mid-deploy. Raise to `43200` (12 h) if the account permits.

### 3. Assume the role from the deploying shell

Three equivalent ways, pick whichever fits your tooling — all are accepted transparently by the deploy scripts:

```bash
# (a) Raw STS assume-role → export env vars
CREDS=$(aws sts assume-role \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
  --role-session-name "multiagent-uat-$(date +%s)" \
  --duration-seconds 14400 \
  --output json)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS"     | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$CREDS"     | jq -r '.Credentials.SessionToken')

# (b) Named profile in ~/.aws/config with source_profile + role_arn
#     [profile uat-deploy]
#       role_arn       = arn:aws:iam::<ACCOUNT_ID>:role/PeerIslandsTerraformDeploy
#       source_profile = my-sso-profile
#       duration_seconds = 14400
export AWS_PROFILE=uat-deploy

# (c) AWS IAM Identity Center (SSO) — exchange OIDC token for STS session
aws sso login --profile uat-deploy
export AWS_PROFILE=uat-deploy
```

After any of the three, set `AUTH_MODE=sts` in your `.env` so the deploy scripts validate the assumed-role caller shape (the shared validator at [`../scripts/_aws-auth.sh`](../scripts/_aws-auth.sh) refuses to proceed if the resolved ARN isn't an `assumed-role`). Then confirm and run:

```bash
aws sts get-caller-identity   # must show the assumed-role ARN, not the source identity
source .env
./deploy/deploy-full-with-privatelink.sh --auto-approve
```

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
#    add it to policy.json, publish a new policy version on the IAM user/role,
#    and re-run deploy. Customer-managed policies are capped at 6,144 characters
#    (whitespace excluded) — do not duplicate wildcard grants with long explicit
#    action lists in policy.json or the console rejects the upload.
#
#    Common peering-deploy miss: bedrock-agentcore:GetGateway — means the principal
#    has bedrock:* but NOT bedrock-agentcore:* yet. Ensure BedrockAndAgentCore
#    includes both wildcards and set that policy version as default.

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
