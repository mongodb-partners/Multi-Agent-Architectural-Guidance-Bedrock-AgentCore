---
name: career-coach
description: >-
  Produces a skill-gap analysis and a phased learning roadmap for a candidate targeting a
  specific role (using hybrid search on the career_paths and skills_taxonomy collections),
  AND retrieves compensation benchmarks — base/total/percentiles, benefits norms, and
  grounded negotiation ranges — for a role at a given seniority and location (using hybrid
  search on the compensation_data collection). Use this skill when a candidate asks what
  skills they need for a target role, how to transition between roles, how to reach a more
  senior level, wants a learning/development plan, OR asks what a role pays, what salary to
  expect or ask for, how pay varies by location or seniority, or how to frame a compensation
  negotiation.
metadata:
  author: anujpanchal
  version: "2.0"
  domain: recruitment
---

# Career Coach Skill

This skill covers two workflows. Pick the one(s) that match the candidate's request:

- **Career development** (Steps 1–4) — skill-gap analysis and a phased learning roadmap.
- **Compensation** (Steps 5–7) — salary/benefits benchmarks and a grounded negotiation range.

If the candidate asks about both (e.g. "what does this role pay and what skills do I need?"),
run both workflows and present the answer in two clearly-labelled sections.

## What You Can Do

### Career development

1. **Resolve the candidate's current skill set** — from the skills stated in the message, or
   from a stored `candidates` profile when a `candidateId` is provided.
2. **Retrieve the target role's requirements and progression path** — run a hybrid vector +
   full-text search against the `career_paths` collection.
3. **Compute the skill gap** — diff the candidate's current skills against the target role's
   `requiredSkills`, classifying each as covered, partial, or missing.
4. **Assemble a phased learning roadmap** — enrich each missing/partial skill with learning
   resources from the `skills_taxonomy` collection and order them into time-boxed phases.

### Compensation

5. **Resolve the compensation query** — extract the role title, seniority, and location the
   candidate is asking about.
6. **Retrieve matching benchmarks** — run a hybrid vector + full-text search against the
   `compensation_data` collection, pre-filtered by `seniority` and (when possible) region.
7. **Present a grounded band and negotiation range** — translate the retrieved percentiles
   into a plain-language pay band, benefits summary, and an "ask" range, all sourced from the
   data.

---

## Step 1 — Resolve Current Skills and Target Role

When a candidate asks about skills, a transition, or a development plan:

1. Determine the **target role** from the conversation (e.g. "Machine Learning Engineer",
   "Staff Backend Engineer"). If it is not clear, ask **one** clarifying question and stop.

2. Determine the **candidate's current skills**:
   - If the message lists skills, seniority, or years of experience, use those directly.
   - If the candidate provides a `candidateId`, call `mongodb_query` → `findOne` on the
     `candidates` collection with `{ "candidateId": "<id>" }` and
     `"projection": { "embedding": 0 }`. Use `profile.skills`, `profile.seniority`, and
     `profile.yearsExperience`.
   - If neither is available, ask the candidate to paste their key skills or their current
     role, then stop.

3. Build a `queryText` string in this format for the target-role search:
   ```
   <target role title>
   Current seniority: <candidate seniority or "unspecified">
   Current skills: <comma-separated current skills>
   Goal: transition to <target role title>
   ```

---

## Step 2 — Hybrid Career-Path Search

Perform a hybrid search against the `career_paths` collection in **a single tool call**. The
MCP runtime runs the vector and lexical legs in parallel and merges them with Reciprocal Rank
Fusion server-side — do **not** run a separate `$search` aggregation or compute RRF in-band.

### Single hybrid call

Call `mongodb_vector_search` with:
- `collection`: `career_paths`
- `queryText`: the string built in Step 1.3. The runtime embeds this server-side for the
  vector leg and uses it verbatim for the BM25 lexical leg. **Do NOT call
  `embed_multimodal_content` — the search runtime embeds `queryText` internally.**
- `indexName`: `career_paths_vector_index`
- `hybrid`: `true`
- `lexicalIndex`: `career_paths_text_index`
- `lexicalPath`: `description` — single text-indexed field the BM25 leg searches. It carries
  the densest mix of role title, required-skill, and progression signal. (Atlas Search hybrid
  mode is single-path; multi-field recall is recovered by the vector leg.)
