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
import { getAgent } from "../../src/lib/config-scan.ts";
import { memoryIncludeAssistantMessages } from "../../src/lib/long-term-memory.ts";

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
