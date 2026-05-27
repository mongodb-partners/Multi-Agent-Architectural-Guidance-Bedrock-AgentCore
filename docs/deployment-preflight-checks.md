# Deployment Preflight Checks

This document is the authoritative reference for the deployment preflight system implemented in [`deploy/scripts/_preflight-checks.sh`](../deploy/scripts/_preflight-checks.sh). It catalogs every check that runs before, during, and immediately after a deploy; explains how to interpret a failure; and describes the override knobs supported by every deploy script.

> **Scope.** Preflight does **not** replace the inline guards already present in the deploy scripts. It runs *in addition*, before AWS state is mutated, and exits early with one consolidated, structured failure summary.

---

## TL;DR

```bash
# Normal deploy — preflight runs automatically:
./deploy/deploy-full-with-privatelink.sh --auto-approve

# List checks for a profile without running them:
PREFLIGHT_DRY_RUN=1 bash -c 'source deploy/scripts/_preflight-checks.sh && preflight_validate orchestrator-privatelink'

# Skip a single check by id (after reading the failure envelope):
PREFLIGHT_SKIP=pf_check_atlas_api_health ./deploy/deploy-full-with-privatelink.sh

# Skip everything (audit-logged):
PREFLIGHT_SKIP='*' ./deploy/deploy-full-with-privatelink.sh

# Self-test the module (works on bash 3.2+):
bash deploy/scripts/_preflight-checks.sh --self-test

# Show available profiles:
bash deploy/scripts/_preflight-checks.sh --list-profiles
```

---

## How a failure looks

Every failing check emits a structured envelope:

```
[preflight] ✗ pf_check_atlas_api_key_scope: Atlas API returned 403 (key has wrong role)
  shortcoming  : config
  observed     : GET /groups/<projectId> → 403
  fix:
    1. Atlas → Project Access → Edit API key → role = 'Project Owner'
       (or at least 'Project Cluster Manager' + 'Project Stream Processing Owner')
  ai-fix-hint  : console:https://cloud.mongodb.com/v2/<projectId>#/access
  doc          : docs/deployment-preflight-checks.md#atlas-api-key-scope
```

- **summary** — one-sentence what's wrong.
- **shortcoming** — coarse class (`config` / `external` / `ordering` / `state` / `new-user friction`).
- **observed** — the literal evidence (HTTP code, env var name, file path, …).
- **fix** — plain-English steps a human can follow with no extra context.
- **ai-fix-hint** — closed-vocabulary token for AI editor agents (Cursor, Claude, etc.) to act on. Verbs: `edit:` / `run:` / `console:` / `doc:` / `iam:` / `tfvar:`.
- **doc** — anchor in this file with a deeper write-up.

Failures are **batched**: every check runs to completion and the full list is printed before the script exits. Re-run after fixing all of them, or pass `PREFLIGHT_SKIP=<id>,<id>` to bypass a subset.

---

## Override knobs

| Variable | Effect |
|----------|--------|
| `PREFLIGHT_QUIET=1` (default) | Per-check successes collapse to a single `✓ <id>` line. |
| `PREFLIGHT_VERBOSE=1` | Same as `PREFLIGHT_QUIET=0` — show every check's full message. |
| `PREFLIGHT_SKIP=<id>,<id>` | Skip the named checks. Tracked in the run's audit banner. |
| `PREFLIGHT_SKIP='*'` | Skip everything. Logs a prominent warning naming the operator. |
| `PREFLIGHT_JSON=1` | Emit a single JSON line on stdout instead of the human summary. |
| `PREFLIGHT_DRY_RUN=1` | Print the list of checks for the profile and exit `0`. |
| `PREFLIGHT_NO_COST_PREVIEW=1` | Silence the `pf_advise_cost_and_duration` advisory. |
| `PREFLIGHT_FORCE_LOCK_BREAK=1` | One-shot break of the S3 deploy lock owned by `pf_check_concurrent_deploy_lock`. |
| `PREFLIGHT_DEBUG=1` | Emit `[preflight:dbg]` lines for module-internal flow tracing. |

Exit codes (BSD `sysexits.h`-inspired):

| Code | Meaning |
|------|---------|
| `0`  | All checks passed (or all skipped via `PREFLIGHT_SKIP=*`). |
| `78` | `EX_CONFIG` — actionable configuration / state failures. |
| `73` | `EX_CANTCREAT` — environment / external failure (network egress, Atlas API down). |
| `75` | `EX_TEMPFAIL` — missing prereq tool (terraform/bun/aws/docker etc. not installed or below floor). |
| `2`  | Usage error (unknown profile, missing argument). |

---

## Profiles

Each deploy script invokes `preflight_validate <profile>`. Profiles are defined in the canonical arrays in `_preflight-checks.sh` (search for `PREFLIGHT_PROFILE_*`).

