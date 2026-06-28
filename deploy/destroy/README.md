# Teardown scripts

Mode-specific wrappers for tearing down Terraform stacks provisioned by [`deploy/`](../). Each wrapper hard-sets `NETWORK_MODE` and delegates to the low-level engine [`deploy/scripts/destroy.sh`](../scripts/destroy.sh).

**PrivateLink, VPC peering, and public (BYO Atlas) are mutually exclusive per account+region.** Use the script family that matches how you deployed (`deploy-full-with-privatelink.sh` / `deploy-full-with-vpc-peering.sh` / `deploy-full-public.sh`).

**Canonical detail:** [`docs/deployment-guide.md` §6](../../docs/deployment-guide.md#6-tearing-it-down) · [`docs/reference/deploy-scripts.md` §4](../../docs/reference/deploy-scripts.md#4-teardown) · [Known pitfall: AgentCore ENI delay](../../docs/status/debugging.md)

---

## Scripts at a glance

| Script | When to run | Terraform env |
|---|---|---|
| `destroy-project-with-privatelink.sh` | Remove **one project** (PrivateLink) | `envs/ec2` |
| `destroy-project-with-vpc-peering.sh` | Remove **one project** (VPC peering) | `envs/ec2` |
| `destroy-project-with-public.sh` | Remove **one project** (public / BYO Atlas) | `envs/ec2` |
| `destroy-shared-with-privatelink.sh` | Remove **shared singletons** after all projects are gone (PrivateLink) | `envs/shared` → `envs/network` |
| `destroy-shared-with-vpc-peering.sh` | Remove **shared singletons** after all projects are gone (VPC peering) | `envs/shared` → `envs/network` |
| `destroy-shared-with-public.sh` | Remove **shared singletons** after all projects are gone (public / BYO Atlas) | `envs/shared` → `envs/network` |
| `reap-orphan-security-groups-privatelink.sh` | **Deferred** cleanup — run **~1 hour after** project destroy, once AWS releases AgentCore `agentic_ai` ENIs from deleted runtimes (PrivateLink) | n/a (EC2 API) |
| `reap-orphan-security-groups-vpc-peering.sh` | **Deferred** cleanup — run **~1 hour after** project destroy, once AWS releases AgentCore `agentic_ai` ENIs from deleted runtimes (VPC peering) | n/a (EC2 API) |

---

## Required order

```bash
source .env   # or pass --env-file

# 1. Per-project — once per envs/ec2 stack in the region
./deploy/destroy/destroy-project-with-privatelink.sh --auto-approve
# or: destroy-project-with-vpc-peering.sh

# 2. Shared + network — only after EVERY per-project ec2 stack in the region is destroyed
./deploy/destroy/destroy-shared-with-privatelink.sh --auto-approve
# or: destroy-shared-with-vpc-peering.sh
```

**Why order matters:** `envs/ec2` reads SSM parameters published by `envs/shared` and `envs/network`. Destroying shared/network first leaves orphan references; the next `terraform plan` in `envs/ec2` fails with `ParameterNotFound`. Shared wrappers probe for live EC2 instances and refuse to run unless `--force` is passed.

**What each layer removes:**

- **Project** — AgentCore runtimes + Gateway, EC2, Atlas cluster, Cognito, ECR, KB, Memory, per-project DNS, etc. Does **not** touch the shared VPC, Atlas connectivity primitives, Voyage SageMaker, or shared log groups.
- **Shared** — Voyage SageMaker endpoint, CloudWatch log groups, dashboards, Bedrock invocation logging (`envs/shared`).
- **Network** — Shared VPC, Atlas PrivateLink VPCE or VPC peering, SSM canaries (`envs/network`). In **public** mode there is no Atlas connectivity primitive (VPCE/peering are count-gated to 0), so `envs/network` removes only the shared VPC + SSM canaries.

---

## Public mode (Bring-your-own Atlas)

Same two-step order, with the `*-public.sh` wrappers:

```bash
source .env

# 1. Per-project
./deploy/destroy/destroy-project-with-public.sh --auto-approve

# 2. Shared + network (after every per-project ec2 stack in the region is gone)
./deploy/destroy/destroy-shared-with-public.sh --auto-approve
```

What's different vs the private modes:

- **Your BYO Atlas cluster is never touched** — Terraform never created it. Teardown removes only AWS resources (EC2, ECR, Cognito, AgentCore runtimes/Gateway/Memory, KB, etc.).
- **No orphan-SG reaper.** AgentCore runs PUBLIC egress (no VPC attachment), so there are no service-managed `agentic_ai` ENIs to wait on. `envs/network` destroys cleanly in one pass — there is no deferred reaper step for public mode (the section below applies only to PrivateLink / VPC peering).
- No Elastic IP, PrivateLink VPCE, peering, or `atlas-privatelink-dns` zone exist in this mode, so none are torn down.

The wrappers hard-set `NETWORK_MODE=public` and `ATLAS_CLUSTER_SOURCE=byo` and refuse to run if the SSM `network_mode` canary says `privatelink`/`peering` (unless `--force`).

---

## Deferred security-group cleanup (run after a delay)

> Applies to **PrivateLink / VPC peering only**. Public (BYO) mode has no AgentCore ENIs to reap — skip this section.


AgentCore keeps service-managed ENIs (`interface-type=agentic_ai`) attached to runtime security groups for a while after runtimes are destroyed. AWS does not allow operators to detach or delete those ENIs directly.

During **project** destroy, if runtime SGs are still pinned, `destroy.sh --mode ec2`:

1. Removes only those SG resources from Terraform state (does not block indefinitely).
2. Records them in `destroy-reports/orphan-security-groups.tsv`.
3. Prints the matching reaper command for follow-up.

**When to run the reaper:** typically **~1 hour after** project destroy, once AWS releases the ENIs. You can run `destroy-shared-with-*.sh` immediately after project destroy — `envs/shared` usually completes; only the final `envs/network` step may fail if ENIs or orphan SGs are still pinned. The reaper is **not** a substitute for the destroy wrappers — run it after project destroy (or in `--watch` in the background) and **re-run** `destroy-shared-with-*.sh` if network destroy did not finish.

The two reaper scripts are **functionally identical** (same manifest, same SG names); the mode suffix matches the destroy wrapper you used and the follow-up command `destroy.sh` prints.

```bash
source .env

# Single pass (exits 2 if any SG is still pinned)
./deploy/destroy/reap-orphan-security-groups-privatelink.sh
# or: reap-orphan-security-groups-vpc-peering.sh

# Poll every 5 minutes for up to ~2 hours
./deploy/destroy/reap-orphan-security-groups-privatelink.sh --watch --interval 300 --max-attempts 24
```

The reaper is idempotent. It reads the manifest **and** self-discovers SGs by name in the shared VPC:

- `<PROJECT_NAME>-sg-mcp-runtime-<ENVIRONMENT>`
- `<PROJECT_NAME>-sg-agentcore-vpce-<ENVIRONMENT>`

**If network destroy failed on ENI dependencies:**

1. Finish project destroy (if not done).
2. Wait and run the matching reaper (`--watch` is convenient).
3. Re-run `destroy-shared-with-*.sh`.

---

## Flags

### Project wrappers

```bash
./deploy/destroy/destroy-project-with-{privatelink|vpc-peering}.sh \
  [--auto-approve] [--env-file <path>] [--force]
```

| Flag | Effect |
|---|---|
| `--auto-approve` | Pass through to `terraform destroy` (no interactive approve) |
| `--env-file` | Source env vars from a file other than repo-root `.env` |
| `--force` | **PrivateLink only (meaningful):** run when the SSM `network_mode` canary disagrees with this wrapper. **VPC peering:** the wrapper already warns and continues on a mode mismatch; `--force` is accepted for compatibility only. |

### Shared wrappers

```bash
./deploy/destroy/destroy-shared-with-{privatelink|vpc-peering}.sh \
  [--auto-approve] [--env-file <path>] [--with-bootstrap] [--force]
```

| Flag | Effect |
|---|---|
| `--auto-approve` | Pass through to `terraform destroy` |
| `--env-file` | Alternate env file |
| `--with-bootstrap` | On the final **network** step, also empty and delete the shared S3 Terraform state bucket — **only** when no other environment uses it |
| `--force` | Run even when terraform-managed EC2 instances with tag `Environment=<ENVIRONMENT>` still exist. **PrivateLink only (mode guard):** also bypasses an SSM `network_mode` mismatch. **VPC peering:** mode mismatch is warn-only; `--force` only skips the EC2 probe. |

### Reaper scripts

```bash
./deploy/destroy/reap-orphan-security-groups-{privatelink|vpc-peering}.sh \
  [--watch] [--interval <seconds>] [--max-attempts <n>] [--env-file <path>] [--region <region>]
```

| Flag | Default | Effect |
|---|---|---|
| `--watch` | off | Loop until all target SGs are deleted or attempts exhausted |
| `--interval` | `300` | Seconds between `--watch` passes |
| `--max-attempts` | `24` | Max `--watch` passes (~2 h at 5 min intervals) |

Exit code `2` means at least one SG is still pinned or otherwise blocked.

---

## Low-level engine

For `--mode local` or manual teardown of a single Terraform root:

```bash
./deploy/scripts/destroy.sh --mode {local|ec2|shared|network} [--auto-approve] [--with-bootstrap] [--env-file <path>]
```

Normal teardown should use the mode-specific wrappers in this directory so `NETWORK_MODE`, orphan-SG handling, and ordering guards stay correct.

---

## Quick decision tree

```
Deployed with deploy-full-public.sh (BYO Atlas)?
  → destroy-project-with-public.sh
  → destroy-shared-with-public.sh   (no reaper step — public mode has no AgentCore ENIs)

Removing one project only?
  → destroy-project-with-<your-mode>.sh

Removing everything (full account+region wind-down)?
  → destroy-project-with-<your-mode>.sh  (all projects sharing ENVIRONMENT)
  → destroy-shared-with-<your-mode>.sh  (shared usually succeeds; network may fail)
  → if network failed or manifest has orphan SGs:
      reap-orphan-security-groups-<your-mode>.sh --watch
      → re-run destroy-shared-with-<your-mode>.sh

Network destroy failed on AgentCore ENI / SG dependencies?
  → reap-orphan-security-groups-<your-mode>.sh --watch
  → re-run destroy-shared-with-<your-mode>.sh

Laptop-only local stack (no EC2)?
  → deploy/scripts/destroy.sh --mode local
```
