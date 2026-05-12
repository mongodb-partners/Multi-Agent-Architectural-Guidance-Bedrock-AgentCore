import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import path from "node:path";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import {
  resetEnvironmentYamlCacheForTests,
  resolveApiListenPort,
  resolveCorsOrigins,
} from "../../src/lib/environment-config.ts";

describe("environment-config", () => {
  let prevConfigRoot: string | undefined;
  let tmpDir: string | null = null;

  beforeEach(() => {
    resetEnvironmentYamlCacheForTests();
    prevConfigRoot = process.env.CONFIG_ROOT;
    delete process.env.PORT;
    delete process.env.API_PORT;
    delete process.env.CORS_ORIGINS;
  });

  afterEach(() => {
    if (tmpDir) {
      rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = null;
    }
    if (prevConfigRoot !== undefined) {
      process.env.CONFIG_ROOT = prevConfigRoot;
    } else {
      delete process.env.CONFIG_ROOT;
    }
    resetEnvironmentYamlCacheForTests();
  });

  function writeEnvYaml(dir: string, content: string) {
    const file = path.join(dir, "environment.yaml");
    writeFileSync(file, content, "utf8");
  }

  test("resolveApiListenPort uses YAML api.port when env unset", () => {
    tmpDir = mkdtempSync(path.join(tmpdir(), "envcfg-"));
    process.env.CONFIG_ROOT = tmpDir;
    writeEnvYaml(tmpDir, "api:\n  port: 4001\n");
    expect(resolveApiListenPort()).toBe(4001);
  });

  test("resolveApiListenPort prefers PORT over YAML", () => {
    tmpDir = mkdtempSync(path.join(tmpdir(), "envcfg-"));
    process.env.CONFIG_ROOT = tmpDir;
    writeEnvYaml(tmpDir, "api:\n  port: 4001\n");
    process.env.PORT = "5000";
    expect(resolveApiListenPort()).toBe(5000);
  });

  test("resolveCorsOrigins uses YAML when CORS_ORIGINS unset", () => {
    tmpDir = mkdtempSync(path.join(tmpdir(), "envcfg-"));
    process.env.CONFIG_ROOT = tmpDir;
    writeEnvYaml(
      tmpDir,
      "api:\n  corsOrigins:\n    - https://a.example\n    - https://b.example\n",
    );
    expect(resolveCorsOrigins()).toEqual(["https://a.example", "https://b.example"]);
  });

  test("resolveCorsOrigins prefers CORS_ORIGINS env (comma-separated)", () => {
    tmpDir = mkdtempSync(path.join(tmpdir(), "envcfg-"));
    process.env.CONFIG_ROOT = tmpDir;
    writeEnvYaml(
      tmpDir,
      "api:\n  corsOrigins:\n    - https://ignored.example\n",
    );
    process.env.CORS_ORIGINS = "https://one.test, https://two.test ";
    expect(resolveCorsOrigins()).toEqual(["https://one.test", "https://two.test"]);
  });

  test("invalid YAML port falls back to default 3000", () => {
    tmpDir = mkdtempSync(path.join(tmpdir(), "envcfg-"));
    process.env.CONFIG_ROOT = tmpDir;
    writeEnvYaml(tmpDir, "api:\n  port: not-a-number\n");
    expect(resolveApiListenPort()).toBe(3000);
  });
});
