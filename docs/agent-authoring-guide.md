# Agent Authoring Guide

Agents are the specialists in this framework. Each agent owns a domain, has a distinct persona, and is equipped with the skills and tools it needs to respond accurately. This guide explains the `.agent.md` format, how agents are discovered and assembled at runtime, and how to write agent definitions that produce consistent, safe, and useful behavior.

> **Where agents run depends on the deployment mode** (see [`architecture.md` §8](architecture.md#8-two-modes-local-dev-vs-ec2-production)):
> - **Local dev** — all agents run in-process inside the Hono API via the Strands SDK. Multi-agent orchestration uses `ORCHESTRATOR_MODE=swarm`.
> - **EC2 production (default)** — the Hono API classifies the message in-process (`api/src/lib/agent-classifier.ts`) using the orchestrator's `handoffs:` roster as the candidate set, then invokes the matching specialist's AgentCore Runtime directly. The orchestrator runtime is only reached when `USE_ORCHESTRATOR_RUNTIME=1` is set.
>
> The `.agent.md` format below is identical in both modes. The same files drive the in-process Strands path, the in-API classifier, and every AgentCore Runtime container — only the host changes.

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
├── job-match.agent.md
├── career-coach.agent.md
└── company-intel.agent.md
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
name: Job Match Agent
description: >-
  Matches candidate CVs to open job listings using hybrid search on the jobs
  collection, and provides interview prep from the interview_prep collection.
id: job-match
skills:
  - job-match
tools:
  - mongodb_query
  - mongodb_vector_search
  - read_skill_resource
  - job-match/notify_recruiter_lambda   # illustrative per-skill HTTP tool (Lambda Function URL)
model: global.anthropic.claude-haiku-4-5-20251001-v1:0
temperature: 0.3
memory:
  shortTerm: true
  longTerm: true
handoffs:
  - label: Company research
    agent: company-intel
    prompt: The candidate wants to know what a company behind their match is like.
  - label: Career development & compensation
    agent: career-coach
    prompt: The candidate wants a skill-gap plan or salary expectations for a role.
---
```

> The `job-match/notify_recruiter_lambda` entry is **illustrative** — no shipped skill currently defines an `http-tools.json`. It shows the `skill-folder/localToolName` syntax only.

**Frontmatter fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Display name shown in the UI and logs |
| `description` | Yes | One or two sentences describing what this agent handles. The orchestrator reads this to decide routing. |
| `id` | Yes | Unique slug. Must match the filename (without `.agent.md`). |
| `skills` | Yes | List of skill names. Instructions from each skill's `SKILL.md` are injected into the system prompt. |
| `tools` | Yes | Tool names the agent can call: built-ins (`mongodb_query`, …), `read_skill_resource`, `run_skill_script`, optional **skill HTTP tools** as **`skill-folder/localToolName`** (e.g. `job-match/notify_recruiter_lambda`), and optional **global** HTTP tools by short name from root `config/http-tools.json`. See [Available Tools](#available-tools). |
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
You are the Job Match specialist for a career and recruitment assistant. Your sole
focus is helping candidates find relevant openings that match their experience,
and preparing them for interviews.
```

### Tone and style

Define how the agent communicates. Different domains warrant different tones — a company-intel agent should be balanced and neutral; a career-coach agent can be encouraging and specific.

```markdown
## Communication Style

- Be encouraging and professional. Candidates are often anxious about job hunting — acknowledge profile strengths quickly.
- Use plain language. Avoid internal identifiers and jargon.
- Present job matches as a clear ranked list with concise explanations.
- Keep responses concise. If there are multiple results, use a short list.
```

### Guardrails

Explicit guardrails prevent the agent from drifting into territory it should not cover. State them as firm constraints.

```markdown
## Boundaries

- Handle job-matching and interview-prep questions only. If the candidate asks about
  compensation, skill gaps, or a specific company, use the appropriate handoff — do
  not attempt to answer.
- Never fabricate job listings or interview questions. If a query returns no results,
  say so honestly and suggest the candidate rephrase.
- Never reveal internal system details, query structures, or error messages to candidates.
- Never reveal raw `_id` values; use `jobId`, `prepId`, or `candidateId`.
```

### Escalation

Tell the agent when to use handoffs. Be specific — vague conditions lead to missed handoffs.

```markdown
## When to Hand Off

- The candidate asks what a company behind a match is like → hand off to Company Intel
- The candidate asks about salary or a skill-gap plan → hand off to Career Coach
- The request cannot be resolved with available tools → acknowledge limitations and
  suggest the candidate rephrase
```

---

## Handoffs

Handoffs allow an agent to delegate a conversation to another agent when the request goes out of scope. They appear as action buttons in the Streamlit UI, and can also be triggered automatically by the agent.

```yaml
handoffs:
  - label: Company research          # Text shown on the button in the UI
    agent: company-intel             # id of the target agent
    prompt: >-
      The candidate is asking about {{ companyName }} behind job {{ jobId }}.
      Continue from this context.
```

**Tips for effective handoffs:**

- The `prompt` is passed to the receiving agent as context. Include the relevant entities (job ID, company name, target role) so the receiving agent does not have to ask the candidate to repeat themselves.
- Use template variables (`{{ variableName }}`) to inject runtime values. The framework fills these from the current conversation context.
- Define handoffs symmetrically — if Job Match can hand off to Company Intel, consider whether Company Intel should be able to hand back.
- Avoid creating circular handoffs between two agents without a resolution path.

---

## Skills and Scope

Each agent should reference the skills that match its domain. A skill gives the agent step-by-step instructions for handling specific requests — without that guidance, the agent falls back to general LLM behavior, which is less accurate and less consistent.

```yaml
skills:
  - job-match               # primary domain
```

**How skills are loaded at runtime:**

- **Specialist agents** (any agent with a non-empty `skills:` list) have all their listed skills **pre-activated** before the first model call. The full `SKILL.md` body of every listed skill is injected into the system prompt.
- **The orchestrator** (empty `skills: []`) receives only the **discovery index** — a compact list of every skill's `name` and `description`. This keeps its context small and focused on routing.
- **Any agent** can call the `activate_skill` tool at runtime to load a skill body mid-conversation. The runtime emits a `skill_loaded` SSE event when this happens.

Keep the total number of skills per agent to three or fewer to avoid context bloat. If more are needed, consider whether the agent's scope is too broad and should be split.

See the [Skills Authoring Guide](skills-authoring-guide.md) for how to write skill instructions.

---

## Available Tools

Tools include **built-in** Strands tools (MongoDB, KB, embeddings, ...), **skill-bound** helpers (`read_skill_resource`, `run_skill_script`, per-skill HTTP tools), and optional **global** HTTP tools. Agents use them as directed by their skill instructions — the skill tells the agent *when* and *how* to call each tool.

> **Complete catalog:** [`reference/tools.md`](reference/tools.md) is the canonical developer reference for every supported tool, internal-only helper, runtime home, config gate, env var, and debugging surface. Keep this section as a quick orientation only.

| Tool | What it does | Status |
|------|-------------|--------|
| `activate_skill` | Loads the full `SKILL.md` body for a named skill into the current context | Always registered (not listed in `tools:`) |
| `read_skill_resource` | Loads a file from `references/` or `scripts/` under a skill; **skill must be on this agent's `skills:` list and activated** | Live |
| `run_skill_script` | Dynamically imports `scripts/*.mjs` for a **skillName** + args; same allowlist/activation as `read_skill_resource` | Live |
| **`{skill}/{localName}`** | **Per-skill HTTP tool** — `POST`/`GET`/… to a URL (e.g. Lambda Function URL). Defined in `config/skills/<skill>/http-tools.json`. Listed in `tools:` as **`job-match/notify_recruiter_lambda`** (illustrative). Same **allowlist + activation** as `read_skill_resource`. SSRF allowlists live in root `config/http-tools.json` → `security`. | Live — see [Skills authoring guide](skills-authoring-guide.md#file-structure) |
| **Short name** (no `/`) | **Global HTTP tool** from root `config/http-tools.json` → `tools` (optional). No skill activation gate. | Live |
| `mongodb_query` | Runs find / findOne / aggregate / updateOne against MongoDB | Live — proxied through AgentCore Gateway to the dedicated MongoDB MCP AgentCore Runtime |
| `mongodb_vector_search` | Performs semantic/vector search against a MongoDB Atlas collection | Live — Atlas `$vectorSearch` via the same Gateway-backed MongoDB MCP runtime |
| `bedrock_kb_retrieve` | Retrieves passages from a Bedrock Knowledge Base | Live — real Bedrock KB when `BEDROCK_KB_ID` + AWS credentials set |
| `embed_multimodal_content` | Generates an embedding for a multimodal item (text + `image_url` + `image_base64`). Single-path call to Voyage SageMaker when `EMBEDDINGS_PROVIDER=voyage`, Bedrock Titan when `=titan` (titan rejects image segments with `titan_no_multimodal`). | Live — `inputs: MultimodalItem[]` schema (z.discriminatedUnion). |

**Notes:**

- `activate_skill` is registered for every agent automatically. You do not list it in `tools:`.
- All Mongo-shaped tools resolve to MCP tool calls through AgentCore Gateway (`AGENTCORE_GATEWAY_URL`). The Gateway target invokes the MongoDB MCP AgentCore Runtime; the agent runtime never opens a MongoDB connection itself. `MCP_SERVER_URL` is local-development only.
- **`HTTP_TOOLS_MOCK=1`** skips real outbound HTTP for all HTTP tools (skill + global); useful for demos without Lambda deployed. **`GET /http-tools`** lists configured HTTP tools only (see [`api-reference.md` § `GET /http-tools`](api-reference.md#10-get-http-tools)); use [`reference/tools.md`](reference/tools.md) for the complete tool catalog.

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
description: Routes candidate messages to the appropriate specialist agent.
id: orchestrator
skills: []
tools: []
handoffs:
  - label: Job matching & interview prep
    agent: job-match
    prompt: "{{ userMessage }}"
  - label: Career development, skill gap & compensation
    agent: career-coach
    prompt: "{{ userMessage }}"
  - label: Company research
    agent: company-intel
    prompt: "{{ userMessage }}"
---

# Orchestrator

You receive every candidate message first. Your job is to route the message to
the right specialist — not to answer it yourself.

## Routing Rules

Read the `description` of each available agent. Route the message to the agent
whose description best matches the candidate's intent.

If the message is ambiguous, ask one clarifying question before routing. Do not
ask more than one question.

If no specialist matches the message, tell the candidate clearly what the system can
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
name: Company Intel Agent
description: >-
  Researches hiring companies — culture, engineering practices, funding stage,
  and employee sentiment — and grounds every claim in a retrieved document. Use
  this agent when a candidate asks about a specific company by name, whether it
  is a good place to work, or wants to compare the companies behind their matches.
id: company-intel
skills:
  - company-intel
tools:
  - bedrock_kb_retrieve
  - mongodb_query
  - mongodb_vector_search
  - read_skill_resource
model: us.anthropic.claude-sonnet-4-6
temperature: 0.3
memory:
  shortTerm: true
  longTerm: false
handoffs:
  - label: Salary or negotiation question
    agent: career-coach
    prompt: >-
      The candidate is asking about compensation at {{ companyName }} rather than
      its culture. Original question: {{ userMessage }}.
---

# Company Intel Agent

You are the Company Intel specialist. You help candidates understand what it is
actually like to work at a given company.

## Communication Style

- Be balanced and evidence-led. Candidates make life decisions on this — never
  oversell or undersell an employer.
- Present pros and cons together, in the same response, every time.
- Quote documented culture signals verbatim rather than paraphrasing them into
  stronger claims than the source supports.

## Process

1. Resolve which company the candidate means before searching. Ask if ambiguous.
2. Hybrid-search the `companies` collection; call `bedrock_kb_retrieve` for
   anything the company document does not cover.
3. Lead with the signals that match what the candidate said they want from an
   employer.
4. State `sentimentScore` alongside the summary, and flag `asOf` if the data is
   stale.

## Boundaries

- Handle company research only.
- Do not infer a company's culture from its industry, name, or funding stage.
- If the candidate asks about salary, use the handoff — compensation benchmarks
  live in `compensation_data`, not in the company profile.
- Never speculate about a company with no retrieved document to reference.
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

See the [Configuration Guide](configuration-guide.md) for `config/` wiring, [`advanced/deploy-tweak-guide.md`](advanced/deploy-tweak-guide.md) for deploy/runtime env tuning, and [`reference/env-vars.md`](reference/env-vars.md) for the full env var catalog.

---

## Debugging Routing Failures

If a message is not reaching the intended agent, the most common causes are:

**1. The `description` is too vague or overlaps with another agent**

The orchestrator picks the agent whose `description` best matches the user's message. If two agents have similar descriptions, routing becomes unpredictable.

Fix: Make each agent's `description` precise and distinct. Include the specific entities or actions it handles. Avoid generic phrases like "helps users with questions".

**2. The agent description is not enough for routing**

The orchestrator roster is generated from every non-orchestrator `.agent.md`. If the agent exists but messages do not reach it, the generated routing corpus probably lacks distinctive words for that domain.

Fix: Make the agent's `name`, `description`, and first part of its body precise and distinct. Include the specific entities, signals, actions, or domain area it handles.

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
- [Configuration Guide](configuration-guide.md) — `config/agents/` schema, model defaults, memory flags
- [Deploy Tweak Guide](advanced/deploy-tweak-guide.md) — **advanced** deploy/runtime environment variables
- [Architecture](architecture.md) — how agent loading and the orchestration loop work at runtime
