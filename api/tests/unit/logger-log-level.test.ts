import { afterEach, beforeEach, describe, expect, test } from "bun:test";

const SAVED = {
  LOG_LEVEL: process.env.LOG_LEVEL,
  LOG_LEVEL_API: process.env.LOG_LEVEL_API,
  LOG_LEVEL_AGENT_RUNTIME: process.env.LOG_LEVEL_AGENT_RUNTIME,
  LOG_LEVEL_MCP: process.env.LOG_LEVEL_MCP,
  OTEL_SERVICE_NAME: process.env.OTEL_SERVICE_NAME,
};

beforeEach(() => {
  delete process.env.LOG_LEVEL;
  delete process.env.LOG_LEVEL_API;
  delete process.env.LOG_LEVEL_AGENT_RUNTIME;
  delete process.env.LOG_LEVEL_MCP;
  delete process.env.OTEL_SERVICE_NAME;
});

afterEach(() => {
  for (const k of Object.keys(SAVED) as (keyof typeof SAVED)[]) {
    if (SAVED[k] === undefined) delete process.env[k];
    else process.env[k] = SAVED[k];
  }
});

async function captureStdout(fn: () => void | Promise<void>): Promise<string> {
  const chunks: string[] = [];
  const orig = process.stdout.write.bind(process.stdout);
  process.stdout.write = (chunk: string | Uint8Array) => {
    chunks.push(typeof chunk === "string" ? chunk : new TextDecoder().decode(chunk));
    return true;
  };
  try {
    await fn();
  } finally {
    process.stdout.write = orig;
  }
  return chunks.join("");
}

async function emitDebug(): Promise<string> {
  const { logger } = await import("../../src/lib/logger.ts");
  return captureStdout(() => logger.debug("dbg"));
}

describe("Logger — per-component LOG_LEVEL_* overrides", () => {
  test("LOG_LEVEL_API=debug allows debug under service=mongodb-multiagent-api even when global LOG_LEVEL=warn", async () => {
    process.env.LOG_LEVEL = "warn";
    process.env.LOG_LEVEL_API = "debug";
    process.env.OTEL_SERVICE_NAME = "mongodb-multiagent-api";
    const out = await emitDebug();
    expect(out).not.toBe("");
    const line = JSON.parse(out.trim()) as Record<string, unknown>;
    expect(line.level).toBe("debug");
  });

  test("LOG_LEVEL_AGENT_RUNTIME=debug allows debug under service=...-agent-runtime; other services use global", async () => {
    process.env.LOG_LEVEL = "warn";
    process.env.LOG_LEVEL_AGENT_RUNTIME = "debug";
    process.env.OTEL_SERVICE_NAME = "mongodb-multiagent-agent-runtime";
    const out = await emitDebug();
    expect(out).not.toBe("");
  });

  test("LOG_LEVEL_MCP=error suppresses info under service=mongodb-multiagent-mcp even when global LOG_LEVEL=info", async () => {
    process.env.LOG_LEVEL = "info";
    process.env.LOG_LEVEL_MCP = "error";
    process.env.OTEL_SERVICE_NAME = "mongodb-multiagent-mcp";
    const { logger } = await import("../../src/lib/logger.ts");
    const out = await captureStdout(() => logger.info("should-be-suppressed"));
    expect(out).toBe("");
  });

  test("API-specific override only applies to API service; agent-runtime falls back to global", async () => {
    process.env.LOG_LEVEL = "warn";
    process.env.LOG_LEVEL_API = "debug";
    process.env.OTEL_SERVICE_NAME = "mongodb-multiagent-agent-runtime";
    const out = await emitDebug();
    expect(out).toBe("");
  });

  test("missing per-component override falls through to global LOG_LEVEL", async () => {
    process.env.LOG_LEVEL = "debug";
    process.env.OTEL_SERVICE_NAME = "mongodb-multiagent-api";
    const out = await emitDebug();
    expect(out).not.toBe("");
  });
});
