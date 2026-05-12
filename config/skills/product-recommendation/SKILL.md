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
- `indexName`: `products-vector-index`
- `queryText`: the customer's description in their own words

On-demand references (via `read_skill_resource`):

- `references/catalog-overview.md` — fixture fields and categories
- `references/search-patterns.md` — replacement and similarity flows
