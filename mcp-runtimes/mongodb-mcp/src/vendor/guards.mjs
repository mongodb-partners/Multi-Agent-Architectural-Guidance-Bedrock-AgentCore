// MongoDB MCP guards — single source of truth for the validation rules
// applied to `mongodb_query`-style calls.
//
// Imported by `mcp-runtimes/mongodb-mcp/src/server.ts` (and by any future
// host that vendors the MongoDB MCP tool surface). Keep this file pure JS (no
// TypeScript syntax) so Lambda can `import` it as-is with no build step.
// TypeScript consumers (e.g. local CLI smoke tests) pick up types from the
// companion `guards.d.mts` file alongside this one.
//
// Anything that depends on the trace collector, fixtures, MongoDB driver, or
// any other side-effectful concern stays out of this module so callers are
// free to layer their own wrappers around the guards.

// ──────────────────────────────────────────────────────────────────────────────
// Operation classification
// ──────────────────────────────────────────────────────────────────────────────

export const READ_OPS = Object.freeze(["find", "findOne", "aggregate"]);
export const WRITE_OPS = Object.freeze(["insertOne", "updateOne"]);
export const ALLOWED_OPS = Object.freeze([...READ_OPS, ...WRITE_OPS]);

// Destructive / privileged operations the MCP surface refuses outright. Listed
// explicitly so a future dispatcher edit can't silently widen the surface — the
// allowlist check is "if not in ALLOWED_OPS, fail"; this set is belt-and-braces.
export const FORBIDDEN_OPS = Object.freeze([
  "deleteOne",
  "deleteMany",
  "drop",
  "dropDatabase",
  "dropIndex",
  "bulkWrite",
  "findOneAndDelete",
  "findOneAndReplace",
  "findOneAndUpdate",
  "replaceOne",
  "renameCollection",
  "createIndex",
  "createIndexes",
]);

// Aggregation stages that write to / replace collections or execute code.
export const FORBIDDEN_PIPELINE_STAGES = Object.freeze([
  "$out",
  "$merge",
  "$function",
  "$accumulator",
]);

// Operators that execute server-side JavaScript anywhere they appear (filters,
// updates, $expr inside pipelines).
export const FORBIDDEN_QUERY_OPERATORS = Object.freeze([
  "$where",
  "$function",
  "$accumulator",
]);

const READ_SET = new Set(READ_OPS);
const WRITE_SET = new Set(WRITE_OPS);
const ALLOWED_SET = new Set(ALLOWED_OPS);
const FORBIDDEN_OPS_SET = new Set(FORBIDDEN_OPS);
const FORBIDDEN_STAGE_SET = new Set(FORBIDDEN_PIPELINE_STAGES);
const FORBIDDEN_OPERATOR_SET = new Set(FORBIDDEN_QUERY_OPERATORS);

export function isReadOp(op) {
  return READ_SET.has(op);
}

export function isWriteOp(op) {
  return WRITE_SET.has(op);
}

// ──────────────────────────────────────────────────────────────────────────────
// Error type
// ──────────────────────────────────────────────────────────────────────────────

