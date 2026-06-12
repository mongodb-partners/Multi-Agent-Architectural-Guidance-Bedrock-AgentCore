/**
 * Shared MongoDB tool-data redactors used by BOTH the `[mcp] callTool` audit
 * log (api/src/adapters/mongodb-mcp-client.ts) and the OTel span flattener
 * (api/src/lib/trace-collector.ts). Locking in the contract here keeps the
 * two CloudWatch surfaces (log group + /aws/spans) in lockstep and prevents a
 * PII regression on either path. See docs P0-4 / security-audit-test.sh.
 */

import { afterEach, describe, expect, test } from "bun:test";
import {
  PII_ARG_KEYS,
  summariseValue,
  redactMongoArgsForLog,
  maskPiiInString,
} from "../../src/lib/logger.ts";

afterEach(() => {
  delete process.env.MCP_LOG_RAW_ARGS;
});

describe("redactMongoArgsForLog", () => {
  test("summarises filter / document / queryVector and preserves safe metadata", () => {
    const out = redactMongoArgsForLog({
      collection: "orders",
      operation: "find",
      limit: 5,
      filter: { orderId: "o-1", customerEmail: "uat-redaction-test-123@example.com" },
      document: { _id: "ord-1", customer: "alex" },
      queryVector: new Array(1024).fill(0.1),
    }) as Record<string, unknown>;

    expect(out.collection).toBe("orders");
    expect(out.operation).toBe("find");
    expect(out.limit).toBe(5);
    expect(out.filter).toBe("[object keys=2]");
    expect(out.document).toBe("[object keys=2]");
    expect(out.queryVector).toBe("[array len=1024]");

    // The raw email must never survive serialization.
    expect(JSON.stringify(out)).not.toContain("uat-redaction-test-123@example.com");
  });

  test("every key in PII_ARG_KEYS is summarised", () => {
    const args: Record<string, unknown> = {};
    for (const k of PII_ARG_KEYS) args[k] = { secret: "value" };
    const out = redactMongoArgsForLog(args) as Record<string, unknown>;
    for (const k of PII_ARG_KEYS) {
      expect(typeof out[k]).toBe("string");
      expect(out[k]).toMatch(/^\[/);
    }
  });

  test("MCP_LOG_RAW_ARGS=true preserves raw args (operator opt-in)", () => {
    process.env.MCP_LOG_RAW_ARGS = "true";
    const out = redactMongoArgsForLog({
      filter: { email: "alex@example.com" },
    }) as { filter: { email: string } };
    expect(out.filter.email).toBe("alex@example.com");
  });

  test("non-object input is returned unchanged", () => {
    expect(redactMongoArgsForLog(undefined)).toBeUndefined();
    expect(redactMongoArgsForLog("hello")).toBe("hello");
  });
});

describe("summariseValue", () => {
  test("returns null for null/undefined", () => {
    expect(summariseValue(null)).toBeNull();
    expect(summariseValue(undefined)).toBeNull();
  });
  test("describes arrays, objects, and scalars by shape only", () => {
    expect(summariseValue([1, 2, 3])).toBe("[array len=3]");
    expect(summariseValue({ a: 1, b: 2 })).toBe("[object keys=2]");
    expect(summariseValue("abc")).toBe("[string len=3]");
    expect(summariseValue(7)).toBe("[number]");
    expect(summariseValue(true)).toBe("[boolean]");
  });
});

describe("maskPiiInString", () => {
  test("masks email addresses", () => {
    expect(maskPiiInString("contact uat-redaction-test-123@example.com now")).toBe(
      "contact [email] now",
    );
  });

  test("masks multiple occurrences and phone-like runs", () => {
    const out = maskPiiInString("a@b.com and c@d.org call +1 (415) 555-2671");
    expect(out).not.toContain("@b.com");
    expect(out).not.toContain("@d.org");
    expect(out).toContain("[email]");
    expect(out).toContain("[phone]");
  });

  test("leaves PII-free strings untouched", () => {
    expect(maskPiiInString("orders")).toBe("orders");
    expect(maskPiiInString("status=open limit=5")).toBe("status=open limit=5");
  });

  test("MCP_LOG_RAW_ARGS=true disables masking", () => {
    process.env.MCP_LOG_RAW_ARGS = "true";
    expect(maskPiiInString("a@b.com")).toBe("a@b.com");
  });

  test("empty string is a no-op", () => {
    expect(maskPiiInString("")).toBe("");
  });
});
