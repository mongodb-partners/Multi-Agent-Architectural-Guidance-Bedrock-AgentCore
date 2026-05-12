/**
 * MongoDB query diagnostic — answers "why fetched / why not".
 *
 * Pure logic (clause-walker, schema sampler, value-type heuristics, normalizer)
 * lives here so it can be unit-tested with stubbed collections. Side-effects
 * (`countDocuments`, `findOne`, `explain`) accept a `MongoLike` interface so
 * tests don't need a real driver.
 *
 * Gating env vars (read here, callers don't need to know them):
 *  - `MONGO_TRACE_EXPLAIN`           (default 0) — capture explain("executionStats")
 *  - `MONGO_TRACE_DIAGNOSTIC`        (default 0) — run empty/low-result walker
 *  - `MONGO_DIAGNOSTIC_BUDGET_MS`    (default 4000) — total budget per query
 *  - `MONGO_DIAGNOSTIC_TIMEOUT_MS`   (default 500)  — per-probe `maxTimeMS`
 *  - `MONGO_TRACE_SCHEMA_SAMPLE`     (default 1)
 *  - `MONGO_TRACE_FLAG_USERID`       (default 0)
 *  - `MONGO_TRACE_VECTOR_DEBUG`      (default 0)
 */

import type { MongoDiagnosticPayload, MongoSchemaPayload } from "./trace-types.ts";

// ---------------------------------------------------------------------------
// Env helpers
// ---------------------------------------------------------------------------

function envBool(name: string, fallback: boolean): boolean {
  const v = process.env[name]?.trim().toLowerCase();
  if (v === undefined || v === "") return fallback;
  if (v === "0" || v === "false") return false;
  if (v === "1" || v === "true") return true;
  return fallback;
}

function envInt(name: string, fallback: number): number {
  const v = process.env[name];
  if (!v) return fallback;
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

export const diagnosticConfig = () => ({
  explainEnabled: envBool("MONGO_TRACE_EXPLAIN", false),
  diagnosticEnabled: envBool("MONGO_TRACE_DIAGNOSTIC", false),
  schemaEnabled: envBool("MONGO_TRACE_SCHEMA_SAMPLE", true),
  flagUserid: envBool("MONGO_TRACE_FLAG_USERID", false),
  vectorDebug: envBool("MONGO_TRACE_VECTOR_DEBUG", false),
  totalBudgetMs: envInt("MONGO_DIAGNOSTIC_BUDGET_MS", 4_000),
  perProbeMs: envInt("MONGO_DIAGNOSTIC_TIMEOUT_MS", 500),
});

// ---------------------------------------------------------------------------
// Filter normalization + clause split
// ---------------------------------------------------------------------------

/** Rewrite bare `{ field: value }` to `{ field: { $eq: value } }`. */
export function normalizeFilter(filter: unknown): Record<string, unknown> {
  if (!filter || typeof filter !== "object" || Array.isArray(filter)) return {};
  const f = filter as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(f)) {
    if (k.startsWith("$")) {
      out[k] = v;
      continue;
    }
    if (v && typeof v === "object" && !Array.isArray(v) && Object.keys(v).some((kk) => kk.startsWith("$"))) {
      out[k] = v;
    } else {
      out[k] = { $eq: v };
    }
  }
  return out;
}

/** Split a top-level filter into its individual clauses (top-level $and aware). */
export function splitClauses(
  filter: Record<string, unknown>,
): Array<{ field: string; op: string; value: unknown }> {
  const clauses: Array<{ field: string; op: string; value: unknown }> = [];
  for (const [k, v] of Object.entries(filter)) {
    if (k === "$and" && Array.isArray(v)) {
      for (const sub of v) {
        for (const inner of splitClauses(normalizeFilter(sub))) clauses.push(inner);
      }
      continue;
    }
    if (k === "$or" || k === "$nor") continue; // disjunctive — keep whole
    if (v && typeof v === "object" && !Array.isArray(v)) {
      const obj = v as Record<string, unknown>;
      const ops = Object.keys(obj).filter((o) => o.startsWith("$"));
      if (ops.length > 0) {
        clauses.push({ field: k, op: ops[0], value: obj[ops[0]] });
        continue;
      }
    }
    clauses.push({ field: k, op: "$eq", value: v });
  }
  return clauses;
}

/** Compose a filter object back from a list of clauses, omitting one by index. */
function composeWithout(
  clauses: Array<{ field: string; op: string; value: unknown }>,
  omitIdx: number,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (let i = 0; i < clauses.length; i++) {
    if (i === omitIdx) continue;
    const c = clauses[i];
    out[c.field] = { [c.op]: c.value };
  }
  return out;
}

// ---------------------------------------------------------------------------
// Value-type heuristics
// ---------------------------------------------------------------------------

const OBJECTID_HEX = /^[0-9a-fA-F]{24}$/;
const ISO_DATE_LOOKING = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2})?/;

