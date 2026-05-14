# Orders collection (summary)

- `orderId` (string, unique)
- `customerEmail` or `customerId` (string) — the seeded dataset uses **`customerEmail`**
- `status`: pending | processing | shipped | delivered | return_requested | returned | cancelled
- `items[]`: often `sku`, `qty`; may include `returnEligible`
- `notes` (string, optional) — e.g. replacement guidance for agents
- `trackingNumber`, `trackingUrl` optional (shipped orders in the seeded dataset include both)

**Customers** (optional verification): collection `customers` — `email`, `name`, `verified`. You can `findOne` on `email` when the user provides an address and you need to confirm identity before sharing order details.

Use `mongodb_query` on collection `orders`.
