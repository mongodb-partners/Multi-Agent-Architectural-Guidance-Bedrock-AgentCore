// MongoDB diagnostics for the MCP Lambda — schema sampling, explain plan
// capture, and the empty-result clause-walker. Plain JS so the Lambda zip
// needs no build step. Event payload shapes match the rest of the
// `mongo.*` trace family so the Trace Viewer renders them uniformly.

// ──────────────────────────────────────────────────────────────────────────────
// Env helpers
// ──────────────────────────────────────────────────────────────────────────────

function envBool(name, fallback) {
  const v = process.env[name]?.trim().toLowerCase();
  if (v === undefined || v === "") return fallback;
  if (v === "0" || v === "false") return false;
  if (v === "1" || v === "true") return true;
  return fallback;
}

function envInt(name, fallback) {
  const v = process.env[name];
  if (!v) return fallback;
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

export function diagnosticConfig() {
  return {
    explainEnabled: envBool("MONGO_TRACE_EXPLAIN", false),
    diagnosticEnabled: envBool("MONGO_TRACE_DIAGNOSTIC", false),
    schemaEnabled: envBool("MONGO_TRACE_SCHEMA_SAMPLE", true),
    totalBudgetMs: envInt("MONGO_DIAGNOSTIC_BUDGET_MS", 4000),
    perProbeMs: envInt("MONGO_DIAGNOSTIC_TIMEOUT_MS", 500),
  };
}

// ──────────────────────────────────────────────────────────────────────────────
// Filter normalization + clause split
// ──────────────────────────────────────────────────────────────────────────────

export function normalizeFilter(filter) {
  if (!filter || typeof filter !== "object" || Array.isArray(filter)) return {};
  const out = {};
  for (const [k, v] of Object.entries(filter)) {
    if (k.startsWith("$")) {
      out[k] = v;
      continue;
    }
    if (
      v &&
      typeof v === "object" &&
      !Array.isArray(v) &&
      Object.keys(v).some((kk) => kk.startsWith("$"))
    ) {
      out[k] = v;
    } else {
      out[k] = { $eq: v };
    }
  }
  return out;
}

export function splitClauses(filter) {
  const clauses = [];
  for (const [k, v] of Object.entries(filter)) {
    if (k === "$and" && Array.isArray(v)) {
      for (const sub of v) {
        for (const inner of splitClauses(normalizeFilter(sub))) clauses.push(inner);
      }
      continue;
    }
    if (k === "$or" || k === "$nor") continue;
    if (v && typeof v === "object" && !Array.isArray(v)) {
      const ops = Object.keys(v).filter((o) => o.startsWith("$"));
      if (ops.length > 0) {
        clauses.push({ field: k, op: ops[0], value: v[ops[0]] });
        continue;
      }
    }
    clauses.push({ field: k, op: "$eq", value: v });
  }
  return clauses;
}

function composeWithout(clauses, omitIdx) {
  const out = {};
  for (let i = 0; i < clauses.length; i++) {
    if (i === omitIdx) continue;
    const c = clauses[i];
    out[c.field] = { [c.op]: c.value };
  }
  return out;
}

// ──────────────────────────────────────────────────────────────────────────────
// Schema sampling
// ──────────────────────────────────────────────────────────────────────────────

function jsTypeOf(v) {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  if (v instanceof Date) return "Date";
  if (typeof v === "object" && v != null && v._bsontype === "ObjectID") return "ObjectId";
  if (typeof v === "object" && v != null && v.constructor?.name === "ObjectId") return "ObjectId";
  return typeof v;
}

export function buildSchemaSummary(collection, sample, estimatedCount) {
  if (!sample) {
    return { collection, fields: [], estimatedDocumentCount: estimatedCount };
  }
  return {
    collection,
    fields: Object.entries(sample).map(([k, v]) => ({ name: k, type: jsTypeOf(v) })),
    estimatedDocumentCount: estimatedCount,
  };
}

/**
 * Sample one document and grab the estimated count. Returns `{ sample, estimatedCount }`.
 * Never throws — schema sampling is best-effort.
 */
export async function sampleSchema(coll, perProbeMs) {
  try {
    const sample = await coll.findOne({}, { maxTimeMS: perProbeMs });
    const estimatedCount = await coll.estimatedDocumentCount();
    return { sample, estimatedCount };
  } catch {
    return { sample: null, estimatedCount: 0 };
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Value-type heuristics
// ──────────────────────────────────────────────────────────────────────────────

const OBJECTID_HEX = /^[0-9a-fA-F]{24}$/;
const ISO_DATE_LOOKING = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2})?/;

export function detectValueTypeWarnings(clauses, sampleDoc) {
  const out = [];
  if (!sampleDoc) return out;
  for (const c of clauses) {
    const sampleVal = sampleDoc[c.field];
    if (sampleVal == null) continue;
    if (typeof c.value === "string" && OBJECTID_HEX.test(c.value)) {
      const isObjectId =
        typeof sampleVal === "object" &&
        sampleVal != null &&
        ((typeof sampleVal.toHexString === "function") ||
          sampleVal.constructor?.name === "ObjectId");
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

// ──────────────────────────────────────────────────────────────────────────────
// Empty-result clause walker
// ──────────────────────────────────────────────────────────────────────────────

/**
 * Why did this query return 0 results? Walks each clause individually to find
 * the one that's filtering everything out, checks the sample doc for schema
 * mismatches, and runs value-type heuristics.
 *
 * @param {{
 *   collection: string,
 *   filter: Record<string, unknown>,
 *   resultCount: number,
 *   sampleDoc: Record<string, unknown> | null,
 *   coll: { countDocuments: Function, findOne: Function },
 * }} input
 */
export async function runEmptyResultDiagnostic(input) {
  const cfg = diagnosticConfig();
  const start = Date.now();
  const clauses = splitClauses(normalizeFilter(input.filter)).slice(0, 8);
  const out = { ranProbes: 0, budgetMs: cfg.totalBudgetMs };

  if (input.resultCount === 0 && clauses.length > 0) {
    for (let i = 0; i < clauses.length; i++) {
      if (Date.now() - start > cfg.totalBudgetMs) break;
      try {
        const without = composeWithout(clauses, i);
        const countWithout = await input.coll.countDocuments(without, {
          maxTimeMS: cfg.perProbeMs,
        });
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

  if (input.sampleDoc) {
    const sampleKeys = new Set(Object.keys(input.sampleDoc));
    const filterFields = clauses.map((c) => c.field);
    const missing = filterFields.filter((f) => !sampleKeys.has(f));
    if (missing.length > 0) {
      out.field_not_in_sample = missing;
      out.schemaMismatch = true;
    }
  }

  const warnings = detectValueTypeWarnings(clauses, input.sampleDoc);
  if (warnings.length > 0) out.valueTypeWarnings = warnings;

  return out;
}

// ──────────────────────────────────────────────────────────────────────────────
// Explain plan capture
// ──────────────────────────────────────────────────────────────────────────────

/**
 * Run `.find(filter).explain("executionStats")` and build a mongo.plan payload.
 * Returns null if explain is unsupported / not permitted.
 */
export async function runExplain(coll, filter) {
  try {
    const explain = await coll.find(filter).explain("executionStats");
    const exec = explain.executionStats ?? {};
    const winning = explain.queryPlanner?.winningPlan ?? {};
    const rejectedPlans = Array.isArray(explain.queryPlanner?.rejectedPlans)
      ? explain.queryPlanner.rejectedPlans.length
      : undefined;
    const nReturned = Number(exec.nReturned ?? 0);
    const totalDocsExamined = Number(exec.totalDocsExamined ?? 0);
    const selectivity = totalDocsExamined > 0 ? nReturned / totalDocsExamined : undefined;
    const selectivityLow = selectivity !== undefined && selectivity < 0.1;
    const stage = winning.stage;
    const indexMissing = stage === "COLLSCAN" ? Object.keys(filter)[0] : undefined;
    return {
      mode: "lambda",
      explainSupported: true,
      stage,
      indexName: winning.inputStage?.indexName,
      nReturned,
      totalDocsExamined,
      totalKeysExamined: Number(exec.totalKeysExamined ?? 0),
      executionTimeMillis: Number(exec.executionTimeMillis ?? 0),
      rejectedPlans,
      selectivity,
      selectivity_low: selectivityLow,
      index_missing_suggested: indexMissing,
    };
  } catch {
    return null;
  }
}
