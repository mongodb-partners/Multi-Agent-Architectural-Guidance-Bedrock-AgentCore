# Collections Schema Reference

## Collection: `career_paths`

Stores documented role-progression paths, each defining a target role, its required skills,
and an ordered set of learning milestones. **Read-only** — the agent never writes to this
collection.

### Document schema

```json
{
  "_id":            { "$oid": "..." },
  "pathId":         "path-backend-to-ml-engineer",
  "targetRole":     "Machine Learning Engineer",
  "fromRoles":      ["Backend Engineer", "Full-Stack Engineer"],
  "seniority":      "mid",
  "description":    "<narrative of how to move from a backend role into ML engineering>",
  "embeddingText":  "<concatenated text used to generate the embedding>",
  "requiredSkills": [
    { "skillId": "skill-python",          "name": "python",           "importance": "core",     "note": "Primary language for ML tooling" },
    { "skillId": "skill-machine-learning","name": "machine learning", "importance": "core",     "note": "Supervised/unsupervised fundamentals" },
    { "skillId": "skill-pytorch",         "name": "pytorch",          "importance": "important","note": "Model training framework" },
    { "skillId": "skill-vector-search",   "name": "vector search",    "importance": "nice",     "note": "For retrieval/RAG systems" }
  ],
  "milestones": [
    {
      "order":          1,
      "title":          "Foundations — Python for ML & core math",
      "skills":         ["skill-python", "skill-machine-learning"],
      "estimatedWeeks": 8
    },
    {
      "order":          2,
      "title":          "Applied modeling with PyTorch",
      "skills":         ["skill-pytorch"],
      "estimatedWeeks": 6
    },
    {
      "order":          3,
      "title":          "Production ML & retrieval systems",
      "skills":         ["skill-vector-search"],
      "estimatedWeeks": 4
    }
  ],
  "embedding":      [<1024-dimensional float array>]
}
```

### Field notes

| Field | Type | Notes |
|---|---|---|
| `pathId` | string | Human-readable unique ID; cite this in responses, not `_id` |
| `targetRole` | string | The role this path leads to; match against the candidate's stated goal |
| `fromRoles` | string[] | Typical starting roles this path applies to |
| `seniority` | enum | `junior` \| `mid` \| `senior` \| `staff` — level of the target role |
| `requiredSkills` | object[] | Each has `skillId`, `name` (lowercase), `importance`, and a `note`. `importance` is `core` \| `important` \| `nice`. |
| `milestones` | object[] | Ordered by `order`; each has `title`, `skills` (array of `skillId`), and `estimatedWeeks` |
| `embedding` | float[] | 1024-dimensional vector; used by `career_paths_vector_index` |

### Indexes

**Vector index** — `career_paths_vector_index`
```json
{
  "fields": [
    { "numDimensions": 1024, "path": "embedding", "similarity": "cosine", "type": "vector" },
    { "path": "seniority", "type": "filter" }
  ]
}
```
Use the `seniority` filter when the candidate explicitly states a target level.

**Atlas Search index** — `career_paths_text_index`
```json
{
  "mappings": {
    "dynamic": false,
    "fields": {
      "targetRole":  { "type": "string" },
      "fromRoles":   { "type": "string" },
      "description": { "type": "string" }
    }
  }
}
```

---

## Collection: `skills_taxonomy`

Stores individual skills with their learning resources. **Read-only** — the agent only
retrieves from this collection.

### Document schema

```json
{
  "_id":           { "$oid": "..." },
  "skillId":       "skill-pytorch",
  "name":          "pytorch",
  "category":      "machine-learning",
  "description":   "Deep-learning framework for building and training neural networks.",
  "prerequisites": ["skill-python"],
  "resourceType":  "course",
  "resources": [
    { "title": "PyTorch Fundamentals", "provider": "Internal L&D", "url": "https://learn.example.com/pytorch", "estimatedHours": 20 },
    { "title": "Deep Learning with PyTorch (book)", "provider": "External", "url": null, "estimatedHours": 30 }
  ],
  "embeddingText": "<concatenated text used to generate the embedding>",
  "embedding":     [<1024-dimensional float array>]
}
```

### Field notes

