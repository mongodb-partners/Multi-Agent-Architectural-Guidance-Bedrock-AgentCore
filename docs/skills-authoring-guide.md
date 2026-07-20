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

**`http-tools.json`** (optional) declares Strands tools that invoke **HTTPS endpoints** — typically **AWS Lambda Function URLs** or **API Gateway** HTTP APIs. Same trust model as `scripts/*.mjs`: colocated with the skill, reviewed like code. Agents enable each tool by listing **`skill-folder/localToolName`** in `.agent.md` `tools:` (e.g. `job-match/notify_ats_lambda`). The skill must be **allowed and activated** before a call succeeds (like `read_skill_resource`). SSRF **host allowlists** belong in repo-root `config/http-tools.json` → `security`. Details: [Configuration Guide § 3 — Skill configuration](configuration-guide.md#3-skill-configuration-configskillsskill) and [§ 4 — HTTP tool configuration](configuration-guide.md#4-http-tool-configuration), plus the canonical [tool catalog](reference/tools.md).

**Minimal `http-tools.json` example** (inside a skill folder):

```json
{
  "tools": [
    {
      "name": "notify_ats_lambda",
      "description": "POST an application event to the ATS Lambda.",
      "method": "POST",
      "url": "${ATS_NOTIFY_LAMBDA_URL}",
      "parameters": [
        { "name": "jobId", "type": "string", "description": "Job listing ID", "required": true },
        { "name": "event", "type": "string", "description": "e.g. viewed, applied", "required": true }
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
name: job-match
version: "1.0"
description: >-
  Matches candidate CVs to job openings using hybrid search on the jobs
  collection, and provides interview preparation questions. Use this skill
  whenever a candidate submits a CV, asks about job matches, or requests
  interview prep for a specific role.
tags: [jobs, matching, interview-prep]
resources:
  - name: Collections Schema
    file: references/collections-schema.md
    description: Field definitions and index names for the jobs, candidates, and interview_prep collections
  - name: Ranking Policy
    file: references/ranking-policy.md
    description: How to weight skill overlap, seniority, and location when ranking matches
scripts:
  - name: score-match
    file: scripts/score-match.mjs
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

- **Specialist agents** (e.g. `job-match`) pre-activate all their listed skills before the first model call. The full `SKILL.md` body is in the system prompt from the start.
- **The orchestrator** (no `skills:` listed) gets the discovery index only — a compact list of all skill names and descriptions so it can route intelligently.
- **At runtime**, any agent can call the `activate_skill` tool to load a skill body mid-conversation. The full instructions are returned in the tool result and the model uses them immediately.

This means you can have detailed, lengthy reference material without inflating the context for every message. The agent will ask for a reference file only when it encounters a situation that needs it.

In the skill body, signal to the agent when to load a reference file:

```markdown
## Handling Unfamiliar Job Fields

If you encounter a job document field not described here, use read_skill_resource
with skillName "job-match" and path "references/collections-schema.md"
(after this skill is activated — automatic for the job-match specialist).
```

---

## Writing Good Skill Instructions

### Be specific about data access

Don't say "look up the career path". Say exactly which collection to query and which fields to use:

```markdown
## Looking Up a Career Path

To find a specific path, query the `career_paths` collection:
- Use `pathId` if you already resolved one from a previous turn
- Use `targetRole` + filter on `seniority` if the candidate named a goal role
- Fall back to `mongodb_vector_search` on `career_paths_vector_index` when the
  goal is described loosely rather than named
- Always include `pathId`, `targetRole`, `requiredSkills`, and `milestones` in the projection
```

### Tell the agent what to do with what it finds

Don't assume the agent knows how to format a result. Be explicit:

```markdown
## Presenting a Skill Gap

After retrieving a career path:
1. Lead with the count of `core` skills the candidate is missing, in plain language
2. Show each missing skill with its `importance` and the `note` explaining why it matters
3. Show the milestone sequence only after the gap itself is clear
4. Always state total `estimatedWeeks` so the candidate can judge the commitment
```

### Define the boundaries

Specify what this skill does not do and what happens instead:

```markdown
## Out of Scope

This skill handles job matching and interview prep only.

- Salary and compensation questions → hand off to `career-coach`
- Skill-gap analysis and learning roadmaps → hand off to `career-coach`
- Questions about a specific hiring company's culture or funding → hand off to `company-intel`
```

### Document edge cases explicitly

Edge cases are where agents fail most often without guidance:

```markdown
## Edge Cases

**No career path found:** The candidate may have named the role differently.
Ask them to describe the work they want to do before saying no path exists.

**Multiple matching paths:** Ask the candidate to confirm their target
seniority before proceeding.

**Benchmark `sampleSize` is small:** Do not present the percentile band as
authoritative. State the sample size and frame the figure as indicative.
```

---

## Example: Full SKILL.md

```markdown
---
name: company-intel
version: "1.0"
description: >-
  Researches hiring companies — culture, engineering practices, funding stage,
  and employee sentiment. Use this skill when a candidate asks about a specific
  company by name, whether it is a good place to work, or wants to compare the
  companies behind their job matches.
tags: [companies, research, culture]
resources:
  - name: Collections Schema
    file: references/collections-schema.md
    description: Field definitions and index names for the companies collection
---

# Company Intel Skill

## What You Can Do

Research companies from the MongoDB Atlas `companies` collection using hybrid
search (vector + BM25), enriched by the Bedrock knowledge base. Ground every
claim in a retrieved document.

## Finding a Company

Use the `mongodb_vector_search` tool with `hybrid: true` against the
`companies` collection, `lexicalIndex: "companies_text_index"` and
`lexicalPath: "name"`. Pre-filter on `industry` or `stage` when the candidate
names one.

Include these fields in the result: `name`, `industry`, `stage`, `headcount`,
`fundingTotal`, `cultureSignals`, `engineeringPractices`, `sentimentSummary`,
`pros`, `cons`, `sentimentScore`, `asOf`.

Call `bedrock_kb_retrieve` when the candidate asks something the company
document does not cover.

## Personalizing the Answer

Check long-term memory for what the candidate said they want from an employer
(remote, mentorship, equity upside, stability). Lead with the signals that
match those stated priorities.

## Presenting Results

- Always present `pros` and `cons` together — never one without the other
- Quote `cultureSignals` and `engineeringPractices` verbatim; do not paraphrase
  them into stronger claims
- State `sentimentScore` alongside the summary, and flag `asOf` if stale
- Cite `companyId`, not `_id`

## Edge Cases

**Company not in the collection:** Say so plainly. Do not infer a company's
culture from its industry or name.

**Candidate asks about salary at the company:** Hand off to `career-coach` —
compensation benchmarks live in `compensation_data`, not here.

**Candidate is comparing companies:** Run one search per company and present
side-by-side, highlighting the differentiator that matters to their stated
priorities.

## Out of Scope

This skill covers company research only.
- Job matching and interview prep → hand off to `job-match`
- Salary benchmarks and negotiation → hand off to `career-coach`
- Applying to a role → not handled by this framework
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
# Seniority Reference

| `seniority` | Meaning | Typical years |
|--------|---------|----------------------|
| junior | Executes scoped tasks with review | 0–2 |
| mid | Owns features end to end | 2–5 |
| senior | Owns systems, mentors others | 5–9 |
| staff | Owns cross-team technical direction | 9+ |
```

---

## Scripts

Scripts live in `scripts/`. Deterministic policy can be **ESM (`.mjs`)** exported functions that the API imports via the generic **`run_skill_script`** tool. (No skill in `config/skills/` ships a script today — the examples below are illustrative.) Heavier automation can later use the AgentCore Code Interpreter. Use scripts for:

- Input validation with complex rules
- Multi-step data transformations
- Formatted report generation
- Integration with external APIs

In the skill body, tell the agent when to use a script:

```markdown
## Scoring a CV Against a Job

Before telling a candidate how well they match, call **`run_skill_script`** with
`skillName='job-match'`, `scriptPath='scripts/score-match.mjs'`,
`exportName='scoreCandidateAgainstJob'`, `args={…candidate, …job}`. Do not compute
the score from memory alone — always run the script.
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

# Smoke-test skill loading via the API (read-only — no Bedrock call)
curl -s http://127.0.0.1:3000/skills
curl -s http://127.0.0.1:3000/agents          # agents show their skills list
curl -s http://127.0.0.1:3000/http-tools       # per-skill HTTP tools metadata
```

The **`GET /skills`** endpoint returns the discovery index (name + description) for all scanned skills. Config is loaded from disk **on each request**, so edits to `SKILL.md` are picked up immediately without a restart.

To exercise a skill end-to-end, point the API at a deployed AgentCore Orchestrator runtime:

```bash
source .env && source .env.live   # exports AGENTCORE_ORCHESTRATOR_ARN
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
name: job-match
version: "1.2"
# Changelog:
# 1.2 - Added remote-only filter edge case. Clarified match scoring requires the script.
# 1.1 - Added ambiguous-seniority edge case.
# 1.0 - Initial version.
---
```

Changes to `description` are high-impact — the orchestrator uses this field to decide when to activate the skill. Test routing behavior after any `description` change.

---

## Observability while authoring

While you iterate, every chat turn against your skill produces a
[trace](api-reference.md#14-tracing-endpoints). The Streamlit Trace
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

See [demo/demo-mode-guide.md](demo/demo-mode-guide.md) for the full UI walkthrough
and env knobs (`MONGO_TRACE_DIAGNOSTIC`, `MONGO_TRACE_EXPLAIN`, etc.).

---

## Related

- [Configuration Guide](configuration-guide.md) — how to wire skills to agents
- [Architecture](architecture.md) — how the skill loader works at runtime
- [API reference](api-reference.md#14-tracing-endpoints) — trace event types
- [Demo / trace UI guide](demo/demo-mode-guide.md) — UI walkthrough
- [agentskills.io specification](https://agentskills.io/specification) — upstream specification
