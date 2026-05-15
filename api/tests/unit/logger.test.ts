import { trace } from "@opentelemetry/api";
import { afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { initOtel } from "../../src/lib/otel.ts";

// We test the logger by intercepting writes to stdout/stderr.
// Bun supports process.stdout.write / process.stderr.write capture via mocking.

const savedEnv: Record<string, string | undefined> = {};

beforeEach(() => {
  savedEnv.LOG_LEVEL = process.env.LOG_LEVEL;
});

afterEach(() => {
  if (savedEnv.LOG_LEVEL === undefined) delete process.env.LOG_LEVEL;
  else process.env.LOG_LEVEL = savedEnv.LOG_LEVEL;
});

/** Capture stdout writes during `fn()`. Returns concatenated string output. */
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

async function captureStderr(fn: () => void | Promise<void>): Promise<string> {
  const chunks: string[] = [];
  const orig = process.stderr.write.bind(process.stderr);
  process.stderr.write = (chunk: string | Uint8Array) => {
    chunks.push(typeof chunk === "string" ? chunk : new TextDecoder().decode(chunk));
    return true;
  };
  try {
    await fn();
  } finally {
    process.stderr.write = orig;
  }
  return chunks.join("");
}

// Re-import logger fresh inside each test (Bun modules are cached; we use dynamic import).
async function getLogger() {
  // Force re-evaluation by importing the module; level is resolved at call time.
  const mod = await import("../../src/lib/logger.ts");
  return mod.logger;
}

describe("logger — JSON output format", () => {
  test("logger.info writes valid JSON line to stdout", async () => {
    process.env.LOG_LEVEL = "info";
    const logger = await getLogger();
    const out = await captureStdout(() => logger.info("hello world", { foo: "bar" }));
    const line = JSON.parse(out.trim()) as Record<string, unknown>;
    expect(line.level).toBe("info");
    expect(line.msg).toBe("hello world");
    expect(line.foo).toBe("bar");
    expect(typeof line.ts).toBe("string");
  });

  test("logger.error writes to stderr", async () => {
    process.env.LOG_LEVEL = "error";
    const logger = await getLogger();
    const err = await captureStderr(() => logger.error("oops", { code: 42 }));
    const line = JSON.parse(err.trim()) as Record<string, unknown>;
    expect(line.level).toBe("error");
    expect(line.msg).toBe("oops");
    expect(line.code).toBe(42);
  });

  test("logger.warn writes to stderr", async () => {
    process.env.LOG_LEVEL = "warn";
    const logger = await getLogger();
    const err = await captureStderr(() => logger.warn("careful"));
    const line = JSON.parse(err.trim()) as Record<string, unknown>;
    expect(line.level).toBe("warn");
  });
});

describe("logger — LOG_LEVEL filtering", () => {
  test("LOG_LEVEL=error suppresses info and debug", async () => {
    process.env.LOG_LEVEL = "error";
    const logger = await getLogger();
    const out = await captureStdout(() => {
      logger.info("should be suppressed");
      logger.debug("also suppressed");
    });
    expect(out).toBe("");
  });

  test("LOG_LEVEL=error suppresses warn", async () => {
    process.env.LOG_LEVEL = "error";
    const logger = await getLogger();
    const err = await captureStderr(() => logger.warn("suppressed warn"));
    expect(err).toBe("");
  });

  test("LOG_LEVEL=warn allows warn but suppresses info and debug", async () => {
    process.env.LOG_LEVEL = "warn";
    const logger = await getLogger();
    const warnOut = await captureStderr(() => logger.warn("w"));
    const infoOut = await captureStdout(() => logger.info("i"));
    expect(warnOut).not.toBe("");
    expect(infoOut).toBe("");
  });

  test("LOG_LEVEL=debug allows all levels", async () => {
    process.env.LOG_LEVEL = "debug";
    const logger = await getLogger();
    const dbgOut = await captureStdout(() => logger.debug("d"));
    expect(dbgOut).not.toBe("");
    const infoOut = await captureStdout(() => logger.info("i"));
    expect(infoOut).not.toBe("");
  });

  test("unknown LOG_LEVEL falls back to info (debug suppressed)", async () => {
    process.env.LOG_LEVEL = "bogus";
    const logger = await getLogger();
    const dbg = await captureStdout(() => logger.debug("should be suppressed"));
    expect(dbg).toBe("");
    const info = await captureStdout(() => logger.info("should appear"));
    expect(info).not.toBe("");
  });
});

describe("logger — OpenTelemetry trace correlation", () => {
  beforeAll(() => {
    initOtel({ serviceName: "mongodb-multiagent-api-logger-test" });
  });

  test("logger.info includes trace_id when inside an active span", async () => {
    process.env.LOG_LEVEL = "info";
    const logger = await getLogger();
    const t = trace.getTracer("logger-test");
    await t.startActiveSpan("unit-span", async (span) => {
      const out = await captureStdout(() => logger.info("inside span"));
      const line = JSON.parse(out.trim()) as Record<string, unknown>;
      expect(line.trace_id).toBe(span.spanContext().traceId);
      expect(line.span_id).toBe(span.spanContext().spanId);
      span.end();
    });
  });

  test("logger.child merges base fields", async () => {
    process.env.LOG_LEVEL = "info";
    const mod = await import("../../src/lib/logger.ts");
    const child = mod.logger.child({ route: "/unit" });
    const out = await captureStdout(() => child.info("child msg", { extra: 1 }));
    const line = JSON.parse(out.trim()) as Record<string, unknown>;
    expect(line.route).toBe("/unit");
    expect(line.msg).toBe("child msg");
    expect(line.extra).toBe(1);
  });
});
