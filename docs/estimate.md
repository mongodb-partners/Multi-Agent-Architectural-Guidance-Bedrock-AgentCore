# AWS Cost Estimate — POC

> **Last updated:** 2026-05-01
> **Environment:** AWS us-east-1, on-demand pricing, 24/7 availability
> **Scope:** A POC running for one calendar month with light, demo-only traffic

This is the **frozen baseline** infrastructure: 4 AgentCore Runtimes, Lambda MCP for tools, S3-code artifacts, single EC2 t3.medium, MongoDB Atlas M10, Bedrock KB. Anything in [gap-analysis.md](gap-analysis.md) marked "parked" (Voyage AI on SageMaker etc.) is not in this estimate.

---

## 1. Monthly cost summary

| Service | Cost / month | Notes |
|---|---|---|
| EC2 t3.medium + EBS gp3 30GB + EIP | **$36** | $30 instance + $4 EBS + $3.65 EIP if attached |
| MongoDB Atlas M10 | **$60** | M10 dedicated, us-east-1, 3 nodes (Atlas charges separately on Atlas billing) |
| AgentCore Runtimes (4) | **~$30-50** | Pay-per-invocation. Light demo traffic ≈ low end. |
| AgentCore Memory | **~$5** | Event storage + retrieval, light usage |
| Lambda MCP | **<$1** | 1M free requests/month covers POC |
| Bedrock — Claude Sonnet 4.6 | **$30-100** | Token-based; depends on demo volume |
| Bedrock — Titan embeddings | **<$5** | Embedding 100s of small docs is cheap |
| Bedrock Knowledge Base | **~$5** | Storage + retrieval |
| Atlas PrivateLink | **~$10** | $0.01/hr per VPC endpoint |
| ECR | **<$1** | Free tier covers POC |
| S3 (state + KB docs + runtime zips) | **<$1** | Light usage |
| CloudWatch Logs | **<$2** | 30-day retention, low volume |
| Cognito | **$0** | First 50K MAU free |
| Secrets Manager | **<$1** | $0.40/secret/month, 1 secret |
| Route 53 private zone | **$0.50** | $0.50/hosted zone/month |
| **Total (typical demo month)** | **~$200-260** | Excluding any spikes |

If left running 24/7 with no usage, the **floor cost is ~$120/month** (EC2 + Atlas + EIP + endpoint + flat fees).

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

### 2.2 AgentCore (4 runtimes)

AgentCore charges per **runtime invocation** + **vCPU/GB-seconds** consumed.

For a POC with ~500 requests/day:
- ~15,000 invocations/month across all 4 runtimes (orchestrator + specialist round trips)
- Each runtime call lasts 2-8 seconds
- Pricing: ~$0.0005 per second of vCPU + $0.0001/GB-second of memory

Estimated: **$30-50/month** at light demo traffic. Could double with heavier demo days.

### 2.3 AgentCore Memory

- Event writes: ~2 events per turn (USER + ASSISTANT)
- Light demo: 500 turns/day × 2 = 1,000 events/day = 30,000/month
- Storage: ~1 KB per event = 30 MB/month
- Pricing: storage + retrieval combined ~$0.10 per 10k events

Estimated: **~$5/month**.

### 2.4 Lambda MCP

- Tool calls per chat turn: 1-3 average
- Light demo: ~1,500 invocations/day = 45,000/month
- Average duration: 200-800 ms
- Memory: 512 MB
- 45,000 × 0.5s × 0.5 GB = 11,250 GB-seconds (free tier is 400,000)

**Cost: $0** for POC (well under free tier). Only meaningful at >> 100k requests/day.

### 2.5 Bedrock (Claude Sonnet 4.6)

Token pricing (us.anthropic.claude-sonnet-4-6):
- Input: $3.00 / million tokens
- Output: $15.00 / million tokens

For a POC with ~500 turns/day:
- Average input: 2,000 tokens (system + memory + history + question)
- Average output: 400 tokens
- Daily input: 1M, output: 200k
- Monthly input: 30M, output: 6M

Cost: 30 × $3.00 + 6 × $15.00 = **~$180/month** at this rate.

But: most demo days will see far fewer turns. **Realistic POC range: $30-100/month.**

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

| Item | Cost |
|---|---|
| Atlas PrivateLink VPC endpoint | $0.01/hr × 730 = **$7.30** |
| Cross-AZ data transfer (Lambda → Atlas private) | $0.01/GB, light usage = $0-1 |
| Route 53 private zone | **$0.50** |
| Internet egress from EC2 | first 100 GB/month free, light demo = $0 |
| **Subtotal** | **~$10** |

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

## 4. What is NOT in this estimate

- **Voyage AI Marketplace subscription** — parked. Would add ~$40/week if activated.
- **SageMaker endpoint** for Voyage AI — parked. Would add ~$120/month for ml.m5.xlarge.
- **NAT Gateway** — not used. Would add $33/month if added.
- **VPC Interface Endpoints** for Bedrock/AgentCore — not used. Would add ~$102/month.
- **ALB/CloudFront** — not used.
- **Auto-scaling group** — not used.
- **Production HA (multi-AZ EC2 + RDS)** — not in scope for POC.

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
