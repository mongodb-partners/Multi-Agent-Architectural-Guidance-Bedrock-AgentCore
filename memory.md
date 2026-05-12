# Project memory — pitfalls to avoid repeating

**Audience:** human and AI contributors. This is **not** runtime agent memory (that would be AgentCore / MongoDB long-term memory in the product sense).

**Purpose:** Record **only persistent pitfalls** — failure modes that are **non-obvious** and have **recurred more than twice** (or are severe once-off regressions such as **hung tests / infinite loops** in CI). Do **not** add an entry for every bug or design choice; use [`docs/`](docs/), commit messages, and PR descriptions for ordinary fixes.

**How to add an entry**

- Confirm the bar: same class of mistake **repeated** (e.g. third time someone breaks Swarm + dev mock), or a **single** critical regression worth a permanent guardrail.
- Prefer a **bold title** + **symptom** + **rule** + **file(s)**.
- Keep it scannable; link to code or tests when useful.

---

## Do not regress — Strands Swarm + `DevMockModel` structured path

**Symptom:** Integration test `POST /chat orchestrator + ORCHESTRATOR_MODE=swarm …` runs forever (or until timeout). Logs show hundreds of `structured after tools` / repeated `stream turn` lines for the same specialist agent (e.g. `order-management`).

**Cause:** In **`CHAT_MODE=live`** with **`ORCHESTRATOR_MODE=swarm`**, agents use structured output (`strands_structured_output`). After real tools run, Strands/Swarm **invokes the model again** with tool results in the message history. If the mock model responds with **another** `strands_structured_output` at that point, the runtime keeps cycling — the same failure mode applies to **orchestrator and specialists**, not only the orchestrator.

**Rule:** When `lastUserMessageHasToolResults(messages)` and the model is in the **structured** branch (`names.has("strands_structured_output")`), **finish with plain text** (`emitTextStream`), not another `strands_structured_output`. The orchestrator can use routing-style wording; specialists can use a short summary line.

**Implementation:** `api/src/adapters/dev-mock-model.ts` — see the block logged as `text after tool results (dev mock)` (around the `if (structured)` / `lastUserMessageHasToolResults` handling).

**Regression check:** `cd api && bun test tests/integration/app.integration.test.ts` — the swarm case should complete in milliseconds, not tens of seconds.

---

## `read_skill_resource` — activation and allowlist

**Rule:** The tool is bound per agent: **`skillName` must be in that agent’s `.agent.md` `skills:` list**, and the skill must be **activated** (full `SKILL.md` loaded via `activate_skill`, or specialist **`preActivateSkills`**). Otherwise the API returns `skill_not_allowed_for_agent` or `skill_not_activated` — do not bypass with a looser reader.

**Code:** `readSkillResourceWithRegistry` in `api/src/lib/base-tools.ts`, `SkillRegistry.isSkillActivated` in `api/src/lib/skill-loader.ts`.

---

## Skill `scripts/*.mjs` — dynamic import = executable config

**Symptom / risk:** Editing `config/skills/.../scripts/*.mjs` changes runtime behavior the next time the API process loads that module (cached import). This is intentional for policy-as-code but **must be treated as trusted code** — same trust boundary as the rest of `config/`.

**Rule:** Keep skill modules **pure** (no network, no filesystem) unless explicitly designed otherwise. Convention: `.mjs` files in `config/skills/<name>/scripts/` export named functions; the generic `run_skill_script` tool in `api/src/lib/base-tools.ts` dynamically imports them at call time (registry-bound, same allowlist/activation gates as `read_skill_resource`). **No dedicated API loader file per script** — the tool does `import()` inline.

---

## Lambda MCP zip needs `node_modules` baked in

**Symptom:** Right after a fresh deploy.sh / first apply on a new environment, every `mongodb_*` tool call from an agent returns 0 results. Lambda CloudWatch logs show: `Cannot find package 'mongodb' imported from /var/task/index.mjs`. Vector search silently degrades to "catalog appears empty".

**Cause:** `deploy/terraform/modules/lambda-mcp/main.tf` zips `lambda/mongodb-mcp/` with `archive_file`. It does **not** run `npm install`, so a fresh checkout (or any environment where `lambda/mongodb-mcp/node_modules/` was never created) ships a Lambda with a `mongodb` import but no dep tree.

**Rule:** `deploy.sh` Phase 4c runs `npm install --omit=dev --cache /tmp/npm-cache-lambda-mcp` in `lambda/mongodb-mcp/` before `terraform apply` so the archive_file picks up `node_modules/`. **Do not** delete that phase, and **do not** `.gitignore` `lambda/mongodb-mcp/node_modules/` in a way that breaks `terraform plan` between `deploy.sh` runs (the dir is recreated each run; ignoring it is fine, dropping the install step is not).

