# Memory Architecture

> **Audience:** anyone trying to reason about what the system remembers, when it remembers, and where that data lives.

The system uses **two memory layers** with different jobs and different backends.

```mermaid
flowchart TB
  REQ[POST /chat] --> ST[Short-Term Memory<br/>short-term-memory.ts + session-store.ts]
  REQ --> LT[Long-Term Memory<br/>long-term-memory.ts]
  ST --> STAC[AgentCore Events<br/>SHORT_TERM_MEMORY_BACKEND=agentcore<br/>requires userId]
  ST --> STM[In-memory Map cache<br/>session-store]
  ST --> STMG[(MongoDB chat_sessions<br/>default-on when MONGODB_URI set<br/>opt-out via PERSIST_CHAT_SESSIONS=0)]
  LT --> LTMG[(MongoDB agent_memory_facts<br/>PRIMARY)]
  LT --> LTAC[AgentCore Memory Store<br/>fallback]
```

For an editable picture: [`diagrams/03-memory-architecture.drawio`](diagrams/03-memory-architecture.drawio).

---

## 1. Short-Term Memory (current conversation)

**What it is:** per-turn chat transcript for a `sessionId`.

**Primary path in EC2 auth mode:** AgentCore short-term events keyed by `(memoryId, actorId=userId, sessionId)`.

### Read/write flow

1. API appends user turn to `session-store`.
2. If AgentCore short-term is enabled (`SHORT_TERM_MEMORY_BACKEND=agentcore`, memory ID present, and authenticated `userId`), API reads prior turns from AgentCore first.
3. If AgentCore read returns nothing or fails, API falls back to `session-store` (in-memory or Mongo cold read when enabled).
4. After assistant reply, API writes assistant turn to `session-store` and best-effort writes user/assistant events to AgentCore.

### Backends

| Backend | When | Behavior |
|---|---|---|
| **AgentCore events** | `SHORT_TERM_MEMORY_BACKEND=agentcore` + `AGENTCORE_MEMORY_STORE_ID` + `userId` | Primary durable short-term memory in EC2 mode. |
| **In-memory map** | Always | Fast cache/fallback. Lost on API restart. |
| **MongoDB `chat_sessions`** | `MONGODB_URI` set (default-on; opt out with `PERSIST_CHAT_SESSIONS=0`) | Write-through persistence for `session-store`. |

### Decision tree (which backend serves a given turn)

JWKS auth is **mandatory end-to-end** (see `assertJwksAuthConfigured()` in [`api/src/lib/jwt-verify.ts`](../api/src/lib/jwt-verify.ts)), so every authenticated turn has a real `userId = jwtPayload.sub`. The matrix below describes how the API selects a short-term backend per turn:

| `SHORT_TERM_MEMORY_BACKEND` | `AGENTCORE_MEMORY_STORE_ID` | `MONGODB_URI` | Primary read | Persisted write | Notes |
|---|---|---|---|---|---|
| `agentcore` | set | set | **AgentCore events** (per `(memoryId, actorId=userId, sessionId)`) | AgentCore events **and** `chat_sessions` (write-through) | Production EC2 default; survives API restarts. |
| `agentcore` | set | unset | **AgentCore events** | AgentCore events only | Cold-start replay needs AgentCore reachable; in-memory map is a transient cache. |
| `agentcore` | **unset** | — | — | — | **API refuses to boot** — `assertShortTermBackendConfigured()` in [`api/src/lib/short-term-memory.ts`](../api/src/lib/short-term-memory.ts) throws so a misconfigured deploy never silently downgrades to the in-memory map. |
| any other / unset | — | set | `chat_sessions` (write-through with in-memory cache) | `chat_sessions` only | Used when AgentCore is intentionally off; durable across API restarts via Mongo. |
| any other / unset | — | unset | In-memory `Map` only | none | Ephemeral mode — only safe for tests / a single API process. |

`PERSIST_CHAT_SESSIONS=0` opts out of the Mongo write-through even when `MONGODB_URI` is set; the in-memory `Map` then becomes the only short-term store for that process.

The runtime never silently downgrades from AgentCore to the in-memory `Map`: if you opt into the AgentCore backend, you must wire the memory store id, otherwise the API refuses to start.

---

## 2. Long-Term Memory (cross-session personalization)

**What it is:** extracted user facts/preferences/profile signals that persist across sessions.

**Where it lives:** [`api/src/lib/long-term-memory.ts`](../api/src/lib/long-term-memory.ts).

### Backend strategy

| Backend | Role |
|---|---|
| **MongoDB `agent_memory_facts`** | Primary long-term memory store |
| **AgentCore Memory Store** | Fallback when Mongo write/read fails |

### What gets stored

The API extracts fact-like snippets from each user message and writes documents like:

```javascript
{
  userId,
  agentId,
  fact,
  source: "user",
  ts
}
```

