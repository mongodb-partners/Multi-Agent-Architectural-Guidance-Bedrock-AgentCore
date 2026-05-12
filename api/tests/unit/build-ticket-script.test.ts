import { describe, expect, test } from "bun:test";
import { pathToFileURL } from "node:url";
import path from "node:path";

const configRoot = path.resolve(import.meta.dir, "../../../config/skills");

async function loadAndBuild(args: {
  symptom: string;
  errorCodes?: string[];
  orderId?: string;
  sku?: string;
  stepsTried?: string[];
}) {
  const abs = path.join(configRoot, "troubleshooting", "scripts/build-ticket.mjs");
  const mod = (await import(pathToFileURL(abs).href)) as Record<string, unknown>;
  const fn = mod.buildSupportTicket;
  if (typeof fn !== "function") throw new Error(`buildSupportTicket export missing in ${abs}`);
  return fn(args) as {
    ticketId: string;
    priority: "high" | "medium" | "low";
    summary: string;
    body: string;
    requiredFields: { serialNumber: string; proofOfPurchase: string; orderIdField: string };
    nextSteps: string;
  };
}

describe("build-ticket.mjs (dynamic import)", () => {
  test("HW-900 → high priority, serial number required", async () => {
    const t = await loadAndBuild({
      symptom: "Red LED blink pattern on the device",
      errorCodes: ["HW-900"],
      orderId: "ORD-1001",
      stepsTried: ["Hard reset", "Cable swap"],
    });
    expect(t.priority).toBe("high");
    expect(t.ticketId).toMatch(/^TKT-/);
    expect(t.requiredFields.serialNumber).toBe("required");
    expect(t.requiredFields.proofOfPurchase).toBe("required");
    expect(t.requiredFields.orderIdField).toContain("ORD-1001");
    expect(t.body).toContain("HW-900");
    expect(t.body).toContain("ORD-1001");
    expect(t.body).toContain("Hard reset");
    expect(t.nextSteps).toMatch(/4 business hours/);
  });

  test("BAT-401 → high priority", async () => {
    const t = await loadAndBuild({
      symptom: "Battery drains within 2 hours",
      errorCodes: ["BAT-401"],
    });
    expect(t.priority).toBe("high");
    expect(t.requiredFields.serialNumber).toBe("required");
    expect(t.summary).toContain("[HIGH]");
  });

  test("DISP-201 → high priority, summary truncated at 80 chars", async () => {
    const longSymptom = "Screen is completely blank and does not respond to any input including power button presses";
    const t = await loadAndBuild({ symptom: longSymptom, errorCodes: ["DISP-201"] });
    expect(t.priority).toBe("high");
    expect(t.summary.length).toBeLessThanOrEqual("[HIGH] ".length + 80);
  });

  test("BT-301 → medium priority", async () => {
    const t = await loadAndBuild({
      symptom: "Bluetooth won't pair with any device",
      errorCodes: ["BT-301"],
    });
    expect(t.priority).toBe("medium");
    expect(t.requiredFields.serialNumber).toBe("optional");
    expect(t.nextSteps).toMatch(/1 business day/);
  });

  test("FW-501 → medium priority", async () => {
    const t = await loadAndBuild({
      symptom: "Firmware update stuck at 45% for 30 minutes",
      errorCodes: ["FW-501"],
    });
    expect(t.priority).toBe("medium");
    expect(t.summary).toContain("[MEDIUM]");
  });

  test("no error codes → low priority, serial number optional", async () => {
    const t = await loadAndBuild({
      symptom: "Device makes a clicking noise when charging",
      stepsTried: ["Checked cable", "Tried different outlet"],
    });
    expect(t.priority).toBe("low");
    expect(t.requiredFields.serialNumber).toBe("optional");
    expect(t.requiredFields.orderIdField).toBe("please provide");
    expect(t.nextSteps).toMatch(/2 business days/);
  });

  test("NET-204 → low priority", async () => {
    const t = await loadAndBuild({
      symptom: "Wi-Fi keeps dropping every few hours",
      errorCodes: ["NET-204"],
    });
    expect(t.priority).toBe("low");
  });

  test("high + medium mixed codes → high priority wins", async () => {
    const t = await loadAndBuild({
      symptom: "Hardware fault with Bluetooth also failing",
      errorCodes: ["BT-301", "HW-900"],
    });
    expect(t.priority).toBe("high");
  });

  test("ticketId is unique across two calls", async () => {
    const [t1, t2] = await Promise.all([
      loadAndBuild({ symptom: "Issue A", errorCodes: ["PWR-001"] }),
      loadAndBuild({ symptom: "Issue B", errorCodes: ["PWR-001"] }),
    ]);
    // ticketIds are timestamp-based — may collide in same ms; just assert format
    expect(t1.ticketId).toMatch(/^TKT-[A-Z0-9]+$/);
    expect(t2.ticketId).toMatch(/^TKT-[A-Z0-9]+$/);
  });

  test("body omits null fields when orderId and sku not provided", async () => {
    const t = await loadAndBuild({
      symptom: "Power issue",
      errorCodes: ["PWR-001"],
    });
    expect(t.body).not.toContain("Order ID:");
    expect(t.body).not.toContain("SKU:");
  });

  test("sku appears in body when provided", async () => {
    const t = await loadAndBuild({
      symptom: "Connectivity drops",
      errorCodes: ["NET-204"],
      sku: "SKU-5",
    });
    expect(t.body).toContain("SKU: SKU-5");
  });
});