- `limit`: 3 — final fused result count.
- `fetchK`: 8 — per-leg over-fetch before RRF merge.

Each result carries a `_score` (RRF score) and a `_sources` array (`["vector"]`,
`["lexical"]`, or both). Use the top-ranked path whose `targetRole` best matches the
candidate's stated target. Do not re-rank or re-fuse yourself.

---

## Step 3 — Compute the Skill Gap

Diff the candidate's current skills against the chosen path's `requiredSkills` array:

- **Covered** — the candidate already has this skill (exact or clear synonym match).
- **Partial** — the candidate has a related/foundational skill but not the specific one.
- **Missing** — the candidate has no evidence of this skill.

For every **missing** and **partial** skill, look up learning resources. In **one**
`mongodb_query` → `find` call on `skills_taxonomy`, pass a filter matching all the gap
skills at once, e.g.:

```json
{
  "collection": "skills_taxonomy",
  "operation": "find",
  "filter": { "skillId": { "$in": ["<skillId1>", "<skillId2>"] } },
  "projection": { "embedding": 0 }
}
```

If the path stores `requiredSkills` as skill names rather than IDs, filter on
`{ "name": { "$in": [ ... ] } }` instead. Use `references/collections-schema.md` to confirm
the exact field names before constructing the query.

---

## Step 4 — Present the Skill Gap and Roadmap

Present the result in this structure:

1. **Where you are** — one sentence summarizing the candidate's current level and strongest
   relevant skills (the covered set).
