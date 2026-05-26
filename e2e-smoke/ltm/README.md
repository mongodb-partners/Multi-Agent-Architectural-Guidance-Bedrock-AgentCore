# Long-Term Memory Smoke Suite

Focused live smoke tests for vector-backed long-term memory.

Run from the repository root after the API has been deployed:

```bash
source .env
bash e2e-smoke/ltm/ltm-smoke.sh
```

The suite reads `.env.live` for `STREAMLIT_API_URL` and Cognito app id, then uses the same Cognito demo user defaults as the broader smoke:

```bash
E2E_USER=alex@example.com E2E_PASS='DemoUser#2026' bash e2e-smoke/ltm/ltm-smoke.sh
```

## What It Checks

- **Semantic fact recall**: writes a hazelnut/nut-free preference, recalls it from a different session, and asserts the answer is positive rather than a denial.
- **LTM vector/hybrid trace proof**: fetches the persisted trace from `GET /traces/:traceId` and verifies `memory.scoped_read` includes:
  - `mode: "hybrid"`
  - `embeddingSource` and `embeddingModel`
  - `collectionsQueried` containing both `agent_memory_facts` and `chat_messages`
  - `retrieval.topK`, `retrieval.fetchK`, and `retrieval.perCollection`
  - non-zero vector hits for scenarios that require vector proof
- **Correction / polarity**: writes a corrected preference (`do not like pasta`) and verifies the later answer preserves the negation.
- **Chat-message mirror**: writes a session-specific codename and verifies the trace includes `chat_messages` vector participation.

## Useful Overrides

```bash
API_URL=http://host:3000 bash e2e-smoke/ltm/ltm-smoke.sh
LTM_WRITE_SETTLE_SECONDS=10 bash e2e-smoke/ltm/ltm-smoke.sh
LTM_SMOKE_RUN_ID=manual-001 bash e2e-smoke/ltm/ltm-smoke.sh
```

## Interpreting Failures

- `vector_hits_gt_zero` failure means LTM recall may be falling back to lexical/scoped retrieval instead of Atlas Vector Search.
- `chat_messages_vector_gt_zero` failure means the chat-message mirror is not participating in vector retrieval.
- Missing `memory.scoped_read` usually means tracing is disabled or the trace was not persisted.
- A denial such as "I don't know" means memory was not injected into the prompt or the agent ignored it.
