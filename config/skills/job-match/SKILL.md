---
name: job-match
description: >-
  Matches candidate CVs to job openings using hybrid search (vector + full-text)
  on the jobs collection, and provides interview preparation questions from the
  interview_prep collection. Use this skill when a candidate submits their CV,
  asks about job matches, wants job recommendations, or requests interview prep
  questions for a specific role.
metadata:
  author: anujpanchal
  version: "1.0"
  domain: recruitment
---

# Job Match Skill

## What You Can Do

1. **Parse and store candidate CVs** — extract structured profile data from raw CV text, generate an embedding, and store the candidate document in the `candidates` collection.
2. **Hybrid job search** — run a combined vector search + full-text search against the `jobs` collection and return the top 5 ranked matches with scores.
3. **Interview preparation** — retrieve targeted interview tips and questions from the `interview_prep` collection using vector search.

---

## Step 1 — Storing a Candidate's CV

When a candidate pastes their CV text:

1. Parse the raw CV text to extract structured profile fields:
   - `name`, `email`, `phone`, `location`, `headline`, `summary`
   - `yearsExperience` (integer), `seniority` (`junior` | `mid` | `senior` | `staff`)
   - `skills` (array of lowercase strings)
   - `experience` (array of `{ title, company, startDate, endDate, highlights[] }`)
   - `education` (array of `{ degree, field, institution, year }`)
   - `certifications` (array of strings)

2. Build an `embeddingText` string from the parsed fields in this format:
   ```
   <name>
   <headline>
   Seniority: <seniority>
   Years of experience: <yearsExperience>
   Skills: <comma-separated skills>
   <summary>
   <experience highlights joined by newlines>
   ```

3. Generate a `candidateId` in the format `cand-<8 random hex chars>` (e.g. `cand-2ee32acd`).

4. **In the same model turn**, issue two parallel tool calls:

   **Call A — `mongodb_query` → `insertOne`** on the `candidates` collection. The search in Call B does not depend on this result — both calls can run concurrently.

   ```json
   {
     "collection": "candidates",
     "operation": "insertOne",
     "document": {
       "candidateId": "<generated>",
       "rawCv": "<first 500 characters of original CV text>",
       "profile": {
         "name": "<name>",
         "email": "<email>",
         "phone": "<phone or null>",
         "location": "<location or null>",
         "headline": "<headline or null>",
         "summary": "<summary or null>",
         "yearsExperience": "<integer or null>",
         "seniority": "<junior|mid|senior|staff>",
         "skills": ["<skill1>", "<skill2>"],
         "experience": [{ "title": "", "company": "", "startDate": "", "endDate": "", "highlights": [] }],
         "education": [{ "degree": "", "field": "", "institution": "", "year": "" }],
         "certifications": ["<cert1>"]
       }
     }
   }
   ```

   **Call B — `mongodb_vector_search` hybrid call** as described in Step 2 below, using `embeddingText` as `queryText`.

5. Once both calls return, confirm to the candidate that their profile has been saved and present the job matches together.

---

## Step 2 — Hybrid Job Search

When triggered as part of Step 1 CV ingestion, issue this search as **Call B in the same parallel turn as the `mongodb_query` upsert** (Step 1.4). When re-running matching for a returning candidate, issue it as a standalone call. Either way, perform a hybrid search against the `jobs` collection in **a single tool call**. The MCP runtime executes the vector and lexical legs in parallel and merges them with Reciprocal Rank Fusion server-side, so the model does **not** run a separate `$search` aggregation or compute RRF in-band.

### Single hybrid call

Call `mongodb_vector_search` with:
- `collection`: `jobs`
- `queryText`: the candidate's `embeddingText` (or their raw CV text if embeddingText is unavailable). The runtime embeds this server-side for the vector leg and uses it verbatim for the BM25 lexical leg. **Do NOT call `embed_multimodal_content` — the search runtime embeds `queryText` internally.**
- `indexName`: `jobs_vector_index`
- `hybrid`: `true`
- `lexicalIndex`: `jobs_text_index`
- `lexicalPath`: `description` — single text-indexed field the BM25 leg searches. `description` is chosen because it carries the densest mix of title/skills/seniority signal. (Atlas Search hybrid mode is single-path; multi-field recall is recovered by the vector leg.)
- `limit`: 5 — final fused result count.
- `fetchK`: 10 — per-leg over-fetch before RRF merge (preserves the previous 10+10 → top-5 behaviour).

The result documents come back with a `_score` field carrying the RRF score and a `_sources` array listing which legs each hit appeared in (`["vector"]`, `["lexical"]`, or both). You do **not** need to re-rank, re-fuse, or call `$search` separately.

### Output format

Present results as a ranked list (already ordered by `_score` descending). For each job include:
- Rank number and job title
- Company, location, salary range, and remote flag
- Required seniority and minimum years of experience
- Key skills
- A 1–2 sentence explanation of why the candidate's profile matches this role
- Match confidence: High / Medium / Low (based on skill overlap, seniority alignment, and whether the hit came from both legs — `_sources` of length 2 → stronger signal)

---

## Step 3 — Interview Preparation

When a candidate expresses interest in a specific job and asks for interview questions or prep material:

1. Identify the target role from the conversation context (title, company, or jobId).

2. Build a query string combining the role title, key skills, and any stated focus areas (e.g. "behavioral", "system design", "machine learning").

3. Call `mongodb_vector_search` with:
   - `collection`: `interview_prep`
   - `queryText`: the combined query string
   - `indexName`: `prep_vector_index`
   - `limit`: 5

4. Present the retrieved prep material as structured advice. Include the title, category, and the full content of each result.

5. **Critical constraint**: Only respond with information found in the `interview_prep` collection. Do not generate interview questions or advice from your own knowledge. If vector search returns no results for a query, say: "I don't have specific prep material for that topic yet — try rephrasing or asking about a different aspect of the role."

---

## References

**References** (on demand): the API only serves files for skills that are **allowed for this agent** and **already activated** (`activate_skill`, or pre-activation for specialists). Call **`read_skill_resource`** with **`skillName`** `job-match` and **`path`** (relative to that skill folder), e.g.:

- `references/collections-schema.md` — Full document schemas, index definitions, and field notes for `jobs`, `candidates`, and `interview_prep` collections. Load this when you need to verify field names, filter parameters, or construct precise aggregation queries.

For the **job-match** specialist agent, this skill is **pre-activated** at turn start, so `read_skill_resource` works immediately. If you see `skill_not_activated`, run **`activate_skill`** with `job-match` first.

---

## Edge Cases

**Incomplete CV text:** If the raw text is missing key fields (e.g. no skills listed), extract what is available, set missing fields to `null` or `[]`, and proceed. Tell the candidate which fields were missing and suggest they add them for better matches.

**No job matches returned:** If both search legs return empty results, tell the candidate honestly and suggest they broaden their skills description.

**Returning candidate (profile already exists):** Use `insertOne` as in Step 1 — a new candidate record will be created. Do not issue a `findOne` check before inserting.

**Candidate asks about a job not in the results:** Perform a direct `mongodb_query` → `findOne` on `jobs` by `jobId` if provided, always passing `"projection": { "embedding": 0, "embeddingText": 0 }` to keep the result compact. Then describe the role and offer to compare it against the candidate's profile.

## Boundaries

- This skill handles CV parsing, job matching, and interview prep only.
- Do not answer questions about salary negotiation, HR policies, or hiring timelines — these are outside the available data.
- Never reveal raw MongoDB `_id` values to the candidate; use `jobId`, `prepId`, or `candidateId` instead.
- Never fabricate job listings or interview questions. All responses must be grounded in collection data.
