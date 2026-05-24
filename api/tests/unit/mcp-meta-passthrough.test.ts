/**
 * Regression pin: every MongoDB MCP tool's input schema must accept the
 * MCP-spec `_meta` envelope key.
 *
 * Background: MCP spec §2.4 reserves `_meta` on request params. The
 * AgentCore Gateway proxies `tools/call` with that field populated
 * (correlation IDs, progress tokens, …) and AWS validates the forwarded
 * arguments against the tool's declared `inputSchema`. Without `_meta`
 * declared on the schema, every gateway-routed call fails server-side with:
 *
 *   ValidationException - Parameter validation failed:
 *   - additionalProperties validation failed: property '_meta' is not
 *     defined in the schema and the schema does not allow additional
 *     properties
 *
 * The fix lives in `mcp-runtimes/mongodb-mcp/src/schemas.ts` as the
 * `META_PASSTHROUGH` spread that every input schema must include. The
 * matching `dispatch()` in server.ts strips `_meta` before invoking the
 * underlying handler so per-tool guard code never sees the envelope key.
 *
 * See docs/status/debugging.md "MongoDB MCP server schemas must allow MCP-spec
 * `_meta` passthrough".
 *
 * Implementation note: the schemas live outside `rootDir` (`api/`) so we
 * cannot import them directly under TS strict mode. Instead we read the
 * source text and pin the pattern there — this also catches "schema added,
 * `_meta` forgotten" regressions in a single regex scan instead of needing
 * to enumerate every tool by name in the test.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { z } from "zod";

const SCHEMAS_PATH = resolve(
  import.meta.dir,
  "../../..",
  "mcp-runtimes/mongodb-mcp/src/schemas.ts",
);
const SERVER_PATH = resolve(
  import.meta.dir,
  "../../..",
  "mcp-runtimes/mongodb-mcp/src/server.ts",
);

describe("MCP _meta passthrough on MongoDB tool schemas", () => {
  test("META_PASSTHROUGH itself accepts arbitrary record values", () => {
    // We mirror the declaration here so this test is also a guard that
    // `z.record(z.string(), z.unknown()).optional()` keeps the right
    // permissiveness even if Zod's API shifts under us.
    const metaPassthrough = { _meta: z.record(z.string(), z.unknown()).optional() };
    const schema = z.object(metaPassthrough);
    expect(() =>
      schema.parse({
        _meta: {
          correlationId: "abc-123",
          progressToken: 42,
          "bedrock.x-trace": { foo: 1 },
        },
      }),
    ).not.toThrow();
    expect(() => schema.parse({})).not.toThrow();        // optional
    expect(() => schema.parse({ _meta: {} })).not.toThrow(); // empty obj OK
  });

  test("schemas.ts declares META_PASSTHROUGH with the canonical Zod shape", () => {
    const src = readFileSync(SCHEMAS_PATH, "utf8");
    // Spread-compatible record-of-unknown. Tolerates whitespace + future
    // import-style changes; rejects narrowed value types that would reject
    // typical gateway-shaped metadata.
    expect(src).toMatch(
      /export const META_PASSTHROUGH\s*=\s*\{\s*_meta:\s*z\.record\(\s*z\.string\(\)\s*,\s*z\.unknown\(\)\s*\)\.optional\(\)\s*\}/,
    );
  });

  test("every per-tool input schema spreads ...META_PASSTHROUGH", () => {
    const src = readFileSync(SCHEMAS_PATH, "utf8");

    // Find every `export const <name>InputSchema = { … }` block and assert
    // each one ends with `...META_PASSTHROUGH,`. This scales to new tools
    // without needing the test to enumerate them.
    const blocks = [
      ...src.matchAll(
        /export const (\w+InputSchema)\s*=\s*\{([\s\S]*?)\n\};/g,
      ),
    ];
    expect(blocks.length).toBeGreaterThanOrEqual(4); // 4 tools today
    for (const [, name, body] of blocks) {
      expect(
        body,
        `expected ${name} to spread ...META_PASSTHROUGH (gateway-routed calls will fail with ValidationException without it — docs/status/debugging.md "MongoDB MCP server schemas must allow MCP-spec _meta passthrough")`,
      ).toMatch(/\.\.\.META_PASSTHROUGH/);
    }
  });

  test("server.ts strips _meta in dispatch before invoking the handler", () => {
    // The matching dispatch contract: schemas accept `_meta`, but the
    // handler never sees it. Without this strip, every per-tool guard in
    // vendor/guards.mjs would have to special-case the envelope key.
    const src = readFileSync(SERVER_PATH, "utf8");
    expect(src).toMatch(/const \{\s*_meta:\s*_ignored\s*,\s*\.\.\.handlerArgs\s*\}\s*=\s*args/);
  });

  test("server.ts imports its input schemas from ./schemas (not redeclared inline)", () => {
    // Belt-and-suspenders against drift between the inline and shared
    // schema definitions. Once we split them out in c5dc…, the only correct
    // source of truth is ./schemas.ts; an inline re-declaration would let
    // the contract drift without the regex above catching it.
    const src = readFileSync(SERVER_PATH, "utf8");
    expect(src).toMatch(/from\s+["']\.\/schemas(?:\.js|\.ts)?["']/);
    expect(src).toMatch(/mongodbQueryInputSchema/);
    expect(src).toMatch(/mongodbVectorSearchInputSchema/);
    expect(src).toMatch(/mongodbAggregateInputSchema/);
    expect(src).toMatch(/mongodbHybridSearchInputSchema/);
    // No inline redeclaration sneaking back in.
    expect(src).not.toMatch(
      /(?<!\.\.\.)\bconst\s+mongodb\w+InputSchema\s*=\s*\{/,
    );
  });
});
