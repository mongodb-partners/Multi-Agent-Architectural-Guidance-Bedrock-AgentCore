---
name: product-recommendation
description: >-
  Recommend products using MongoDB catalog and vector search on embeddings.
metadata:
  author: peerislands
  version: "1.0"
  domain: e-commerce
---

# Product Recommendation

Use `mongodb_vector_search` and `mongodb_query` on the `products` collection.

**Vector search parameters:**
- `collection`: `products`
- `queryText`: the customer's description in their own words.
  The platform embeds this server-side (Voyage AI primary, Bedrock fallback)
  before running `$vectorSearch`. Never compute or pass `queryVector` yourself.
- `limit`: 3 (tune up to 10 for browsing-style queries)

The vector index defaults to `products-vector-index`; pass `indexName` only if
you need to override it.

On-demand references (via `read_skill_resource`):

- `references/catalog-overview.md` — catalog fields and categories
- `references/search-patterns.md` — replacement and similarity flows