export class MongoGuardError extends Error {
  /**
   * @param {string} message
   * @param {string} [code]
   */
  constructor(message, code = "guard_violation") {
    super(message);
    this.name = "MongoGuardError";
    this.code = code;
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Defaults / parsing helpers
// ──────────────────────────────────────────────────────────────────────────────

export const DEFAULT_MAX_LIMIT = 200;

const TRUTHY = new Set(["1", "true", "yes", "on"]);
export function parseBoolEnv(value) {
  if (value === undefined || value === null) return false;
  return TRUTHY.has(String(value).trim().toLowerCase());
}

export function parseMaxLimit(value, fallback = DEFAULT_MAX_LIMIT) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

// ──────────────────────────────────────────────────────────────────────────────
// Pure validators — each throws MongoGuardError on violation, returns void/data
// ──────────────────────────────────────────────────────────────────────────────

const COLLECTION_NAME = /^[A-Za-z0-9_.\-]+$/;

export function assertCollection(name) {
  if (typeof name !== "string" || name.length === 0) {
    throw new MongoGuardError("'collection' is required and must be a string", "invalid_collection");
  }
  if (name.length > 120 || !COLLECTION_NAME.test(name)) {
    throw new MongoGuardError(
      `invalid collection name: '${String(name).slice(0, 40)}'`,
      "invalid_collection",
    );
  }
}

export function assertOperation(op) {
  if (FORBIDDEN_OPS_SET.has(op)) {
    throw new MongoGuardError(`destructive operation refused: '${op}'`, "forbidden_operation");
  }
  if (!ALLOWED_SET.has(op)) {
    throw new MongoGuardError(
      `unsupported operation '${op}' (allowed: ${ALLOWED_OPS.join(", ")})`,
      "unsupported_operation",
    );
  }
}

export function assertNoDatabaseOverride(database, defaultDb) {
  if (database === undefined || database === null) return;
  if (String(database) !== defaultDb) {
    throw new MongoGuardError(
      "database override is not permitted by this MCP server (always uses the configured default)",
      "database_override",
    );
  }
}

/**
 * Walk an arbitrary value (object/array/primitive) and return the first key
 * that appears in the `forbidden` set, or null. Depth-bounded so a malicious
 * caller can't blow the stack with deep nesting.
 */
export function findForbiddenKey(value, forbidden, depth = 0) {
  if (depth > 32) return "<depth-limit>";
  if (Array.isArray(value)) {
    for (const v of value) {
      const hit = findForbiddenKey(v, forbidden, depth + 1);
      if (hit) return hit;
    }
    return null;
  }
  if (value && typeof value === "object") {
    for (const key of Object.keys(value)) {
      if (forbidden.has(key)) return key;
      const hit = findForbiddenKey(value[key], forbidden, depth + 1);
      if (hit) return hit;
    }
  }
  return null;
}

export function assertSafeFilter(filter, label = "filter") {
  if (filter === undefined || filter === null) return;
  if (typeof filter !== "object" || Array.isArray(filter)) {
    throw new MongoGuardError(`${label} must be an object`, "invalid_filter");
  }
  const hit = findForbiddenKey(filter, FORBIDDEN_OPERATOR_SET);
  if (hit) {
    throw new MongoGuardError(`forbidden operator in ${label}: ${hit}`, "forbidden_operator");
  }
}

export function assertSafePipeline(pipeline) {
  if (!Array.isArray(pipeline)) {
    throw new MongoGuardError("'pipeline' must be an array", "invalid_pipeline");
  }
  for (const stage of pipeline) {
    if (!stage || typeof stage !== "object" || Array.isArray(stage)) {
      throw new MongoGuardError("pipeline stages must be objects", "invalid_pipeline");
    }
    for (const key of Object.keys(stage)) {
      if (FORBIDDEN_STAGE_SET.has(key)) {
        throw new MongoGuardError(`forbidden pipeline stage: ${key}`, "forbidden_stage");
      }
    }
  }
  const hit = findForbiddenKey(pipeline, FORBIDDEN_OPERATOR_SET);
  if (hit) {
    throw new MongoGuardError(`forbidden operator in pipeline: ${hit}`, "forbidden_operator");
  }
}

export function assertWritesAllowed(op, allowWrite) {
  if (!allowWrite) {
    throw new MongoGuardError(
      `writes are disabled — set MONGODB_ALLOW_WRITE=1 to allow ${op}`,
      "writes_disabled",
    );
  }
}

export function assertNonEmptyFilter(filter, op) {
  if (
    !filter ||
    typeof filter !== "object" ||
    Array.isArray(filter) ||
    Object.keys(filter).length === 0
  ) {
    throw new MongoGuardError(
      `${op} refused: filter must be a non-empty object`,
      "empty_filter",
    );
  }
}

export function clampLimit(limit, fallback, max = DEFAULT_MAX_LIMIT) {
  const candidate = Number.isFinite(limit) ? Math.floor(limit) : fallback;
  const positive = candidate > 0 ? candidate : fallback;
  return Math.min(positive, max);
}

// ──────────────────────────────────────────────────────────────────────────────
// Composite validator
// ──────────────────────────────────────────────────────────────────────────────

/**
 * Run every relevant guard for a `mongodb_query` call and return normalized
 * inputs. Throws MongoGuardError on the first violation.
 *
 * Both call sites (the Lambda handler and the API's runMongoDataQuery) should
 * call this exactly once at entry; everything past it can assume the inputs
 * are well-formed.
 *
 * @param {object} input  Raw inputs from the agent / MCP caller.
 * @param {object} [options]
 * @param {boolean} [options.allowWrite=false]
 * @param {string}  [options.defaultDb]      If provided, refuses database overrides that differ.
 * @param {number}  [options.maxLimit=DEFAULT_MAX_LIMIT]
 * @param {number}  [options.defaultFindLimit=10]
 * @param {number}  [options.defaultAggregateLimit] Defaults to maxLimit.
 * @returns {{
 *   collection: string,
 *   operation: string,
 *   filter: Record<string, unknown>,
 *   projection: Record<string, unknown> | undefined,
 *   sort: Record<string, unknown> | undefined,
 *   limit: number,
 *   pipeline: unknown[] | undefined,
 *   update: Record<string, unknown> | undefined,
 *   document: Record<string, unknown> | undefined,
 * }}
 */
export function validateMongoQueryInputs(input, options = {}) {
  const allowWrite = options.allowWrite === true;
  const defaultDb = options.defaultDb;
  const maxLimit = options.maxLimit ?? DEFAULT_MAX_LIMIT;
  const defaultFindLimit = options.defaultFindLimit ?? 10;
  const defaultAggregateLimit = options.defaultAggregateLimit ?? maxLimit;

  const collection = input?.collection;
  assertCollection(collection);

  const operation = input?.operation ?? "find";
  assertOperation(operation);

  if (defaultDb !== undefined) {
    assertNoDatabaseOverride(input?.database, defaultDb);
  }

  // Accept either `query` (Strands tool naming) or `filter` (Mongo driver naming).
  const rawFilter =
    input?.query && typeof input.query === "object" && !Array.isArray(input.query)
      ? input.query
      : input?.filter;
  const filter = rawFilter ?? {};
  assertSafeFilter(filter, "filter");

  let limit = 0;
  let pipeline;
  let update;
  let document;

  if (operation === "find") {
    limit = clampLimit(input?.limit, defaultFindLimit, maxLimit);
  } else if (operation === "findOne") {
    limit = 1;
  } else if (operation === "aggregate") {
    if (!Array.isArray(input?.pipeline)) {
      throw new MongoGuardError("aggregate requires `pipeline` (array)", "invalid_pipeline");
    }
    assertSafePipeline(input.pipeline);
    pipeline = input.pipeline;
    limit = clampLimit(input?.limit, defaultAggregateLimit, maxLimit);
  } else if (operation === "insertOne") {
    assertWritesAllowed("insertOne", allowWrite);
    if (!input?.document || typeof input.document !== "object" || Array.isArray(input.document)) {
      throw new MongoGuardError(
        "insertOne requires a `document` object",
        "invalid_document",
      );
    }
    assertSafeFilter(input.document, "document");
    document = input.document;
  } else if (operation === "updateOne") {
    assertWritesAllowed("updateOne", allowWrite);
    if (!input?.update || typeof input.update !== "object" || Array.isArray(input.update)) {
      throw new MongoGuardError(
        "updateOne requires an `update` object",
        "invalid_update",
      );
    }
    assertNonEmptyFilter(filter, "updateOne");
    assertSafeFilter(input.update, "update");
    update = input.update;
  }

  return {
    collection,
    operation,
    filter,
    projection: normalizeRecord(input?.projection),
    sort: normalizeRecord(input?.sort),
    limit,
    pipeline,
    update,
    document,
  };
}

function normalizeRecord(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  if (Object.keys(value).length === 0) return undefined;
  return value;
}
