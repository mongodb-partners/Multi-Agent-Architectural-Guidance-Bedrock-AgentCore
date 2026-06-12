# Request Flow

> **What this shows:** what happens end-to-end when a user sends a chat message — classification, specialist invocation, MongoDB tool calls, SSE streaming, and the dangling long-term-memory write.
> **Sources of truth:** [`docs/architecture.md` §4](../architecture.md), [`api/src/routes/chat.ts`](../../api/src/routes/chat.ts), [`api/src/lib/agent-classifier.ts`](../../api/src/lib/agent-classifier.ts).

The production default is a **single hop**: the Hono API classifies the message in-process and invokes the matching specialist AgentCore Runtime directly. The legacy orchestrator-runtime hop is available only behind `USE_ORCHESTRATOR_RUNTIME=1` as a one-release rollback.

---

## 1. Single-hop happy path

Example: a user asks **"Where is my order ORD-1234?"**

```mermaid
sequenceDiagram
  participant U as User (Streamlit UI)
  participant API as Hono API (EC2)
  participant LTM as MongoDB LTM (hybrid retrieval)
  participant SPEC as order-management Runtime
  participant BED as Bedrock
  participant GW as AgentCore Gateway
  participant MCP as mongodb-mcp Runtime
  participant DB as MongoDB Atlas

  U->>API: POST /chat {message, sessionId} + Bearer JWT
  API->>API: verifyJwt() -> userId = jwt.sub
  API->>API: appendUserMessage() · getSession() -> priorTurns
  API->>API: classifyAgent(message) -> order-management
  API->>LTM: readLongTermMemoryContext(userId, message)
  LTM-->>API: "## Relevant prior context" block
  API->>SPEC: InvokeAgentRuntime(arn, payload, Accept: text/event-stream)
  SPEC->>BED: InvokeModel — reason about question
  BED-->>SPEC: tool_use: mongodb_query
  SPEC->>GW: MCP tools/call (Bearer userJwt)
  GW->>MCP: mongodb-mcp target
  MCP->>DB: db.orders.findOne({orderId: "ORD-1234"})
  DB-->>MCP: order document
  MCP-->>SPEC: MCP response {documents}
  SPEC->>BED: InvokeModel — compose answer (stream)
  BED-->>SPEC: token stream
  SPEC-->>API: SSE: agent_info / token / trace / done
  API-->>U: SSE forwarded verbatim (TTFB = first specialist token)
  par dangling microtask (off the user clock)
    API->>LTM: writeLongTermMemory() — extract -> embed -> bulkWrite upsert
  end
```

**Key properties:**

- The API stays *outside* AgentCore: it owns sessions, classification, and memory read+write. Runtimes are stateless and receive full context (including `## Relevant prior context`) on every call.
- All MongoDB tool calls route through the AgentCore Gateway to the `mongodb-mcp` runtime — agents never open MongoDB connections directly.
- `InvokeAgentRuntime` with `Accept: text/event-stream` is **true SSE streaming**, so TTFB equals the specialist's first Bedrock token, not the buffered full reply.
- `runtimeSessionId` must be at least 33 characters (an AgentCore requirement); the API pads short session IDs.
- The LTM write is a dangling microtask so it never sits on TTFB. The trace is re-persisted after it settles so `memory.long_term_write` / `memory.long_term_skip` land in the stored trace.

---

## 2. In-API classifier decision

The classifier (`api/src/lib/agent-classifier.ts`) scores the message against the orchestrator's `handoffs:` roster with a heuristic, falling back to Bedrock Haiku only when uncertain.

```mermaid
flowchart TB
  MSG[User message] --> HEUR["Heuristic score<br/>token + bigram overlap<br/>vs each candidate corpus"]
  HEUR --> TOP{"Top score >= min<br/>AND margin over runner-up<br/>>= CLASSIFIER_HEURISTIC_MARGIN?"}
  TOP -->|yes, confident| MULTI{"2+ specialists clear<br/>multi-select gates?"}
  TOP -->|no, uncertain| HAIKU["Bedrock Haiku fallback<br/>tool-forced agentIds array"]
  HAIKU --> MULTI
  MULTI -->|single| ONE["One specialist<br/>fast path · tokens persist directly"]
  MULTI -->|multiple| MANY["Multi-specialist orchestration<br/>(see section 3)"]
```

