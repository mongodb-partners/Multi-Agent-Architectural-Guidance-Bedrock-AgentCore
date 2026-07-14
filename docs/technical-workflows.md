# Technical Details & Workflows

A scenario-driven walkthrough of how this framework actually works at runtime — what
gets loaded, where, and why. Each scenario traces one flow end to end through real
code. For the static per-folder map, see [PROJECT_STRUCTURE.md](../PROJECT_STRUCTURE.md);
for the product overview, [README.md](../README.md).

---

## 0. The mental model in one paragraph

Everything the agents *do* is configuration, not code. A **specialist** is a markdown
file ([config/agents/order-management.agent.md](../config/agents/order-management.agent.md)):
frontmatter picks the model + tools + skills, the body is the system prompt. A **skill**
is a folder ([config/skills/order-management/](../config/skills/order-management/)) whose
`SKILL.md` holds domain instructions loaded on demand, plus optional `scripts/`,
`references/`, and `http-tools.json`. At runtime a **Bun + Hono API** receives a chat turn,
classifies it to a specialist, and invokes that specialist as a **Bedrock AgentCore
Runtime**, streaming tokens back over SSE. MongoDB tools don't live in the agent — they're
served by a separate **MongoDB MCP AgentCore Runtime** reached through the AgentCore
Gateway. Five runtimes total: orchestrator + 3 specialists + 1 MCP.

Two processes share one code bundle in [api/](../api/):
- [api/src/index.ts](../api/src/index.ts) — the **API** (HTTP/SSE, auth, sessions, memory, tracing).
- [api/src/agent-runtime-code.ts](../api/src/agent-runtime-code.ts) — the **stateless agent runtime** (`AGENT_ID` env var selects which persona it runs).

---

## Scenario 1 — How a skill gets loaded (progressive disclosure)

This is the flow the request asked about specifically: where the SKILL.md markdown is
read and how it reaches the model.