| Profile | Caller | Stage |
|---------|--------|-------|
| `orchestrator-privatelink`  | [`deploy/deploy-full-with-privatelink.sh`](../deploy/deploy-full-with-privatelink.sh) | Before phase 1 (network) |
| `orchestrator-peering`      | [`deploy/deploy-full-with-vpc-peering.sh`](../deploy/deploy-full-with-vpc-peering.sh) | Before phase 1 |
| `network`                   | [`deploy/scripts/deploy-network.sh`](../deploy/scripts/deploy-network.sh) | After AWS auth |
| `shared`                    | [`deploy/scripts/deploy-shared.sh`](../deploy/scripts/deploy-shared.sh) | After AWS auth |
| `shared-post-apply`         | [`deploy/scripts/deploy-shared.sh`](../deploy/scripts/deploy-shared.sh) | After `terraform apply` + SSM canary verification, before the summary. Voyage-only — auto-skips when `EMBEDDINGS_PROVIDER != voyage`. |
| `project-pre-apply`         | [`deploy/scripts/deploy-project.sh`](../deploy/scripts/deploy-project.sh) | After AWS auth, before terraform apply |
| `project-post-apply`        | [`deploy/scripts/deploy-project.sh`](../deploy/scripts/deploy-project.sh) | After `seed-indexes` + embedding seed, before MongoDB URI normalization |
| `project-pre-env-sync`      | [`deploy/scripts/deploy-project.sh`](../deploy/scripts/deploy-project.sh) | After Phase 6b runtime env sync + Phase 7 `.env.live` write; before SSM copy to EC2. Includes `mcp-runtime-env-complete`. |
| `local-post-apply`          | [`deploy/scripts/deploy-local.sh`](../deploy/scripts/deploy-local.sh) | After seed-all + seed-indexes + embedding seed. **Intentionally omits** `pf_check_shell_runtime_safe` (orchestrator-only), `pf_check_privatelink_endpoint_available` and `pf_check_mcp_runtime_env_complete` (no PrivateLink endpoint / AgentCore runtimes in the local path). |
| `agents`                    | [`deploy/deploy-agents.sh`](../deploy/deploy-agents.sh) | After AWS auth |
| `api`                       | [`deploy/deploy-api.sh`](../deploy/deploy-api.sh) | After AWS auth |
| `ui`                        | [`deploy/deploy-ui.sh`](../deploy/deploy-ui.sh) | After AWS auth |

Run `bash deploy/scripts/_preflight-checks.sh --list-profiles` for the live list.

---

## Check catalog

Each check below corresponds to a `pf_check_*` (or `pf_advise_*`) function. The function is the source of truth: the comments inside `_preflight-checks.sh` carry `pf:check:` and `pf:catches:` markers documenting what each one defends against.

### New-user friction

#### env-file-setup
**Function:** `pf_check_env_file_present_and_sourceable`
**Catches:** `.env` missing, malformed (CRLF / unclosed quote / spaces around `=`), world-readable.
**Fix:** `cp .env.sample .env && chmod 600 .env`, then fill in real values.

#### env-required-keys
**Function:** `pf_check_env_required_keys_filled`
**Catches:** `.env` copied from sample with placeholder values (`...`, `your-`, `<...>`, `changeme`) still in.
**Fix:** Open `.env` and replace every flagged key with a real value. The check covers AWS keys (skips static keys when `AUTH_MODE=sts`), MongoDB Atlas API keys, `PROJECT_NAME`, `ENVIRONMENT`, `SHARED_VPC_NAME`, `EMBEDDINGS_PROVIDER`, and (when `EMBEDDINGS_PROVIDER=voyage`) `VOYAGE_MODEL_PACKAGE_ARN`.

#### naming-constraints
**Function:** `pf_check_resource_name_constraints`
**Catches:** A `PROJECT_NAME` / `ENVIRONMENT` combination that produces an AWS resource name exceeding a hard service limit (IAM role 64, S3 bucket 63, NLB 32, …) — caught **before** Terraform fails halfway through phase 4.
**Hard max:** `PROJECT_NAME ≤ (47 − len(ENVIRONMENT))` chars. **Recommended:** `≤ (39 − len(ENVIRONMENT))` chars to leave headroom for new resources.
**Format rules:** `PROJECT_NAME` and `SHARED_VPC_NAME` must be lowercase alphanumeric + single hyphens, start with a letter, no leading/trailing hyphen (S3-bucket compliance). `ENVIRONMENT` must be lowercase alphanumeric (no hyphens), and is recommended ≤ 8 chars. Repo default `multiagent-mongodb-framework` (28 chars) is comfortably inside the recommended range.

#### aws-region-consistency
**Function:** `pf_check_env_aws_region_consistency`
**Catches:** `.env AWS_REGION` ≠ `AWS_DEFAULT_REGION` ≠ AWS profile region (a classic source of "why is my resource in `us-east-2`?" tickets).
**Fix:** Set `export AWS_DEFAULT_REGION="$AWS_REGION"` in `.env` (the existing `.env.sample` already does this).

#### clock-skew
**Function:** `pf_check_clock_skew`
**Catches:** Local clock drifts > 5 min from `sts.amazonaws.com` `Date:` header. AWS rejects requests with a `SignatureDoesNotMatch` / `RequestExpired` error that **looks** like an auth bug.
**Fix (macOS):** System Settings → General → Date & Time → Set automatically.
**Fix (Linux):** `sudo timedatectl set-ntp true`.

#### session-manager-plugin
**Function:** `pf_check_session_manager_plugin`
**Catches:** `session-manager-plugin` not on PATH — every post-deploy `aws ssm start-session` will fail.
**Fix (macOS):** `brew install --cask session-manager-plugin`.
**Fix (Linux):** Download the matching `.deb` / `.rpm` from `s3.amazonaws.com/session-manager-downloads/...`.