2. **The gap** — a short list of missing and partial skills, each with a one-line note on why
   the target role needs it (from the path's `requiredSkills` notes when present).
3. **Your roadmap** — the path's phased plan. Order the phases using the path's `milestones`
   (each milestone has an `order`, `title`, `skills`, and `estimatedWeeks`). Under each
   milestone, list the concrete learning resources retrieved from `skills_taxonomy`
   (`name`, `resourceType`, and `resources` links/titles) verbatim.
4. **Estimated timeline** — sum the `estimatedWeeks` across milestones the candidate still
   needs, and state it as an approximate range.

Cite `pathId` when you reference a specific progression path.

---

## Step 5 — Resolve Role, Seniority, and Location (compensation)

When a candidate asks about pay, expectations, or negotiation:

1. Extract from the conversation:
   - **Role title** (e.g. "Machine Learning Engineer", "Staff Backend Engineer").
   - **Seniority** — one of `junior` | `mid` | `senior` | `staff`. If not stated, infer from
     the role title or the candidate's stated years of experience; otherwise leave unset.
   - **Location** — a city/region or "remote". Map it to a `region` value where possible
     (see `references/collections-schema.md` for the region enum). If not stated, leave unset
     and note that the benchmark will be nationwide.

2. If the **role** is missing, ask **one** clarifying question and stop. Seniority and
   location are optional — proceed without them if not provided.

3. Build a `queryText` string in this format:
   ```
   <role title>
   Seniority: <seniority or "unspecified">
   Location: <location or "any / remote">
   ```

---

## Step 6 — Filtered Hybrid Compensation Search

Perform a hybrid search against the `compensation_data` collection in **a single tool call**.
The MCP runtime runs the vector and lexical legs in parallel and merges them with Reciprocal
Rank Fusion server-side — do **not** run a separate `$search` aggregation or compute RRF
in-band.

### Single hybrid call

Call `mongodb_vector_search` with:
- `collection`: `compensation_data`
- `queryText`: the string built in Step 5.3. The runtime embeds this server-side for the
  vector leg and uses it verbatim for the BM25 lexical leg. **Do NOT call
  `embed_multimodal_content` — the search runtime embeds `queryText` internally.**
- `indexName`: `compensation_vector_index`
- `hybrid`: `true`
- `lexicalIndex`: `compensation_text_index`
- `lexicalPath`: `role` — single text-indexed field the BM25 leg searches. It carries the
  densest role/title signal. (Atlas Search hybrid mode is single-path; multi-field recall is
  recovered by the vector leg.)
- `limit`: 3 — final fused result count.
- `fetchK`: 8 — per-leg over-fetch before RRF merge.
- `filter`: when seniority and/or region are known, pass them as pre-filter fields, e.g.
  `{ "seniority": "senior", "region": "us-south" }`. Only include keys you actually resolved
  in Step 5. `seniority` and `region` are declared as `filter` fields on the vector index.

Each result carries a `_score` (RRF score) and a `_sources` array. Use the top-ranked record
whose `role`, `seniority`, and `region` best match the query. Do not re-rank or re-fuse
yourself.

---

## Step 7 — Present the Band and Negotiation Range

From the chosen benchmark document, present:

1. **Coverage line** — the exact `role`, `seniority`, `region`, and `asOf` date the benchmark
   applies to, so the candidate knows the basis.
2. **Pay band** — from `baseSalary` and `totalComp`, show:
   - Base: `p25`–`p75` as the typical range, and note the `p50` (median).
   - Total comp: `p25`–`p75`, and note the `p50`.
   - State the `currency` and whether figures are annual.
3. **Benefits & equity** — summarize `benefits` (array of strings) and `equityNote` verbatim.
4. **Suggested ask range** — frame a realistic ask: for a strong candidate, anchor near the
   `p50`–`p75` of total comp; for a stretch, mention `p90` if present. Present this as a range
   and clearly label it as guidance derived from the retrieved percentiles.

Cite `benchmarkId` when you reference a specific record.

---

## References

**References** (on demand): the API only serves files for skills that are **allowed for this
agent** and **already activated** (`activate_skill`, or pre-activation for specialists). Call
**`read_skill_resource`** with **`skillName`** `career-coach` and **`path`** (relative to that
skill folder), e.g.:

- `references/collections-schema.md` — Full document schemas, index definitions, and field
  notes for the `career_paths`, `skills_taxonomy`, and `compensation_data` collections
  (including the `region` enum and percentile fields). Load this when you need to verify field
  names, the region mapping, filter parameters, or construct precise queries.

For the **career-coach** specialist agent, this skill is **pre-activated** at turn start, so
`read_skill_resource` works immediately. If you see `skill_not_activated`, run
**`activate_skill`** with `career-coach` first.

---

## Edge Cases

**Target role not found in `career_paths`:** If the hybrid search returns no path whose
`targetRole` reasonably matches, tell the candidate honestly and suggest a closely related
role that does exist, or ask them to rephrase. Do not invent a progression path.

**Candidate already meets all requirements:** If every `requiredSkill` is covered, say so and
present the path's advanced/next-level milestones (highest `order`) as stretch goals.

**No learning resources for a gap skill:** If `skills_taxonomy` has no document for a gap
skill, list the skill in the gap section and note that no structured resource is on file yet —
do not fabricate a course or link.

**Only a `candidateId` and no target role:** Ask the candidate which role they are targeting
before running any search.

**No exact compensation match for the combination:** If no `compensation_data` record matches
the role+seniority+region, relax the pre-filter to seniority-only or role-only and note to the
candidate that the figure is a broader benchmark, not their exact combination. Never
extrapolate a number that is not in the data.

**Compensation location not covered:** If the region has no data, present the
nationwide/remote benchmark for the role and say the location-specific figure is not on file.

**Stale benchmark:** If the top compensation result's `asOf` is old, present it but flag the
date so the candidate can weigh it.

**Candidate asks to negotiate a specific offer:** Provide the grounded range and framing, but
do not promise an outcome and do not give legal or tax advice.

## Boundaries

- This skill handles skill-gap analysis, role transitions, learning roadmaps, AND
  compensation benchmarking, benefits norms, and negotiation framing.
- Do not research or evaluate specific employers — that belongs to the company-research
  specialist.
- Do not match the candidate to open job listings or write interview prep — that belongs to
  the job-match specialist.
- Do not give legal, tax, or immigration advice, and never promise a specific offer outcome.
- Never reveal raw MongoDB `_id` values; use `pathId`, `skillId`, `candidateId`, or
  `benchmarkId`.
- Never fabricate career paths, skills, courses, certifications, timelines, figures, ranges,
  benefits, or percentiles. All responses must be grounded in collection data, and all
  compensation numbers must be presented as ranges with their source basis.
