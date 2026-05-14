import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, unlinkSync, writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import {
  assertHttpToolsFileSecure,
  buildHttpToolsMap,
  makeHttpConfigTool,
  resetHttpToolsMapCacheForTests,
} from "../../src/lib/http-tools-runtime.ts";
import {
  loadHttpToolsFile,
  resetHttpToolsLoadCacheForTests,
} from "../../src/lib/http-tools-load.ts";
import type { HttpToolDefinition, HttpToolsFile } from "../../src/lib/http-tools-schema.ts";

const tmpDir = path.join(import.meta.dir, "../fixtures/_ssrf_tmp");
const tmpFile = path.join(tmpDir, "http-tools.json");

const sampleTool: HttpToolDefinition = {
  name: "fixture_call",
  description: "fixture",
  method: "POST",
  url: "https://api.example.test/hook",
  parameters: [{ name: "x", type: "string", description: "x", required: true }],
  timeoutMs: 1000,
  passThroughBody: false,
};

afterEach(() => {
  if (existsSync(tmpFile)) unlinkSync(tmpFile);
  delete process.env.HTTP_TOOLS_CONFIG_PATH;
  resetHttpToolsLoadCacheForTests();
  resetHttpToolsMapCacheForTests();
});

function writeFile(content: HttpToolsFile) {
  mkdirSync(tmpDir, { recursive: true });
  writeFileSync(tmpFile, JSON.stringify(content), "utf8");
  process.env.HTTP_TOOLS_CONFIG_PATH = tmpFile;
}

describe("HTTP tools SSRF guard (P0-3)", () => {
  test("assertHttpToolsFileSecure passes for an empty tools file (no allowlist required)", () => {
    expect(() => assertHttpToolsFileSecure({ tools: [] }, "test.json")).not.toThrow();
  });

  test("assertHttpToolsFileSecure throws when tools exist but security block is missing", () => {
    expect(() =>
      assertHttpToolsFileSecure({ tools: [sampleTool] }, "test.json"),
    ).toThrow(/no security allowlist/);
  });

  test("assertHttpToolsFileSecure throws when allowedHosts and allowedHostSuffixes are both empty", () => {
    expect(() =>
      assertHttpToolsFileSecure(
        { security: { allowedHosts: [], allowedHostSuffixes: [] }, tools: [sampleTool] },
        "test.json",
      ),
    ).toThrow(/no security allowlist/);
  });

  test("assertHttpToolsFileSecure passes with allowedHosts populated", () => {
    expect(() =>
      assertHttpToolsFileSecure(
        { security: { allowedHosts: ["api.example.test"] }, tools: [sampleTool] },
        "test.json",
      ),
    ).not.toThrow();
  });

  test("buildHttpToolsMap throws when http-tools.json declares tools without an allowlist", () => {
    writeFile({ tools: [sampleTool] });
    expect(() => buildHttpToolsMap()).toThrow(/no security allowlist/);
  });

  test("runtime call rejected with ssrf_blocked when allowlist missing (defense in depth)", async () => {
    process.env.HTTP_TOOLS_MOCK = "0";
    const file: HttpToolsFile = { tools: [sampleTool] }; // no security block
    const t = makeHttpConfigTool(sampleTool, file) as unknown as {
      invoke: (input: Record<string, unknown>) => Promise<{ status: string; code?: string; message?: string }>;
    };
    const result = await t.invoke({ x: "v" });
    expect(result.status).toBe("error");
    expect(result.code).toBe("ssrf_blocked");
    expect(result.message).toBe("allowlist_missing");
    delete process.env.HTTP_TOOLS_MOCK;
  });

  test("runtime call accepted when host matches allowlist (mock mode)", async () => {
    process.env.HTTP_TOOLS_MOCK = "1";
    const file: HttpToolsFile = {
      security: { allowedHosts: ["api.example.test"] },
      tools: [sampleTool],
    };
    const t = makeHttpConfigTool(sampleTool, file) as unknown as {
      invoke: (input: Record<string, unknown>) => Promise<{ status: string }>;
    };
    const result = await t.invoke({ x: "v" });
    expect(result.status).toBe("ok");
    delete process.env.HTTP_TOOLS_MOCK;
  });

  test("loadHttpToolsFile + buildHttpToolsMap accept a properly-secured file", () => {
    writeFile({
      security: { allowedHosts: ["api.example.test"] },
      tools: [sampleTool],
    });
    const file = loadHttpToolsFile(true);
    expect(file.tools.length).toBe(1);
    const map = buildHttpToolsMap();
    expect(map.has("fixture_call")).toBe(true);
  });
});
