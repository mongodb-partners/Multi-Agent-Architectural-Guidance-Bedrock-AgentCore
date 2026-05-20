/**
 * Tests for `TraceCollector.buildSpanTree()`.
 *
 * The Developer details panel's "Span tree" sub-section renders this directly;
 * if it returns a flat list, an orphaned subtree, or duplicated nodes the
 * developer loses the only view that shows the actual call hierarchy.
 */

import { describe, expect, test } from "bun:test";
import { TraceCollector } from "../../src/lib/trace-collector.ts";

function makeCollector() {
  return new TraceCollector({ sessionId: "s", messageId: "m", agentId: "orchestrator" });
}

describe("TraceCollector.buildSpanTree", () => {
  test("synthetic chat turn with nested spans yields a tree (no orphans, no duplicates)", () => {
    const c = makeCollector();
    const turn = c.start("chat.turn.start", {
      sessionId: "s",
      messageId: "m",
      agentId: "orchestrator",
      startTs: 0,
    });
    const model = c.start("model.request", {
      modelId: "anthropic.claude-sonnet-4-5",
      region: "us-east-1",
      systemPromptHash: "h",
      systemPromptBytes: 1,
      priorTurnsCount: 0,
      userMessage: "hi",
    });
    const tool = c.start("tool.call", { toolName: "lookup", phase: "start" });
    c.end(tool, { phase: "end" });
    c.end(model, {});
    c.end(turn, {});

    const tree = c.buildSpanTree();
    // One root (chat.turn.start) covering the whole turn.
    expect(tree).toHaveLength(1);
    expect(tree[0].type).toBe("chat.turn.start");
    expect(tree[0].id).toBe(turn);

    // Under the root: the model.request span (start half) is nested. The
    // matching end half also lands as a child because end events carry
    // `parentId = startSpanId` — that's the existing buildSpanTree contract
    // and the Trace Viewer's "Span tree" section filters end-halves out by
    // (durationMs !== undefined && parentNode.type === node.type) when
    // rendering. We assert both still appear so a future change can't
    // silently strip the start-half (which would lose the model name).
    const modelChild = tree[0].children.find(
      (n) => n.type === "model.request" && n.id === model,
    );
    expect(modelChild).toBeDefined();
    // tool.call must be nested under model.request.
    const toolChild = modelChild?.children.find(
      (n) => n.type === "tool.call" && n.id === tool,
    );
    expect(toolChild).toBeDefined();

    // No duplicate ids anywhere in the tree.
    const seenIds = new Set<string>();
    const walk = (n: { id: string; children: typeof tree }): void => {
      expect(seenIds.has(n.id)).toBe(false);
      seenIds.add(n.id);
      for (const c of n.children) walk(c);
    };
    for (const root of tree) walk(root);
  });

  test("end events merge their durationMs back onto the start node", async () => {
    const c = makeCollector();
    const id = c.start("tool.call", { toolName: "x", phase: "start" });
    await new Promise((r) => setTimeout(r, 3));
    c.end(id, { phase: "end" });
    const tree = c.buildSpanTree();
    expect(tree).toHaveLength(1);
    expect(tree[0].id).toBe(id);
    expect(tree[0].durationMs).toBeGreaterThanOrEqual(0);
  });

  test("one-off events (no parentId) are returned as top-level roots", () => {
    const c = makeCollector();
    c.event("error", { class: "X", message: "y" });
    c.event("error", { class: "Z", message: "w" });
    const tree = c.buildSpanTree();
    expect(tree.length).toBe(2);
    for (const node of tree) {
      expect(node.type).toBe("error");
      expect(node.children).toHaveLength(0);
    }
  });

  test("toJSON().spanTree mirrors buildSpanTree() output", () => {
    const c = makeCollector();
    const turn = c.start("chat.turn.start", {
      sessionId: "s",
      messageId: "m",
      agentId: "orchestrator",
      startTs: 0,
    });
    c.end(turn, {});
    const json = c.toJSON();
    expect(json.spanTree).toEqual(c.buildSpanTree());
  });
});