**Regression check:** After `deploy.sh`, invoke `aws lambda invoke --function-name <project>-mongodb-mcp-<env>` with a mongodb_query payload — should return `statusCode: 200`, not `errorType: Error`.

---

## Voyage AI on SageMaker — three env surfaces, all required

**Symptom:** Agents respond "the catalog appears to be empty" to product/troubleshoot queries even after `voyage-3.5-lite` SageMaker endpoint is `InService` and `db-seeding/seed-embeddings.ts` has written 1024-d Voyage embeddings into Atlas.

**Cause:** `VOYAGE_SAGEMAKER_ENDPOINT` must be set in **three** places, not one:

1. **EC2 API** (`.env.live` → `/opt/multiagent/.env.live`) — used when the API embeds queries directly (in-process / fallback path).
2. **AgentCore Runtime env vars** (orchestrator + 3 specialists) — used when the runtime embeds queries before calling the Lambda MCP `mongodb_vector_search` tool. Updated via `aws bedrock-agentcore-control update-agent-runtime --environment-variables ...` in `deploy.sh` Phase 6b.
3. **Atlas vector index dimensions must match the request `output_dimension`.** voyage-3.5-lite defaults to **2048-d** but our index is sized for **1024-d** (Titan v2 wire-compat). The adapter must pass `output_dimension: 1024` and the seed script must do the same — both honour `VOYAGE_OUTPUT_DIM` env (default `1024`).

If any one is missing the call falls through to Bedrock Titan, returns Titan-1024-d vectors against a Voyage-1024-d-seeded index, and similarity scores are too low to surface results.

**Rule:** When changing the embedding provider/dimension, walk all three surfaces. `deploy.sh` already handles surfaces (1) and (2); surface (3) is enforced in `api/src/adapters/voyage-embedding.ts` and `db-seeding/seed-embeddings.ts`. A re-seed (`REWIRE_EMBEDDINGS=1`) is required whenever the provider or dimension changes — old embeddings live in a different vector space.

**Regression check:** From a Cognito-authed Streamlit/curl chat, ask a query that should match seeded data (e.g. "rugged outdoor widget for a workshop"). Expected: a SKU returns ranked first. If you get "catalog appears empty", check (a) `aws lambda get-function-configuration` env var `MONGODB_URI` is the awsPrivateLink-direct URI (Phase 5c), (b) `aws bedrock-agentcore-control get-agent-runtime ... --query environmentVariables.VOYAGE_SAGEMAKER_ENDPOINT` is non-null on every runtime, (c) the Atlas index `numDimensions` matches what the adapter requests.

---

## API container imports `lambda/mongodb-mcp/guards.mjs` from outside `/app`

**Symptom:** API container on EC2 crash-loops with `Cannot find module '../../../lambda/mongodb-mcp/guards.mjs' from '/app/src/adapters/mongo-data.ts'` even though `lambda/mongodb-mcp/guards.mjs` exists locally and the Dockerfile `COPY`s it.

**Cause:** `api/src/adapters/mongo-data.ts` imports the shared guards module via `../../../lambda/mongodb-mcp/guards.mjs`. The path uses **three** `..` because the source-tree layout has `api/` one level under repo root. In the Docker image, `/app/src/adapters/mongo-data.ts` going up three levels lands at the **filesystem root** (`/`), not `/app`. So `COPY lambda/mongodb-mcp/guards.mjs ./lambda/mongodb-mcp/guards.mjs` (which puts it at `/app/lambda/...`) doesn't match — the import resolves to `/lambda/mongodb-mcp/guards.mjs`.

**Rule:** Copy guards to the **filesystem root** so the relative import resolves the same way at runtime as in source. `api/Dockerfile` does this with `COPY lambda/mongodb-mcp/guards.mjs /lambda/mongodb-mcp/guards.mjs` (note absolute `/lambda/...` destination, not `./lambda/...`). Same for `guards.d.mts`.

**Regression check:** `docker build -f api/Dockerfile -t test . && docker run --rm test ls /lambda/mongodb-mcp/` should list `guards.mjs` and `guards.d.mts`. `/app/lambda/` should NOT exist.

---

## Appendix — future entries

Add new sections above this appendix only when the **persistent pitfalls** bar is met (see Purpose). Put merge blockers or hung-test hazards near the top under **Do not regress**.
