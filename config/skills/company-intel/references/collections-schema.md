# Collections Schema Reference

## Collection: `companies`

Stores structured profiles of hiring companies — industry, stage, size, culture signals,
engineering practices, and an employee-sentiment summary. **Read-only** — the agent never
writes to this collection.

### Document schema

```json
{
  "_id":            { "$oid": "..." },
  "companyId":      "co-lumen-retail",
  "name":           "Lumen Retail",
  "industry":       "Retail / E-commerce",
  "stage":          "Series C",
  "foundedYear":    2014,
  "headcount":      "1,000–5,000",
  "fundingTotal":   "$310M",
  "headquarters":   "Austin, TX",
  "description":    "<narrative overview of the company and its products>",
  "embeddingText":  "<concatenated text used to generate the embedding>",
  "cultureSignals":       ["Remote-friendly", "Strong mentorship", "Fast release cadence"],
  "engineeringPractices": ["Trunk-based development", "On-call rotation (1 week / 6)", "RFC design reviews"],
  "sentimentSummary": "Engineers praise autonomy and modern tooling; some note high pace during peak retail seasons.",
  "pros":           ["Modern stack", "Growth opportunities", "Good mentorship"],
  "cons":           ["Seasonal crunch", "Rapidly changing priorities"],
  "sentimentScore": 4.1,
  "asOf":           "2026-01-01",
  "embedding":      [<768-dimensional float array>]
}
```

### Field notes

| Field | Type | Notes |
|---|---|---|
| `companyId` | string | Human-readable unique ID; cite this in responses, not `_id` |
| `name` | string | Company name; text-indexed for the BM25 lexical leg (`lexicalPath: "name"`) |
| `industry` | string | Sector label |
| `stage` | string | e.g. `Seed`, `Series A`–`Series D`, `Public`, `Bootstrapped` |
| `foundedYear` | int | Year founded |
| `headcount` | string | Employee band, e.g. `51–200`, `1,000–5,000` |
| `fundingTotal` | string | Total raised (display string); may be `null` for public/bootstrapped |
| `cultureSignals` | string[] | Documented culture attributes; present verbatim |
| `engineeringPractices` | string[] | Documented engineering norms; present verbatim |
| `sentimentSummary` | string | One-paragraph balanced sentiment summary; present verbatim |
| `pros` / `cons` | string[] | Balanced signal lists; always present both together |
| `sentimentScore` | number | 1.0–5.0 aggregate rating; state alongside the summary |
| `asOf` | string (date) | Freshness of the sentiment data; flag if stale |
| `embedding` | float[] | 768-dimensional vector; used by `companies_vector_index` |

### Indexes

**Vector index** — `companies_vector_index`
```json
{
  "fields": [
    { "numDimensions": 768, "path": "embedding", "similarity": "cosine", "type": "vector" },
    { "path": "industry", "type": "filter" },
    { "path": "stage",    "type": "filter" }
  ]
}
```
Use the `industry` or `stage` filters when the candidate scopes their question (e.g. "early
stage fintechs").

**Atlas Search index** — `companies_text_index`
```json
{
  "mappings": {
    "dynamic": false,
    "fields": {
      "name":        { "type": "string" },
      "industry":    { "type": "string" },
      "description": { "type": "string" }
    }
  }
}
```

---

## Knowledge base enrichment

When the structured record is thin or the question is broad, use `bedrock_kb_retrieve` (the
company-intel agent lists this tool). Combine the company name with the candidate's focus in a
natural-language query. Treat returned passages as external/employee-sentiment context and
attribute them as such — never present them as first-person company statements. The KB is
configured via `BEDROCK_KB_ID`; no schema applies to its passages.
