# Catalog overview

- Collection: `products`
- Useful fields: `sku`, `title`, `description`, `category`, `tags`
- Replacement flows: when an order line references a return or replacement, query `products` for the same `category` or overlapping `tags`, or suggest documented upgrade SKUs from order `notes`.

## Sample categories in the seeded dataset

| Category     | Example SKUs |
|-------------|--------------|
| `home`      | SKU-1, SKU-3, SKU-4, SKU-5, SKU-6 |
| `electronics` | SKU-2 |

## Query tips

- `mongodb_query`: filter by `category`, `tags` (array contains), or text match on `title` / `description`.
- `mongodb_vector_search`: use the user’s plain-language need as the query text; the gateway-backed MCP tool runs Atlas `$vectorSearch` against the seeded `embedding` field.
