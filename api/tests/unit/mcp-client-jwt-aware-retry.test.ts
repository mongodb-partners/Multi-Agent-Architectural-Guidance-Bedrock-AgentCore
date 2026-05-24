/**
 * Regression pin: `getMcpTools()` JWT-aware retry on degraded singleton.
 *
 * Background: a runaway boot-time prewarm used to connect MCP without a JWT
 * in scope. The AgentCore Gateway rejected with `Missing Bearer token` and
 * `loadMcpTools()` returned `[]`. Because `getMcpTools()` reuses an in-flight
 * promise as a process-wide singleton, the empty result was then returned to
 * every chat turn arriving in the same boot window — even ones carrying a
 * real JWT — locking the runtime into a degraded template for the lifetime
 * of the process.
 *
 * The fix introduces `shouldRetryDegradedMcpSingleton(...)`: when the
 * in-flight singleton resolved to `[]` AND the current caller has a JWT in
 * scope, discard the singleton and start a fresh load. This is a pure
 * function so the regression is pinnable without standing up the whole
 * MCP client.
 *
 * See docs/status/debugging.md "MongoDB MCP prewarm singleton race".
 */

import { describe, expect, test } from "bun:test";
import { shouldRetryDegradedMcpSingleton } from "../../src/adapters/mongodb-mcp-client.ts";
import type { Tool } from "@strands-agents/sdk";

const FAKE_TOOL: Tool = { name: "mongodb_query" } as unknown as Tool;

describe("getMcpTools JWT-aware retry decision", () => {
  test("retries when in-flight was empty AND a JWT is in scope", () => {
    expect(shouldRetryDegradedMcpSingleton([], true)).toBe(true);
  });

  test("does NOT retry when in-flight was empty but no JWT is in scope (boot prewarm)", () => {
    // If we have no JWT either, a fresh load would fail the same way.
    // Returning the empty singleton avoids thrashing the gateway connect.
    expect(shouldRetryDegradedMcpSingleton([], false)).toBe(false);
  });

  test("does NOT retry when in-flight returned real tools", () => {
    expect(shouldRetryDegradedMcpSingleton([FAKE_TOOL], true)).toBe(false);
    expect(shouldRetryDegradedMcpSingleton([FAKE_TOOL], false)).toBe(false);
  });

  test("does NOT retry when in-flight returned multiple real tools", () => {
    const tools = [FAKE_TOOL, { name: "mongodb_vector_search" } as unknown as Tool];
    expect(shouldRetryDegradedMcpSingleton(tools, true)).toBe(false);
  });
});