#### docker-cross-platforms
**Function:** `pf_check_docker_cross_platforms`
**Catches:** Docker cannot run cross-platform images (QEMU/binfmt not registered) — `linux/arm64` (AgentCore Runtime) and `linux/amd64` builds invoked from the deploy scripts will fail opaquely mid-deploy with an "exec format error". The check runs `docker run --rm --platform linux/{amd64,arm64} alpine:3 true` and reports which platforms failed alongside the Docker binary path, version, and context.
**Fix (Docker Desktop):** Settings → General → enable **Use Rosetta for x86_64/amd64 emulation**, then restart Docker Desktop. On Apple Silicon this also covers `linux/amd64`; ARM64 is native.
**Fix (Linux / colima):** Register QEMU binfmt handlers once per boot via `docker run --privileged --rm tonistiigi/binfmt --install all`.
**Fix (GitHub Actions / CI):** Add `uses: docker/setup-qemu-action@v3` before the deploy step (already wired into `.github/workflows/deploy.yml`).

#### local-prerequisites
**Function:** `pf_check_disk_and_docker_resources`
**Catches:** < 10 GB free on `/`, or Docker daemon running with < 4 GB memory (multi-platform builds OOM).
**Fix:** Free disk; raise Docker Desktop's memory in Settings → Resources.

