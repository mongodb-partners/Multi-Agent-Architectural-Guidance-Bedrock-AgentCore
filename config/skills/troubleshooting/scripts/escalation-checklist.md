# Escalation checklist (support)

Load via `read_skill_resource` when the user hits hardware faults, repeated failures, or asks for a human.

1. **Severity** — Safety or data loss → stop self-service troubleshooting; advise immediate safe steps only.
2. **Error codes** — If the user mentions **HW-900**, **PWR-001**, **NET-204**, etc., cross-check `references/error-codes.md` and `references/common-issues.md`.
3. **Doc coverage** — If MongoDB / KB tools return no good match after one reformulated query, say so honestly.
4. **Ticket payload** — Collect: symptom, error code (if any), order id or SKU if relevant, steps already tried, serial number if HW-900 / replacement path.
5. **Create ticket** — Call `create_support_ticket` with `{ symptom, errorCodes, orderId, sku, serialNumber, customerEmail, stepsTried }`. This persists the ticket to MongoDB and returns `ticketId`, `priority`, and `nextSteps`. This step is **mandatory** — do not skip it.
6. **Handoff message** — Share the `ticketId` and `nextSteps` from the tool response with the customer. Never reveal the internal MongoDB `_id`.

Dev mock: cite mock KB snippets as **supplementary**; ground answers in `troubleshooting_docs` when possible.
