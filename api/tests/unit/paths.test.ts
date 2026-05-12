import { afterEach, describe, expect, test } from "bun:test";
import path from "node:path";
import { resolveConfigRoot } from "../../src/lib/paths.ts";

describe("resolveConfigRoot", () => {
  const prev = process.env.CONFIG_ROOT;

  afterEach(() => {
    if (prev === undefined) delete process.env.CONFIG_ROOT;
    else process.env.CONFIG_ROOT = prev;
  });

  test("CONFIG_ROOT overrides cwd", () => {
    process.env.CONFIG_ROOT = "/tmp/custom-config";
    expect(resolveConfigRoot()).toBe(path.resolve("/tmp/custom-config"));
  });
});
