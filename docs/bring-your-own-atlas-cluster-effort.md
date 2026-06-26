# Plan — BYO Atlas Cluster over Public Internet (Demo)

> Point this deployment at a **pre-existing MongoDB Atlas cluster** reached over
> the **public internet**. No PrivateLink, no VPC peering, no Terraform-created
> cluster.
>
> **Demo assumption (explicit):** the Atlas IP access list may be set to
> `0.0.0.0/0`. This removes the only hard requirement of the previous draft (a
> stable, whitelistable egress IP) and lets us skip all new network infra.

---

## 1. Why the demo assumption changes everything

The hard part of public Atlas is that the MCP runtime lives in **private
subnets with no NAT** (`modules/networking/main.tf` — IGW + public route table
only), so it has no path to the public internet. The previous plan solved that
with a **NAT gateway + Elastic IP** purely to get *one stable IP to whitelist*.

If `0.0.0.0/0` is acceptable, we no longer need a stable IP — so we no longer
need the NAT. Instead we run the MCP runtime in AgentCore's **`PUBLIC` network
mode**, exactly like the existing agent runtimes (`ec2/main.tf:1046, 1080`).
PUBLIC mode uses AWS-managed egress (variable IP) — fine, because Atlas allows
everything.

| | Previous (whitelist one IP) | This demo (`0.0.0.0/0`) |
|---|---|---|
| Runtime egress | NAT gateway + EIP, private route table | **AgentCore `PUBLIC` mode** — zero infra |
| `modules/networking` | +35 LoC | **no change** |
| Bedrock KB over public SRV | Blocked (Bedrock IPs not whitelistable) | **Works** — `0.0.0.0/0` allows them |
| Effort | ~3 days | **~1.5 days** |

`ponytail:` `PUBLIC` mode is the lazy win only because `0.0.0.0/0` is allowed.
The moment a real deployment needs a scoped allowlist, revert to NAT+EIP (kept
in git history) — do not ship `0.0.0.0/0` to production.

---

## 2. Connectivity model

- **MCP runtime → Atlas:** `network_mode = "PUBLIC"`, dials the BYO **SRV** URI
  over the public internet. No VPC subnets/SG, no NAT, no VPC endpoints needed
  for this runtime.
- **Operator seeding / smoke (local-exec):** runs from the deploy machine over
  public SRV — already works.
- **Bedrock KB ingestion:** public-SRV arm (`enable_kb_privatelink=false`,
  `enable_kb_peering=false`) — reaches Atlas from Bedrock-managed IPs, allowed by
  `0.0.0.0/0`.
- **Atlas IP access list:** set to `0.0.0.0/0` **in the Atlas console** (the
  operator owns the cluster; we never write to their allowlist). For a demo on
  *our* cluster with API keys, Terraform could add it — but the BYO path assumes
  no API keys, so console it is.

No new network resources anywhere.

---

## 3. File-by-file changes (minimal)

### 3.1 Cluster module — `modules/mongodb-atlas/` *(BYO passthrough — the core)*
- `variables.tf`: add `cluster_source` (`managed`/`byo`), `byo_connection_string`
  (sensitive), `byo_srv_host`.
- `main.tf`: gate `mongodbatlas_cluster.main`, `mongodbatlas_database_user.app`,
  and both `mongodbatlas_project_ip_access_list.*` with
  `count = var.cluster_source == "managed" ? 1 : 0`; make the
  `atlas_privatelink_has_operator_ip` check fire only when managed.
- `outputs.tf`: once the cluster is counted, **every** output that dereferences
  `mongodbatlas_cluster.main...` must guard:
  `var.cluster_source == "byo" ? <byo or ""> : mongodbatlas_cluster.main[0]...`.
  For public we only need `connection_string` (= `byo_connection_string`) and
  `mongo_host` (= `byo_srv_host`) to carry real values; PL/peering outputs
  return `""`. Unavoidable — indexing `[0]` on a count=0 resource errors.
- ~50 LoC.

### 3.2 Per-project env — `envs/ec2/main.tf` (+ `variables.tf`)
- `variables.tf`: add `cluster_source`, `byo_connection_string`, `byo_srv_host`,
  `allow_public_atlas` (bool); extend `network_mode` validation to accept `"public"`.
- Forward the new vars to `module.mongodb_atlas` (`254-270`).
- `module.mongodb_mcp_runtime` (`919-953`): in public mode set
  `network_mode = "PUBLIC"` and drop `vpc_subnet_ids` /
  `vpc_security_group_ids` and the VPCE `depends_on` (mirror `acr_orchestrator`).
  Keep `MONGODB_URI = local.mcp_mongodb_uri`.
- `mcp_mongodb_uri` (`894`): add a `public` branch → `module.mongodb_atlas.connection_string` (SRV).
- `check "mcp_uri_is_direct_private_runtime_uri"` (`900-917`): add a `public`
  branch allowing `mongodb+srv://`, gated behind `var.allow_public_atlas == true`.
- Add `check "managed_plus_public_forbidden"`: `var.cluster_source == "byo" || var.network_mode != "public"`.
- KB: public-SRV arm (set both `enable_kb_*` false in public mode).
- ~40 LoC.

### 3.3 Network env — `envs/network/`
- `variables.tf`: extend `network_mode` validation to accept `"public"`.
- `main.tf`: both `atlas_privatelink` and `atlas_vpc_peering` already `count` on
  their mode → naturally `0` in public. SSM `network_mode` param just records
  `public`. **No NAT, no other change.**
