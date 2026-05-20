# AWS Cost Estimate — POC

> **Last updated:** 2026-05-01
> **Environment:** AWS us-east-1, on-demand pricing, 24/7 availability
> **Scope:** A POC running for one calendar month with light, demo-only traffic

This is the **deployed baseline** infrastructure: 5 AgentCore Runtimes (orchestrator + 3 specialists + dedicated `mongodb-mcp-runtime`), S3-code artifacts for the 4 agent runtimes, a separate ARM64 container image for the MCP runtime, single EC2 t3.medium, MongoDB Atlas M10, Bedrock KB, the shared observability stack (Voyage SageMaker endpoint when `EMBEDDINGS_PROVIDER=voyage`, CloudWatch log groups, fleet/mongo/cost/atlas dashboards, Bedrock invocation logging), and an ADOT collector sidecar on EC2.

Anything marked "not yet implemented" in [`architecture.md` §9](architecture.md#9-what-is-not-yet-implemented) is not in this estimate.

---

## 1. Monthly cost summary

| Service | Cost / month | Notes |
|---|---|---|
| EC2 t3.medium + EBS gp3 30GB + EIP | **$36** | $30 instance + $4 EBS + $3.65 EIP if attached |
| MongoDB Atlas M10 | **$60** | M10 dedicated, us-east-1, 3 nodes (Atlas charges separately on Atlas billing) |
| AgentCore Runtimes (5 — 4 agent + 1 MCP) | **~$35-60** | Pay-per-invocation + GB-s. Light demo traffic ≈ low end. The MCP runtime adds ~10-20% on top of the 4 agent runtimes. |
| AgentCore Memory | **~$5** | Event storage + retrieval, light usage |
| Bedrock — Claude Sonnet 4.6 (troubleshoot + product) | **$30-100** | Token-based; depends on demo volume |
| Bedrock — Claude Haiku 4.5 (orchestrator + order-mgmt + classifier + LTM extractor) | **~$5-15** | Haiku is ~10× cheaper than Sonnet on output tokens |
| Bedrock — Titan embeddings (Voyage fallback) | **<$5** | Embedding 100s of small docs is cheap |
| Voyage on SageMaker (`ml.g6.xlarge`, when `EMBEDDINGS_PROVIDER=voyage`) | **~$1800/mo if always-on** | $2.45/hr × 730. **Pause the endpoint when not demoing** — see [`reference/deploy-scripts.md`](reference/deploy-scripts.md) `deploy-shared.sh`. Titan fallback adds $0. |
| Bedrock Knowledge Base | **~$5** | Storage + retrieval |
| Atlas PrivateLink VPCE (PL mode) **or** VPC peering (peering mode) | **~$10** | $0.01/hr per VPCE in PL mode; peering itself is free (data-transfer-only) but the KB peering NLB adds ~$22/mo + LCU when `enable_kb_peering=true` |
| Bedrock KB private NLB (`enable_kb_privatelink` or `enable_kb_peering`) | **~$22-30** | Internal NLB + LCU; off if you opt out (privacy regression — see [`architecture.md` §7.4](architecture.md#private-atlas-connectivity)) |
| CloudWatch (logs + dashboards + invocation logging + Transaction Search) | **~$10-15** | 30-day API retention, 7-day aux retention, EMF metrics, span sampling at 100% |
| ECR | **<$1** | Free tier covers POC |
| S3 (state + KB docs + runtime zips) | **<$1** | Light usage |
| Cognito | **$0** | First 50K MAU free |
| Secrets Manager | **<$1** | $0.40/secret/month, 1 secret |
| Route 53 private zone (PL mode only) | **$0.50** | $0.50/hosted zone/month |
| **Total (typical demo month, Voyage paused)** | **~$220-310** | Excluding any spikes |

If left running 24/7 with no usage, the **floor cost is ~$140/month** (EC2 + Atlas + EIP + endpoint + flat fees + private KB NLB). **With Voyage always-on, add ~$1800/mo** — pause it.

---

## 2. Detailed breakdown

### 2.1 Compute — EC2

| Item | Spec | Cost / month |
|---|---|---|
| t3.medium on-demand | 2 vCPU, 4GB RAM | $30.37 |
| EBS gp3 30 GB | encrypted, default IOPS | $2.40 |
| Elastic IP | attached | $0 (only $3.65 if NOT attached) |
| **Subtotal** | | **~$33** |

`docker compose up -d` runs API + UI as systemd-managed containers. CPU-bound work (Bedrock token streaming) is light. RAM peaks ~1.5GB. Headroom is large.

### 2.2 AgentCore (5 runtimes)

AgentCore charges per **runtime invocation** + **vCPU/GB-seconds** consumed.

For a POC with ~500 requests/day on the default single-hop path (in-API classifier → specialist):
- ~15,000 invocations/month on the agent runtimes (one specialist invocation per turn; orchestrator hop bypassed unless `USE_ORCHESTRATOR_RUNTIME=1`)
- ~15,000-45,000 invocations/month on `mongodb-mcp-runtime` (1-3 Mongo tool calls per turn)
- Each agent runtime call lasts 2-8 seconds; MCP calls are 100-500 ms
- Pricing: ~$0.0005 per second of vCPU + $0.0001/GB-second of memory

Estimated: **$35-60/month** at light demo traffic. The `USE_ORCHESTRATOR_RUNTIME=1` rollback path roughly doubles agent runtime invocations.

### 2.3 AgentCore Memory

- Event writes: ~2 events per turn (USER + ASSISTANT)
- Light demo: 500 turns/day × 2 = 1,000 events/day = 30,000/month
- Storage: ~1 KB per event = 30 MB/month
- Pricing: storage + retrieval combined ~$0.10 per 10k events

Estimated: **~$5/month**.

### 2.4 (removed — Lambda MCP)

The legacy Lambda MongoDB MCP host was deleted in CLIENT_REVIEW Phase 7e. MongoDB tool calls now go through the dedicated `mongodb-mcp-runtime` AgentCore Runtime; its cost is rolled into § 2.2 above.

### 2.5 Bedrock — mixed Claude Sonnet 4.6 / Haiku 4.5

Today's per-agent model selection (see [`config/agents/*.agent.md`](../config/agents/)):

| Agent | Model | Input $/M | Output $/M |
|---|---|---|---|
| orchestrator | Claude Haiku 4.5 | $1.00 | $5.00 |
| order-management | Claude Haiku 4.5 | $1.00 | $5.00 |
| troubleshooting | Claude Sonnet 4.6 | $3.00 | $15.00 |
| product-recommendation | Claude Sonnet 4.6 | $3.00 | $15.00 |
| classifier fallback (in-API) | Claude Haiku 4.5 | $1.00 | $5.00 |
| LTM fact extractor | Claude Haiku 4.5 | $1.00 | $5.00 |

For a POC with ~500 turns/day split evenly across specialists:
- Per turn: ~2,000 input tokens (system + memory + history + question) + 400 output tokens
- Half the turns hit Sonnet (troubleshooting + product) at ~$0.012 per turn
- Half hit Haiku (order-management) at ~$0.004 per turn
- Plus per-turn classifier + extractor on Haiku (~$0.001)

Daily: 500 × (~$0.008 avg) = ~$4/day = **~$120/month** at this rate.

But: most demo days will see far fewer turns. **Realistic POC range: $30-100/month** combined.

### 2.6 Bedrock embeddings (Titan v2)

- $0.02 per million tokens
- Embedding 100 troubleshooting docs × 500 tokens = 50k tokens = **<$0.01**
- Vector search query embeddings: light

**Cost: <$5/month.**

### 2.7 Bedrock Knowledge Base

- Storage of ingested docs: pennies
- Retrieval: $0.075 per 1k retrieve calls
- Light demo: ~10 retrievals/day = 300/month = $0.02

**Cost: ~$5/month** including ingestion and storage overhead.

### 2.8 MongoDB Atlas M10

| Item | Cost |
|---|---|
| M10 dedicated cluster (3 nodes) | $0.08/hr × 730 hrs = **$58.40** |
| Atlas backup snapshots | $0.02/GB-month, ~10 GB = $0.20 |
| Atlas data transfer | minimal | $0 |
| **Subtotal** | **~$60** |

Billed on Atlas, not AWS. Atlas charges to a separate credit card.

### 2.9 Networking

| Item | Cost (PrivateLink mode) | Cost (peering mode) |
|---|---|---|
| Atlas Interface VPCE | $0.01/hr × 730 = **$7.30** | — |
| VPC peering connection | — | $0 (peering itself is free) |
| Cross-AZ data transfer | $0.01/GB, light usage = $0-1 | $0.01/GB, light usage = $0-1 |
| Route 53 private zone (per cluster) | **$0.50** | — (peering uses Atlas-managed `-pri.mongodb.net` SRV) |
| Bedrock KB private NLB (`enable_kb_privatelink` / `enable_kb_peering`) | **~$22 + LCU** | **~$22 + LCU (EXPERIMENTAL)** |
| Internet egress from EC2 | first 100 GB/month free | first 100 GB/month free |
| **Subtotal** | **~$30** | **~$25** |

### 2.10 Other AWS services

| Item | Cost |
|---|---|
| ECR storage (3 repos × 5 image versions × 200 MB) | $0.10/GB-month × 3 GB = **$0.30** |
| S3 (~1 GB tfstate + KB docs + zips) | $0.023/GB = **<$0.05** |
| CloudWatch Logs (~5 GB ingest + 30-day retention) | **~$2** |
| Secrets Manager (1 secret) | **$0.40** |
| Cognito (light traffic) | **$0** (50k MAU free) |
| KMS (default keys) | **$0** |
| **Subtotal** | **~$3** |

---

## 3. What drives cost spikes

| Lever | Where it shows up | How to control |
|---|---|---|
| Demo session volume | Bedrock Claude tokens | Cap with rate limits or trigger demo-mode shut-offs |
| Long agent chains | AgentCore runtime invocations + Bedrock | Tune `SWARM_MAX_STEPS`, system prompt brevity |
| Long memory injection | Bedrock input tokens | Lower `MEMORY_INJECT_TURNS` from default 5 |
| Idle EC2 24/7 | EC2 + EIP | Stop instance when not demoing (saves ~$30/mo) |
| Atlas always-on | M10 cluster | Pause cluster when not in use (Atlas console — saves the cluster cost) |

**To reduce idle cost** when not actively demoing:

```bash
# Stop EC2 (keep state)
aws ec2 stop-instances --instance-ids "$EC2_INSTANCE_ID"

# Pause Atlas cluster (Atlas console → Cluster → Pause)
```

This drops monthly cost to ~$30 (EBS + Atlas paused storage + flat fees).

---

## 4. What is NOT in this estimate (by default)

- **Voyage AI SageMaker endpoint always-on** — ~$1800/mo on `ml.g6.xlarge`. Provisioned only when `EMBEDDINGS_PROVIDER=voyage` (otherwise the stack uses Bedrock Titan v2). Pause via `deploy-shared.sh` re-apply with `EMBEDDINGS_PROVIDER=titan` when not actively demoing.
- **NAT Gateway** — not used. Would add $33/month if added.
- **VPC Interface Endpoints** for Bedrock/AgentCore — not used. Would add ~$102/month.
- **ALB/CloudFront** — not used.
- **Auto-scaling group** — not used.
- **Production HA (multi-AZ EC2 + RDS)** — not in scope for POC.
- **MongoDB Atlas Prometheus scrape** (`enable_atlas_metrics=true`) — opt-in; adds the ADOT extra scrape config + custom metrics namespace ~$5-10/mo.

---

## 5. Tax + region notes

- All prices above are **us-east-1 on-demand**, USD, before tax.
- AWS tax varies by billing entity (typically 0% for US business accounts, 18% for India GST).
- Atlas tax handled separately on Atlas invoice.
- Reserved instances / Savings Plans not applicable for a POC.

---

## 6. Cost at-a-glance for project planning

| Phase | Cost / month |
|---|---|
| Active demo period (running 24/7, 500 turns/day) | **~$200** |
| Active demo period (running 24/7, 2000 turns/day) | **~$300** |
| Idle (everything provisioned, no traffic) | **~$120** |
| Paused (EC2 stopped, Atlas paused) | **~$30** |
| Destroyed (after `destroy.sh`) | **$0** |

For a 3-month POC engagement with active demos, budget **~$700** (active months) **+ overage buffer**.
