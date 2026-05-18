# Agent Authoring Guide

Agents are the specialists in this framework. Each agent owns a domain, has a distinct persona, and is equipped with the skills and tools it needs to respond accurately. This guide explains the `.agent.md` format, how agents are discovered and assembled at runtime, and how to write agent definitions that produce consistent, safe, and useful behavior.

> **Where agents run depends on the deployment mode** (see [`architecture.md` §8](architecture.md#8-two-modes-local-dev-vs-ec2-production)):
> - **Local dev** — all agents run in-process inside the Hono API via the Strands SDK. Multi-agent orchestration uses `ORCHESTRATOR_MODE=swarm`.
> - **EC2 production** — each agent runs in its own AgentCore Runtime container. The orchestrator routes by calling `InvokeAgentRuntime` on a specialist's ARN. `ORCHESTRATOR_MODE=runtime`.
>
> The `.agent.md` format below is identical in both modes. The same files drive both the in-process Strands path and the AgentCore Runtime path — only the host changes.

---

## What an Agent Is

An agent is a combination of:

- A **persona** — who the agent is, how it communicates, and what it values
- A **scope** — which domains it handles and which it does not
- **Skills** — domain knowledge packages loaded into its context
- **Tools** — built-in data capabilities (MongoDB, vector search, KB, etc.) plus optional **per-skill HTTP tools** (Lambda Function URLs / API Gateway) declared in `config/skills/<skill>/http-tools.json`
- **Handoffs** — other agents it can delegate to when a request goes out of scope

The agent's identity and behavior are defined entirely in its `.agent.md` file. The framework assembles the agent at runtime by loading the file, injecting the referenced skill instructions into the system prompt, and wiring up the listed tools.

---

## File Location and Naming

```
config/agents/
├── orchestrator.agent.md
├── order-management.agent.md
├── product-recommendation.agent.md
└── troubleshooting.agent.md
```

- One file per agent
- Filename must match the `id` field in the frontmatter
- The API rescans this directory **on each request** — edits hot-reload without restarting

---

## .agent.md Format

### Frontmatter

Every `.agent.md` file starts with a YAML frontmatter block:

```yaml
---
name: Order Management Agent
description: >-
  Handles order lookups, status checks, shipment tracking, cancellations, and
  return requests for logged-in customers.
id: order-management
skills:
  - order-management
tools:
  - mongodb_query
  - mongodb_vector_search
  - run_skill_script
  - read_skill_resource
  - order-management/notify_fulfillment_lambda   # per-skill HTTP tool (Lambda Function URL)
model: anthropic.claude-3-5-sonnet-20240620-v1:0
temperature: 0.3
memory:
  shortTerm: true
  longTerm: true
handoffs:
  - label: Billing question
    agent: billing-agent
    prompt: The customer has a billing question related to order {{ orderId }}.
  - label: Product question
    agent: product-recommendation
    prompt: The customer wants to know more about a product from their order.
---
```

**Frontmatter fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Display name shown in the UI and logs |
| `description` | Yes | One or two sentences describing what this agent handles. The orchestrator reads this to decide routing. |
| `id` | Yes | Unique slug. Must match the filename (without `.agent.md`). |
| `skills` | Yes | List of skill names. Instructions from each skill's `SKILL.md` are injected into the system prompt. |
| `tools` | Yes | Tool names the agent can call: built-ins (`mongodb_query`, …), `read_skill_resource`, `run_skill_script`, optional **skill HTTP tools** as **`skill-folder/localToolName`** (e.g. `order-management/notify_fulfillment_lambda`), and optional **global** HTTP tools by short name from root `config/http-tools.json`. See [Available Tools](#available-tools). |
| `model` | No | Bedrock model ID. Defaults to the configured global model. |
| `maxTokens` | No | Maximum tokens per response. Default: 4096. |
| `temperature` | No | Sampling temperature (0–1). Lower = more precise. Default: 0.7. |
| `memory.shortTerm` | No | Enable replay of prior turns for the same `sessionId`. Default: true. Runtime backend is controlled by API env (`SHORT_TERM_MEMORY_BACKEND=agentcore` in EC2 auth mode, with `session-store`/Mongo fallback), not by this flag. |
| `memory.longTerm` | No | Enable cross-session personalization memory. Default: true. |
| `handoffs` | No | Agents this agent can delegate to. See [Handoffs](#handoffs) below. Omit the key (or use `[]`) when there are none — the runtime defaults to no handoffs. |

You can omit **`maxTokens`** (defaults to **4096**), **`temperature`** when **0.7** matches your needs, and **`handoffs`** when the list is empty. Override only what differs.

### Body

The markdown body becomes the agent's base system prompt. The framework appends loaded skill instructions after this content.

Structure the body to cover:

1. **Role statement** — who the agent is in one sentence
2. **Purpose** — what it exists to do for the user
3. **Tone and style** — how it communicates
4. **Guardrails** — what it never does
5. **Escalation** — when to use handoffs

---

## Writing the Agent Persona

### Role statement

Start with a clear, direct statement of the agent's role. Avoid vague phrases like "helpful assistant". Be specific about the domain.

```markdown
You are the Order Management specialist for Acme Commerce. Your sole focus is
helping customers with their orders: finding them, checking their status,
tracking shipments, processing cancellations, and initiating returns.
```

### Tone and style

Define how the agent communicates. Different domains warrant different tones — a troubleshooting agent should be methodical and calm; a product recommendation agent can be warmer and more conversational.

```markdown
## Communication Style

- Be direct and factual. Customers asking about orders are often anxious — get to the answer quickly.
- Use plain language. Avoid internal status codes and jargon.
- Acknowledge frustration before jumping to solutions when an order is delayed or missing.
- Keep responses concise. If there are multiple pieces of information, use a short list.
```

### Guardrails

Explicit guardrails prevent the agent from drifting into territory it should not cover. State them as firm constraints.

```markdown
## Boundaries

- Handle order-related questions only. If the user asks about products, billing,
  or account management, use the appropriate handoff — do not attempt to answer.
- Never fabricate order data. If a query returns no results, say so honestly and
  suggest the user verify their order number or email.
- Never reveal internal system details, query structures, or error messages to users.
- Do not offer compensation, refunds, or exceptions without explicit policy backing
  from the skill instructions.
```

### Escalation

Tell the agent when to use handoffs. Be specific — vague conditions lead to missed handoffs.

```markdown
## When to Hand Off

- The user asks about a product from their order → hand off to Product Recommendation
- The user disputes a charge → hand off to Billing
- The issue cannot be resolved with available tools → acknowledge limitations and
  suggest the user contact human support
```

---

## Handoffs

Handoffs allow an agent to delegate a conversation to another agent when the request goes out of scope. They appear as action buttons in the Streamlit UI, and can also be triggered automatically by the agent.

```yaml
handoffs:
  - label: Product question          # Text shown on the button in the UI
    agent: product-recommendation    # id of the target agent
    prompt: >-
      The customer is asking about {{ productName }} from order {{ orderId }}.
      Continue from this context.
```

**Tips for effective handoffs:**

- The `prompt` is passed to the receiving agent as context. Include the relevant entities (order ID, product name, issue description) so the receiving agent does not have to ask the user to repeat themselves.
- Use template variables (`{{ variableName }}`) to inject runtime values. The framework fills these from the current conversation context.
- Define handoffs symmetrically — if Order Management can hand off to Billing, consider whether Billing should be able to hand back.
- Avoid creating circular handoffs between two agents without a resolution path.

---

## Skills and Scope

Each agent should reference the skills that match its domain. A skill gives the agent step-by-step instructions for handling specific requests — without that guidance, the agent falls back to general LLM behavior, which is less accurate and less consistent.

```yaml
skills:
  - order-management        # primary domain
  - return-policy           # secondary — loaded when return topics arise
```

**How skills are loaded at runtime:**

- **Specialist agents** (any agent with a non-empty `skills:` list) have all their listed skills **pre-activated** before the first model call. The full `SKILL.md` body of every listed skill is injected into the system prompt.
- **The orchestrator** (empty `skills: []`) receives only the **discovery index** — a compact list of every skill's `name` and `description`. This keeps its context small and focused on routing.
- **Any agent** can call the `activate_skill` tool at runtime to load a skill body mid-conversation. The runtime emits a `skill_loaded` SSE event when this happens.

Keep the total number of skills per agent to three or fewer to avoid context bloat. If more are needed, consider whether the agent's scope is too broad and should be split.

See the [Skills Authoring Guide](skills-authoring-guide.md) for how to write skill instructions.

---

## Available Tools

Tools include **built-in** Strands tools (MongoDB, KB, embeddings, …), **skill-bound** helpers (`read_skill_resource`, `run_skill_script`, per-skill HTTP tools), and optional **global** HTTP tools. Agents use them as directed by their skill instructions — the skill tells the agent *when* and *how* to call each tool.

| Tool | What it does | Status |
|------|-------------|--------|
| `activate_skill` | Loads the full `SKILL.md` body for a named skill into the current context | Always registered (not listed in `tools:`) |
| `read_skill_resource` | Loads a file from `references/` or `scripts/` under a skill; **skill must be on this agent's `skills:` list and activated** | Live |
| `run_skill_script` | Dynamically imports `scripts/*.mjs` for a **skillName** + args; same allowlist/activation as `read_skill_resource` | Live |
| **`{skill}/{localName}`** | **Per-skill HTTP tool** — `POST`/`GET`/… to a URL (e.g. Lambda Function URL). Defined in `config/skills/<skill>/http-tools.json`. Listed in `tools:` as **`order-management/notify_fulfillment_lambda`**. Same **allowlist + activation** as `read_skill_resource`. SSRF allowlists live in root `config/http-tools.json` → `security`. | Live — see [Configuration Guide](configuration-guide.md#http-tools-lambda--api-gateway) |
| **Short name** (no `/`) | **Global HTTP tool** from root `config/http-tools.json` → `tools` (optional). No skill activation gate. | Live |
| `mongodb_query` | Runs find / findOne / aggregate / updateOne against MongoDB | Live — proxied through the dedicated MongoDB MCP AgentCore Runtime |
| `mongodb_vector_search` | Performs semantic/vector search against a MongoDB Atlas collection | Live — Atlas `$vectorSearch` via the same MongoDB MCP runtime |
| `bedrock_kb_retrieve` | Retrieves passages from a Bedrock Knowledge Base | Live — real Bedrock KB when `BEDROCK_KB_ID` + AWS credentials set |
| `generate_embedding` | Generates a text embedding via Amazon Bedrock (Titan / Cohere) | Live — real Bedrock embedding when `EMBEDDING_MODEL_ID` + AWS credentials set |

**Notes:**

- `activate_skill` is registered for every agent automatically. You do not list it in `tools:`.
- All Mongo-shaped tools resolve to MCP tool calls against the MongoDB MCP AgentCore Runtime (`MONGODB_MCP_RUNTIME_ARN` / `MONGODB_MCP_RUNTIME_ENDPOINT`). The agent runtime never opens a MongoDB connection itself.
- **`HTTP_TOOLS_MOCK=1`** skips real outbound HTTP for all HTTP tools (skill + global); useful for demos without Lambda deployed. **`GET /http-tools`** lists configured tools (see [API Reference](api-reference.md#list-http-tools-lambda--api-config)).

Only list tools that the agent's skills actually use. Giving an agent tools it has no instructions for does not add capability — it adds surface area for unexpected behavior.

---

## The Orchestrator Agent

The orchestrator is a special agent that receives every incoming message and routes it to the right specialist. It does not answer domain questions directly.

When writing the orchestrator agent definition:

- Its `description` is less important for routing (it is the default recipient)
- Its body should describe the routing logic: how to read descriptions, when to clarify before routing, and what to do when no specialist matches
- It should have `handoffs` entries for every specialist agent
- It should not reference domain skills — its job is routing, not answering

```markdown
---
name: Orchestrator
description: Routes customer messages to the appropriate specialist agent.
id: orchestrator
skills: []
tools: []
handoffs:
  - label: Order question
    agent: order-management
    prompt: "{{ userMessage }}"
  - label: Product question
    agent: product-recommendation
    prompt: "{{ userMessage }}"
  - label: Troubleshooting
    agent: troubleshooting
    prompt: "{{ userMessage }}"
---

# Orchestrator

You receive every customer message first. Your job is to route the message to
the right specialist — not to answer it yourself.

## Routing Rules

Read the `description` of each available agent. Route the message to the agent
whose description best matches the user's intent.

If the message is ambiguous, ask one clarifying question before routing. Do not
ask more than one question.

If no specialist matches the message, tell the user clearly what the system can
help with and what it cannot.

## What You Never Do

- Answer domain questions yourself
- Make up a specialist that does not exist
- Route to a specialist and also provide your own answer
```

---

## Example: Full Agent Definition

```markdown
---
name: Troubleshooting Agent
description: >-
  Diagnoses product and service issues, walks customers through resolution steps,
  and escalates when the issue requires human intervention. Use this agent when
  the customer reports something is broken, not working, or behaving unexpectedly.
id: troubleshooting
skills:
  - troubleshooting
tools:
  - bedrock_kb_retrieve
  - mongodb_query
  - read_skill_resource
model: anthropic.claude-3-5-sonnet-20240620-v1:0
temperature: 0.2
memory:
  shortTerm: true
  longTerm: false
handoffs:
  - label: Replacement or refund
    agent: order-management
    prompt: >-
      The customer has a confirmed defective product ({{ productName }}) and
      needs to start a replacement or return. Issue summary: {{ issueSummary }}.
---

# Troubleshooting Agent

You are the Troubleshooting specialist. You help customers diagnose and resolve
issues with products and services.

## Communication Style

- Be calm, methodical, and patient. Customers reaching troubleshooting are often
  frustrated — validate the issue before diving into steps.
- Present resolution steps one at a time. Wait for the customer to confirm each
  step before moving to the next.
- Avoid technical jargon unless the customer demonstrates technical familiarity.

## Process

1. Understand the issue fully before suggesting a fix. Ask clarifying questions
   if necessary.
2. Search the knowledge base for known issues and documented resolutions.
3. Walk the customer through the resolution steps.
4. If the issue is unresolved after documented steps, acknowledge the limitation
   and offer escalation options.

## Boundaries

- Handle diagnostic and resolution steps only.
- Do not promise outcomes (e.g., "this will definitely fix it").
- If the issue requires a replacement or refund, use the handoff — do not try
  to process it yourself.
- Never speculate about causes if you have no knowledge base result to reference.
```

---

## Agent Quality Checklist

Before committing an agent definition, verify:

- [ ] `description` is specific enough for the orchestrator to route correctly
- [ ] `id` matches the filename exactly
- [ ] All referenced `skills` have a corresponding directory in `config/skills/`
- [ ] All listed `tools` exist: built-in names, `skill-folder/localName` for per-skill HTTP tools (matching `http-tools.json`), or global HTTP short names from root `http-tools.json`
- [ ] The body has a clear role statement, tone guidance, and guardrails
- [ ] Handoff conditions are specific, not vague
- [ ] Handoff `prompt` templates include enough context for the receiving agent
- [ ] The agent does not try to handle topics outside its scope
- [ ] `temperature` is appropriate for the domain (lower for factual/precise, higher for conversational)

---

## Adding a New Agent

1. Create `config/skills/<domain>/SKILL.md` with domain instructions (see [Skills Authoring Guide](skills-authoring-guide.md))
2. Create `config/agents/<name>.agent.md` referencing that skill
3. Save the file — the next API request picks up the new agent in the generated orchestrator roster (no restart needed)
4. Run `./deploy/deploy-agents.sh --auto-approve` when the deployed AgentCore runtimes need the new specialist

No code changes are required unless the new agent needs a tool that does not already exist in the registry.

---

## Testing an Agent Locally

Before deploying, validate an agent definition against a running local stack:

```bash
cd api && bun run typecheck          # catches frontmatter type mismatches via Zod
cd api && bun run validate:agentcore # smoke-tests BedrockAgentCoreClient on Bun (no network by default)
bun test                             # unit + integration tests
```

To test interactively against a deployed AgentCore Orchestrator runtime:

```bash
source .env && source .env.live   # exports AGENTCORE_ORCHESTRATOR_ARN
cd api && bun run dev               # starts the local API
cd ui && streamlit run app.py       # starts the Streamlit UI (separate terminal)
```

Or via Docker: `docker compose up --build` from the repo root.

See the [Configuration Guide](configuration-guide.md) and [`DEV_STATUS.md`](../DEV_STATUS.md) for env vars and local setup.

---

## Debugging Routing Failures

If a message is not reaching the intended agent, the most common causes are:

**1. The `description` is too vague or overlaps with another agent**

The orchestrator picks the agent whose `description` best matches the user's message. If two agents have similar descriptions, routing becomes unpredictable.

Fix: Make each agent's `description` precise and distinct. Include the specific entities or actions it handles. Avoid generic phrases like "helps users with questions".

**2. The agent description is not enough for routing**

The orchestrator roster is generated from every non-orchestrator `.agent.md`. If the agent exists but messages do not reach it, the generated routing corpus probably lacks distinctive words for that domain.

Fix: Make the agent's `name`, `description`, and first part of its body precise and distinct. Include the specific entities, symptoms, actions, or product area it handles.

**3. The orchestrator is answering directly instead of routing**

If the orchestrator's body system prompt says "help the user" rather than "route to a specialist", the model may answer directly.

Fix: Review the orchestrator body — it should say "your job is to route, not to answer" and list "answer domain questions yourself" under "What You Never Do".

**To trace routing in logs:**

Set `LOG_LEVEL=debug` to see per-request config-scan and skill-load events. The API emits structured JSON lines (`api/src/lib/logger.ts`). Check the Strands model output in the API console to see which agent descriptions were evaluated and which was selected. Routing scores are not yet exposed as structured fields.

---

## Versioning and Updating Agents

Agent files are plain text and tracked in git. Treat changes to `.agent.md` files as you would code changes:

- **Minor edits** (tone, wording) — update in place, bump a comment at the top, deploy
- **Skill changes** (adding or removing a skill) — test in dev first, the change alters the full system prompt
- **Handoff changes** — verify both ends: the agent being added to and the orchestrator routing to it
- **Removing an agent** — remove it from `config/agents/` and from the `handoffs` of any non-orchestrator agent that explicitly points to it

There is no built-in versioning for agent files. Use git tags or PR descriptions to document what changed and why. Include conversation log evidence when changing an agent in response to observed failures.

---

## Related

- [Skills Authoring Guide](skills-authoring-guide.md) — how to write the domain knowledge that powers agents
- [Configuration Guide](configuration-guide.md) — environment variables, model defaults, memory settings
- [Architecture](architecture.md) — how agent loading and the orchestration loop work at runtime