- ~5 LoC.

### 3.4 Local env — `envs/local/`
- Mirror `cluster_source` + `byo_connection_string`; pass URI through. ~10 LoC.

### 3.5 Deploy script — `deploy/scripts/deploy-project.sh`
- Accept `NETWORK_MODE=public` (`334`).
- When `ATLAS_CLUSTER_SOURCE=byo` + `public`: skip the `atlas_db_password`
  require (`362`, password is in the BYO URI), skip `atlas_project_id` (`365`),
  skip Atlas API keys (`367-370`) and the Admin-API call (`413`).
- Export `TF_VAR_cluster_source`, `TF_VAR_byo_connection_string`,
  `TF_VAR_byo_srv_host`, `TF_VAR_allow_public_atlas`; write them into the
  tfvars block (`656`). MONGODB_URI build (`987/1139`) reads
  `atlas_connection_string` → works unchanged.
- ~35 LoC.

### 3.6 Env wiring
- `.env.sample` + `_preflight-checks.sh`/`_env-live.sh`: public-BYO vars, relax
  the Atlas-creds requirement in this path, add an `ALLOW_PUBLIC_ATLAS=1` gate
  and one SRV TCP/TLS reachability probe. ~30 LoC.

```bash
# ── BYO Atlas over public internet (DEMO — 0.0.0.0/0 allowlist) ───────────────
# export ATLAS_CLUSTER_SOURCE="byo"
# export NETWORK_MODE="public"
# export ALLOW_PUBLIC_ATLAS="1"
# export MONGODB_BYO_URI="mongodb+srv://user:pass@cluster.xxxxx.mongodb.net/?retryWrites=true&w=majority"
# export MONGODB_BYO_SRV_HOST="cluster.xxxxx.mongodb.net"
# export MONGODB_BYO_DB_NAME="myapp_dev"
```

### 3.7 Destroy
- No new wrapper. Pass `-var cluster_source=byo -var network_mode=public` to the
  existing `destroy.sh` so TF doesn't delete a cluster it never created. ~5 LoC.

---

## 4. Reuse — what does NOT change

- `modules/networking` — **no change** (no NAT, no new routes).
- Both Atlas network modules (`atlas-privatelink`, `atlas-vpc-peering`) — `count=0` in public.
- MCP runtime SG / VPC endpoints — unused by the runtime in PUBLIC mode; leave
  them (harmless) or gate to non-public as optional cleanup.
- All downstream consumers (`seed_mongodb_indexes`, `bedrock_kb`, runtime env) —
  read `module.mongodb_atlas.*` outputs, unchanged once outputs proxy BYO values.
- No new deploy wrappers — reuse the existing flow with env vars.

---

## 5. Effort

| Bucket | Files | Net LoC | Eng-days |
|---|---|---|---|
| BYO passthrough in cluster module | `modules/mongodb-atlas` (3 files) | ~50 | 0.5 |
| `envs/ec2` public branch + PUBLIC-mode runtime + guards | 1–2 files | ~40 | 0.4 |
| `envs/network` + `envs/local` | 2 files | ~15 | 0.1 |
| `deploy-project.sh` public+BYO branch | 1 file | ~35 | 0.3 |
| Env wiring + preflight probe | 3 files | ~30 | 0.2 |
| End-to-end test against a real BYO cluster | – | – | 0.5 |
| **Total** | | **~170 LoC** | **~1.5–2 days** |

---

## 6. Caveats

1. **`0.0.0.0/0` is demo-only.** Atlas open to the world + runtime egress over
   the public internet. Gated behind explicit `ALLOW_PUBLIC_ATLAS=1` and the
   `allow_public_atlas` Terraform guard so it can't be set by accident.
2. **No Atlas API keys needed** — public BYO never calls the Atlas Admin API.
3. **PUBLIC-mode runtime** loses VPC network isolation for the MCP path; that is
   the intended trade for this demo.
4. **Mode switching** still requires destroy + redeploy.
5. **KB works here** (vs the scoped-IP plan) precisely because `0.0.0.0/0`
   admits Bedrock's managed source IPs.

---

## 7. Checklist

- [ ] `modules/mongodb-atlas`: cluster / DB user / IP list `count`-gated on `cluster_source`; all outputs guarded for BYO.
- [ ] `envs/ec2`: MCP runtime → `network_mode="PUBLIC"` (drop subnets/SG/VPCE deps) in public mode; `mcp_mongodb_uri` SRV branch; runtime guard public branch behind `allow_public_atlas`; `managed_plus_public_forbidden` check; KB public-SRV arm.
- [ ] `envs/network`: `network_mode="public"` accepted; atlas modules `count=0`; SSM records `public`.
- [ ] `envs/local`: BYO URI passthrough.
- [ ] `deploy-project.sh`: `NETWORK_MODE=public` + BYO branch (skip password / project-id / API keys / Admin-API call).
- [ ] `.env.sample` + preflight: public-BYO vars, `ALLOW_PUBLIC_ATLAS` gate, SRV TCP/TLS probe.
- [ ] `destroy.sh`: pass `cluster_source=byo` + `network_mode=public`.
- [ ] **UAT:** set `0.0.0.0/0` in the Atlas console; deploy; verify chat + memory + KB against the BYO cluster.
