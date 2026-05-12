import { tool, type JSONValue } from "@strands-agents/sdk";
import { z } from "zod";
import { runMongoDataQuery } from "../../adapters/mongo-data.ts";
import { logger } from "../logger.ts";

const HIGH_PRIORITY_CODES = ["HW-900", "BAT-401", "DISP-201", "THERM-101"];
const MED_PRIORITY_CODES  = ["BT-301", "FW-501", "BOOT-010"];

export const createSupportTicketTool = tool({
  name: "create_support_ticket",
  description:
    "Build a structured support ticket and persist it to the support_tickets MongoDB collection in one step. " +
    "Call this whenever self-service troubleshooting is exhausted or the customer requests escalation. " +
    "Returns ticketId, priority, and nextSteps to share with the customer.",
  inputSchema: z.object({
    symptom: z.string().describe("Customer's symptom description"),
    errorCodes: z.array(z.string()).optional().describe("Error codes seen, e.g. ['HW-900']"),
    orderId: z.string().optional().describe("Order ID if provided"),
    sku: z.string().optional().describe("Product SKU if known"),
    serialNumber: z.string().optional().describe("Serial number if provided (required for HW faults)"),
    customerEmail: z.string().optional().describe("Customer email if known"),
    stepsTried: z.array(z.string()).optional().describe("Troubleshooting steps already attempted"),
  }),
  callback: async (input): Promise<JSONValue> => {
    const errorCodes = input.errorCodes ?? [];
    const stepsTried = input.stepsTried ?? [];

    const priority =
      errorCodes.some(c => HIGH_PRIORITY_CODES.includes(c)) ? "high" :
      errorCodes.some(c => MED_PRIORITY_CODES.includes(c))  ? "medium" : "low";

    const nextSteps: Record<string, string> = {
      high:   "A support agent will contact you within 4 business hours. Express replacement may be available.",
      medium: "A support agent will contact you within 1 business day.",
      low:    "A support agent will contact you within 2 business days.",
    };

    const ticketId = "TKT-" + Date.now().toString(36).toUpperCase().slice(-6);

    const doc: Record<string, unknown> = {
      ticketId,
      priority,
      summary: `[${priority.toUpperCase()}] ${input.symptom.slice(0, 80)}`,
      symptom: input.symptom,
      errorCodes,
      stepsTried,
      status: "open",
      source: "troubleshooting-agent",
    };
    if (input.orderId)       doc.orderId       = input.orderId;
    if (input.sku)           doc.sku           = input.sku;
    if (input.serialNumber)  doc.serialNumber  = input.serialNumber;
    if (input.customerEmail) doc.customerEmail = input.customerEmail;

    const result = await runMongoDataQuery({
      collection: "support_tickets",
      operation: "insertOne",
      document: doc,
    });

    const inserted = result as Record<string, unknown>;
    if (inserted.status !== "ok") {
      logger.error("[create_support_ticket] insertOne failed", { result });
      return { status: "error", message: "Failed to persist ticket", detail: result };
    }

    return { status: "ok", ticketId, priority, summary: doc.summary as string, nextSteps: nextSteps[priority] };
  },
});
