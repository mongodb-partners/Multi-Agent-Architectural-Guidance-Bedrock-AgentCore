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
 * Allowed call sites:
 *   - api/src/lib/create-strands-agent.ts (template builder; calls getMcpTools)
 *   - api/src/lib/run-chat-stream.ts (uses cached template tools)
 *   - api/src/lib/specialist-answer-synthesizer.ts (synthesizer agent —
 *     intentionally `tools: []`; does not need MCP because it's a pure
 *     text-collation pass over already-fetched specialist answers).
 *
 * If a fourth call site appears, this test will fail and force the author to
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
  "lib/specialist-answer-synthesizer.ts",
];

/**
 * Subset of the allow-list that legitimately omits MCP tools. The
 * synthesizer agent collates already-fetched specialist answers — there's
 * no Mongo / gateway data left to fetch. All other entries MUST attach the
 * gateway MCP tools.
 */
const TOOLS_OPTIONAL_SITES = new Set<string>([
  "lib/specialist-answer-synthesizer.ts",
]);

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
    test(`${rel} attaches gateway MCP tools (directly or via cached template)`, () => {
      const body = readSrc(rel);
      expect(body).toMatch(/new\s+Agent\s*\(/);
      if (TOOLS_OPTIONAL_SITES.has(rel)) {
        // Synthesizer agent: confirm it intentionally passes `tools: []`
        // so this exception is documented in the source, not just here.
        expect(body).toMatch(/tools\s*:\s*\[\s*\]/);
        return;
      }
      // Either the file calls getMcpTools() inline (create-strands-agent.ts
      // does this when building a template), or it sources its `tools:`
      // array from a template returned by `getAgentTemplate()` (run-chat-stream.ts
      // post-Phase 4c). Both paths produce a `tools` array that contains
      // the gateway MCP tools.
      const inlinesGetMcpTools = /getMcpTools\s*\(/.test(body);
      const usesAgentTemplate = /getAgentTemplate\s*\(/.test(body) && /template\.tools/.test(body);
      expect(inlinesGetMcpTools || usesAgentTemplate).toBe(true);
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
