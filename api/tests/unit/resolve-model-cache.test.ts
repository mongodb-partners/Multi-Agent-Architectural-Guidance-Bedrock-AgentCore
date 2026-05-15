/**
 * Unit tests for the resolve-model BedrockModel cache.
 *
 * Without this cache, the swarm path constructed 4 BedrockModel clients per
 * chat (one per agent), each pulling AWS credentials and deriving signing
 * keys. The test pins:
 *   - Same agent config returns the SAME model instance
 *   - Different model id / temperature / region rebuilds
 *   - Test reset helper actually clears the cache
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  resolveModel,
  resetResolveModelCacheForTests,
} from "../../src/adapters/resolve-model.ts";
import type { AgentDetail } from "../../src/lib/config-scan.ts";

const SAVED_ENV = { ...process.env };

function makeAgent(overrides: Partial<AgentDetail> = {}): AgentDetail {
  return {
    id: "test-agent",
    name: "Test Agent",
    description: "Test",
    skills: [],
    tools: [],
    handoffs: [],
    model: "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    maxTokens: 1024,
    temperature: 0.3,
    memory: undefined,
    ...overrides,
  } as AgentDetail;
}

describe("resolve-model — caching", () => {
  beforeEach(() => {
    process.env.AWS_REGION = "us-east-1";
    resetResolveModelCacheForTests();
  });
  afterEach(() => {
    process.env = { ...SAVED_ENV };
    resetResolveModelCacheForTests();
  });

  test("identical agent config yields identical Model instance", () => {
    const a = makeAgent();
    const m1 = resolveModel(a);
    const m2 = resolveModel(a);
    expect(m1).toBe(m2);
  });

  test("changing maxTokens rebuilds the model", () => {
    const m1 = resolveModel(makeAgent({ maxTokens: 1024 }));
    const m2 = resolveModel(makeAgent({ maxTokens: 2048 }));
    expect(m1).not.toBe(m2);
  });

  test("changing temperature rebuilds the model", () => {
    const m1 = resolveModel(makeAgent({ temperature: 0.0 }));
    const m2 = resolveModel(makeAgent({ temperature: 0.7 }));
    expect(m1).not.toBe(m2);
  });

  test("changing model id rebuilds", () => {
    const m1 = resolveModel(makeAgent({ model: "us.anthropic.claude-haiku-4-5-20251001-v1:0" }));
    const m2 = resolveModel(makeAgent({ model: "us.anthropic.claude-sonnet-4-6" }));
    expect(m1).not.toBe(m2);
  });

  test("changing AWS_REGION rebuilds (clients are region-bound)", () => {
    const a = makeAgent();
    const m1 = resolveModel(a);
    process.env.AWS_REGION = "us-west-2";
    const m2 = resolveModel(a);
    expect(m1).not.toBe(m2);
  });

  test("missing model field throws with a helpful message", () => {
    expect(() => resolveModel(makeAgent({ model: "" }))).toThrow(/no model configured/i);
  });

  test("reset helper clears the cache between calls", () => {
    const a = makeAgent();
    const m1 = resolveModel(a);
    resetResolveModelCacheForTests();
    const m2 = resolveModel(a);
    expect(m1).not.toBe(m2);
  });
});
