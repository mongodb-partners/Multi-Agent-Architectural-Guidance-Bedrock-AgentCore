/**
 * Regression tests for long-term memory recall fixes.
 *
 * Fix 1 — orchestrator.agent.md missing memory.longTerm: true
 *   chat.ts checks contextAgent.memory?.longTerm before calling
 *   readLongTermMemoryContext. Without the flag, wantsScoped = false and
 *   ALL memory retrieval was silently skipped for every default request.
 *
 * Fix 2 — chat_messages retrieval role filter excluded assistant messages
 *   The filter { userId, role: "user" } meant the agent could never recall
 *   what it previously said. Changed to include both roles by default so
 *   the agent can answer "why did you return X in a previous session?"
 */
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { getAgent, loadAgentPersona } from "../../src/lib/config-scan.ts";
import { memoryIncludeAssistantMessages } from "../../src/lib/long-term-memory.ts";
import {
  LONG_TERM_MEMORY_RECALL_RULES,
  withLongTermMemory,
} from "../../src/lib/prompt.ts";

describe("orchestrator long-term memory config", () => {
  test("orchestrator has memory.longTerm = true (required for LTM retrieval in chat.ts)", () => {
    const orchestrator = getAgent("orchestrator");
    expect(orchestrator).not.toBeNull();
    expect(orchestrator!.memory?.longTerm).toBe(true);
  });

  test("order-management retains memory.longTerm = true", () => {
    const agent = getAgent("order-management");
    expect(agent).not.toBeNull();
    expect(agent!.memory?.longTerm).toBe(true);
  });

  test("chat.ts wantsScoped evaluates to true for orchestrator (regression guard)", () => {
    // Mirrors the exact expression in api/src/routes/chat.ts:
    //   const wantsScoped = Boolean(contextAgent.memory?.longTerm);
    const orchestrator = getAgent("orchestrator");
    const wantsScoped = Boolean(orchestrator?.memory?.longTerm);
    expect(wantsScoped).toBe(true);
  });
});

describe("chat_messages assistant recall (MEMORY_INCLUDE_ASSISTANT_MESSAGES)", () => {
  let savedEnv: string | undefined;

  beforeEach(() => {
    savedEnv = process.env.MEMORY_INCLUDE_ASSISTANT_MESSAGES;
  });

  afterEach(() => {
    if (savedEnv !== undefined) {
      process.env.MEMORY_INCLUDE_ASSISTANT_MESSAGES = savedEnv;
    } else {
      delete process.env.MEMORY_INCLUDE_ASSISTANT_MESSAGES;
    }
  });

  test("included by default when env var is unset", () => {
    delete process.env.MEMORY_INCLUDE_ASSISTANT_MESSAGES;
    expect(memoryIncludeAssistantMessages()).toBe(true);
  });

  test("included when env var is set to '1'", () => {
    process.env.MEMORY_INCLUDE_ASSISTANT_MESSAGES = "1";
    expect(memoryIncludeAssistantMessages()).toBe(true);
  });

  test("excluded when env var is '0'", () => {
    process.env.MEMORY_INCLUDE_ASSISTANT_MESSAGES = "0";
    expect(memoryIncludeAssistantMessages()).toBe(false);
  });

  test("excluded when env var is 'false'", () => {
    process.env.MEMORY_INCLUDE_ASSISTANT_MESSAGES = "false";
    expect(memoryIncludeAssistantMessages()).toBe(false);
  });
});

describe("framework-canonical long-term memory recall rules", () => {
  test("LONG_TERM_MEMORY_RECALL_RULES contains the four non-negotiable instructions", () => {
    // Lock down the headline rules: the names matter because chat-stream and
    // the orchestrator persona used to duplicate them inline. If you add or
    // remove a rule here, update agent personas and docs in the same change.
    expect(LONG_TERM_MEMORY_RECALL_RULES).toContain("Memory recall rules (framework-injected)");
    expect(LONG_TERM_MEMORY_RECALL_RULES).toContain("Use the context proactively");
    expect(LONG_TERM_MEMORY_RECALL_RULES).toContain("Never deny having memory when the block is non-empty");
    expect(LONG_TERM_MEMORY_RECALL_RULES).toContain("Don't ask for information you already have");
    expect(LONG_TERM_MEMORY_RECALL_RULES).toContain("Don't make up details that aren't in memory");
  });

  test("withLongTermMemory injects the canonical rules block when context is non-empty", () => {
    const out = withLongTermMemory("BASE", "User likes teal.");
    expect(out).toContain("BASE");
    expect(out).toContain("User likes teal.");
    expect(out).toContain(LONG_TERM_MEMORY_RECALL_RULES);
  });

  test("withLongTermMemory leaves the prompt untouched when no context is provided", () => {
    expect(withLongTermMemory("BASE", "")).toBe("BASE");
    expect(withLongTermMemory("BASE", "   ")).toBe("BASE");
  });

  test("orchestrator persona no longer copies the recall rules inline", () => {
    // Companion guarantee for the prompt consolidation: personas should
    // delegate to the framework block rather than duplicate it.
    const persona = (loadAgentPersona("orchestrator") || "").toLowerCase();
    expect(persona).not.toContain("proactive memory recall (critical)");
    expect(persona).not.toContain("never say \"what accounts did you share?\"");
  });

  test("order-management persona no longer copies the recall rules inline", () => {
    const persona = (loadAgentPersona("order-management") || "").toLowerCase();
    expect(persona).not.toContain("you do have long-term memory");
    expect(persona).not.toContain("do not say \"i don't have the ability to recall previous conversations");
  });
});
