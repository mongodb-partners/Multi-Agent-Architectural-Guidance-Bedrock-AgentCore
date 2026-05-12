---
name: order-management
description: >-
  Query and manage customer orders from MongoDB Atlas. Use for order lookups,
  status, tracking, and returns.
metadata:
  author: peerislands
  version: "1.0"
  domain: e-commerce
---

# Order Management

Use `mongodb_query` on the `orders` collection. Prefer **`find`** with `orderId` or `customerEmail` when the user provides them; use limits to keep responses small. For **tracking**, read `trackingNumber` and `trackingUrl` from the order document when present.

Optional: `customers` collection — `findOne` on `email` to confirm a verified profile when policy calls for it (see `references/order-schema.md`).

**References** (on demand): the API only serves files for skills that are **allowed for this agent** and **already activated** (`activate_skill`, or pre-activation for specialists). Call **`read_skill_resource`** with **`skillName`** `order-management` and **`path`** (relative to that skill folder), e.g.:

- `references/order-schema.md` — field expectations (dev fixtures may use a subset, e.g. `customerEmail`).

For the **order-management** specialist agent, this skill is **pre-activated** at turn start, so `read_skill_resource` works immediately. If you see `skill_not_activated`, run **`activate_skill`** with `order-management` first.

**Return eligibility (programmatic):** After loading an order with `mongodb_query`, call **`run_skill_script`** with `skillName='order-management'`, `scriptPath='scripts/validate-return.mjs'`, `exportName='validateReturnEligibility'`, `args={…order object}`. The API dynamically imports the `.mjs` file and calls the named export. The tool response (`status`, `result.verdict`, `result.reasons`, `result.flags`) is returned as a **tool result** — summarize it clearly for the customer. To view the script source, use **`read_skill_resource`** with `path` `scripts/validate-return.mjs`.

**HTTP / Lambda tools (config):** Optional `http-tools.json` in this skill folder (next to `SKILL.md`) defines tools that invoke HTTPS endpoints (e.g. Lambda Function URLs). Add each tool’s **Strands name** to the agent’s `tools:` list as **`order-management/<localToolName>`** (same pattern as `scripts/*.mjs` paths). The skill must be **activated** before the call succeeds (specialists pre-activate). SSRF allowlists live in repo-root `config/http-tools.json` → `security`. See `http-tools.example.json` here and the [Configuration guide](../../../docs/configuration-guide.md).