- Collection: `agent_memory_facts`
- TTL index: `MEMORY_TTL_DAYS * 86400` seconds (EC2 deploy sets 30 days)

### Fact extractor (LLM)

Extraction lives in [`api/src/lib/long-term-memory.ts`](../api/src/lib/long-term-memory.ts):

| Backend | Behavior |
|---|---|
| **LLM** ([`api/src/lib/llm-fact-extractor.ts`](../api/src/lib/llm-fact-extractor.ts)) | Calls Amazon Bedrock `ConverseCommand` with a tool-forced JSON schema (`record_facts`); model returns categorized facts + ignored snippets. This is the only extractor — there is no regex fallback. |

**Bedrock runtime failure → skip the write.** When the LLM extractor throws (throttling, AccessDenied, network), the write is skipped and a `memory.long_term_skip` event is emitted with `reason: "llm_extractor_failed"` plus extractor diagnostics (`extractorModelId`, `extractorError`). Rationale: a regex fallback would produce false positives — e.g. "Can you check the status of order ORD-1234?" matches an `order` topic pattern — and silently storing wrong "facts" on every Bedrock blip is worse than skipping. The user can re-state the fact in a future turn.

**Env vars**

| Variable | Purpose | Default |
|---|---|---|
| `MEMORY_EXTRACTION_MODEL_ID` | Bedrock model id (or cross-region inference profile id) used by the LLM extractor. Must support tool use. | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |
| `MEMORY_EXTRACTION_MAX_FACTS` | Cap on facts persisted per turn | `6` |

**Trace event** `memory.long_term_write` records `extractorModelId`, `extractorLatencyMs`, and per-candidate `category` + `note`, all visible in the trace UI.

### Read path injected into prompts

When `agent.memory.longTerm=true` and `userId` is known:

- read shared user facts (`readSharedLongTermMemory(userId)`) across all agents
- read agent-scoped facts (`readLongTermMemory(userId, agentId)`)
- prepend both into system prompt as memory context

This is why specialist flows can personalize from facts learned in a different specialist session.

---

## 3. Auth Context in Memory Injection

In addition to long-term facts, chat prompt context includes an **Authenticated User Context** block from:

- JWT claims (`sub`, `email`, `name`, etc.)
- Cognito `GetUser` fallback (important for access tokens that omit `email`)
- Mongo enrichment (`customers` tier/verified and recent ordered SKUs)

This drives identity-aware prompts like:
- "my orders"
- "my open tickets"
- "recommend based on my previous orders"

---

## 4. What Memory Currently Does Not Do

- No vector-similarity recall over memory facts (recall is rule-based + recency-oriented).
- No full memory summarization/consolidation pipeline.
- No hard PII classifier before memory write. The LLM extractor is prompt-instructed to skip ephemeral / non-personal text and label what it stores by category, but it is not a PII guard.

---

## 5. Debugging Memory

### Check AgentCore short-term events

```bash
aws bedrock-agentcore list-events \
  --memory-id "$AGENTCORE_MEMORY_STORE_ID" \
  --actor-id "<userId>" \
  --session-id "<sessionId>" \
  --include-payloads \
  --region us-east-1
```

### Check Mongo long-term facts

```bash
# Database name is project+env-derived (underscored). Example for
# PROJECT_NAME=mongodb-multiagent / ENVIRONMENT=dev:
use mongodb_multiagent_dev
db.agent_memory_facts.find({ userId: "<userId>" }).sort({ ts: -1 }).limit(20)
```

### Useful logs (`LOG_LEVEL=debug`)

```text
[chat] injecting long-term memory { userId, agentId }
[memory] wrote facts to MongoDB agent_memory_facts { userId, agentId }
[auth-context] failed to enrich auth context from Mongo ...
```

---

## 6. Critical files reference

| File | Purpose |
|---|---|
| [`api/src/lib/short-term-memory.ts`](../api/src/lib/short-term-memory.ts) | AgentCore short-term read/write |
| [`api/src/lib/session-store.ts`](../api/src/lib/session-store.ts) | Fallback chat session cache + optional Mongo persistence |
| [`api/src/lib/chat-sessions-collection.ts`](../api/src/lib/chat-sessions-collection.ts) | `chat_sessions` collection access |
| [`api/src/lib/long-term-memory.ts`](../api/src/lib/long-term-memory.ts) | Long-term facts read/write and storage fallback logic |
| [`api/src/lib/llm-fact-extractor.ts`](../api/src/lib/llm-fact-extractor.ts) | Bedrock-backed LLM fact extractor (tool-forced JSON output) |
| [`api/src/lib/auth-user-context.ts`](../api/src/lib/auth-user-context.ts) | Authenticated identity enrichment for prompts |
| [`api/src/routes/chat.ts`](../api/src/routes/chat.ts) | End-to-end read/write hook integration |
