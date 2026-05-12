import { describe, expect, test } from "bun:test";
import { pathToFileURL } from "node:url";
import path from "node:path";

const configRoot = path.resolve(import.meta.dir, "../../../config/skills");

async function loadAndRun(skillName: string, order: Record<string, unknown>) {
  const abs = path.join(configRoot, skillName, "scripts/validate-return.mjs");
  const mod = (await import(pathToFileURL(abs).href)) as Record<string, unknown>;
  const fn = mod.validateReturnEligibility;
  if (typeof fn !== "function") throw new Error(`export missing in ${abs}`);
  return fn(order) as { verdict: string; reasons: string[]; flags: Record<string, unknown> };
}

describe("validate-return.mjs (dynamic import)", () => {
  test("ORD-1003 fixture shape: needs_review + replacement flag", async () => {
    const r = await loadAndRun("order-management", {
      orderId: "ORD-1003",
      status: "delivered",
      customerEmail: "alex@example.com",
      items: [{ sku: "SKU-1", qty: 1, returnEligible: true }],
      notes: "Customer requested replacement — suggest SKU-4 or SKU-5 (same line, upgraded).",
    });
    expect(r.verdict).toBe("needs_review");
    expect(r.flags.replacementSuggested).toBe(true);
    expect(r.reasons).toContain("replacement_notes_present");
  });

  test("delivered + returnEligible without replacement notes → eligible", async () => {
    const r = await loadAndRun("order-management", {
      orderId: "ORD-X",
      status: "delivered",
      items: [{ sku: "A", qty: 1, returnEligible: true }],
    });
    expect(r.verdict).toBe("eligible");
  });

  test("cancelled → not_eligible", async () => {
    const r = await loadAndRun("order-management", {
      orderId: "ORD-X",
      status: "cancelled",
      items: [],
    });
    expect(r.verdict).toBe("not_eligible");
  });

  test("shipped → needs_review", async () => {
    const r = await loadAndRun("order-management", {
      orderId: "ORD-1001",
      status: "shipped",
      customerEmail: "alex@example.com",
      items: [{ sku: "SKU-1", qty: 1 }],
    });
    expect(r.verdict).toBe("needs_review");
  });
});
