# Orders collection (summary)

- `orderId` (string, unique)
- `customerEmail` or `customerId` (string) — dev fixtures use **`customerEmail`**
- `status`: pending | processing | shipped | delivered | return_requested | returned | cancelled
- `items[]`: often `sku`, `qty`; may include `returnEligible`
- `notes` (string, optional) — e.g. replacement guidance for agents
- `trackingNumber`, `trackingUrl` optional (shipped orders in dev fixtures may include both)

**Customers** (optional verification): collection `customers` in dev fixtures — `email`, `name`, `verified`. You can `findOne` on `email` when the user provides an address and you need to confirm identity before sharing order details.

Use `mongodb_query` on collection `orders` when the database is configured.
