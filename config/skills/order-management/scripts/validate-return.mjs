/**
 * Programmatic return-eligibility rules for the order-management skill.
 *
 * - Loaded at runtime by the API (`run_skill_script` tool) via dynamic `import()`.
 * - Keep this file **pure** (no I/O): deterministic given an order document.
 *
 * Policy (demo / dev fixtures):
 * - `cancelled` / `returned` → not eligible.
 * - `delivered` + at least one line item with `returnEligible: true` → usually eligible,
 *   unless `notes` suggest a replacement path (then `needs_review` + `replacementSuggested`).
 * - `shipped` / `processing` / `pending` → needs_review (org-specific).
 */

/** @typedef {'eligible' | 'not_eligible' | 'needs_review'} Verdict */

/**
 * @param {Record<string, unknown> | null | undefined} order One document from `orders` (e.g. mongodb_query).
 * @returns {{ verdict: Verdict, reasons: string[], flags: { replacementSuggested?: boolean } }}
 */
export function validateReturnEligibility(order) {
  if (!order || typeof order !== "object") {
    return { verdict: "not_eligible", reasons: ["missing_order"], flags: {} };
  }

  const status = String(order.status ?? "").toLowerCase();
  if (status === "cancelled" || status === "returned") {
    return { verdict: "not_eligible", reasons: [`status_${status}`], flags: {} };
  }

  const notes = typeof order.notes === "string" ? order.notes : "";
  const replacementSuggested = /replacement|upgrade|sku-?4|sku-?5/i.test(notes);

  const items = Array.isArray(order.items) ? order.items : [];
  const anyReturnEligible = items.some((it) => {
    if (!it || typeof it !== "object") return false;
    return it.returnEligible === true;
  });

  if (status === "delivered" && anyReturnEligible && replacementSuggested) {
    return {
      verdict: "needs_review",
      reasons: ["delivered_return_eligible", "replacement_notes_present"],
      flags: { replacementSuggested: true },
    };
  }

  if (status === "delivered" && anyReturnEligible) {
    return {
      verdict: "eligible",
      reasons: ["delivered_return_eligible_items"],
      flags: {},
    };
  }

  if (status === "delivered") {
    return {
      verdict: "needs_review",
      reasons: ["delivered_no_explicit_return_flag_on_items"],
      flags: { replacementSuggested },
    };
  }

  if (status === "shipped" || status === "processing" || status === "pending") {
    return {
      verdict: "needs_review",
      reasons: [`status_${status}_policy_dependent`],
      flags: { replacementSuggested },
    };
  }

  return {
    verdict: "needs_review",
    reasons: ["unknown_or_unhandled_status"],
    flags: { replacementSuggested },
  };
}
