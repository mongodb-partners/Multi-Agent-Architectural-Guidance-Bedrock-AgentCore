import { describe, expect, test } from "bun:test";
import {
  normalizeFilter,
  splitClauses,
  detectValueTypeWarnings,
  buildSchemaSummary,
  runEmptyResultDiagnostic,
  scoreHistogram,
  type MongoLike,
} from "../../src/lib/mongo-diagnostic.ts";

describe("normalizeFilter", () => {
  test("wraps bare equality clauses with $eq", () => {
    expect(normalizeFilter({ status: "shipped", qty: 3 })).toEqual({
      status: { $eq: "shipped" },
      qty: { $eq: 3 },
    });
  });

  test("preserves operator clauses", () => {
    expect(normalizeFilter({ qty: { $gt: 5 } })).toEqual({ qty: { $gt: 5 } });
  });

  test("preserves top-level $and / $or", () => {
    const f = { $and: [{ a: 1 }] };
    expect(normalizeFilter(f).$and).toBeDefined();
  });

  test("returns empty object for non-object input", () => {
    expect(normalizeFilter(null)).toEqual({});
    expect(normalizeFilter(42)).toEqual({});
  });
});

describe("splitClauses", () => {
  test("returns one clause per top-level field", () => {
    const out = splitClauses(normalizeFilter({ a: 1, b: { $gt: 2 } }));
    expect(out.length).toBe(2);
    expect(out[0]).toEqual({ field: "a", op: "$eq", value: 1 });
    expect(out[1]).toEqual({ field: "b", op: "$gt", value: 2 });
  });

  test("flattens top-level $and clauses", () => {
    const out = splitClauses(normalizeFilter({ $and: [{ a: 1 }, { b: 2 }] }));
    expect(out.length).toBe(2);
    expect(out.map((c) => c.field).sort()).toEqual(["a", "b"]);
  });
});

describe("detectValueTypeWarnings", () => {
  test("flags 24-hex string against ObjectId sample", () => {
    class FakeObjectId {
      toHexString() {
        return "deadbeefdeadbeefdeadbeef";
      }
    }
    const sample = { customerId: new FakeObjectId() };
    const clauses = [{ field: "customerId", op: "$eq", value: "deadbeefdeadbeefdeadbeef" }];
    const warnings = detectValueTypeWarnings(clauses, sample as Record<string, unknown>);
    expect(warnings.length).toBe(1);
    expect(warnings[0].kind).toBe("objectid_string");
  });

  test("flags case-only mismatches", () => {
    const sample = { status: "Shipped" };
    const clauses = [{ field: "status", op: "$eq", value: "SHIPPED" }];
    const warnings = detectValueTypeWarnings(clauses, sample);
    expect(warnings[0].kind).toBe("case_sensitive");
  });

  test("flags ISO-string against Date sample", () => {
    const sample = { createdAt: new Date("2024-01-01") };
    const clauses = [{ field: "createdAt", op: "$gte", value: "2024-01-01" }];
    const warnings = detectValueTypeWarnings(clauses, sample);
    expect(warnings[0].kind).toBe("iso_string_vs_date");
  });

  test("returns empty when no sample provided", () => {
    expect(detectValueTypeWarnings([], null)).toEqual([]);
  });
});

describe("buildSchemaSummary", () => {
  test("describes each sampled field with a JS-friendly type", () => {
    const sample = { name: "alice", age: 30, tags: ["a"], joined: new Date() };
    const out = buildSchemaSummary("users", sample, 100);
    expect(out.collection).toBe("users");
    expect(out.estimatedDocumentCount).toBe(100);
    const t = Object.fromEntries(out.fields.map((f) => [f.name, f.type]));
    expect(t.name).toBe("string");
    expect(t.age).toBe("number");
    expect(t.tags).toBe("array");
    expect(t.joined).toBe("Date");
  });

  test("returns empty fields when sample missing", () => {
    expect(buildSchemaSummary("c", null, 0).fields).toEqual([]);
  });
});

describe("runEmptyResultDiagnostic", () => {
  test("identifies offending clause by counting without each one", async () => {
    const counts: Record<string, number> = {
      "(omit:status)": 5,
      "(omit:tier)": 0,
    };

    const coll: MongoLike = {
      countDocuments: async (filter) => {
        const keys = Object.keys(filter).sort();
        if (keys.join(",") === "tier") return counts["(omit:status)"];
        if (keys.join(",") === "status") return counts["(omit:tier)"];
        return 0;
      },
      findOne: async () => ({ status: "shipped", tier: "gold" }),
    };

    const out = await runEmptyResultDiagnostic({
      collection: "orders",
      filter: { status: "delivered", tier: "gold" },
      resultCount: 0,
      sampleDoc: { status: "shipped", tier: "gold" },
      coll,
    });

    expect(out.offendingClause?.field).toBe("status");
    expect(out.offendingClause?.countWithout).toBe(5);
    expect(out.ranProbes).toBeGreaterThan(0);
  });

  test("flags fields not present in the sampled document", async () => {
    const coll: MongoLike = {
      countDocuments: async () => 0,
      findOne: async () => ({ status: "shipped" }),
    };
    const out = await runEmptyResultDiagnostic({
      collection: "orders",
      filter: { phantom: "x" },
      resultCount: 0,
      sampleDoc: { status: "shipped" },
      coll,
    });
    expect(out.field_not_in_sample).toEqual(["phantom"]);
    expect(out.schemaMismatch).toBe(true);
  });
});

describe("scoreHistogram", () => {
  test("buckets scores 0..1 into 5 bins", () => {
    const { histogram, summary } = scoreHistogram([0.05, 0.25, 0.45, 0.65, 0.85, 0.95]);
    expect(histogram.length).toBe(5);
    expect(histogram.reduce((a, b) => a + b, 0)).toBe(6);
    expect(summary.min).toBe(0.05);
    expect(summary.max).toBe(0.95);
  });

  test("returns zero histogram on empty input", () => {
    const { histogram } = scoreHistogram([]);
    expect(histogram).toEqual([0, 0, 0, 0, 0]);
  });
});