export function detectValueTypeWarnings(
  clauses: Array<{ field: string; op: string; value: unknown }>,
  sampleDoc: Record<string, unknown> | null,
): NonNullable<MongoDiagnosticPayload["valueTypeWarnings"]> {
  const out: NonNullable<MongoDiagnosticPayload["valueTypeWarnings"]> = [];
  if (!sampleDoc) return out;
  for (const c of clauses) {
    const sampleVal = sampleDoc[c.field];
    if (sampleVal == null) continue;
    if (typeof c.value === "string" && OBJECTID_HEX.test(c.value)) {
      // sample appears to be an ObjectId by being an object with toHexString or constructor name.
      const isObjectId =
        typeof sampleVal === "object" &&
        sampleVal != null &&
        (("toHexString" in sampleVal && typeof (sampleVal as { toHexString?: unknown }).toHexString === "function") ||
          (sampleVal as { constructor?: { name?: string } }).constructor?.name === "ObjectId");
      if (isObjectId) {
        out.push({
          field: c.field,
          kind: "objectid_string",
          detail: `filter passes a 24-hex string but sample field is an ObjectId — wrap with new ObjectId('${c.value}')`,
        });
      }
    }
    if (typeof c.value === "string" && c.op === "$eq" && typeof sampleVal === "string") {
      if (c.value.toLowerCase() === sampleVal.toLowerCase() && c.value !== sampleVal) {
        out.push({
          field: c.field,
          kind: "case_sensitive",
          detail: `case mismatch — filter '${c.value}' vs sample '${sampleVal}'`,
        });
      }
    }
    if (typeof c.value === "string" && ISO_DATE_LOOKING.test(c.value) && sampleVal instanceof Date) {
      out.push({
        field: c.field,
        kind: "iso_string_vs_date",
        detail: `filter passes an ISO-date string but sample field is a Date — wrap with new Date('${c.value}')`,
      });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Schema sampling
// ---------------------------------------------------------------------------

function jsTypeOf(v: unknown): string {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  if (v instanceof Date) return "Date";
  if (typeof v === "object" && v != null && (v as { _bsontype?: string })._bsontype === "ObjectID") return "ObjectId";
  if (typeof v === "object" && v != null && (v as { constructor?: { name?: string } }).constructor?.name === "ObjectId")
    return "ObjectId";
  return typeof v;
}

export function buildSchemaSummary(
  collection: string,
  sample: Record<string, unknown> | null,
  estimatedCount: number,
): MongoSchemaPayload {
  if (!sample) {
    return { collection, fields: [], estimatedDocumentCount: estimatedCount };
  }
  return {
    collection,
    fields: Object.entries(sample).map(([k, v]) => ({ name: k, type: jsTypeOf(v) })),
    estimatedDocumentCount: estimatedCount,
  };
}

// ---------------------------------------------------------------------------
// Clause walker — empty / low-result diagnostic
// ---------------------------------------------------------------------------

export type MongoLike = {
  countDocuments: (
    filter: Record<string, unknown>,
    options?: { maxTimeMS?: number },
  ) => Promise<number>;
  findOne: (
    filter: Record<string, unknown>,
    options?: { maxTimeMS?: number },
  ) => Promise<Record<string, unknown> | null>;
};

export type DiagnosticRunInput = {
  collection: string;
  filter: Record<string, unknown>;
  resultCount: number;
  sampleDoc: Record<string, unknown> | null;
  coll: MongoLike;
};

export async function runEmptyResultDiagnostic(
  input: DiagnosticRunInput,
): Promise<MongoDiagnosticPayload> {
  const cfg = diagnosticConfig();
  const start = Date.now();
  const clauses = splitClauses(normalizeFilter(input.filter)).slice(0, 8);
  const out: MongoDiagnosticPayload = {
    ranProbes: 0,
    budgetMs: cfg.totalBudgetMs,
  };

  // 1. clause-by-clause counts to find the offending one.
  if (input.resultCount === 0 && clauses.length > 0) {
    for (let i = 0; i < clauses.length; i++) {
      if (Date.now() - start > cfg.totalBudgetMs) break;
      try {
        const without = composeWithout(clauses, i);
        const countWithout = await input.coll.countDocuments(without, { maxTimeMS: cfg.perProbeMs });
        out.ranProbes += 1;
        if (countWithout > 0) {
          out.offendingClause = {
            field: clauses[i].field,
            op: clauses[i].op,
            value: clauses[i].value,
            countWith: 0,
            countWithout,
          };
          break;
        }
      } catch {
        // budget exceeded / index missing / permission — silently move on
      }
    }
  }

  // 2. schema mismatch — fields in filter not present on the sampled doc.
  if (input.sampleDoc) {
    const sampleKeys = new Set(Object.keys(input.sampleDoc));
    const filterFields = clauses.map((c) => c.field);
    const missing = filterFields.filter((f) => !sampleKeys.has(f));
    if (missing.length > 0) {
      out.field_not_in_sample = missing;
      out.schemaMismatch = true;
    }
  }

  // 3. value-type heuristics.
  const warnings = detectValueTypeWarnings(clauses, input.sampleDoc);
  if (warnings.length > 0) out.valueTypeWarnings = warnings;

  return out;
}

// ---------------------------------------------------------------------------
// Vector-search histogram + recall comparison
// ---------------------------------------------------------------------------

export function scoreHistogram(scores: number[]): {
  histogram: number[];
  summary: { min: number; max: number; avg: number };
} {
  if (scores.length === 0) {
    return { histogram: [0, 0, 0, 0, 0], summary: { min: 0, max: 0, avg: 0 } };
  }
  const histogram = [0, 0, 0, 0, 0];
  let min = Number.POSITIVE_INFINITY;
  let max = Number.NEGATIVE_INFINITY;
  let sum = 0;
  for (const s of scores) {
    const idx = Math.min(4, Math.max(0, Math.floor(s * 5)));
    histogram[idx] += 1;
    if (s < min) min = s;
    if (s > max) max = s;
    sum += s;
  }
  return { histogram, summary: { min, max, avg: sum / scores.length } };
}
