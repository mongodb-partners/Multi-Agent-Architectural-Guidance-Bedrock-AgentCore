import { afterEach, beforeEach, describe, expect, test } from "bun:test";

/**
 * Redactor matrix — the 8 cases the plan calls out. We capture the JSON line
 * the default logger emits and parse it back to assert per-key redaction.
 */

const savedEnv: Record<string, string | undefined> = {};

beforeEach(() => {
  savedEnv.LOG_LEVEL = process.env.LOG_LEVEL;
  process.env.LOG_LEVEL = "info";
});

afterEach(() => {
  if (savedEnv.LOG_LEVEL === undefined) delete process.env.LOG_LEVEL;
  else process.env.LOG_LEVEL = savedEnv.LOG_LEVEL;
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

async function emit(ctx: Record<string, unknown>): Promise<Record<string, unknown>> {
  const { logger } = await import("../../src/lib/logger.ts");
  const out = await captureStdout(() => logger.info("redact-test", ctx));
  return JSON.parse(out.trim()) as Record<string, unknown>;
}

describe("logger default redactor — 8-case matrix", () => {
  test("1. Authorization header masked", async () => {
    const line = await emit({ headers: { Authorization: "Bearer secret-abc" } });
    expect((line.headers as Record<string, unknown>).Authorization).toBe("***");
  });

  test("2. JWT-shaped string in a neutral field becomes jwt:*** (value-level mask)", async () => {
    const jwt =
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhYmMifQ.signature-part-here-_abc";
    // Use a key that does NOT match SENSITIVE_KEY so the value-level JWT_LIKE
    // mask runs (sensitive keys are key-level masked to "***" before the value
    // is even inspected).
    const line = await emit({ evidence: jwt });
    expect(line.evidence).toBe("jwt:***");
  });

  test("3. mongodb_uri value masks credentials", async () => {
    const line = await emit({ mongodb_uri: "mongodb+srv://user:pass@host/db" });
    // Key is sensitive (matches /mongodb_uri/) so the whole value is starred.
    expect(line.mongodb_uri).toBe("***");
  });

  test("3b. mongodb+srv connection string in a non-sensitive key still masks creds", async () => {
    const line = await emit({ dsn: "mongodb+srv://alex:p@ssw0rd@cluster.mongodb.net/app" });
    expect(line.dsn).toBe("mongodb+srv://***@cluster.mongodb.net/app");
  });

  test("4. password key masked", async () => {
    const line = await emit({ password: "hunter2" });
    expect(line.password).toBe("***");
  });

  test("5. api_key / apiKey / api-key all masked", async () => {
    const line = await emit({ api_key: "k1", apiKey: "k2", "api-key": "k3" });
    expect(line.api_key).toBe("***");
    expect(line.apiKey).toBe("***");
    expect(line["api-key"]).toBe("***");
  });

  test("6. nested object at depth 2 still redacted", async () => {
    const line = await emit({
      outer: {
        inner: {
          token: "leak-me",
          ok: "ok",
        },
      },
    });
    const outer = line.outer as Record<string, Record<string, unknown>>;
    expect(outer.inner.token).toBe("***");
    expect(outer.inner.ok).toBe("ok");
  });

  test("7. email value is sha1-hashed (PII)", async () => {
    const line = await emit({ email: "alex@example.com" });
    expect(typeof line.email).toBe("string");
    expect(line.email as string).toMatch(/^sha1:[0-9a-f]{8}$/);
  });

  test("8. long `query` and `message` fields truncated to 256 chars + ellipsis", async () => {
    const long = "A".repeat(500);
    const line = await emit({ query: long });
    const truncated = line.query as string;
    expect(truncated.length).toBeLessThanOrEqual(257);
    expect(truncated.endsWith("…")).toBe(true);
  });
});