#### aws-service-limits
**Function:** `pf_check_aws_service_limits`
**Catches:** Account-level service quotas at floor (VPC 5/region default, Elastic IP 5/region default). Does **not** cover SageMaker — see [`sagemaker-endpoint-quota`](#sagemaker-endpoint-quota) for the Voyage GPU endpoint quota check.
**Fix:** Request a quota increase via Service Quotas console.

#### shell-runtime-safe
**Function:** `pf_check_shell_runtime_safe`
**Profiles:** `orchestrator-privatelink`, `orchestrator-peering` (inherited), `shared`.
**Catches:** Regression of the `cmd | head -1` / SIGPIPE class of bug that previously killed `deploy-shared.sh` with `rc=141` halfway through preflight, leaving the operator with only `[full-deploy:diag] ERROR rc=141 line=… command=bash …deploy-shared.sh` and no actionable failure envelope. Root cause was `pf_check_tool_versions` parsing `terraform version | head -1 | awk … | tr -d v` inside command substitution: terraform ≥ 1.6 emits 3+ lines, `head -1` exits early, terraform receives SIGPIPE on its second write, `set -o pipefail` propagates 141, and `set -e` in `deploy-shared.sh` exits the script.

**Two-prong fix is now in place:**

1. **`pf_check_tool_versions` uses SIGPIPE-safe helpers** (`_pf_capture_first_line` / `_pf_capture_first_line_2`) that capture the producer's full stdout into a shell variable, then extract the first line via `${var%%$'\n'*}` parameter expansion. No early-exiting downstream reader exists, so the producer never receives SIGPIPE.
2. **`preflight_validate` invokes each check via `if ! "$id"; then …`** — a form that POSIX/bash treat as exempt from `set -e`. A check that returns non-zero (SIGPIPE, accidental rc, or otherwise) is therefore captured by the runner and recorded as a `module bug (rc=N)` _pf_fail entry instead of killing the deploy script.

**What this check verifies at runtime:**

- Captures `BASH_VERSION` for support tickets (warns on bash 3.2 as a future-proofing nudge — module remains compatible).
- Confirms the platform raises SIGPIPE on a synthetic `yes | head -1` pipeline (purely informational; some sandboxes suppress SIGPIPE).
- Drives a synthetic check that returns rc=141 and asserts the runner deflected it (regression test for prong 2 — locked down by self-test 13).

**Skipped when:** never.
**Fix on failure:** the failure envelope walks you through re-sourcing `_preflight-checks.sh` (in case a downstream wrapper monkey-patched `preflight_validate`) and falling back to `/bin/bash` explicitly if the operator is on a non-bash shell. The self-test (`bash deploy/scripts/_preflight-checks.sh --self-test`) covers both fix prongs and will catch any regression in CI before deploy.

#### deploy preview (`pf_advise_cost_and_duration`)
Advisory only — never fails. Prints expected resources, ~$240–320/month estimate, ~25–40 min build time, and the teardown command. Silence with `PREFLIGHT_NO_COST_PREVIEW=1`.

### Tools / network / API health

#### tool-versions
**Function:** `pf_check_tool_versions`
**Catches:** `terraform < 1.6`, `bun < 1.1`, `aws-cli < 2.15`, `python3 < 3.10`, `docker < 24`, `jq < 1.6` (advisory), or any of them missing entirely.
**Fix:** Upgrade per the version printed; see [`docs/deployment-guide.md`](deployment-guide.md#prerequisites).

#### aws-cli-agentcore-gateway-model
**Function:** `pf_check_aws_cli_agentcore_gateway_model`
**Catches:** AWS CLI installed and on PATH, but its bundled `botocore` service model for `bedrock-agentcore-control` is too old to know the AgentCore Gateway MCP target shape used by [`deploy/terraform/modules/agentcore-gateway/main.tf`](../deploy/terraform/modules/agentcore-gateway/main.tf). The Terraform `null_resource` calls `aws bedrock-agentcore-control create-gateway-target` with `targetConfiguration.mcp.mcpServer` and `credentialProviderConfigurations[].credentialProvider.iamCredentialProvider`; stale CLIs reject both with `Parameter validation failed: Unknown parameter in targetConfiguration.mcp: "mcpServer"` / `Unknown parameter in credentialProviderConfigurations[0].credentialProvider: "iamCredentialProvider"`. The generic `aws-cli >= 2.15` floor in `pf_check_tool_versions` is **not** sufficient — AWS CLI 2.28.x ships an old service model and was observed in the field hitting this exact failure; AWS CLI 2.34.x and later include the required shape.
**Detection:** Runs `aws bedrock-agentcore-control create-gateway-target --generate-cli-skeleton input` (offline, no auth, no network), parses the JSON with `python3`, and asserts both fields above are present in the local service model. Auto-skips if `aws` or `python3` is missing — those are reported by `pf_check_tool_versions`.
**Fix (macOS / Homebrew):** `brew update && brew upgrade awscli && aws --version`.
**Fix (macOS pkg / Linux):** Reinstall AWS CLI v2 from the official bundle for your arch (`https://awscli.amazonaws.com/AWSCLIV2.pkg` on macOS, `awscli-exe-linux-x86_64.zip` or `awscli-exe-linux-aarch64.zip` on Linux), then `aws --version` to confirm.
**Fix (CI):** Update the runner base image, or add an "install AWS CLI v2" step before the deploy step. The official `awscli-exe-linux-<arch>.zip` flow works inside `ubuntu-latest`.

#### network-egress
**Function:** `pf_check_network_egress`
**Catches:** Corporate proxy / firewall blocks egress to `cloud.mongodb.com`, `sts.amazonaws.com`, regional Bedrock / SSM / ECR / S3.
**Fix:** Set `HTTPS_PROXY` / `HTTP_PROXY` before re-running, or whitelist the listed hostnames.

#### atlas-api-health
**Function:** `pf_check_atlas_api_health`
**Catches:** Atlas Admin API down or degraded right now (two probes 1 s apart, both non-2xx). Triggers `EX_EXTERNAL` (73) so CI knows the failure is environmental.
**Fix:** Check `https://status.mongodb.com`, retry in 5 minutes.

### AWS / Bedrock / IAM

#### agentcore-regions
**Function:** `pf_check_aws_region_agentcore`
**Catches:** `AGENTCORE_CONTROL_REGION` (or `AWS_REGION` fallback) outside the AgentCore allow-list (`us-east-1` / `us-west-2` / `ap-southeast-1` / `eu-central-1`).
**Fix:** Set `AGENTCORE_CONTROL_REGION=us-east-1` in `.env`.

#### bedrock-model-access
**Function:** `pf_check_bedrock_model_access`
**Catches:** Bedrock model access not granted in the chosen region for the model id we will invoke (default `us.anthropic.claude-sonnet-4-...`). Probes via `bedrock get-foundation-model`; classifies `AccessDenied / not subscribed / ValidationException` as a real failure.
**Fix:** Open the Bedrock console → Model access → enable Anthropic Claude Sonnet 4 (and Voyage embeddings if `EMBEDDINGS_PROVIDER=voyage`). Approval is usually instant.

#### iam-deploy-actions
**Function:** `pf_check_iam_deploy_actions`
**Catches:** Caller IAM principal denied for any action Terraform needs (incl. **SCP DENY** detection through `OrganizationsDecisionDetail`). Uses `iam:SimulatePrincipalPolicy` so it honors permissions boundaries and SCPs.
**Fix:** Attach the reference policy at `deploy/iam/multiagent-deploy-policy.json` to your IAM user/role, or remove the SCP block named in the failure.

#### runtime-role-bedrock-invoke
**Function:** `pf_check_runtime_role_bedrock_invoke` *(post-apply only)*
**Catches:** After `terraform apply`, the AgentCore runtime role lacks `bedrock:InvokeModel` / `bedrock:InvokeModelWithResponseStream`. First chat turn would 403.
**Fix:** Re-run `terraform apply` on the `agentcore-runtime` module; the policy is set in `deploy/terraform/modules/agentcore-runtime/iam.tf`.

### Atlas

#### atlas-api-keys
**Function:** `pf_check_atlas_api_keys_present`
**Catches:** `MONGODB_ATLAS_PUBLIC_KEY` / `MONGODB_ATLAS_PRIVATE_KEY` / `TF_VAR_mongodb_atlas_project_id` missing.
**Fix:** Atlas → Organization → API Keys → create a Project-level key, paste into `.env`.

#### atlas-api-key-scope
**Function:** `pf_check_atlas_api_key_scope`
**Catches:** API key 401 (not on Access List), 403 (wrong role), or 404 (wrong project id). Uses the live Atlas Admin API.
**Fix:** See the failure envelope — each HTTP code points to a different Atlas console page.

#### atlas-cluster-tier
**Function:** `pf_check_atlas_cluster_tier`
**Catches:** A pre-existing cluster on **M0 / M2 / M5** — these tiers don't accept PrivateLink and don't support vector indexes. Only fails if the cluster already exists; first-time deploys (where Terraform creates the cluster) pass.
**Fix:** Atlas → Cluster → Edit configuration → Cluster Tier ≥ M10, **or** destroy and let Terraform recreate at the configured tier.

#### atlas-privatelink-orphans
**Function:** `pf_check_atlas_privatelink_no_orphans`
**Catches:** Stale PrivateLink endpoints in `DELETING` / `FAILED` state from a previous deploy that didn't fully clean up. Atlas refuses to create a new endpoint while orphans linger.
**Fix:** `./deploy/scripts/destroy.sh --mode local`, or DELETE each orphan via the Atlas Admin API (the failure envelope prints the exact `curl` command).

#### atlas-project-quota
**Function:** `pf_check_atlas_project_quota`
**Catches:** Atlas project at the default 25-cluster cap.
**Fix:** Use a different project (`TF_VAR_mongodb_atlas_project_id`), or contact MongoDB support.

#### embedding-dim-consistency
**Function:** `pf_check_embedding_dim_consistency` *(post-apply only)*
**Catches:** `EMBEDDINGS_PROVIDER` switched (e.g. titan ↔ voyage) without re-seeding documents — the stored vector dim in SSM (`/<SHARED_VPC_NAME>/<region>/embeddings/dim`) ≠ the new provider's expected dim. First vector search would return 0 hits.
**Fix:** `REWIRE_EMBEDDINGS=1 bun db-seeding/seed-embeddings.ts` (also runs `seed-indexes.ts` upstream), **or** revert `EMBEDDINGS_PROVIDER`.

#### privatelink-endpoint-available
**Function:** `pf_check_privatelink_endpoint_available` *(post-apply only)*
**Profiles:** `project-post-apply` (skipped when `NETWORK_MODE != privatelink`).
**Catches:** AWS VPC endpoint or Atlas PrivateLink endpoint service is still `pendingAcceptance` / `Failed` / not `available`. Without an `available` endpoint, EC2 → Atlas traffic falls back to public-SRV (PrivateLink mode would silently route over the internet) or fails outright.
**Fix:** Wait 1–3 minutes for endpoint provisioning to finish; inspect with `aws ec2 describe-vpc-endpoints --vpc-endpoint-ids $ATLAS_PRIVATELINK_ENDPOINT_ID`.

#### mcp-runtime-env-complete
**Function:** `pf_check_mcp_runtime_env_complete` *(post-apply only)*
**Profiles:** `project-pre-env-sync` (after Phase 6b + `.env.live` generation; **not** `project-post-apply` — running earlier compares against a stale `.env.live`).
**Catches:** Phase 6b didn't run (or partially ran), so the `mongodb-mcp` AgentCore Runtime's `MONGODB_URI` / `MONGODB_DB` are empty, the MCP URI **authority** (user@hosts; query params like `retryWrites` are ignored) drifted from shell `MONGODB_URI` / `.env.live`, OR a specialist runtime is missing `AGENTCORE_GATEWAY_URL`. Visible symptom: chat returns "tool returned 0 results" because the MCP runtime can't reach Atlas, even though the API's `/health` says `mongodb: connected`.
**Fix:** `./deploy/deploy-agents.sh --auto-approve` re-runs Phase 6b (`update_runtime_env_dynamic` + `update_mcp_runtime_mongodb_env`). See [docs/status/debugging.md "AgentCore Runtime env wipe"](status/debugging.md#agentcore-runtime-env-wipe).

#### kb-ingestion-complete
**Function:** `pf_check_kb_ingestion_complete` *(post-apply only)*
**Profiles:** `project-post-apply`, `local-post-apply` (skipped when `BEDROCK_KB_ID` empty).
**Catches:** The latest Bedrock KB ingestion job is not `COMPLETE`, OR completed with `0` documents indexed. Uses `aws bedrock-agent list-ingestion-jobs` (authoritative, schema-independent — survives Bedrock chunk-shape changes).
**Fix:** Inspect with `aws bedrock-agent list-ingestion-jobs --knowledge-base-id <kb-id> --data-source-id <ds-id>`; re-trigger by running `terraform apply` on the `bedrock-kb` module.

### Voyage (Marketplace)

#### voyage-marketplace
**Function:** `pf_check_voyage_marketplace_subscribed`
**Catches:** `EMBEDDINGS_PROVIDER=voyage` but `VOYAGE_MODEL_PACKAGE_ARN` is unset, **or** `aws sagemaker describe-model-package` returns an error (not subscribed in this region).
**Fix:** `./deploy/scripts/setup-voyage-marketplace.sh` walks you through the Marketplace subscription, then prints the per-region ARN to paste into `.env`.

#### voyage-marketplace-model-matches-arn
**Function:** `pf_check_voyage_marketplace_model_matches_arn`
**Profiles:** `orchestrator-privatelink`, `orchestrator-peering` (inherited), `shared`, `project-pre-apply`, `api`, `agents`.
**Catches:** A mismatch between **what the operator declared** in `.env` (`VOYAGE_MARKETPLACE_MODEL`) and **what was actually subscribed** (`VOYAGE_MODEL_PACKAGE_ARN`). This stack only supports the Voyage **multimodal** listings — `voyage-multimodal-3` and `voyage-multimodal-3.5`. Text-only Voyage listings (`voyage-3*`, `voyage-4*`, `voyage-code-*`, …) are refused at preflight; the legacy `{ "input": [...] }` request envelope was removed in the multimodal-only migration. See [`docs/reference/voyage.md`](reference/voyage.md) for the SSOT.

The endpoint **name** suffix is just a Terraform label — it does not determine the schema. The actual schema is fixed by `VOYAGE_MODEL_PACKAGE_ARN`. Without this check, a `.env` that names `voyage-multimodal-3` but whose `VOYAGE_MODEL_PACKAGE_ARN` points at a text-only Voyage listing deploys cleanly — and then [`db-seeding/seed-embeddings.ts`](../db-seeding/seed-embeddings.ts) fails every row with a Pydantic `1 validation error for InputData / input / Field required` at Phase 11 of `deploy-project.sh` (or in CI's post-deploy smoke).

The check gates on two things:

1. `VOYAGE_MARKETPLACE_MODEL` is in `voyage_supported_models` (bash SSOT) — i.e. `voyage-multimodal-3` or `voyage-multimodal-3.5`.
2. `VOYAGE_MODEL_PACKAGE_ARN` resource-id tail contains `multimodal` (or one of the known spelling variants `multimodel` / `miltimodal` — both are Marketplace metadata typos).

**Skipped when:** `EMBEDDINGS_PROVIDER != voyage`, or `VOYAGE_MODEL_PACKAGE_ARN` is empty (handled by `pf_check_voyage_marketplace_subscribed`).

**Fix:** Re-run `./deploy/scripts/setup-voyage-marketplace.sh --model voyage-multimodal-3` (subscribe at https://aws.amazon.com/marketplace/pp/prodview-hrid2zxusacxy). The helper rewrites `VOYAGE_MODEL_PACKAGE_ARN`, `VOYAGE_MARKETPLACE_MODEL`, and `TF_VAR_voyage_endpoint_name_suffix` consistently. If you need text-only embeddings, switch `EMBEDDINGS_PROVIDER=titan`.

#### voyage-endpoint-live-smoke
**Function:** `pf_check_voyage_endpoint_live_smoke`
**Profiles:** `shared-post-apply` (right after `terraform apply` in `deploy-shared.sh`), `project-pre-apply` (re-check before `deploy-project.sh` Phase 11 seeds embeddings), `api` (re-check before image redeploy bakes `.env.live`).
**Catches:** Same root cause as `voyage-marketplace-model-matches-arn` (and any future drift between the runtime adapter `api/src/adapters/voyage-embedding.ts` and the live Marketplace schema), but at runtime — by actually invoking the SageMaker endpoint. The probe body comes from the bash SSOT helper `voyage_canonical_body "preflight ping" document`, which shells out to `bun api/scripts/voyage-print.ts body` (which itself calls `buildVoyageRequestBody`). One canonical body, one source of truth.

```json
{"inputs":[{"content":[{"type":"text","text":"preflight ping"}]}],"input_type":"document","truncation":true,"output_encoding":null}
```

A non-zero `aws sagemaker-runtime invoke-endpoint` is surfaced with the endpoint's own error text, and — when the error matches the canonical "wrong envelope" Pydantic fingerprint (`input` / `Field required`) — the failure envelope reads:

```
endpoint rejected the multimodal envelope (sent 'inputs', expected 'input').
The deployed model package is text-only — this stack only supports multimodal Voyage listings.
```

A 200 OK is additionally cross-checked against `voyage_embedding_dims` (1024 today, sourced from `VOYAGE_EMBEDDING_DIMS` in the TS SSOT). Any dim drift fails the check.

**Skipped when:** `EMBEDDINGS_PROVIDER != voyage`, or the endpoint name cannot yet be resolved (`VOYAGE_SAGEMAKER_ENDPOINT` / `TF_VAR_voyage_endpoint_name_suffix` both unset — `shared-post-apply` exports the Terraform output before invoking), or `bun` is unavailable on the host (the SSOT body cannot be built without it).

**Fix:** The failure envelope walks you through running `pf_check_voyage_marketplace_model_matches_arn` first (cheap, env-only). If it passed, you have an env/ARN that agree internally but disagree with the actually-deployed model — verify what's behind the endpoint via:

```bash
CONFIG=$(aws sagemaker describe-endpoint --endpoint-name "$VOYAGE_SAGEMAKER_ENDPOINT" \
  --region "$AWS_REGION" --query 'EndpointConfigName' --output text)
MODEL=$(aws sagemaker describe-endpoint-config --endpoint-config-name "$CONFIG" \
  --region "$AWS_REGION" --query 'ProductionVariants[0].ModelName' --output text)
aws sagemaker describe-model --model-name "$MODEL" --region "$AWS_REGION" \
  --query 'PrimaryContainer.ModelPackageName' --output text
```

Re-run `./deploy/scripts/setup-voyage-marketplace.sh --model voyage-multimodal-3` then `./deploy/scripts/deploy-shared.sh` to let Terraform replace the SageMaker model + endpoint config.

#### sagemaker-endpoint-quota
**Function:** `pf_check_sagemaker_endpoint_quota`
**Profiles:** `orchestrator-privatelink`, `orchestrator-peering` (inherited), `shared`.
**Catches:** `EMBEDDINGS_PROVIDER=voyage` but the account has **0** quota for the chosen Voyage GPU instance type (`VOYAGE_INSTANCE_TYPE`, default `ml.g6.xlarge`) under the Service Quotas key `"<instance-type> for endpoint usage"`. New AWS accounts default to 0 for many `ml.g5.*` / `ml.g6.*` types; without an explicit quota grant `envs/shared` fails ~6 min into `terraform apply` with `ResourceLimitExceeded` at `module.voyage_sagemaker`. The check first queries customer-applied quotas (`list-service-quotas`); if absent it falls back to `list-aws-default-service-quotas` so brand-new accounts still see a precise pre-flight failure instead of a 6-minute terraform regression.
**Skipped when:** `EMBEDDINGS_PROVIDER != voyage` (Titan deploys don't need SageMaker), or the chosen instance type has no matching Service Quotas entry (rare — the inline terraform apply still catches it).
**Fix:** Open Service Quotas → SageMaker → search for `"<instance-type> for endpoint usage"` → Request quota increase → value ≥ 1. Approval is usually 0–60 min on accounts with payment history, up to 24 h on brand-new accounts. Alternatively set `EMBEDDINGS_PROVIDER=titan` in `.env` to skip Voyage entirely.
**Why this isn't covered by `aws-service-limits`:** that check is region-default sanity (VPCs + EIPs) and doesn't introspect SageMaker; this one specifically resolves the per-instance-type endpoint quota.

### Network / VPC / SSM

#### shared-network-ssm
**Function:** `pf_check_shared_network_ssm`
**Catches:** Caller is `deploy-shared.sh` or `deploy-project.sh` but the shared-network canary `/<SHARED_VPC_NAME>/<region>/canary/network` is missing — meaning `deploy-network.sh` was never run for this account+region.
**Fix:** `./deploy/scripts/deploy-network.sh`, or use the orchestrator (`./deploy/deploy-full-with-privatelink.sh`).

#### shared-stack-ssm
**Function:** `pf_check_shared_stack_ssm`
**Catches:** Caller is `deploy-project.sh` but the shared-stack canary `/<SHARED_VPC_NAME>/<region>/<env>/canary/shared` is missing — `deploy-shared.sh` never ran for this account+region+environment.
**Fix:** `./deploy/scripts/deploy-shared.sh`.

#### agentcore-vpcendpoints
**Function:** `pf_check_agentcore_vpcendpoints_present`
**Catches:** No `com.amazonaws.<region>.bedrock-agentcore` VPC endpoint in the shared VPC. Runtimes can't reach the AgentCore control plane.
**Fix:** Re-run `./deploy/scripts/deploy-network.sh` (creates the AgentCore + Bedrock VPCEs).

### State & seeding

#### concurrent-deploy-lock
**Function:** `pf_check_concurrent_deploy_lock`
**Catches:** Another deploy in progress for the same `PROJECT_NAME`/`ENVIRONMENT` (S3-backed mutex at `s3://<bucket>/.preflight-locks/deploy.lock`). Lock body identifies host/pid/user/ts of the holder.
**Fix:** Wait for the other deploy. If you're sure none is running, `PREFLIGHT_FORCE_LOCK_BREAK=1 ./deploy/deploy-full-with-privatelink.sh` breaks it once. The lock auto-releases on `EXIT`, `INT`, `TERM` via the module's trap.

#### deploy-manifest
**Function:** `pf_check_deploy_manifest_present`
**Catches:** State bucket `<PROJECT_NAME>-<ENV>-<ACCT>` already exists but its manifest names a *different* `PROJECT_NAME` or `ENVIRONMENT` — i.e. you renamed the project but reused the bucket. Terraform would silently mix the two.
**Fix:** Run `./deploy/scripts/destroy.sh --mode local` with the **old** name first, then re-run with the new one.

#### env-live-keys
**Function:** `pf_check_env_live_required_keys` *(post-apply only)*
**Catches:** `.env.live` missing one of `MONGODB_URI`, `MONGODB_DB`, `AUTH_JWKS_URI`, `AUTH_ISSUER`, `STREAMLIT_COGNITO_*` after Terraform apply — the API or UI would crash on boot.
**Fix:** Re-run `./deploy/deploy-api.sh` (regenerates `.env.live` from Terraform outputs).

#### vector-indexes
**Function:** `pf_check_vector_indexes_present` *(post-apply only)*
**Catches:** Atlas Search vector indexes for `agent_memory_facts` / `chat_messages` / `products` / `troubleshooting_docs` not in `READY` state. First chat turn returns zero vector hits.
**Fix:** `bun db-seeding/seed-indexes.ts` is idempotent. Atlas builds vector indexes asynchronously — wait 2–5 min and re-run preflight.

#### documents-have-embeddings
**Function:** `pf_check_documents_have_embeddings` *(post-apply only)*
**Profiles:** `project-post-apply`, `local-post-apply`.
**Catches:** Either `products` OR seeder-owned `troubleshooting_docs` (KB-managed rows are intentionally excluded via `bedrock_text_chunk: { $exists: false }`) has ≥ 1 row without an `embedding`, OR the sample row's `embedding.length` differs from `EMBEDDING_DIMENSIONS`, OR the sample row's `embeddingModel` doesn't start with the expected provider prefix (`voyage:` / `bedrock:`).
**Implementation:** Uses `bun -e` directly (no `mongosh` / `pymongo` skip path — this check NEVER silently passes now). The target database name is resolved by `_pf_resolve_mongodb_db` in priority order: `MONGODB_DB` → `ATLAS_DB_NAME` → `${PROJECT_NAME//-/_}_${ENVIRONMENT}` (the canonical project convention). `deploy-project.sh` exports `MONGODB_DB="$ATLAS_DB_NAME"` early so both env vars are always populated when preflight runs inside a deploy.
**Fix:** `bun db-seeding/seed-embeddings.ts` is idempotent (gap-fills missing). For a provider switch: `REWIRE_EMBEDDINGS=1 bun db-seeding/seed-embeddings.ts`.

---

## Self-test

The module ships a self-test harness that runs **without contacting AWS or Atlas** — safe to run anywhere, including CI / pre-commit:

```bash
bash deploy/scripts/_preflight-checks.sh --self-test
```

The harness verifies:

1. Dry-run lists the expected check.
2. `PREFLIGHT_SKIP=*` short-circuits the run with exit `0`.
3. Unknown profile name returns exit `2`.
4. `_pf_pass` / `_pf_skip` / `_pf_fail` correctly record summary, fix steps, and ai-fix-hints.
5. `_pf_prereq` honors a failed prerequisite (auto-skip dependents).
6. Every literal `--hint "verb:..."` value uses the closed vocabulary (`edit:` / `run:` / `console:` / `doc:` / `iam:` / `tfvar:`).
7. Every check id referenced from a profile resolves to a defined function.
8. The state-bucket formula `${PROJECT_NAME}-${ENVIRONMENT}-${ACCOUNT_ID}` is identical across every deploy script that defines `SHARED_BUCKET=…` (catches risk #7: lock + manifest writing to the wrong bucket if any deploy script renames the formula).
9. `pf_check_resource_name_constraints` actually rejects an over-length `PROJECT_NAME` (regression-pins the binding-IAM-role math at 47 − len(ENVIRONMENT) chars).
10. Every `--doc "docs/deployment-preflight-checks.md#anchor"` referenced from the module resolves to an actual heading in this file (catches doc drift the moment a check renames its anchor or a section is removed).
11. Every `_pf_fail` call site provides a `--summary` argument (the only mandatory field).

Tests 6–11 are the **documentation- and code-drift firewalls**: any new check, profile entry, doc anchor, or `_pf_fail` call that drifts from the module's invariants fails the self-test before the change merges.

### Defensive: crashed-check detection

If a `pf_check_*` function ever returns without calling exactly one of `_pf_pass` / `_pf_fail` / `_pf_skip` (e.g. an unhandled `set -e` trip inside the check, or an early `return 0` on an error path), the dispatcher detects the missing result-record and surfaces it as:

```
✗ <id>: check function returned without recording a result (rc=N)
  shortcoming  : module bug
  observed     : no _pf_pass / _pf_fail / _pf_skip call before return
  fix:
    1. Open deploy/scripts/_preflight-checks.sh, search for <id>, and ensure every code path calls one of the three result helpers
  ai-fix-hint  : edit:deploy/scripts/_preflight-checks.sh
```

This guarantees that **every** check in a profile contributes to the pass/fail/skip accounting — the total can never silently drift below the profile's check count.

---

## Adding a new check

1. **Function naming.** Use `pf_check_<topic>_<specific>` for hard checks, `pf_advise_<topic>` for advisory-only output. Both names are picked up by the dispatcher.
2. **Output API.** Inside the function, call **exactly one of** `_pf_pass <id> "<one-liner>"`, `_pf_skip <id> "<reason>"`, or `_pf_fail <id> --summary ... --shortcoming ... --observed ... --fix ... --hint ... --doc ...`.
3. **Prereq chaining.** If the check depends on another (e.g. you need a valid Atlas API key first), call `_pf_prereq pf_check_atlas_api_key_scope || { _pf_skip <my_id> "prereq failed"; return 0; }` at the top.
4. **AI-fix-hint vocabulary.** Hints **must** start with one of: `edit:` (file/path/key), `run:` (command), `console:` (URL), `doc:` (relative path with anchor), `iam:` (policy/attach), `tfvar:` (Terraform variable). The self-test enforces this.
5. **Profile registration.** Add the function name to one or more `PREFLIGHT_PROFILE_*` arrays in `_preflight-checks.sh`. The self-test will catch any typo.
6. **Documentation.** Add a `### <anchor>` subsection here, matching the `--doc` value passed to `_pf_fail`.
7. **Self-test.** Run `bash deploy/scripts/_preflight-checks.sh --self-test` locally before opening a PR.

---

## bash 3.2 compatibility

The module targets **bash 3.2** (the default `/bin/bash` on macOS) without requiring an upgrade to 4.x. We achieve this with three deliberate choices:

- Associative-array storage is emulated with a `_pf_set` / `_pf_get` / `_pf_kv_reset` API backed by encoded scalar variables (`_PF_KV__<MAP>__<KEY>`) and a tracking list. Indirect read uses `eval "printf '%s' \"\${${var}:-}\""`.
- Indirect array expansion uses `eval "_PF_CHECKS=(\"\${${arr_name}[@]}\")"` instead of bash 4 namerefs.
- We use `while IFS= read -r line; do ...; done < <(...)` instead of `mapfile -t`.

If you add a new feature, **do not introduce `declare -A`, `local -n`, `mapfile`, `readarray`, or `${var,,}`** — the self-test does not catch these statically, but the module will fail to load on macOS bash. Run `bash deploy/scripts/_preflight-checks.sh --self-test` on stock macOS before merging.

---

## Cross-references

- [`AGENTS.md`](../AGENTS.md) — repository conventions; preflight is referenced under "Conventions for code changes".
- [`docs/deployment-guide.md`](deployment-guide.md) — deploy flow + prerequisites; preflight runs are the first phase of every script listed there.
- [`docs/status/debugging.md`](status/debugging.md) — operational runbook; the **Known persistent pitfalls** section is the long-form companion to this catalog.
- [`README.md`](../README.md) — top-level deploy commands.