| Field | Type | Notes |
|---|---|---|
| `skillId` | string | Human-readable unique ID; matches `requiredSkills[].skillId` in `career_paths` |
| `name` | string | Lowercase skill name; matches `requiredSkills[].name` |
| `category` | string | e.g. `machine-learning`, `backend`, `data`, `leadership` |
| `prerequisites` | string[] | Array of `skillId` values that should be learned first |
| `resourceType` | string | e.g. `course`, `book`, `project`, `certification` |
| `resources` | object[] | Each has `title`, `provider`, `url` (nullable), and `estimatedHours` |
| `embedding` | float[] | 1024-dimensional vector; used by `skills_taxonomy_vector_index` |

### Index

**Vector index** — `skills_taxonomy_vector_index`
```json
{
  "fields": [
    { "numDimensions": 1024, "path": "embedding", "similarity": "cosine", "type": "vector" },
    { "path": "category", "type": "filter" }
  ]
}
```
Lookups against this collection are usually done with `mongodb_query` → `find` filtered by
`skillId` (`$in`) or `name` (`$in`); vector search is only needed when resolving a fuzzy
skill description with no known `skillId`.

---

## Collection: `compensation_data`

Stores compensation benchmarks per role, seniority, and region. Each document carries base and
total-comp percentile bands, benefits norms, and an `asOf` date. **Read-only** — the agent
never writes to this collection. Used by the compensation workflow (Steps 5–7).

### Document schema

```json
{
  "_id":           { "$oid": "..." },
  "benchmarkId":   "comp-ml-engineer-senior-us-south",
  "role":          "Machine Learning Engineer",
  "seniority":     "senior",
  "region":        "us-south",
  "locationLabel": "Austin, TX (US South)",
  "currency":      "USD",
  "asOf":          "2026-01-01",
  "baseSalary":    { "p25": 150000, "p50": 168000, "p75": 185000, "p90": 205000 },
  "totalComp":     { "p25": 175000, "p50": 200000, "p75": 232000, "p90": 268000 },
  "benefits":      ["401k match up to 6%", "Health/dental/vision", "20 days PTO", "Remote stipend"],
  "equityNote":    "Typical RSU grant 0.05%–0.12% vesting over 4 years for this level.",
  "sampleSize":    142,
  "embeddingText": "<concatenated text used to generate the embedding>",
  "embedding":     [<1024-dimensional float array>]
}
```

### Field notes

| Field | Type | Notes |
|---|---|---|
| `benchmarkId` | string | Human-readable unique ID; cite this in responses, not `_id` |
| `role` | string | Role title; text-indexed for the BM25 lexical leg (`lexicalPath: "role"`) |
| `seniority` | enum | `junior` \| `mid` \| `senior` \| `staff` — declared as a vector-index `filter` field |
| `region` | enum | See region map below — declared as a vector-index `filter` field |
| `locationLabel` | string | Human-readable location for display |
| `currency` | string | ISO currency code (e.g. `USD`); always state it with figures |
| `asOf` | string (date) | Benchmark date; flag if stale |
| `baseSalary` | object | Percentile band: `p25`, `p50`, `p75`, `p90` |
| `totalComp` | object | Percentile band including bonus/equity: `p25`, `p50`, `p75`, `p90` |
| `benefits` | string[] | Documented benefits norms; present verbatim |
| `equityNote` | string | Equity/RSU norm for this level; present verbatim |
| `sampleSize` | int | Number of data points; a small `sampleSize` warrants a lower-confidence note |
| `embedding` | float[] | 1024-dimensional vector; used by `compensation_vector_index` |

### Region enum (map candidate location → `region`)

| `region` | Covers |
|---|---|
| `us-west` | CA, WA, OR, and West Coast metros |
| `us-south` | TX, FL, GA, and South metros (e.g. Austin, Atlanta) |
| `us-east` | NY, MA, DC, and East Coast metros |
| `us-central` | IL, CO, and Central metros |
| `remote-us` | US-wide remote roles |
| `emea` | Europe / Middle East / Africa |
| `apac` | Asia-Pacific |

When the candidate's location does not clearly map, use `remote-us` (for US contexts) or leave
`region` unset and present a nationwide benchmark.

### Indexes

**Vector index** — `compensation_vector_index`
```json
{
  "fields": [
    { "numDimensions": 1024, "path": "embedding", "similarity": "cosine", "type": "vector" },
    { "path": "seniority", "type": "filter" },
    { "path": "region",    "type": "filter" }
  ]
}
```
Use the `seniority` and `region` filters to pre-filter before vector scoring when the
candidate states a level and/or a location.

**Atlas Search index** — `compensation_text_index`
```json
{
  "mappings": {
    "dynamic": false,
    "fields": {
      "role":          { "type": "string" },
      "locationLabel": { "type": "string" }
    }
  }
}
```
