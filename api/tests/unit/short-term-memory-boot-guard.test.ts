import { describe, expect, test, afterEach, beforeEach } from "bun:test";
import { assertShortTermBackendConfigured } from "../../src/lib/short-term-memory.ts";

const ENV_KEYS = ["SHORT_TERM_MEMORY_BACKEND", "AGENTCORE_MEMORY_STORE_ID"] as const;

describe("assertShortTermBackendConfigured", () => {
  const original: Record<string, string | undefined> = {};

  beforeEach(() => {
    for (const key of ENV_KEYS) {
      original[key] = process.env[key];
      delete process.env[key];
    }
  });

  afterEach(() => {
    for (const key of ENV_KEYS) {
      const prev = original[key];
      if (prev === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = prev;
      }
    }
  });

  test("does nothing when AgentCore backend is not selected", () => {
    expect(() => assertShortTermBackendConfigured()).not.toThrow();
    process.env.SHORT_TERM_MEMORY_BACKEND = "session-store";
    expect(() => assertShortTermBackendConfigured()).not.toThrow();
  });

  test("passes when AgentCore backend has a memory store id", () => {
    process.env.SHORT_TERM_MEMORY_BACKEND = "agentcore";
    process.env.AGENTCORE_MEMORY_STORE_ID = "mem-abc123";
    expect(() => assertShortTermBackendConfigured()).not.toThrow();
  });

  test("fails fast when AgentCore is selected but memory store id is missing", () => {
    process.env.SHORT_TERM_MEMORY_BACKEND = "agentcore";
    expect(() => assertShortTermBackendConfigured()).toThrow(
      /AGENTCORE_MEMORY_STORE_ID/,
    );
  });

  test("fails fast when memory store id is whitespace only", () => {
    process.env.SHORT_TERM_MEMORY_BACKEND = "agentcore";
    process.env.AGENTCORE_MEMORY_STORE_ID = "   ";
    expect(() => assertShortTermBackendConfigured()).toThrow(
      /AGENTCORE_MEMORY_STORE_ID/,
    );
  });

  test("backend selector is case-insensitive and trims whitespace", () => {
    process.env.SHORT_TERM_MEMORY_BACKEND = "  AGENTCORE  ";
    expect(() => assertShortTermBackendConfigured()).toThrow();
    process.env.AGENTCORE_MEMORY_STORE_ID = "mem-xyz";
    expect(() => assertShortTermBackendConfigured()).not.toThrow();
  });
});
