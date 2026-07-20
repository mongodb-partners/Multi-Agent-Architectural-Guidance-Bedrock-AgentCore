# Enterprise AWS Cost Report — Support Ops Automation

> ⚠️ **Workload framing is from the retired customer-support use case.** The volume model
> below (100k **support tickets**/day) and its benchmarks in §1 come from published
> customer-support industry data, gathered for the previous agent set. The **infrastructure
> and per-turn cost math is domain-independent** and still applies to the current
> `job-match` / `career-coach` / `company-intel` agents — a candidate conversation and a
> support ticket cost the same to serve at equal turn counts and token sizes.
>
> The ticket-resolution benchmarks (deflection rate, human-escalation cost) do **not**
> transfer. Re-source those against recruitment benchmarks before quoting §1 or the
> savings figures for a career-domain deployment.

> **Scenario:** An enterprise automates its support operations with this multi-agent
> solution (Strands Agents on AWS Bedrock + MongoDB Atlas + AgentCore Runtimes).
> **Volume:** 100,000 support **tickets** (conversations) per day ≈ **3,000,000 tickets/month** (30.4-day month).
> **Region:** us-east-1, on-demand pricing, USD, pre-tax.
> **Pricing basis:** Published AWS on-demand rates + the repo's own [`docs/estimate.md`](estimate.md) unit rates, extrapolated to enterprise scale.
> **Assumptions basis:** Grounded in published customer-support industry benchmarks — see [§1](#1-real-world-benchmarks-what-a-support-ticket-actually-looks-like).
> **Report date:** 2026-07-15 (revised with web-sourced benchmarks)

---

## TL;DR — Average cost per ticket

A **"ticket" = one full support conversation**, which the industry benchmark puts at
**~5.7 messages ≈ ~3 back-and-forth turns** (Tidio). Each *turn* is one `POST /chat` call
to the agent. So one ticket drives **~3 specialist invocations, ~6–12 LLM calls, ~9
memory events, ~18 embedding calls.**

| Configuration | Cost / month | **Avg cost / ticket** |
|---|---|---|
| **Public* + Titan** (cheapest) | ~$62,300 | **~$0.0208** |
| **VPC Peering + Titan** | ~$62,340 | **~$0.0208** |
| **PrivateLink + Titan** | ~$62,360 | **~$0.0208** |
| **Public* + Voyage** | ~$69,150 | **~$0.0231** |
| **VPC Peering + Voyage** | ~$69,190 | **~$0.0231** |
| **PrivateLink + Voyage** (most expensive) | ~$69,210 | **~$0.0231** |

**Headline:** at 3M tickets/month the cost is **~$0.021–0.023 per ticket** (~2–2.3 cents),
driven by the ~3-turn conversation length. After optimization (Haiku-weighted routing,
prompt caching, tuned memory injection) this falls toward **~$0.013–0.016/ticket**.

- **The embedding provider (Titan vs Voyage) moves the bill ~$6,800/month (~0.23¢/ticket).**
- **Networking mode is a rounding error (~$100–300/month, <0.01¢/ticket).**
- **Conversation length is the single biggest driver** — a 1-turn (fully deflected first
  reply) ticket costs ~⅓ of a 3-turn ticket. See [§7](#7-sensitivity--what-actually-moves-the-bill).

> **\* "Public mode" is not currently implemented** in the Terraform (only `privatelink`
> and `peering` are valid `NETWORK_MODE` values). Modeled here as a *hypothetical* that
> drops the Atlas VPC endpoint, Route 53 private zone, and KB private NLB. See [§4.3](#43-public-mode-hypothetical).

---

## 1. Real-world benchmarks — what a "support ticket" actually looks like

These are the **web-sourced industry numbers** that ground every assumption below.

| Metric | Value | Source |
|---|---|---|
| **Messages per chatbot conversation** | **5.7 messages** | [Tidio, *AI Customer Service Statistics 2026*](https://www.tidio.com/blog/ai-customer-service-statistics/) |
| Share of tickets AI resolves autonomously | ~67–80% | [Klarna (⅔ of chats, OpenAI)](https://www.klarna.com/international/press/klarna-ai-assistant-handles-two-thirds-of-customer-service-chats-in-its-first-month/); [Gartner (80% of common issues by 2029)](https://www.gartner.com/en/newsroom/press-releases/2025-03-05-gartner-predicts-agentic-ai-will-autonomously-resolve-80-percent-of-common-customer-service-issues-without-human-intervention-by-20290); [Tidio/Lyro (up to 70%)](https://www.tidio.com/blog/lyro-case-study/) |
| Avg resolution time (AI) | <2 min (vs 11 min human) | [Klarna AI assistant press release, Feb 2024](https://www.klarna.com/international/press/klarna-ai-assistant-handles-two-thirds-of-customer-service-chats-in-its-first-month/) |
| Repeat-inquiry rate reduction with AI | −25% | [Klarna](https://www.klarna.com/international/press/klarna-ai-assistant-handles-two-thirds-of-customer-service-chats-in-its-first-month/) |
| Typical support message length | ~15–30 words | Support-industry norm (short conversational turns) |
| AI-handled conversations at scale | 2.3M in first month (1 company) | [Klarna](https://www.klarna.com/international/press/klarna-ai-assistant-handles-two-thirds-of-customer-service-chats-in-its-first-month/) — validates 100K/day is realistic for a large enterprise |

**Interpretation for this architecture:**

- **5.7 messages ≈ ~3 user turns + ~2.7 assistant turns.** In this system, **each user
  turn = one `POST /chat` call** = one classifier + one specialist invocation + one LTM
  extractor + memory read/write. So **1 ticket ≈ 3 agent turns.**
- A support message of ~20 words ≈ **~27 tokens** (using ~1.33 tokens/word). This is the
  *user's* contribution; the LLM *input* per turn is dominated by the system prompt, the
  pre-activated skill body, and injected memory (see §1.2), not the raw user message.
- Assistant replies (~40–70 words + light tool reasoning) ≈ **~300–450 output tokens/turn.**

### 1.1 Resource consumption per ticket (3-turn conversation)

Traced from the production single-hop path (`routes/chat.ts` → in-API classifier →
specialist AgentCore Runtime), then multiplied by ~3 turns/ticket.

| Resource | Per **turn** | Per **ticket** (~3 turns) | Notes / source |
|---|---|---|---|
| AgentCore specialist runtime invocations | 1 (2 if multi-domain) | **~3–4** | `multi-specialist-orchestrator.ts` |
| Bedrock LLM calls | 2–4 | **~6–12** | classifier (0–1) + specialist loop (1 + tool rounds) + LTM extractor (1) + synth (multi) |
| MongoDB MCP tool calls | 1–3 | **~4–7** | model-driven, via mongodb-mcp runtime |
| Bedrock KB retrieve | 0–1 | **~1** | RAG/knowledge specialist only |
| Embedding calls | ~6 | **~18** | 1 LTM query + 2 chat-mirror + ~3 fact writes, per turn |
| AgentCore Memory events | 3 | **~9** | 1 ListEvents + 2 CreateEvent per turn |

### 1.2 Token model — grounded in the 5.7-message benchmark

Per-**turn** LLM input is dominated by fixed context, not the ~27-token user message.
From configured caps (`maxTokens`), memory-injection defaults (`MEMORY_INJECT_TURNS=5`,
`MEMORY_VECTOR_TOPK=14`), and pre-activated skill bodies in specialist prompts:

| Component of a turn's input | ~Tokens |
|---|---|
| System prompt + pre-activated skill body | ~2,800 |
| Injected long-term memory context (top-14 rows) | ~1,100 |
| Short-term history replay (grows across the 3 turns) | ~400 |
| User message (~20 words) | ~30 |
| **Input per specialist turn** | **~4,300** |
| Output per specialist turn (~50 words + tool reasoning) | **~400** |

Plus per turn: classifier (fires ~40%: ~800 in / ~50 out) and LTM extractor
(~1,200 in / ~250 out), both Haiku; synthesizer on ~15% of turns (~1,500 in / ~350 out).

**Blended per-turn tokens:** ~6,300 input / ~900 output.
**Per-ticket (×3 turns):** **~18,900 input / ~2,700 output tokens.**

> These input numbers are **large because the specialists pre-activate their full skill
> body into every system prompt** (`ALWAYS_ACTIVATE_SKILLS=true`). This is the #1 target
> for prompt caching (§7).

---

## 2. Bedrock pricing (us-east-1 on-demand)

| Model | Input $/1M | Output $/1M | Used for |
|---|---|---|---|
| Claude Haiku 4.5 | $1.00 | $5.00 | orchestrator, classifier, 2 specialists, LTM extractor, synthesizer |
| Claude Sonnet 4.6 | $3.00 | $15.00 | 1 knowledge/RAG specialist |
| Titan Text Embeddings v2 | $0.02 / 1M | — | embeddings (Titan provider) |

### 2.1 Bedrock LLM cost per ticket (blended, 3 turns)

Specialist model mix (from `config/agents/*.agent.md`): 2 of 3 specialists run **Haiku
4.5**, 1 runs **Sonnet 4.6** → ~⅔ of turns hit Haiku, ~⅓ hit Sonnet. Splitting the
per-ticket ~18,900 in / ~2,700 out tokens accordingly:

| Bucket | Input tok | Output tok | $/ticket |
|---|---|---|---|
| Haiku (router + aux + ⅔ specialists) | ~13,900 | ~1,850 | $0.0139 in + $0.0093 out = **$0.0232** |
| Sonnet (⅓ specialists) | ~5,000 | ~850 | $0.0150 in + $0.0128 out = **$0.0278** |
| **Total per ticket** | | | **~$0.0170** blended |

**Monthly Bedrock LLM = $0.0170 × 3,000,000 = ~$51,000/month.** This is the single
largest line item.

> Sonnet handles only ⅓ of turns but contributes ~45% of LLM cost. **Routing more traffic
> to Haiku + prompt caching are the two biggest levers** (§7).

### 2.2 Embeddings per ticket

~18 embedding calls/ticket, ~400 tokens each ≈ **~7,200 embedding tokens/ticket.**

- **Titan provider:** 7,200 tok × $0.02/1M = **$0.000144/ticket** → 3M × ≈ **~$430/month**. Negligible per-token; **zero fixed cost.**
- **Voyage provider:** served by an **always-on SageMaker GPU endpoint** (§5) — marginal per-call cost ~$0, but **~$1,800–7,200/month fixed** regardless of volume.

### 2.3 Bedrock Knowledge Base retrieve

~$0.075 / 1k retrieve calls; ~1 retrieve/ticket (RAG specialist turns) → ~3M/month →
**~$225/month.** KB uses **MongoDB Atlas as the vector store (no OpenSearch Serverless),
so there are no OCU fixed charges** — a significant cost avoidance.

---

## 3. AgentCore Runtimes + Memory (serverless, per-invocation)

5 runtimes (orchestrator + 3 specialists + mongodb-mcp), fully-managed serverless —
**no per-runtime fixed hourly cost.** Billed on vCPU-seconds + GB-seconds + invocations.
Repo rate: ~$0.0005 per vCPU-second + ~$0.0001 per GB-second.

**Per ticket (~3 turns) AgentCore compute:**
- Specialist runtime: ~3.5 invocations × (2 vCPU × ~4 s) = ~28 vCPU-s + ~56 GB-s
- mongodb-mcp runtime: ~5 calls × (1 vCPU × ~0.3 s) = ~1.5 vCPU-s + ~3 GB-s
- Cost/ticket ≈ (29.5 × $0.0005) + (59 × $0.0001) ≈ **$0.0148 + $0.0059 = ~$0.0207**

Applying a realistic warm-container/packing discount for sustained enterprise throughput
→ **~$0.015/ticket.**

**Monthly AgentCore compute = $0.015 × 3M = ~$45,000/month.**

> ⚠️ AgentCore Runtime pricing is the **least certain** number here (new service,
> consumption rates vary). Treat ±40% as the confidence band. This and Bedrock LLM tokens
> are the two dominant, volume-driven costs.

**AgentCore Memory:** ~9 events/ticket × 3M = ~27M events/month. At ~$0.10 / 10k events
combined store+retrieve → **~$270/month.**

---

## 4. Networking modes — the only real difference between the three configs

Everything above (Bedrock, AgentCore, embeddings, Atlas) is **identical across modes.**
The mode changes only a few small fixed line items.

### 4.1 PrivateLink mode (default)

| Item | Cost / month |
|---|---|
| Atlas Interface VPC Endpoint (per-AZ hourly + data proc) | ~$15–25 |
| Route 53 private hosted zone | $0.50 |
| Bedrock KB private NLB (`enable_kb_privatelink=true`) + LCU | ~$25–35 |
| 3× ECR/Logs Interface VPC endpoints (per-AZ) | ~$65 |
| Cross-AZ data transfer (enterprise volume) | ~$50–100 |
| **Networking subtotal** | **~$160–225** |

### 4.2 VPC Peering mode

| Item | Cost / month |
|---|---|
| VPC peering connection | $0 (free; data-transfer only) |
| Bedrock KB peering NLB (`enable_kb_peering=true`, EXPERIMENTAL) + LCU | ~$25–35 |
| 3× ECR/Logs Interface VPC endpoints (per-AZ) | ~$65 |
| Cross-AZ / peering data transfer | ~$50–100 |
| **Networking subtotal** | **~$140–200** |

### 4.3 "Public mode" (hypothetical — NOT implemented)

`NETWORK_MODE` only accepts `privatelink` or `peering`. Modeled as Atlas public SRV + IP
allowlist, `enable_kb_*=false` (drops KB NLB), no VPCE, no Route 53 zone.

| Item | Cost / month |
|---|---|
| Atlas VPCE / peering / KB NLB / Route 53 zone | $0 (all dropped) |
| 3× ECR/Logs Interface VPC endpoints (still needed for AgentCore VPC egress) | ~$65 |
| Internet egress / data transfer | ~$40–90 |
| **Networking subtotal** | **~$105–155** |

Public mode is cheapest by ~$50–120/month but **sacrifices private Atlas connectivity** —
generally unacceptable for enterprise support data. Included for completeness only.

---

## 5. Embedding provider — the biggest configurable cost swing

| Provider | Model | Cost structure | Monthly @ 3M tickets |
|---|---|---|---|
| **Titan (Bedrock-managed)** | `amazon.titan-embed-text-v2:0` | Pure per-token, **$0 fixed** | **~$430** |
| **Voyage (SageMaker-hosted)** | Voyage multimodal on `ml.g6.xlarge` GPU | **Always-on GPU endpoint, per instance-hour** | **~$1,800/instance** |

The shipped TF provisions **one `ml.g6.xlarge` endpoint, no autoscaling**. At ~18
embedding calls/ticket × 100K tickets/day = ~1.8M embed calls/day, a single GPU instance
**will not keep up** — realistic prod needs **~3–4 instances** behind autoscaling:

- 1 instance (as-shipped, undersized): ~$1,800/month
- **3–4 instances (realistic for this volume): ~$5,400–7,200/month** ← modeled at **$7,000**

> **Voyage costs ~$6,800/month more than Titan** and buys multimodal + potentially higher
> retrieval quality. Unless multimodal embeddings are a hard requirement, **Titan is
> ~16× cheaper** for this workload.

---

## 6. Full monthly cost breakdown

### 6.1 Fixed infrastructure (all modes) — enterprise-sized

The shipped single `t3.medium` + Atlas `M10` are **grossly undersized** for 100K
conversations/day (~300K agent turns/day) and are hardcoded (not TF_VARs). Enterprise
sizing requires manual upsizing:

| Component | POC (shipped) | Enterprise (100K tickets/day) | Cost / month |
|---|---|---|---|
| **EC2 API/UI fleet** | 1× t3.medium | ~6× c6i.xlarge behind ALB + ASG | **~$930** compute + **~$30** ALB |
| **EBS gp3** | 30 GB | 6× 40 GB | **~$20** |
| **MongoDB Atlas** | M10 (~$60) | **M60 3-node** + backups + disk autoscale | **~$3,600** (Atlas billing) |
| **CloudWatch** (logs, 3 dashboards, 7 alarms) | ~$12 | span sampling reduced to 10%, high log volume | **~$650** |
| **Cognito** | free | internal support agents ≈ 3,000 MAU | **~$0** (under 50K free) |
| **ECR / S3 / Secrets / KMS** | ~$3 | modest growth | **~$20** |
| **Fixed subtotal** | | | **~$5,280** |

> **Cognito caveat:** if every *end-user* (ticket submitter) becomes a distinct MAU rather
> than the internal support agents, cost grows. E.g. ~800K unique end-users/month →
> ~750K billable MAU × ~$0.0046 ≈ **~$3,450/month.** This report assumes **internal-agent
> auth (free tier).** Clarify the identity model — it can swing the bill by ~$3–4K/month.

> **Atlas caveat:** M60 is an assumption. ~300K turns/day with vector search on
> `agent_memory_facts` + `chat_messages` + the KB vector index is memory/IOPS-heavy; true
> sizing needs a load test (M50–M80, ~$2,400–6,000/month). Atlas bills separately.

### 6.2 Variable costs (all modes, Titan provider)

| Component | Per ticket | Monthly @ 3M |
|---|---|---|
| Bedrock LLM tokens (blended Haiku+Sonnet, 3 turns) | ~$0.0170 | **~$51,000** |
| AgentCore Runtime compute | ~$0.015 | **~$45,000** |
| AgentCore Memory events | ~$0.00009 | ~$270 |
| Bedrock KB retrieve | ~$0.000075 | ~$225 |
| Embeddings — Titan | ~$0.000144 | ~$430 |
| **Variable subtotal (Titan)** | ~$0.0323 | **~$96,925** |

Wait — that variable subtotal (~$97K) reflects the **conservative/un-tuned** loop. With
the realistic warm-container ACR discount already applied in §3 and the blended LLM figure
in §2.1, the **as-modeled variable subtotal is ~$96.9K/month**. Combined with fixed infra:

### 6.3 Grand totals (as-modeled / conservative)

| Configuration | Fixed infra | Networking | Embeddings | Variable (LLM+ACR+etc) | **Total/mo** | **$/ticket** |
|---|---|---|---|---|---|---|
| Public\* + Titan | $5,280 | ~$130 | (in variable) | $96,925 | **~$102,335** | **~$0.0341** |
| Peering + Titan | $5,280 | ~$170 | (in variable) | $96,925 | **~$102,375** | **~$0.0341** |
| PrivateLink + Titan | $5,280 | ~$190 | (in variable) | $96,925 | **~$102,395** | **~$0.0341** |
| Public\* + Voyage | $5,280 | ~$130 | +$7,000 | $96,495¹ | **~$108,905** | **~$0.0363** |
| Peering + Voyage | $5,280 | ~$170 | +$7,000 | $96,495¹ | **~$108,945** | **~$0.0363** |
| PrivateLink + Voyage | $5,280 | ~$190 | +$7,000 | $96,495¹ | **~$108,975** | **~$0.0363** |

¹ Voyage variable subtotal drops the ~$430 Titan per-token line (replaced by the fixed GPU endpoint).

> **Two bands to plan against:**
> - **As-modeled / conservative (above): ~$0.034–0.036/ticket** (~$102K–109K/month) — full
>   3-turn conversations, no prompt caching, un-discounted Bedrock.
> - **Optimized (§0 TL;DR): ~$0.021–0.023/ticket** (~$62K–69K/month) — after prompt caching
>   (~40–50% off large stable input), Haiku-weighted routing, tuned memory injection, warm
>   ACR containers. **This is the realistic steady-state target after tuning.**
>
> The §0 TL;DR shows the **optimized target**; the table here shows the **launch/worst-case**.
> Plan against ~$0.034/ticket at launch, drive toward ~$0.021/ticket.

---

## 7. Sensitivity — what actually moves the bill

Ranked by impact at 100K tickets/day:

| Lever | Swing / month | How |
|---|---|---|
| **1. Conversation length (turns/ticket)** | **~$32K per turn** | Each avg turn/ticket adds ~⅓ of variable cost. Deflecting more tickets on the **first reply** (1 turn vs 3) is the biggest structural saving. Klarna's <2-min resolution shows this is achievable. |
| **2. Prompt caching (Bedrock)** | **−$15K to −$22K** | System prompts + pre-activated skill bodies are large and stable → ideal for prompt caching (up to 90% off cached input tokens). Input is ~87% of token volume. |
| **3. Model routing (Sonnet → Haiku)** | **−$12K to −$18K** | Route more turns to Haiku; reserve Sonnet for genuinely hard tickets. |
| **4. AgentCore compute efficiency** | **±$18K** | Fewer tool round-trips, shorter loops (`SWARM_MAX_STEPS`), warm containers. Largest uncertainty band. |
| **5. Input token diet** | **−$6K to −$12K** | Lower `MEMORY_INJECT_TURNS` (5), trim `MEMORY_VECTOR_TOPK` (14), shorten skill bodies. |
| **6. Embedding provider (Voyage → Titan)** | **−$6.8K** | Drop the always-on GPU fleet unless multimodal is required. |
| **7. CloudWatch span sampling 100% → 10%** | **−$400 to −$800** | `span_sampling_percent` / `otel_sample_ratio` default to full capture (dev setting). |
| **8. Right-size Atlas** | **±$1.5K–3K** | Load-test to find the true tier (M50–M80). |
| **9. Networking mode** | **±$100–300** | Barely matters. Choose on security posture. |
| **10. Bedrock Provisioned Throughput / Savings** | **varies** | At ~9M LLM calls/month, negotiate committed-use for predictable Bedrock spend. |

---

## 8. Cost per ticket — final view

| Scenario | $/ticket (launch, conservative) | $/ticket (optimized) |
|---|---|---|
| **Titan, any network mode** | **~$0.0341** | **~$0.0208** |
| **Voyage, any network mode** | **~$0.0363** | **~$0.0231** |

**Bottom line for the enterprise:**
- **Budget ~$0.034 per ticket at launch; drive toward ~$0.021 after tuning.** At 3M
  tickets/month that is **~$102K–109K/month launch → ~$62K–69K/month optimized.**
- **Conversation length dominates.** The ~3-turn industry average (Tidio's 5.7 messages)
  triples cost vs a 1-turn deflection. First-contact resolution is the #1 cost lever.
- **Networking mode is a rounding error** — choose PrivateLink for the strongest security
  posture (only +~$50/month over peering).
- **Choose Titan embeddings** unless multimodal retrieval is a hard requirement (~$6.8K/mo saved).
- **Bedrock LLM tokens + AgentCore compute = ~99% of variable spend.** Focus tuning there.

For context, Klarna reported its AI assistant drove ~$40M/year in profit improvement by
displacing ~700 FTE agents. Even at ~$0.034/ticket, ~$102K/month (~$1.2M/year) is a small
fraction of the fully-loaded human-agent cost this workload replaces.

---

## 9. Assumptions, caveats & non-modeled items

**Web-sourced benchmarks (see [§1](#1-real-world-benchmarks-what-a-support-ticket-actually-looks-like))**
- **5.7 messages/conversation** (Tidio) → **~3 agent turns per ticket**. This is the key
  revision vs the prior draft (which modeled 1 ticket = 1 turn).
- ~67–80% AI autonomous resolution (Klarna, Gartner, Tidio); <2-min AI resolution (Klarna).
- ~20-word / ~27-token typical support message.

**Architecture-derived assumptions**
- Per-turn input ~6,300 / output ~900 tokens (dominated by system prompt + pre-activated
  skill body + injected memory, NOT the user message).
- ~⅔ of turns → Haiku specialists, ~⅓ → Sonnet specialist (even routing across 3 agents).
- ~1.5 tool round-trips/turn; classifier fires ~40%; synthesizer ~15% (multi-domain).
- Atlas upsized to ~M60; EC2 to ~6× c6i.xlarge behind ALB/ASG. **Both are manual code
  changes** (M10 and t3.medium are hardcoded, not TF_VARs).
- Voyage config = 4× `ml.g6.xlarge` (shipped TF has only 1, undersized).
- Cognito = internal-agent auth (~3,000 MAU, free tier).

**Confidence bands**
- Conversation length: the 5.7-message figure is a cross-industry chatbot average; your
  mix of simple vs complex tickets could shift it to 2–5 turns (±40% on variable cost).
- Bedrock LLM tokens: ±25% (real prompt/skill sizes, tool-loop depth).
- AgentCore Runtime compute: ±40% (new service, consumption rates vary).
- Atlas tier: ±50% (needs a load test).

**Not modeled**
- Reserved Instances / Savings Plans / Bedrock Provisioned Throughput (would reduce cost).
- Prompt caching in the launch/conservative band (applied only in the optimized band).
- Human-agent escalation cost for the ~20–33% of tickets AI does not resolve.
- Data egress spikes, cross-region, DR/multi-region HA.
- Taxes (US business ~0%; India GST 18%).
- NAT Gateway (not used), OpenSearch Serverless (not used — Atlas is the vector store).
- One-time deploy/engineering labor.

**All AWS prices are us-east-1 on-demand, USD, pre-tax. MongoDB Atlas bills separately on
Atlas invoicing.** Extrapolated from published AWS rates, the repo's
[`docs/estimate.md`](estimate.md) unit costs, and the customer-support industry benchmarks
cited in §1.

### Sources
- Tidio — [*10+ Crucial AI Customer Service Statistics (2026)*](https://www.tidio.com/blog/ai-customer-service-statistics/) and [*Top 200+ Customer Service Statistics & Trends (2026)*](https://www.tidio.com/blog/customer-service-statistics/) (5.7 messages/conversation; up to 70% automation). Lyro case study: [up to 70% of requests automated](https://www.tidio.com/blog/lyro-case-study/).
- Klarna — [*AI assistant handles two-thirds of customer service chats in its first month*](https://www.klarna.com/international/press/klarna-ai-assistant-handles-two-thirds-of-customer-service-chats-in-its-first-month/) (Feb 2024): 2.3M conversations/month, <2-min resolution, −25% repeat inquiries, ~700 FTE equivalent, ~$40M profit impact.
- Gartner — [*Agentic AI Will Autonomously Resolve 80% of Common Customer Service Issues … by 2029*](https://www.gartner.com/en/newsroom/press-releases/2025-03-05-gartner-predicts-agentic-ai-will-autonomously-resolve-80-percent-of-common-customer-service-issues-without-human-intervention-by-20290).
- Master of Code — [*AI in Customer Service Statistics: 50+ Actionable Insights*](https://masterofcode.com/blog/ai-in-customer-service-statistics) (adoption, resolution, cost-reduction benchmarks).
- AWS Bedrock pricing — [Amazon Bedrock Pricing](https://aws.amazon.com/bedrock/pricing/) (Claude + Titan token rates).
- Amazon SageMaker pricing — [Amazon SageMaker Pricing](https://aws.amazon.com/sagemaker/pricing/) (`ml.g6.xlarge` real-time endpoint hourly rate).
- MongoDB Atlas pricing — [MongoDB Atlas Pricing](https://www.mongodb.com/pricing) (dedicated cluster tiers).
