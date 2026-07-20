# Demo script — live multi-agent (Claude models + real Atlas data)

Use this for **live screen share** demos against the running local stack or a deployed environment.

**Stack:** API `:3000` + Streamlit UI `:8501` — Claude Haiku 4.5 (orchestrator + job-match + career-coach) + Claude Sonnet 4.6 (company-intel) + MongoDB Atlas M10 + Bedrock KB.

**Audience:** technical buyers, platform engineers, or leadership who care that **new behavior ships by editing markdown** (`config/agents/`, `config/skills/`) rather than forking JavaScript.

> ⚠️ **Seed-data gap.** `career_paths`, `skills_taxonomy`, `compensation_data`, and `companies` are seeded by `db-seeding/seed-all.ts`. The `jobs`, `candidates`, and `interview_prep` collections that `job-match` needs have **no seeder yet**, so the scenes below deliberately exercise `career-coach` and `company-intel` only. Add a `job-match` scene once those fixtures land.

**Runtime:** ~12–14 minutes for the full arc; ~5 minutes for a tight cut (scenes 1 + 2 + 6).

---

## Before the demo

Ensure AWS creds are fresh and both services are running.

```bash
# 1. Verify creds
source .env && aws sts get-caller-identity

# 2. Start stack (kill old processes first)
lsof -ti:3000,8501 | xargs kill -9 2>/dev/null
source .env && source .env.live && export PATH=”$HOME/.bun/bin:$PATH”
cd api && nohup bun run dev > ../logs/api.log 2>&1 &
~/.venvs/multiagent-ui/bin/streamlit run ui/app.py --server.headless true &

# 3. Confirm health
curl -s http://localhost:3000/health | python3 -m json.tool
```

Open **http://localhost:8501** in your browser.

**Presenter line:** *”Everything you see is driven from markdown in `config/agents/` and `config/skills/`. The API hot-reloads them — changing agent behavior is a markdown edit, not a code deploy.”*

---

## Scene 0 — Orient the UI (30 s)

1. Sidebar: point at **Active session**, **New session**, **Target agent**.
2. Open **About this agent** on **Orchestrator** — read the one-line description.
3. **Wow hook:** *“Specialists are separate agents with their own tools and skills; the orchestrator only routes.”*

---

## Scene 1 — Swarm: skill-gap plan (handoff + real data) (~2.5 min)

Target agent = **orchestrator**.

```text
I'm a backend engineer and I want to move into machine learning. What do I need to learn?
```

**Call out while it streams:**
- 🔀 **Handoff: orchestrator → career-coach** — Strands Swarm, not a hardcoded `if`
- Real Atlas hybrid search returns **`path-backend-to-ml-engineer`** → target role **Machine Learning Engineer**, core skills **python** and **machine learning**, plus a 3-milestone roadmap with `estimatedWeeks`

**Presenter line:** *"The orchestrator has no tools. It routes. The specialist queries real MongoDB Atlas — same data that would back a production talent portal."*

---

## Scene 2 — Company intel: culture + sentiment, grounded (~2.5 min)

New session, **orchestrator**.

```text
What's it like to work at Lumen Retail? I care about mentorship and remote flexibility.
```

**Call out:**
- Handoff to **company-intel** (the only Sonnet specialist — long grounded narratives)
- Hybrid search on `companies` + `bedrock_kb_retrieve` for anything the profile does not cover
- Agent returns `cultureSignals` and `engineeringPractices` **verbatim**, presents **pros and cons together**, and states `sentimentScore` with its `asOf` date

**Presenter line:** *"The 'always show cons with pros' rule is in `SKILL.md` — one line of markdown. No code change required to tighten or loosen it."*

---

## Scene 3 — Compensation: benchmark + negotiation framing (~2 min)

New session, **orchestrator**.

```text
What should a senior Machine Learning Engineer in Austin be paid?
```

**Call out:**
- Handoff to **career-coach** again — same agent, second workflow (compensation, Steps 5–7 of its `SKILL.md`)
- Pre-filters `compensation_data` on `seniority: "senior"` and `region: "us-south"` **before** vector scoring
- Returns the `baseSalary` / `totalComp` percentile bands with `currency`, `asOf`, and `sampleSize` — never a bare number

**Presenter line:** *"One agent, two workflows, one markdown file. Adding compensation did not add a runtime."*

---

## Scene 4 — Direct specialist (speed round) (~1.5 min)

Click **New session**. Set **Target agent** to **company-intel**.

```text
Compare Cloudpeak Systems and Northwind Analytics for someone who wants high ownership.
```

**Call out:** Agent queries Atlas twice, presents both side by side against the stated priority — no orchestrator hop.

**Presenter line:** *"Target a specialist directly for power users or API integrations. Same agent, same tools, no routing overhead."*

---

## Scene 5 — Multi-intent: skill gap + company research in one prompt (~2 min)

New session, **orchestrator**.

```text
What skills do I need to become a Staff Software Engineer, and is Vertex Commerce a good place to do it?
```

**Call out while it streams:**
- The orchestrator recognises **two distinct intents** in a single message
- 🔀 **Parallel dispatch: orchestrator → career-coach** queries Atlas, returns `path-senior-to-staff-engineer` (technical strategy, cross-team influence, architecture)
- 🔀 **Parallel dispatch: orchestrator → company-intel** queries the `companies` collection, returns Vertex Commerce's culture signals and sentiment
- Both specialist responses are **collated into a single coherent reply** — the user also sees two separate handoffs

