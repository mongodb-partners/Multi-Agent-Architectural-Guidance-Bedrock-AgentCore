# Skills Authoring Guide

Skills are the primary mechanism for giving agents domain expertise. This guide explains the `SKILL.md` format, how skills are loaded and used at runtime, and how to write skills that produce accurate, consistent agent behavior.

---

## What a Skill Is

A skill is a markdown file that tells an agent **what it knows** and **how to act** in a specific domain. It replaces the need to encode domain logic in code. When a user message matches a domain, the agent loads the skill into its context and follows the instructions there to respond.

The skill format follows the [agentskills.io open specification](https://agentskills.io/specification). It uses YAML frontmatter for metadata and markdown prose for instructions.

A skill is intentionally **not** code. It is natural language guidance, structured enough for an agent to follow precisely, human enough to be written and reviewed by domain experts without programming knowledge.

---

## File Structure

```
config/skills/<skill-name>/
├── SKILL.md              ← required. instructions and how-to content
├── http-tools.json       ← optional. HTTPS tools (e.g. Lambda URLs) for this skill
├── references/           ← optional. detailed reference docs
│   ├── schema.md
│   ├── error-codes.md
│   └── api-reference.md
└── scripts/              ← optional. reusable helper scripts (.mjs policy, etc.)
    └── validate-input.mjs
```

The `SKILL.md` file is always loaded when the skill is activated. Files in `references/` are loaded on demand — only when the agent explicitly requests them during a conversation. Keep `SKILL.md` focused and delegate detail to `references/`.

**`http-tools.json`** (optional) declares Strands tools that invoke **HTTPS endpoints** — typically **AWS Lambda Function URLs** or **API Gateway** HTTP APIs. Same trust model as `scripts/*.mjs`: colocated with the skill, reviewed like code. Agents enable each tool by listing **`skill-folder/localToolName`** in `.agent.md` `tools:` (e.g. `order-management/notify_fulfillment_lambda`). The skill must be **allowed and activated** before a call succeeds (like `read_skill_resource`). SSRF **host allowlists** belong in repo-root `config/http-tools.json` → `security`. Details: [Configuration Guide](configuration-guide.md#http-tools-lambda--api-gateway).

**Minimal `http-tools.json` example** (inside a skill folder):

```json
{
  "tools": [
    {
      "name": "notify_fulfillment_lambda",
      "description": "POST order event to the fulfillment Lambda.",
      "method": "POST",
      "url": "${ORDER_NOTIFY_LAMBDA_URL}",
      "parameters": [
        { "name": "orderId", "type": "string", "description": "Order ID", "required": true },
        { "name": "event",   "type": "string", "description": "e.g. shipped, cancelled", "required": true }
      ]
    }
  ]
}
```

- **`url`** supports `${ENV_VAR}` expansion (resolved from `process.env` at call time).
- **`parameters`** become the Zod input schema the model sees. Use `"passThroughBody": true` instead when the Lambda expects an arbitrary JSON object.
- **`headers`** (optional) also support `${ENV_VAR}` — e.g. `"Authorization": "Bearer ${MY_TOKEN}"`.
- Set **`HTTP_TOOLS_MOCK=1`** to skip real HTTP during local dev / CI.

---

## SKILL.md Format

### Frontmatter

Every `SKILL.md` starts with a YAML frontmatter block:

```yaml
---
name: order-management
version: "1.0"
description: >-
  Handles order lookups, status checks, tracking updates, cancellations, and
  return requests for logged-in customers. Use this skill whenever the user
  asks about a specific order, a list of their orders, or a return.
tags: [orders, fulfillment, returns]
resources:
  - name: Order Schema
    file: references/order-schema.md
    description: Field definitions and status enum values for the orders collection
  - name: Return Policy
    file: references/return-policy.md
    description: Return eligibility rules and processing times
scripts:
  - name: validate-return
    file: scripts/validate-return.mjs
    description: Pure JS policy; API loads via run_skill_script tool (dynamic import)
---
```

**Frontmatter fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique slug matching the directory name |
| `version` | No | Semantic version. Used for changelog tracking. |
| `description` | Yes | When to activate this skill. The orchestrator reads this to decide routing. Write it carefully. |
| `tags` | No | Keywords for discoverability |
| `resources` | No | List of reference files in `references/`. Loaded on demand. |
| `scripts` | No | Optional scripts in `scripts/` — e.g. `.mjs` policy loaded by the API, or assets the agent reads via `read_skill_resource`; Code Interpreter is planned for heavier runs. |

### Body

The body is the instruction content the agent receives. Use standard markdown headings to organize sections.

A well-structured body has:

1. **Overview** — what the agent can do with this skill
2. **Data available** — what collections or APIs are accessible and what they contain
3. **How-to sections** — step-by-step instructions for each common task
4. **Edge cases** — what to do when data is missing, ambiguous, or out of scope
5. **Boundaries** — what this skill does *not* handle, and what to do instead

---

## Progressive Disclosure

Skills use three loading levels to manage context window size:

| Level | What is loaded | When | How |
|-------|---------------|------|-----|
| **Discovery** | `name` and `description` only (~100 tokens each) | Every turn, for every agent | Injected automatically into the system prompt as a compact index |
| **Activation** | Full `SKILL.md` body | When the agent decides the domain is relevant | Specialist agents pre-activate their own skills before the first model call. The orchestrator and any agent can also call `activate_skill` at runtime. |
| **On-demand** | Files in `references/` and `scripts/` | When the agent needs deeper context | Agent calls `read_skill_resource` with `skillName` + relative `path` only after that skill is **activated** (specialist pre-load or `activate_skill`) and **allowed** for the agent |
| **HTTP tools** | `http-tools.json` in the skill folder | When the agent must call a Lambda/API over HTTPS | Agent calls tools named **`skill-folder/localName`** listed in `.agent.md` `tools:`; same **allowed + activated** gates as `read_skill_resource` |

**How activation works in practice:**

- **Specialist agents** (e.g. `order-management`) pre-activate all their listed skills before the first model call. The full `SKILL.md` body is in the system prompt from the start.
- **The orchestrator** (no `skills:` listed) gets the discovery index only — a compact list of all skill names and descriptions so it can route intelligently.
- **At runtime**, any agent can call the `activate_skill` tool to load a skill body mid-conversation. The full instructions are returned in the tool result and the model uses them immediately.

This means you can have detailed, lengthy reference material without inflating the context for every message. The agent will ask for a reference file only when it encounters a situation that needs it.

In the skill body, signal to the agent when to load a reference file:

```markdown
## Handling Unusual Statuses

If you encounter a status code not described here, use read_skill_resource
with skillName "order-management" and path "references/order-schema.md"
(after this skill is activated — automatic for the order-management specialist).
```

---

## Writing Good Skill Instructions

### Be specific about data access

Don't say "look up the order". Say exactly which collection to query and which fields to use:

```markdown
## Looking Up an Order

To find a specific order, query the `orders` collection:
- Use `orderId` if the user provides an order number
- Use `customerId` + sort by `createdAt` descending if the user asks for recent orders
- Always include `status`, `lineItems`, `shippingAddress`, and `estimatedDelivery` in the projection
```

### Tell the agent what to do with what it finds

Don't assume the agent knows how to format a result. Be explicit:

```markdown
## Presenting Order Status

After retrieving an order:
1. Lead with the current status in plain language (not the raw enum value)
2. Show estimated delivery date if status is SHIPPED or IN_TRANSIT
3. Show tracking number only if the user explicitly asks for it
4. If status is CANCELLED, always mention the refund timeline
```

### Define the boundaries

Specify what this skill does not do and what happens instead:

```markdown
## Out of Scope

This skill handles order status, tracking, and returns only.

- Billing disputes → hand off to `billing-agent`
- Product questions about items in an order → hand off to `product-agent`
- Complaints about delivery experience → acknowledge and escalate to `support-agent`
```

### Document edge cases explicitly

Edge cases are where agents fail most often without guidance:

```markdown
## Edge Cases

**Order not found:** The customer may have used a different email. Ask them to
confirm the email on their account before saying the order doesn't exist.

**Multiple matching orders:** Ask the user to confirm the order date or item
description before proceeding.

**Order in HOLD status:** Do not reveal the hold reason. Tell the customer
their order is being reviewed and suggest they contact support if urgent.
```

---

## Example: Full SKILL.md

```markdown
---
name: product-recommendation
version: "1.0"
description: >-
  Recommends products based on user preferences, browsing history, and semantic
  similarity. Use this skill when the user is looking for a product, asking
  "what should I buy", or requesting alternatives to something they already have.
tags: [products, recommendations, search]
resources:
  - name: Product Catalog Schema
    file: references/product-schema.md
    description: Field definitions, category taxonomy, and attribute types
---

# Product Recommendation Skill

## What You Can Do

Find products from the MongoDB Atlas `products` collection using semantic
vector search. Use the user's intent, stated preferences, and conversation
history to generate relevant recommendations.

## Finding Products

Use the `mongodb_vector_search` tool to find semantically similar products.
Pass a natural language description of what the user wants as the query.

Include these fields in the result: `name`, `description`, `price`,
`category`, `rating`, `inStock`.

Only return products where `inStock` is true unless the user explicitly
asks to see out-of-stock items.

## Personalizing Recommendations

Check long-term memory for previously stated preferences before running
search. If preferences exist, weight the search query to reflect them.

If the user has viewed or purchased products in this session, factor those
into the next recommendation.

## Presenting Results

- Present at most 3 products per response unless the user asks for more
- Lead with the most relevant one and explain briefly why it fits their need
- Always mention price and in-stock status
- If all results are expensive, acknowledge that and offer to search a lower
  price range

## Edge Cases

**No results found:** Broaden the search query and try again once. If still
no results, ask the user to describe their need differently.

**User wants a brand you don't carry:** Acknowledge it honestly and offer
the closest alternative. Do not fabricate a product.

**User is comparing options:** Use `mongodb_vector_search` for each option
and present side-by-side, highlighting the key differentiator.

## Out of Scope

This skill covers product discovery only.
- Purchasing → not handled by this framework
- Price negotiation → decline politely
- Inventory forecasting → hand off to `inventory-agent` if present
```

---

## Reference Files

Reference files live in `references/` and are loaded only when the agent requests them. Use them for:

- **Schema documentation** — field names, types, enum values, examples
- **Policy documents** — business rules that are too long to include in the main skill
- **API references** — external service call formats and response structures
- **Lookup tables** — error codes, status mappings, country codes

A reference file is plain markdown. There is no special format requirement beyond being human-readable and useful to an LLM.

```markdown
# Order Status Reference

| Status | Meaning | Next Possible Statuses |
|--------|---------|----------------------|
| PENDING | Order received, not yet processed | PROCESSING, CANCELLED |
| PROCESSING | Being picked and packed | SHIPPED, CANCELLED |
| SHIPPED | In transit with carrier | DELIVERED, RETURNED |
| DELIVERED | Confirmed delivered | RETURNED |
| CANCELLED | Cancelled before shipment | — |
| RETURNED | Return accepted | — |
```

---

## Scripts

Scripts live in `scripts/`. Deterministic policy can be **ESM (`.mjs`)** exported functions that the API imports via the generic **`run_skill_script`** tool (see `validate-return.mjs`). Heavier automation can later use the AgentCore Code Interpreter. Use scripts for:

- Input validation with complex rules
- Multi-step data transformations
- Formatted report generation
- Integration with external APIs

In the skill body, tell the agent when to use a script:

```markdown
## Validating a Return Request

Before telling a user their return is eligible, call **`run_skill_script`** with
`skillName='order-management'`, `scriptPath='scripts/validate-return.mjs'`,
`exportName='validateReturnEligibility'`, `args={…order object}`. Do not confirm
eligibility from memory alone — always run the validation.
```

Scripts should be narrow and deterministic. They should not make decisions — that is the agent's job. They should perform a calculation or lookup and return a structured result.

> **AgentCore Code Interpreter** (Phase 4 — not yet wired) will provide a sandbox for heavier scripts that need network access, file I/O, or longer runtimes. Until then, `.mjs` scripts via `run_skill_script` cover most policy-as-code use cases.

---

## Skill Quality Checklist

Before committing a skill, verify:

- [ ] `description` is specific enough to distinguish this skill from others
- [ ] Every common user request for this domain is covered with step-by-step instructions
- [ ] Edge cases are listed with explicit handling instructions
- [ ] Boundaries are defined — what the skill does NOT do, and where to hand off
- [ ] Reference files are referenced from the body so the agent knows when to load them
- [ ] The `SKILL.md` body is under 500 lines (move detail to `references/`)
- [ ] Instructions do not contradict each other
- [ ] No hardcoded values that will change (use references or the schema doc instead)

---

## Sharing Instructions Across Skills

Some instructions are relevant to multiple skills — tone guidelines, PII handling rules, or a shared escalation policy. Rather than duplicating them, put the shared content in a reference file and instruct each skill to load it.

**1. Create a shared reference file:**

```
config/skills/_shared/
└── tone-and-escalation.md
```

**2. Declare it in each skill's frontmatter:**

```yaml
resources:
  - name: Tone and Escalation Policy
    file: ../../_shared/tone-and-escalation.md
    description: Shared tone guidelines and escalation rules for all agents
```

**3. Tell the agent when to load it in the skill body:**

```markdown
## Communication Style

Follow the Tone and Escalation Policy reference for all response formatting
and escalation decisions.
```

Keep shared files narrow and stable. They are loaded on demand, so changes affect every skill that references them — test across all dependent agents before deploying.

---

## Testing a Skill Locally

Validate skill files without a full deployment:

```bash
# Type-check and schema-validate all config files (no model call)
cd api && bun run typecheck && bun run validate:bun && bun run validate:agentcore

# Start the API in stub mode — no Bedrock call, instant responses
cd api && bun run dev

# Smoke-test skill loading via the API
curl -s http://127.0.0.1:3000/skills
curl -s http://127.0.0.1:3000/agents          # agents show their skills list
curl -s http://127.0.0.1:3000/http-tools       # per-skill HTTP tools metadata
```

The **`GET /skills`** endpoint returns the discovery index (name + description) for all scanned skills. Config is loaded from disk **on each request**, so edits to `SKILL.md` are picked up immediately without a restart.

To test with mock backends (no AWS required):

```bash
export CHAT_MODE=live
export DEV_MOCK_BACKENDS=1
cd api && bun run dev
```

This uses `DevMockModel` (deterministic routing and tool calls) with fixture data from `data/dev/mongo-fixtures.json`.

To test with a real Bedrock model (requires AWS credentials):

```bash
export CHAT_MODE=live
export AWS_REGION=us-east-1
cd api && bun run dev
```

Then send a chat request to an agent that uses the skill and verify the model follows the instructions in the body. Check the SSE stream for `skill_loaded` events — one is emitted for each skill that was activated before the model call.

---

## Versioning and Iteration

Skills should be treated as living documents. After each deployment, review conversation logs for patterns where the agent:

- Gave a wrong answer that the skill should have prevented
- Asked for information it could have found itself
- Went out of scope when the skill should have bounded it

Update `SKILL.md` in response to these patterns. Increment the `version` field and add a changelog comment at the top:

```markdown
---
name: order-management
version: "1.2"
# Changelog:
# 1.2 - Added HOLD status edge case. Clarified return eligibility check requires script.
# 1.1 - Added multiple-matching-orders edge case.
# 1.0 - Initial version.
---
```

Changes to `description` are high-impact — the orchestrator uses this field to decide when to activate the skill. Test routing behavior after any `description` change.

---

## Observability while authoring

While you iterate, every chat turn against your skill produces a
[trace](api-reference.md#13-tracing-endpoints). The Streamlit Trace
Viewer shows, per turn:

- `skill.activated` — which skills were loaded into the prompt (so you can
  confirm your skill is actually being picked up).
- `tool.call` / `tool.http` / `tool.mcp` — every tool invocation your skill
  triggered, with arguments, latency, status, and (for HTTP) response
  snippets with redacted headers.
- `mongo.intent` → `mongo.query` → `mongo.result` (+ `mongo.diagnostic`
  when empty) — surfaces wrong filter shapes (e.g. string-vs-ObjectId,
  field not in sample) without enabling debug logging.
- `prompt.assembled` — exact breakdown of persona / memory / skills /
  auth context in the system prompt, with byte attribution.

If your skill seems "ignored", open the Trace Viewer first — usually the
`prompt.assembled` and `skill.activated` events tell you why.

See [demo-mode-guide.md](demo-mode-guide.md) for the full UI walkthrough
and env knobs (`MONGO_TRACE_DIAGNOSTIC`, `MONGO_TRACE_EXPLAIN`, etc.).

---

## Related

- [Configuration Guide](configuration-guide.md) — how to wire skills to agents
- [Architecture](architecture.md) — how the skill loader works at runtime
- [API reference](api-reference.md#13-tracing-endpoints) — trace event types
- [Demo / trace UI guide](demo-mode-guide.md) — UI walkthrough
- [agentskills.io specification](https://agentskills.io/specification) — upstream specification
