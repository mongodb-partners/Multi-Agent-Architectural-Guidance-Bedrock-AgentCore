/**
 * Static invariant: every `new Agent(...)` site must attach gateway MCP tools.
 *
 * History: when the cleanup removed the in-process Mongo path, the streaming
 * chat agent in `run-chat-stream.ts` silently lost its Mongo tools because it
 * builds `new Agent({...})` directly from `toolsForAgent(...)` (which drops
 * Mongo names by design — they are supposed to come from the gateway). The
 * gateway tools are added by `getMcpTools()`; if that call is missing, the
 * model has no Mongo tool to call and only narrates that it would like to.
 *
 * Mocking Strands' `Agent` to test this dynamically would couple the test to
 * SDK internals. A static source scan is cheap and catches the regression at
 * the seam where it matters: the `new Agent(...)` constructor call.
 *
 * Allowed call sites (both must call `getMcpTools()`):
 *   - api/src/lib/create-strands-agent.ts
 *   - api/src/lib/run-chat-stream.ts
 *
 * If a third call site appears, this test will fail and force the author to
 * decide whether the new agent needs MCP tools (it almost certainly does) and
 * to update the allow-list with a justification.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = join(fileURLToPath(import.meta.url), "..", "..", "..", "..");
const API_SRC = join(REPO_ROOT, "api", "src");

const ALLOWED_AGENT_CONSTRUCTORS = [
  "lib/create-strands-agent.ts",
  "lib/run-chat-stream.ts",
];

function readSrc(rel: string): string {
  return readFileSync(join(API_SRC, rel), "utf-8");
}

function findAgentConstructorSites(): string[] {
  // Walk every .ts under api/src and collect any that contains `new Agent(`.
  // Fast enough that we don't bother short-circuiting.
  const { readdirSync, statSync } = require("node:fs");
  const out: string[] = [];
  function walk(dir: string, relPrefix = "") {
    for (const entry of readdirSync(dir)) {
      const abs = join(dir, entry);
      const rel = relPrefix ? `${relPrefix}/${entry}` : entry;
      const st = statSync(abs);
      if (st.isDirectory()) {
        walk(abs, rel);
        continue;
      }
      if (!entry.endsWith(".ts")) continue;
      const body = readFileSync(abs, "utf-8");
      // Match `new Agent(` but not `new AgentSomething(` (e.g. AgentRuntimeClient).
      if (/\bnew\s+Agent\s*\(/.test(body)) out.push(rel);
    }
  }
  walk(API_SRC);
  return out.sort();
}

describe("Strands Agent constructor invariants", () => {
  test("only the allow-listed call sites construct `new Agent({...})`", () => {
    const sites = findAgentConstructorSites();
    expect(sites.sort()).toEqual([...ALLOWED_AGENT_CONSTRUCTORS].sort());
  });

  for (const rel of ALLOWED_AGENT_CONSTRUCTORS) {
    test(`${rel} attaches gateway MCP tools (calls getMcpTools)`, () => {
      const body = readSrc(rel);
      expect(body).toMatch(/getMcpTools\s*\(/);
      // Belt-and-braces: `await getMcpTools()` should appear before the
      // `new Agent(` site in the same file. We just check both substrings
      // exist; ordering is enforced by the typecheck (mcpTools must be
      // declared before it is spread into `tools: [...inProcessTools, ...mcpTools]`).
      expect(body).toMatch(/new\s+Agent\s*\(/);
    });
  }

  test("agent-runtime-code.ts wraps invocation in withGatewayJwt(userJwt, ...)", () => {
    // Mirror invariant for the runtime container: without this scope, the
    // gateway MCP transport's `jwtInjectingFetch` reads `currentGatewayJwt() ===
    // undefined` and the `connect`/`listTools` handshake fails with
    // "Missing Bearer token", so `getMcpTools()` returns []. This was the very
    // first symptom we hit on the live stack.
    const body = readSrc("agent-runtime-code.ts");
    expect(body).toMatch(/withGatewayJwt\s*\(\s*userJwt\s*,/);
  });
});
