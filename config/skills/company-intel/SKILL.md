---
name: company-intel
description: >-
  Researches a hiring company's culture, engineering practices, funding/stage, size, and
  employee sentiment using hybrid search (vector + full-text) on the companies collection,
  enriched by the Bedrock knowledge base. Use this skill when a candidate asks about a
  specific company, what it is like to work there, its reputation, funding or size, or wants
  the companies behind their job matches profiled.
metadata:
  author: anujpanchal
  version: "1.0"
  domain: recruitment
---

# Company Intel Skill

## What You Can Do

1. **Resolve the company target** — identify which company (or companies) the candidate wants
   profiled, including companies referenced from prior job-match results.
2. **Retrieve the structured company record** — run a hybrid vector + full-text search against
   the `companies` collection.
3. **Enrich with the knowledge base** — when the record is thin or the candidate asks a broad
   question, pull additional context from the Bedrock knowledge base.
4. **Present a balanced profile** — combine both sources into an attributed summary with
   strengths and watch-outs.

---

## Step 1 — Resolve the Company Target

When a candidate asks about a company:

1. Identify the **company name(s)** from the message or the recent conversation (e.g. a
   company named in an earlier job-match result). If more than three companies are requested,
   ask the candidate to pick the top ones to profile.

2. If no company is named and none is available from context, ask **one** clarifying question
   and stop.

3. Build a `queryText` string in this format for each company:
   ```
   <company name>
   <industry if known>
   culture, engineering practices, funding stage, employee sentiment
   ```

---

## Step 2 — Hybrid Company Search

Perform a hybrid search against the `companies` collection in **a single tool call** per
company. The MCP runtime runs the vector and lexical legs in parallel and merges them with
Reciprocal Rank Fusion server-side — do **not** run a separate `$search` aggregation or
compute RRF in-band.

### Single hybrid call

Call `mongodb_vector_search` with:
- `collection`: `companies`
- `queryText`: the string built in Step 1.3. The runtime embeds this server-side for the
  vector leg and uses it verbatim for the BM25 lexical leg. **Do NOT call
  `embed_multimodal_content` — the search runtime embeds `queryText` internally.**
- `indexName`: `companies_vector_index`
- `hybrid`: `true`
- `lexicalIndex`: `companies_text_index`
- `lexicalPath`: `name` — single text-indexed field the BM25 leg searches, so an exact company
  name matches strongly. (Atlas Search hybrid mode is single-path; broader recall is recovered
  by the vector leg.)
- `limit`: 3 — final fused result count.
- `fetchK`: 8 — per-leg over-fetch before RRF merge.

Each result carries a `_score` (RRF score) and a `_sources` array. Pick the record whose
`name` matches the requested company. If the exact company is not among the results, do a
direct `mongodb_query` → `findOne` on `companies` by `companyId` or an exact-name filter
`{ "name": "<company>" }` with `"projection": { "embedding": 0 }`.

---

## Step 3 — Enrich with the Knowledge Base

Use `bedrock_kb_retrieve` when:
- The `companies` record is missing or thin (few culture/sentiment fields), OR
- The candidate asks a broad question the structured fields do not answer (e.g. "how do
  engineers describe the on-call culture?").

Call `bedrock_kb_retrieve` with a natural-language query combining the company name and the
candidate's focus (e.g. "Lumen Retail engineering on-call culture and work-life balance").
Treat the returned passages as supporting evidence and attribute them as knowledge-base
context. Never present KB passages as first-person company statements.

If neither the collection nor the KB returns anything for the company, tell the candidate
honestly and do not guess.

---

## Step 4 — Present a Balanced Profile

Present each company in this structure:

1. **Headline** — one line: `name`, `industry`, `stage`, and `headcount` band.
2. **Culture & practices** — from `cultureSignals` and `engineeringPractices` (present the
   documented items; do not editorialize beyond them).
3. **Stage & size** — from `stage`, `foundedYear`, `headcount`, and `fundingTotal` when
   present.
4. **What people say** — from `sentimentSummary` and any KB passages, clearly labeled as
   employee sentiment / external context. Include both positive signals and documented
   watch-outs (`pros` / `cons` when present).
5. **Fit note** — one balanced sentence on who this environment tends to suit, grounded in the
   retrieved signals.

Cite `companyId` when you reference a specific record. When profiling multiple companies,
present them as parallel sections so the candidate can compare.

---

## References

**References** (on demand): the API only serves files for skills that are **allowed for this
agent** and **already activated** (`activate_skill`, or pre-activation for specialists). Call
**`read_skill_resource`** with **`skillName`** `company-intel` and **`path`** (relative to that
skill folder), e.g.:

- `references/collections-schema.md` — Full document schema, index definitions, and field
  notes for the `companies` collection. Load this when you need to verify field names, filter
  parameters, or construct precise queries.

For the **company-intel** specialist agent, this skill is **pre-activated** at turn start, so
`read_skill_resource` works immediately. If you see `skill_not_activated`, run
**`activate_skill`** with `company-intel` first.

---

## Edge Cases

**Company not in the dataset:** If neither hybrid search nor a direct `findOne` finds the
company, try `bedrock_kb_retrieve` once. If that is also empty, tell the candidate the company
is not on file and offer to profile a company that is.

**Thin record:** If the record exists but has few sentiment/culture fields, present what is
there and enrich with the KB (Step 3) rather than inventing detail.

**Multiple companies requested:** Profile up to three per turn. If more are requested, ask the
candidate to prioritize.

**Ambiguous name (multiple matches):** Ask the candidate to confirm which one (by industry or
location) before profiling.

## Boundaries

- This skill handles company research — culture, practices, stage/size, and sentiment — only.
- Do not provide salary figures or compensation benchmarks — that belongs to the compensation
  specialist.
- Do not design learning plans or analyze skill gaps — that belongs to the career-development
  specialist.
- Do not match the candidate to open job listings or write interview prep — that belongs to
  the job-match specialist.
- Do not speculate about a company's future, layoffs, or stock performance.
- Never reveal raw MongoDB `_id` values; use `companyId`.
- Never fabricate company facts, culture, funding, headcount, or sentiment. All responses must
  be grounded in collection or knowledge-base data, and presented in a balanced way.