- `CLASSIFIER_BACKEND=heuristic` disables the Haiku fallback entirely.
- Multi-select gates: `CLASSIFIER_MULTI_MIN_SCORE` (default `3.0`), `CLASSIFIER_MULTI_RELATIVE_MARGIN` (default `1.5`), `CLASSIFIER_MULTI_MAX_AGENTS` (default `2`).
- The Haiku fallback uses the orchestrator's model (`us.anthropic.claude-haiku-4-5-...`).

---

## 3. Multi-specialist orchestration + synthesizer

When the classifier returns 2+ specialists, the API invokes each in ranked order, streams each draft tagged `phase: "specialist"`, then runs an in-process **synthesizer** (a transient Strands `Agent`, `id: "synthesizer"`, no AgentCore runtime, no `.agent.md`) to compose one cohesive answer streamed as `phase: "synthesis"`.

```mermaid
sequenceDiagram
  participant API as Hono API
  participant S1 as Specialist A Runtime
  participant S2 as Specialist B Runtime
  participant SYN as Synthesizer (in-process Strands)
  participant U as UI

  API->>S1: InvokeAgentRuntime (ranked #1)
  S1-->>U: token (phase: specialist) — draft A
  API->>S2: InvokeAgentRuntime (ranked #2)
  S2-->>U: token (phase: specialist) — draft B
  API->>SYN: synthesize(draftA, draftB, userMessage)
  SYN-->>U: token (phase: synthesis) — final answer
  Note over API: only synthesis text is persisted (agentId: orchestrator)
```

- Specialist drafts live in the trace + live UI only; only the synthesis text persists.
- Single-domain prompts skip all of this (no synthesis, no `phase` field).
- Trace events: `orchestrator.multi_route_decision`, `orchestrator.specialist_draft` (one per specialist), `orchestrator.synthesis`.
- The synthesizer Bedrock call is tagged `agentId: "synthesizer"` for cost attribution.

See [`api/src/lib/multi-specialist-orchestrator.ts`](../../api/src/lib/multi-specialist-orchestrator.ts) and [`api/src/lib/specialist-answer-synthesizer.ts`](../../api/src/lib/specialist-answer-synthesizer.ts).

---

## 4. SSE event lifecycle

The `/chat` endpoint streams these named SSE events (verified in [`api/src/routes/chat.ts`](../../api/src/routes/chat.ts)):

```mermaid
flowchart LR
  AI[agent_info] --> AA[agent_active]
  AA --> SK[skill_loaded]
  SK --> TC[tool_call]
  TC --> TK["token<br/>(optional phase:<br/>specialist | synthesis)"]
  TK --> HO[handoff]
  HO --> TR[trace]
  TR --> ERR[error]
  ERR --> DONE[done]
```

| Event | Meaning |
|---|---|
| `agent_info` | Selected agent + routing metadata at stream start |
| `agent_active` | Which agent is currently producing output |
| `skill_loaded` | A skill was activated for the turn |
| `tool_call` | A tool (e.g. `mongodb_query`) was invoked |
| `token` | A text token; carries `phase` in multi-specialist mode |
| `handoff` | Routing handoff between agents |
| `trace` | A trace event (throttled to the UI by `TRACE_SSE_THROTTLE_MS=100`) |
| `error` | A recoverable/terminal error for the turn |
| `done` | Terminates the stream |

---

## 5. Orchestrator rollback path

`USE_ORCHESTRATOR_RUNTIME=1` reinstates the legacy two-hop path for one-release rollback:

```mermaid
flowchart LR
  API[Hono API] -->|default: single hop| SPEC[Specialist Runtime]
  API -.->|USE_ORCHESTRATOR_RUNTIME=1| ORCH[Orchestrator Runtime]
  ORCH -.->|InvokeAgentRuntime| SPEC
```

The orchestrator runtime shares the same code bundle as the specialists; `AGENT_ID=orchestrator` selects the persona at boot.

---

**Related diagrams:** [AWS infrastructure](01-aws-infrastructure.md) · [memory architecture](03-memory-architecture.md) · [deployment pipeline](04-deployment-pipeline.md)
