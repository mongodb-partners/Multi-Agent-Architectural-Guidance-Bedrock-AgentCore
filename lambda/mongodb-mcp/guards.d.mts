// TypeScript declarations for ./guards.mjs.
//
// This file exists so the API (TypeScript) can `import { ... } from
// "../../../lambda/mongodb-mcp/guards.mjs"` with full type-checking, without
// requiring `allowJs: true` in api/tsconfig.json. The runtime module is the
// sibling `.mjs` file.

export type MongoOperation =
  | "find"
  | "findOne"
  | "aggregate"
  | "insertOne"
  | "updateOne";

export const READ_OPS: readonly ["find", "findOne", "aggregate"];
export const WRITE_OPS: readonly ["insertOne", "updateOne"];
export const ALLOWED_OPS: readonly MongoOperation[];
export const FORBIDDEN_OPS: readonly string[];
export const FORBIDDEN_PIPELINE_STAGES: readonly string[];
export const FORBIDDEN_QUERY_OPERATORS: readonly string[];

export function isReadOp(op: string): op is "find" | "findOne" | "aggregate";
export function isWriteOp(op: string): op is "insertOne" | "updateOne";

export class MongoGuardError extends Error {
  readonly name: "MongoGuardError";
  readonly code: string;
  constructor(message: string, code?: string);
}

export const DEFAULT_MAX_LIMIT: number;

export function parseBoolEnv(value: unknown): boolean;
export function parseMaxLimit(value: unknown, fallback?: number): number;

export function assertCollection(name: unknown): asserts name is string;
export function assertOperation(op: unknown): asserts op is MongoOperation;
export function assertNoDatabaseOverride(
  database: unknown,
  defaultDb: string,
): void;
export function findForbiddenKey(
  value: unknown,
  forbidden: Set<string>,
  depth?: number,
): string | null;
export function assertSafeFilter(filter: unknown, label?: string): void;
export function assertSafePipeline(pipeline: unknown): asserts pipeline is unknown[];
export function assertWritesAllowed(
  op: string,
  allowWrite: boolean,
): asserts allowWrite is true;
export function assertNonEmptyFilter(
  filter: unknown,
  op: string,
): asserts filter is Record<string, unknown>;
export function clampLimit(
  limit: unknown,
  fallback: number,
  max?: number,
): number;

export interface MongoQueryRawInput {
  collection?: unknown;
  operation?: unknown;
  filter?: unknown;
  query?: unknown;
  projection?: unknown;
  sort?: unknown;
  limit?: unknown;
  pipeline?: unknown;
  update?: unknown;
  document?: unknown;
  database?: unknown;
}

export interface ValidateOptions {
  /** Permit write operations (insertOne, updateOne). Default false. */
  allowWrite?: boolean;
  /** When set, reject `input.database` values that differ from this. */
  defaultDb?: string;
  /** Hard ceiling on read `limit`. Default {@link DEFAULT_MAX_LIMIT}. */
  maxLimit?: number;
  /** Default `limit` for `find` when caller doesn't supply one. Default 10. */
  defaultFindLimit?: number;
  /** Default `limit` for `aggregate` when caller doesn't supply one. Default = maxLimit. */
  defaultAggregateLimit?: number;
}

export interface NormalizedMongoQueryInputs {
  collection: string;
  operation: MongoOperation;
  filter: Record<string, unknown>;
  projection: Record<string, unknown> | undefined;
  sort: Record<string, unknown> | undefined;
  limit: number;
  pipeline: unknown[] | undefined;
  update: Record<string, unknown> | undefined;
  document: Record<string, unknown> | undefined;
}

export function validateMongoQueryInputs(
  input: MongoQueryRawInput,
  options?: ValidateOptions,
): NormalizedMongoQueryInputs;
