# Search and recommendation patterns

1. **Direct match** — User names a product or use case → `mongodb_query` with regex on `title` or `description`, or tag overlap.

2. **Similar item (cheaper / alternative)** — User wants “something like X but under $Y”:
   - `mongodb_vector_search` with the user's full description as `queryText`.
   - Supplement with `mongodb_query` with `{ “price”: { “$lte”: <budget> } }` for price-filtered results.

3. **Replacement for broken/discontinued product** — User's product stopped working:
   - `mongodb_vector_search` with “replacement for <product name>” as `queryText`.
   - Supplement with `mongodb_query` on `replacesSkus` field if available.

4. **Use-case / feature match** — User describes a scenario (outdoor, rugged, waterproof, travel, home):
   - `mongodb_vector_search` with the user's exact description as `queryText` — product embeddings are enriched to match natural-language use cases.

5. **Budget query** — User asks for “best under $X”:
   - `mongodb_query` with `{ “price”: { “$lte”: <X> } }`, sort by `rating` descending.

6. **Bundle / combo** — User wants multiple items or a value pack:
   - `mongodb_vector_search` with “bundle home travel combo kit” style query.

7. **Order-linked replacement** — If user mentions an order ID, load `orders`, map `sku` to `products` and suggest upgrades.

Always cite `sku`, `title`, and `price` in the answer so the customer can confirm.