**What to show in Trace Viewer:**
- Two `agent.handoff` events with different `targetAgent` values in the same turn
- Each specialist emits its own `mongo.vector_search` tool event
- A final `orchestrator.collate` step assembles the merged answer

**Presenter line:** *"One prompt, two specialists, one answer. The orchestrator fans out automatically because each intent maps to a different `handoffs` entry in `orchestrator.agent.md` — no code, no conditional routing table."*

---

## Scene 6 — Config is the product (~2 min)

Switch to the **repo** (IDE or GitHub):

1. Open [`config/agents/orchestrator.agent.md`](../../config/agents/orchestrator.agent.md) — **handoffs** table in frontmatter.
2. Open [`config/skills/career-coach/SKILL.md`](../../config/skills/career-coach/SKILL.md) — tool usage + `read_skill_resource` paths.
3. Open the [`db-seeding/`](../../db-seeding/) `seed-{career-paths,skills-taxonomy,compensation,companies}.ts` scripts — the same fixtures that live in Atlas, served through the MongoDB MCP AgentCore Runtime.

**Presenter line:** *“A new vertical is mostly new markdown under `config/` plus data shape—not a new microservice per customer.”*

---

## Tight 5-minute cut

1. Scene 0 — orient UI (30 s)
2. Scene 1 — backend → ML skill gap (2 min)
3. Scene 2 — Lumen Retail company intel (1.5 min)
4. Scene 6 — show `config/` (1 min)

---

## If something breaks

| Symptom | Likely fix |
|---------|------------|
| API exits at boot with "AGENTCORE_ORCHESTRATOR_ARN is not set" | Source `.env.live` (or export the ARN) before `bun run dev` |
| No handoff lines | The orchestrator runtime is in single-agent mode; set `ORCHESTRATOR_MODE=swarm` on that runtime and redeploy |
| Empty / errors | API not running; check `curl -s http://127.0.0.1:3000/health` |
| UI can’t reach API | `STREAMLIT_API_URL` / firewall; default `http://127.0.0.1:3000` |

---

## After the demo

- Point to [`reference/env-vars.md`](../reference/env-vars.md) for the full env matrix. Optional setup (persistence, auth, real backends) is summarized in **[Before the demo](#before-the-demo)** above.
- Point to [`README.md`](../README.md) "Authoritative source files" for what’s still open in the production story (multi-tenancy, AgentCore Code Interpreter, etc.).
- **Docker option:** run `docker compose up --build` (or `make docker-up`) from the repo root to show the full stack in containers — no Bun or Python install required. The API still requires `AGENTCORE_ORCHESTRATOR_ARN` and AWS credentials in the environment.

---

## KT checklist (handoff for the next owner)

Use this after a demo session so someone else can **run it again** and **explain the boundaries** without you in the room.

| # | Topic | They should be able to… |
|---|--------|-------------------------|
| 1 | **Run the stack** | Source `.env` + `.env.live`, then start API (`bun run dev` in `api/`) and UI (`streamlit run app.py` in `ui/`) pointing at the deployed AgentCore Orchestrator runtime. |
| 2 | **Swarm vs single** | Toggle `ORCHESTRATOR_MODE=swarm` on the orchestrator runtime, pick **orchestrator** vs a specialist in the UI, and state what changes (handoffs vs direct agent). |
| 3 | **Where config lives** | Open `config/agents/*.agent.md` (persona + `handoffs` + `tools`) and `config/skills/*/SKILL.md` (domain instructions + progressive disclosure). |
| 4 | **Tool path** | All Mongo tools resolve to MCP calls through AgentCore Gateway (`AGENTCORE_GATEWAY_URL`); the Gateway target invokes the MongoDB MCP AgentCore Runtime. `MCP_SERVER_URL` is local-development only. |
| 5 | **API contract** | Name `POST /chat` (SSE), `GET /agents`, `GET /skills`, `GET /sessions`, `DELETE /sessions/:id`, `GET /http-tools`, and where events are documented ([`docs/api-reference.md`](../api-reference.md)). |
| 6 | **What’s actually missing** | List at least three **not implemented** items (configurable behavior belongs in [Before the demo](#before-the-demo)): e.g. **AgentCore Code Interpreter** wired into specialist flows; **CI/CD** as the primary deploy path; **ECS/ALB** rollout beyond EC2 + container images; customer-scoped multi-tenancy on operational collections. Source of truth: [`README.md`](../README.md). |
| 7 | **Extend a vertical** | Describe the steps to add a new skill folder + reference an agent’s `skills:` list (or walk through [`docs/skills-authoring-guide.md`](../skills-authoring-guide.md) / [`docs/agent-authoring-guide.md`](../agent-authoring-guide.md)). |
| 8 | **Regression** | Run `cd api && bun run typecheck && bun test` before a big demo or config change. |

**Optional deep dives (assign reading):** [`AGENTS.md`](../../AGENTS.md) (contributor rules), [`docs/architecture.md`](../architecture.md), [`docs/configuration-guide.md`](../configuration-guide.md).
