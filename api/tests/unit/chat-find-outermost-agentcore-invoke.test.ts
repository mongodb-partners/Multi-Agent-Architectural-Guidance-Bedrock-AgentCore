/**
 * Regression pin: `findOutermostAgentcoreInvokeId(collector)` MUST match
 * already-closed `agentcore.invoke` wrapper spans.
 *
 * History: an earlier version of this helper required `durationMs === undefined`
 * (i.e. open spans only). But by the time the chat route's `finally` block
 * runs, the AgentCore adapter has already closed its wrapper span — so the
 * open-span gate matched zero events, `attachEventsNested(...)` was never
 * called, and the chat turn summary always reported `mongoQueries: 0` /
 * `mcpCalls: 0` even when CloudWatch logs showed successful MCP tool calls.
 *
 * See docs/status/debugging.md "AgentCore Gateway response strips meta.traces —
 * `mongoQueries` must count `tool.mcp`".
 */

import { describe, expect, test } from "bun:test";
import { findOutermostAgentcoreInvokeId } from "../../src/routes/chat.ts";
import { TraceCollector } from "../../src/lib/trace-collector.ts";

function makeCollector() {
  return new TraceCollector({
    sessionId: "s",
    messageId: "m",
    agentId: "orchestrator",
  });
}

describe("findOutermostAgentcoreInvokeId", () => {
  test("matches an already-closed (end()-emitted) agentcore.invoke wrapper", () => {
    const c = makeCollector();
    const id = c.start("agentcore.invoke", { arn: "x", mode: "ec2_to_orchestrator" });
    c.end(id, { httpStatus: 200 });

    const found = findOutermostAgentcoreInvokeId(c);
    expect(found).toBe(id);
  });

  test("matches the OUTERMOST (most recent) when multiple wrappers exist", () => {
    const c = makeCollector();
    const first = c.start("agentcore.invoke", { mode: "ec2_to_orchestrator" });
    c.end(first);
    const second = c.start("agentcore.invoke", { mode: "orchestrator_to_specialist" });
    c.end(second);

    const found = findOutermostAgentcoreInvokeId(c);
    expect(found).toBe(second);
  });

  test("returns undefined when no agentcore.invoke event was ever emitted", () => {
    const c = makeCollector();
    c.event("chat.turn.start", { agentId: "orchestrator" });
    c.event("tool.call", { name: "noop" });

    const found = findOutermostAgentcoreInvokeId(c);
    expect(found).toBeUndefined();
  });

  test("matches a never-closed (still-open) agentcore.invoke wrapper too", () => {
    // Belt-and-suspenders — the original bug went the other way (only-closed),
    // so we also pin that an in-flight wrapper is found. This rules out a
    // future refactor that adds the opposite gate.
    const c = makeCollector();
    const id = c.start("agentcore.invoke", { mode: "ec2_to_orchestrator" });
    // No `c.end(id)` — wrapper still open.

    const found = findOutermostAgentcoreInvokeId(c);
    expect(found).toBe(id);
  });
});
