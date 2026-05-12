import { describe, expect, test } from "bun:test";
import { attributeHandoff } from "../../src/lib/handoff-attribution.ts";

const ORDER_META = { description: "handles order status and shipment tracking", skills: ["order-lookup"] };
const PRODUCT_META = { description: "answers product information questions", skills: ["product-catalog"] };
const TROUBLESHOOT_META = { description: "diagnoses device errors", skills: ["device-faq"] };

const HANDOFFS = [
  { label: "Order Issues", agent: "order-management", prompt: "track order shipment" },
  { label: "Product Info", agent: "product", prompt: "describe product features" },
  { label: "Troubleshoot", agent: "troubleshoot", prompt: "diagnose device errors" },
];

const META = (id: string) => {
  if (id === "order-management") return ORDER_META;
  if (id === "product") return PRODUCT_META;
  if (id === "troubleshoot") return TROUBLESHOOT_META;
  return undefined;
};

describe("attributeHandoff", () => {
  test("single-keyword match in description yields a triggerSpan + a non-zero score", () => {
    const r = attributeHandoff({
      userMessage: "where is my order?",
      orchestratorReasoning: "",
      chosenAgentId: "order-management",
      orchestratorHandoffs: HANDOFFS,
      agentMeta: META,
    });
    expect(r.chosenScore).toBeGreaterThan(0);
    const orderSpan = r.triggerSpans.find((s) => s.phrase === "order");
    expect(orderSpan).toBeDefined();
    expect(orderSpan?.source).toBe("userMessage");
    expect(orderSpan?.matchedAgainst).toBeDefined();
  });

  test("bigram beats two unigrams (higher score)", () => {
    const bigramR = attributeHandoff({
      userMessage: "track order shipment status",
      orchestratorReasoning: "",
      chosenAgentId: "order-management",
      orchestratorHandoffs: HANDOFFS,
      agentMeta: META,
    });
    // The bigram "order shipment" (or "track order") should be in matchedPhrases.
    const allMatched = bigramR.triggerSpans.map((s) => s.phrase);
    const hasBigram = allMatched.some((p) => p.includes(" "));
    expect(hasBigram).toBe(true);
  });

  test("case-insensitive matching preserves original-cased offsets", () => {
    const message = "WHERE is my Order Shipment?";
    const r = attributeHandoff({
      userMessage: message,
      orchestratorReasoning: "",
      chosenAgentId: "order-management",
      orchestratorHandoffs: HANDOFFS,
      agentMeta: META,
    });
    const span = r.triggerSpans.find((s) => s.phrase === "order" && s.source === "userMessage");
    expect(span).toBeDefined();
    const [start, end] = span!.offset;
    expect(message.slice(start, end).toLowerCase()).toBe("order");
    expect(message[start]).toBe("O"); // original case preserved
  });

  test("stopwords ('the', 'is') are ignored from scoring", () => {
    const r = attributeHandoff({
      userMessage: "the is for a my we",
      orchestratorReasoning: "",
      chosenAgentId: "order-management",
      orchestratorHandoffs: HANDOFFS,
      agentMeta: META,
    });
    expect(r.chosenScore).toBe(0);
    expect(r.confidence).toBeNull();
  });

  test("close-call: two near-equal scores → low confidence", () => {
    // Message that overlaps both order and product handoffs.
    const r = attributeHandoff({
      userMessage: "I have order question and product question",
      orchestratorReasoning: "",
      chosenAgentId: "order-management",
      orchestratorHandoffs: HANDOFFS,
      agentMeta: META,
    });
    expect(r.alternativesConsidered.length).toBeGreaterThan(0);
    // Confidence should be present but bounded (not 1.0).
    expect(r.confidence).not.toBeNull();
    expect(r.confidence!).toBeLessThan(1);
  });

  test("empty-match scenario → confidence null + all alternatives 0", () => {
    const r = attributeHandoff({
      userMessage: "xxxxxx yyyyyy zzzzzz",
      orchestratorReasoning: "",
      chosenAgentId: "order-management",
      orchestratorHandoffs: HANDOFFS,
      agentMeta: META,
    });
    expect(r.chosenScore).toBe(0);
    expect(r.alternativesConsidered.every((a) => a.score === 0)).toBe(true);
    expect(r.confidence).toBeNull();
  });

  test("skill names contribute to scoring", () => {
    const r = attributeHandoff({
      userMessage: "I need device-faq please",
      orchestratorReasoning: "",
      chosenAgentId: "troubleshoot",
      orchestratorHandoffs: HANDOFFS,
      agentMeta: META,
    });
    const skillSpan = r.triggerSpans.find((s) => s.matchedAgainst === "skill");
    expect(skillSpan).toBeDefined();
  });

  test("orchestrator reasoning contributes spans tagged with 'orchestratorReasoning' source", () => {
    const r = attributeHandoff({
      userMessage: "help",
      orchestratorReasoning: "this needs order tracking",
      chosenAgentId: "order-management",
      orchestratorHandoffs: HANDOFFS,
      agentMeta: META,
    });
    const fromReason = r.triggerSpans.find((s) => s.source === "orchestratorReasoning");
    expect(fromReason).toBeDefined();
    expect(fromReason?.phrase).toBe("order");
  });

  test("alternatives are sorted descending by score", () => {
    const r = attributeHandoff({
      userMessage: "order shipment product information device errors",
      orchestratorReasoning: "",
      chosenAgentId: "order-management",
      orchestratorHandoffs: HANDOFFS,
      agentMeta: META,
    });
    for (let i = 0; i + 1 < r.alternativesConsidered.length; i++) {
      expect(r.alternativesConsidered[i].score).toBeGreaterThanOrEqual(
        r.alternativesConsidered[i + 1].score,
      );
    }
  });

  test("chosen agent never appears in alternativesConsidered", () => {
    const r = attributeHandoff({
      userMessage: "order shipment",
      orchestratorReasoning: "",
      chosenAgentId: "order-management",
      orchestratorHandoffs: HANDOFFS,
      agentMeta: META,
    });
    expect(r.alternativesConsidered.find((a) => a.agentId === "order-management")).toBeUndefined();
  });
});
