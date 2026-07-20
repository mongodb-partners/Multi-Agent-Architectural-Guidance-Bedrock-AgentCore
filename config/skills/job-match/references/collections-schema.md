# Collections Schema Reference

## Collection: `jobs`

Stores all open job listings. **Read-only** — the agent never writes to this collection.

### Document schema

```json
{
  "_id":               { "$oid": "..." },
  "jobId":             "job-ml-engineer-1",
  "company":           "Lumen Retail",
  "title":             "Machine Learning Engineer — Search & Recommendations",
  "description":       "<full job description>",
  "embeddingText":     "<concatenated text used to generate the embedding>",
  "location":          "Remote (US)",
  "remote":            true,
  "seniority":         "mid",
  "minYearsExperience": 3,
  "salaryRange":       "$140k–$175k",
  "skills":            ["python", "machine learning", "vector search", "pytorch"],
  "embedding":         [<1024-dimensional float array>]
}
```

### Field notes

| Field | Type | Notes |
|---|---|---|
| `jobId` | string | Human-readable unique ID; use this in handoff prompts, not `_id` |
| `seniority` | enum | `junior` \| `mid` \| `senior` \| `staff` |
| `remote` | boolean | Use as a filter when the candidate specifies remote-only preference |
| `minYearsExperience` | int | Match against candidate's `yearsExperience` |
| `skills` | string[] | Lowercase; use for keyword overlap scoring |
| `embedding` | float[] | 1024-dimensional vector; used by `jobs_vector_index` |

### Indexes

**Vector index** — `jobs_vector_index`
```json
{
  "fields": [
    { "numDimensions": 1024, "path": "embedding", "similarity": "cosine", "type": "vector" },
    { "path": "seniority", "type": "filter" },
    { "path": "remote",    "type": "filter" }
  ]
}
```
Use `filter` fields to pre-filter by `seniority` or `remote` before vector scoring when the candidate explicitly states a seniority level or remote-only preference.

**Atlas Search index** — `jobs_text_index`
```json
{
  "mappings": {
    "dynamic": false,
    "fields": {
      "company":     { "type": "string" },
      "description": { "type": "string" },
      "location":    { "type": "string" },
      "skills":      { "type": "string" },
      "title":       { "type": "string" }
    }
  }
}
```

---

## Collection: `candidates`

Stores candidate profiles extracted from submitted CVs. The agent writes new documents here when a candidate submits their CV.

### Document schema

```json
{
  "_id":         { "$oid": "..." },
  "candidateId": "cand-2ee32acd",
  "createdAt":   "2026-06-03T16:50:34.040Z",
  "rawCv":       "<original CV plain text>",
  "profile": {
    "name":            "Priya Sharma",
    "email":           "priya.sharma@example.com",
    "phone":           "+1 (555) 207-3391",
    "location":        "Austin, TX",
    "headline":        "Senior Software Engineer | Backend-leaning Full-Stack Engineer",
    "summary":         "<professional summary>",
    "yearsExperience": 6,
    "seniority":       "senior",
    "skills":          ["typescript", "node.js", "mongodb", "vector search"],
    "experience": [
      {
        "title":      "Senior Software Engineer",
        "company":    "Vertex Commerce",
        "startDate":  "2021",
        "endDate":    "Present",
        "highlights": ["<bullet 1>", "<bullet 2>"]
      }
    ],
    "education": [
      {
        "degree":      "B.S.",
        "field":       "Computer Science",
        "institution": "University of Texas at Austin",
        "year":        "2018"
      }
    ],
    "certifications": ["AWS Certified Solutions Architect – Associate"]
  },
  "embedding": [<1024-dimensional float array>]
}
```

### Field notes

| Field | Type | Notes |
|---|---|---|
| `candidateId` | string | Format: `cand-<8 hex chars>`; use this in responses, not `_id` |
| `profile.seniority` | enum | `junior` \| `mid` \| `senior` \| `staff` |
| `profile.yearsExperience` | int | Parsed from CV; used for job seniority/experience matching |
| `profile.skills` | string[] | Lowercase; used to build the full-text search query |
| `embedding` | float[] | 1024-dimensional embedding of the candidate's `embeddingText` |

### Index

**Vector index** — `candidate_vector_index`
```json
{
  "fields": [
    { "numDimensions": 1024, "path": "embedding", "similarity": "cosine", "type": "vector" }
  ]
}
```

---

## Collection: `interview_prep`

Holds interview preparation material (tips, frameworks, sample questions). **Read-only** — the agent only retrieves from this collection.

### Document schema

```json
{
  "_id":          { "$oid": "..." },
  "prepId":       "prep-star-method",
  "category":     "behavioral",
  "title":        "The STAR method for behavioral questions",
  "content":      "<full prep content>",
  "embeddingText":"<concatenated text used to generate the embedding>",
  "tags":         ["behavioral", "star", "storytelling"],
  "embedding":    [<1024-dimensional float array>]
}
```

### Field notes

| Field | Type | Notes |
|---|---|---|
| `prepId` | string | Human-readable unique ID; cite this in responses |
| `category` | string | e.g. `behavioral`, `technical`, `system-design`, `coding` |
| `tags` | string[] | Keywords; useful for building the vector search query |
| `content` | string | The full prep material to present to the candidate verbatim |
| `embedding` | float[] | 1024-dimensional vector; used by `prep_vector_index` |

### Index

**Vector index** — `prep_vector_index`
```json
{
  "fields": [
    { "numDimensions": 1024, "path": "embedding", "similarity": "cosine", "type": "vector" },
    { "path": "category", "type": "filter" }
  ]
}
```
Use the `category` filter when the candidate asks specifically for behavioral, technical, or system-design prep.