Skills follow the [agentskills.io](https://agentskills.io/specification) *progressive
disclosure* contract — three phases, each loading more only when justified. All the
machinery is in [api/src/lib/skill-loader.ts](../api/src/lib/skill-loader.ts).

### Phase 1 — Discovery (startup, ~100 tokens/skill)

`listSkillDiscovery()` scans `config/skills/*/SKILL.md` and parses **only the
frontmatter** (`name` + `description`) via `gray-matter`. The result is cached by the
skills-directory mtime, so config edits hot-reload without a restart.

```
config/skills/order-management/SKILL.md
---
name: order-management
description: Query and manage customer orders from MongoDB Atlas...   ← this is all Phase 1 reads
---
# Order Management                                                    ← body is Phase 2
```

When an agent turn builds its system prompt, `withSkillDiscoverySection()` in
[api/src/lib/prompt.ts](../api/src/lib/prompt.ts) appends a compact index:

```
## Available skills (discovery index)
Use `activate_skill` to load full instructions before answering domain questions.
- **order-management**: Query and manage customer orders from MongoDB Atlas...
```

So the model sees *that a skill exists and what it's for* — but not the body yet.

### Phase 2 — Activation (the body is loaded)

`loadSkillInstructions(skillName)` reads the SKILL.md, strips frontmatter, and returns
**the markdown body** (cached by file mtime). Two ways this fires:

1. **Specialists pre-activate.** A specialist always needs its domain instructions, so
   [run-chat-stream.ts](../api/src/lib/run-chat-stream.ts) calls `registry.activateAll()`
   at template-build time (`preActivateSkills = true`). The body is spliced into the
   system prompt *before the first model call*.
2. **The orchestrator activates lazily.** It gets the discovery index only. If the model
   decides it needs a skill, it calls the `activate_skill` tool
   ([base-tools.ts `makeActivateSkillTool`](../api/src/lib/base-tools.ts)), which mutates
   the per-turn `SkillRegistry` and returns the body as the tool result.

Either way, the body reaches the model through
`withActivatedSkills()` in [prompt.ts](../api/src/lib/prompt.ts):

```
## Activated skill instructions
### Skill: order-management
<full SKILL.md body verbatim>
```

**This is the answer to "where the markdown is passed":** the SKILL.md body is
concatenated into the system prompt string built by `buildSystemPrompt(persona,
discoveries, activated, memoryContext)` in [prompt.ts:111](../api/src/lib/prompt.ts#L111),
then handed to the Strands `Agent` constructor as `systemPrompt` in
[run-chat-stream.ts:212](../api/src/lib/run-chat-stream.ts#L212).

> One important nuance, called out in the code: Strands can't mutate the system prompt
> mid-stream. When the orchestrator calls `activate_skill` *during* a turn, the body comes
> back as a **tool result** (visible to subsequent steps in the same loop), not as a new
> system-prompt block. Specialists dodge this entirely by pre-activating.

### Phase 3 — On-demand resources (references / scripts)

The SKILL.md body tells the model what else is available. The model then pulls files only
when needed, through two tools (both in [base-tools.ts](../api/src/lib/base-tools.ts)):

- `read_skill_resource(skillName, path)` → reads e.g. `references/order-schema.md`.
- `run_skill_script(skillName, scriptPath, exportName, args)` → dynamically `import()`s a
  `.mjs` from `scripts/` and calls a named export (e.g. `validateReturnEligibility`),
  returning the value as a tool result.

Both enforce the same gates before touching disk:
1. `skillName` must be in the agent's `skills:` list (`allowedSkills`).
2. The skill must already be **activated** (Phase 2) — else `skill_not_activated`.
3. Path traversal is blocked (`resolveSkillResourcePath` rejects anything resolving
   outside the skill folder), and reads are size-capped (`SKILL_RESOURCE_MAX_BYTES`).

### The state holder: `SkillRegistry`

One `SkillRegistry` exists per agent template
([skill-loader.ts:186](../api/src/lib/skill-loader.ts#L186)). It knows the allowed skills,
holds the Phase-1 discoveries, and accumulates Phase-2 activated bodies. It's passed into
the tool factories so `activate_skill` / `read_skill_resource` can mutate and read shared
state within a turn.

```
SKILL.md frontmatter ──Phase 1──▶ discovery index in system prompt
        │                              │
        │                         model calls activate_skill (orchestrator)
        │                              │  OR registry.activateAll() (specialist)
SKILL.md body ───────Phase 2──────▶ "## Activated skill instructions" in system prompt
        │
scripts/ + references/ ─Phase 3──▶ read_skill_resource / run_skill_script tool results
```

---

## Scenario 2 — A chat turn, end to end

User types in Streamlit → answer streams back. The default production path is
**single-hop**: the API classifies in-process and calls the specialist runtime directly
(no orchestrator LLM hop). Entry point: [api/src/routes/chat.ts](../api/src/routes/chat.ts).

1. **Auth.** `authMiddleware` verifies the Cognito JWT (JWKS). `jwt.sub` becomes the
   `userId` for sessions + memory. No JWT → the API doesn't even boot (see Scenario 6).
2. **Session + short-term history.** `getSession()` loads prior turns (from AgentCore
   Memory when `SHORT_TERM_MEMORY_BACKEND=agentcore`, else the Mongo `chat_sessions`
   mirror). The new user message is appended.
3. **Context build (parallel).** [chat.ts:207](../api/src/routes/chat.ts#L207) runs two
   independent lookups concurrently to save an RTT: the authenticated-user context block,
   and — if the target agent's frontmatter sets `memory.longTerm: true` — a hybrid
   vector+BM25 recall over `agent_memory_facts` + `chat_messages`
   (`readLongTermMemoryContext`). Both become the `memoryContext` string.
4. **Classification.** For the orchestrator agent (default) with `USE_ORCHESTRATOR_RUNTIME`
   off, `runMultiSpecialistFlow` calls `classifyAgents()` (Scenario 3) to pick specialist(s).
5. **Invoke the specialist runtime.** `invokeAgentRuntime()`
   ([adapters/agentcore-runtime.ts](../api/src/adapters/agentcore-runtime.ts)) sends
   `InvokeAgentRuntimeCommand` with `Accept: text/event-stream`. The payload carries the
   full turn: `message`, `agentId`, `sessionId`, `priorTurns`, `memoryContext`, `userJwt`,
   and a W3C trace carrier. The runtime is **stateless** — all context travels in the
   payload.
6. **Runtime runs the agent.** [agent-runtime-code.ts](../api/src/agent-runtime-code.ts)
   `/invocations` handler builds the Strands agent and streams (Scenario 1 + 4). Frames
   come back as `event: stream` (tokens/tool_calls/handoffs), `event: trace`, and a final
   `event: done`.
7. **Relay + persist.** The API forwards each frame to the browser's SSE channel. After
   the stream ends (off the user's TTFB clock) it persists the assistant message, splices
   the runtime's nested trace under the `agentcore.invoke` wrapper span, writes the trace
   doc, emits `done`, and dispatches long-term-memory fact extraction as a dangling
   promise.

Streaming is never buffered at any hop — end-to-end TTFB equals the specialist's first
Bedrock token. An SSE keepalive comment frame (`: keepalive`, every ~15s) keeps the
connection warm across cold-start runtime silences that would otherwise trip NLB/NAT idle
timeouts.

---

## Scenario 3 — Routing: how the classifier picks a specialist

[api/src/lib/agent-classifier.ts](../api/src/lib/agent-classifier.ts). Two backends,
tried in order, so most turns pay zero LLM cost to route.

- **Tier A — deterministic abstain.** If the message has no content tokens after
  stopword stripping ("Can you help me?"), or only low-signal filler ("I need help with
  *something*"), the classifier abstains → the orchestrator asks the user to clarify. No
  Bedrock call.
- **Tier 1 — heuristic.** Token+bigram overlap between the message and each candidate's
  corpus (built from the orchestrator's `handoffs[]` labels/prompts + each specialist's
  `description` + `skills`). Sub-millisecond. Accepted when the top score clears
  `HEURISTIC_MIN_SCORE` **and** beats the runner-up by `HEURISTIC_MARGIN`.
- **Tier 2 — Haiku fallback.** Only when the heuristic is uncertain. One tool-forced
  Bedrock Haiku call (`route_to_specialists`) returns an ordered `agentIds` array.

Results are LRU-cached per normalized message. **Multi-select** kicks in only when a
runner-up clears a high absolute floor *and* is close to the leader (e.g. "track my order
AND recommend a laptop") — capped at `CLASSIFIER_MULTI_MAX_AGENTS` (default 2). The
candidate index is rebuilt whenever `listAgents()` changes, so a new `.agent.md` becomes
routable as soon as its runtime ARN env var exists.

---

## Scenario 4 — Tool resolution: where each tool actually comes from

An agent's `tools:` list is just names. [base-tools.ts `toolsForAgent`](../api/src/lib/base-tools.ts#L459)
resolves each name to a real Strands `Tool` — and the source differs by kind:

| Tool name in `.agent.md` | Resolved to | Where it runs |
|---|---|---|
| `mongodb_query`, `mongodb_vector_search`, `mongodb_aggregate` | **Dropped** from in-process list; re-attached from the **AgentCore Gateway MCP target** by `createConfiguredStrandsAgent` via `getMcpTools()` | MongoDB MCP runtime |
| `bedrock_kb_retrieve`, `embed_multimodal_content` | Static in-process tools | Inside the agent runtime |
| `read_skill_resource`, `run_skill_script`, `activate_skill` | Skill tools bound to the per-turn `SkillRegistry` | Inside the agent runtime |
| `order-management/<toolName>` (skill-scoped) | HTTP tool defined in that skill's `http-tools.json` | HTTPS call (e.g. Lambda URL), SSRF-allowlisted |
| bare name in root `config/http-tools.json` | Global HTTP tool | HTTPS call |

Two deliberate design points:
- **The agent never has an in-process Mongo driver.** Gateway MCP is the only Mongo
  transport, so query guards (allowlist, write gate, `$out`/`$merge` denylist, limit cap
  in [mcp-runtimes/mongodb-mcp/src/vendor/guards.mjs](../mcp-runtimes/mongodb-mcp/src/vendor/guards.mjs))
  can't be bypassed.
- **Degraded mode.** If an agent declares `mongodb_*` but `getMcpTools()` returns `[]`
  (Gateway URL drifted, MCP runtime down), the template is built but **not cached**, a
  `tools.degraded` trace + `TOOLS_UNAVAILABLE` SSE error surface loudly, and the next turn
  re-attempts MCP. This prevents a boot-time MCP blip from silently locking every turn to a
  tool-less agent that hallucinates "I can't access the database." See
  [create-strands-agent.ts:158](../api/src/lib/create-strands-agent.ts#L158).

The MCP JWT plumbing: the caller's Cognito token rides the invocation payload as `userJwt`,
the runtime injects it as `Authorization: Bearer` on outbound Gateway calls, and the MCP
`callTool` wrapper stamps `jwt.sub` into every query filter — so a user can only ever read
their own data.

---

## Scenario 5 — Agent config → runtime: the deploy split & template cache

Config edits have **two different propagation paths**, and mixing them up is a common
gotcha:

- **API-side metadata** (agent list, classifier corpus, skill discovery) is **mtime-hot-
  reloaded** — the API rescans `config/` per request. Edit a description, it's live.
- **Runtime behavior** (the system prompt the specialist actually runs with) lives in the
  **deployed code artifact**. The runtime is a stateless container that was bundled at
  deploy time. Changing a `.agent.md` body or a `SKILL.md` requires
  `./deploy/deploy-agents.sh` to re-bundle + redeploy the runtimes.

Inside a process, agent construction is cached per `agentId`
([create-strands-agent.ts](../api/src/lib/create-strands-agent.ts)). `getAgentTemplate()`
caches the heavy parts — resolved model client, tool list, `SkillRegistry`, base system
prompt — keyed on the `AgentDetail` reference (which changes when the `.agent.md` mtime
changes, auto-invalidating). Per-turn work is then just: splice `memoryContext` into the
cached base prompt, and hand cached parts + a fresh seeded `messages` array to a new
`Agent`. The cache is bypassed for lazy-skill orchestrator runs so one turn's
`activate_skill` calls can't leak into the next.

---

## Scenario 6 — Memory: short-term vs long-term, and how it enters the prompt

Two independent systems (see [docs/memory-architecture.md](memory-architecture.md),
[docs/long-term-memory-design.md](long-term-memory-design.md)):

- **Short-term** = conversation history. Production backend is AgentCore Memory
  (`SHORT_TERM_MEMORY_BACKEND=agentcore`); a Mongo `chat_sessions` mirror backs the
  Sessions page and acts as fallback. Loaded as `priorTurns`, seeded into the Strands agent
  as `messages` history.
- **Long-term** = durable facts + replayed snippets, keyed by JWT `sub`. Only fetched when
  the agent's frontmatter opts in with `memory.longTerm: true`. Retrieval is **hybrid**:
  vector + BM25 over `agent_memory_facts` and `chat_messages`, fused with RRF + recency +
  MMR ([docs/hybrid-search.md](hybrid-search.md)).

Long-term context is injected into the **system prompt** (not the message history) by
`withLongTermMemory()` in [prompt.ts:87](../api/src/lib/prompt.ts#L87), placed *before* the
skills so the model sees user context early, and always followed by the framework-canonical
`LONG_TERM_MEMORY_RECALL_RULES` block — so every memory-enabled agent gets identical recall
rules without each persona copying them.

The **write path** is deferred: after the answer streams, `writeLongTermMemory()` runs as a
dangling promise (`queueMicrotask`) — a Bedrock Haiku fact-extraction call + Mongo write —
so it never sits on the user's TTFB clock. It's keyed by `(userId, finalAgentId)`.

---

## Scenario 7 — Multi-specialist orchestration & synthesis

When the classifier returns **more than one** specialist,
[multi-specialist-orchestrator.ts](../api/src/lib/multi-specialist-orchestrator.ts) drives
the flow (via `runMultiSpecialistFlow`). It's a generator that both the API path
([chat.ts](../api/src/routes/chat.ts)) and the orchestrator-runtime path
([agent-runtime-code.ts `handleOrchestrator`](../api/src/agent-runtime-code.ts#L226))
consume through one `SpecialistInvoker` interface — so `USE_ORCHESTRATOR_RUNTIME=1` is
externally indistinguishable from the in-API single-hop route.

- **Single-specialist fast path:** the one specialist's tokens *are* the final answer;
  persisted under that specialist's `agentId`.
- **Multi path:** each ranked specialist is invoked sequentially, its tokens streamed as a
  `phase: "specialist"` **draft** (UI renders them as drafts, not the answer). Then a
  **synthesizer** agent ([specialist-answer-synthesizer.ts](../api/src/lib/specialist-answer-synthesizer.ts))
  composes one cohesive reply; those tokens are the persisted answer, under `orchestrator`.
- **Clarification path:** if the classifier abstained (Tier A/B), the orchestrator streams
  a clarify-me reply ([orchestrator-clarify.ts](../api/src/lib/orchestrator-clarify.ts))
  instead of force-routing.

---

## Scenario 8 — The trace pipeline (why the Trace Viewer can show everything)

Every turn creates one `TraceCollector` ([trace-collector.ts](../api/src/lib/trace-collector.ts))
per process. Events (`prompt.assembled`, `skill.activated`, `tool.call`, `model.usage`,
`handoff.decision`, `agentcore.invoke`, latency checkpoints…) are appended with span
start/end semantics and per-event-type byte caps.

The clever part is **nested traces across the process boundary.** The API's collector and
the runtime's collector are separate. The runtime streams its events as `event: trace`
frames; the API accumulates them and, after the stream ends, `attachEventsNested()` splices
them **under the `agentcore.invoke` wrapper span** — located by
`findOutermostAgentcoreInvokeId()` ([chat.ts:922](../api/src/routes/chat.ts#L922)) using the
span's *start* event (not the synthetic end event, which would shift the whole nested trace
by the span duration). The result is a single unified tree spanning API → runtime →
sub-specialist, rendered by [ui/pages/2_Trace_Viewer.py](../ui/pages/2_Trace_Viewer.py).
Traces persist to a Mongo `traces` doc + an in-memory ring buffer; OTel spans additionally
export to X-Ray when `OTEL_EXPORTER_OTLP_ENDPOINT` is set.

---

## Scenario 9 — Deployment topology (what actually runs on AWS)

Five AgentCore Runtimes ([docs/agentcore-runtime-design.md](agentcore-runtime-design.md)):

| Runtime | Mode | Selected by |
|---|---|---|
| orchestrator | `NODE_22` code artifact | `AGENT_ID=orchestrator` |
| order-management | code artifact | `AGENT_ID=order-management` |
| product-recommendation | code artifact | `AGENT_ID=product-recommendation` |
| troubleshooting | code artifact | `AGENT_ID=troubleshooting` |
| mongodb-mcp | ARM64 container, streamable-HTTP MCP on `:8000/mcp` | reached via AgentCore Gateway |

The four chat runtimes share the **one** [api/](../api/) bundle; `AGENT_ID` picks the
persona at boot. Terraform is split into singletons by blast radius
([deploy/terraform/.design.md](../deploy/terraform/.design.md)):

| Stack | Scope | Singleton |
|---|---|---|
| `envs/network` | VPC + Atlas connectivity (PrivateLink or peering) + SSM | account+region |
| `envs/shared` | Voyage SageMaker + CloudWatch + Bedrock logging | account+region+env |
| `envs/ec2` | Atlas + KB + EC2 + Cognito + 5 runtimes + ADOT sidecar | per-project |
| `envs/local` | Laptop Atlas + KB + memory (no EC2/runtimes) | per-laptop |

Connectivity is mutually exclusive per account: `NETWORK_MODE=privatelink` (default),
`peering`, or the demo-only `public`/BYO-Atlas path. Switching modes = destroy + redeploy.
Deploy orchestrators: [deploy/deploy-full-with-privatelink.sh](../deploy/deploy-full-with-privatelink.sh)
and siblings. Targeted redeploys: `deploy-agents.sh` (config), `deploy-api.sh` /
`deploy-ui.sh` (code). Full runbook: [docs/deployment-guide.md](deployment-guide.md).

---

## Adding a new vertical (the payoff of all the above)

1. `config/agents/<name>.agent.md` — frontmatter (model, `tools:`, `skills:`, `memory:`)
   + persona body. Add a handoff entry to the orchestrator so the classifier can route to it.
2. `config/skills/<name>/SKILL.md` — domain instructions; optional `scripts/`,
   `references/`, `http-tools.json`.
3. `./deploy/deploy-agents.sh --auto-approve` — bundles + deploys the new runtime and
   injects its ARN env var.

No framework code changes. Authoring guides:
[agent-authoring-guide.md](agent-authoring-guide.md),
[skills-authoring-guide.md](skills-authoring-guide.md).
