# Base-tool Lambda adapters (Gateway mode)

Placeholder layout for **ACTION_PLAN.md** Phase 1 / Phase 4: generic Lambda handlers that mirror the five Strands base tools (`mongodb_query`, `mongodb_vector_search`, `bedrock_kb_retrieve`, `generate_embedding`, `read_skill_resource`) so **AgentCore Gateway** can invoke them instead of in-process `api/src/lib/base-tools.ts`.

Each subdirectory is reserved for a future **Node.js or Bun** Lambda package (handler + `package.json` + small README). **Direct mode** (current default) keeps tools in the API process; no deploy is required until Gateway work lands.

| Directory | Tool |
|-----------|------|
| `mongodb-query/` | `mongodb_query` |
| `mongodb-vector-search/` | `mongodb_vector_search` |
| `bedrock-kb-retrieve/` | `bedrock_kb_retrieve` |
| `generate-embedding/` | `generate_embedding` |
| `read-skill-resource/` | `read_skill_resource` |

See [`docs/deployment-guide.md`](../../docs/deployment-guide.md) and [`TASKS.md`](../../TASKS.md) for status.
