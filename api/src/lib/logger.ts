/**
 * Structured JSON logger with OpenTelemetry trace correlation.
 *
 * LOG_LEVEL: error | warn | info | debug (default: info)
 * Per-service overrides: LOG_LEVEL_API, LOG_LEVEL_AGENT_RUNTIME, LOG_LEVEL_MCP
 *
 * Each line is JSON: { level, ts, msg, service?, channel?, trace_id?, span_id?, trace_flags?, ...ctx }
 * error/warn → stderr; info/debug → stdout.
 *
 * logger.child(ctx) merges ctx into every entry.
 * logger.audit() tags channel: "audit" for compliance filters.
 */

import { createHash } from "node:crypto";
import { trace } from "@opentelemetry/api";

type Level = "error" | "warn" | "info" | "debug";

const RANK: Record<Level, number> = { error: 0, warn: 1, info: 2, debug: 3 };

const SENSITIVE_KEY = /token|secret|password|authorization|jwt|api[_-]?key|mongodb_uri/i;

const JWT_LIKE =
  /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;

function resolveLevelForService(service: string | undefined): number {
  const s = (service ?? "").toLowerCase();
  let override: string | undefined;
  if (s.includes("agent-runtime") || s.includes("agent_runtime")) {
    override = process.env.LOG_LEVEL_AGENT_RUNTIME?.trim();
  } else if (s.includes("mcp")) {
    override = process.env.LOG_LEVEL_MCP?.trim();
  } else if (s.includes("mongodb-multiagent-api") || s.endsWith("-api")) {
    override = process.env.LOG_LEVEL_API?.trim();
  }
  const raw = (override ?? process.env.LOG_LEVEL ?? "info").toLowerCase().trim();
  return RANK[raw as Level] ?? RANK.info;
}

function maskMongoUri(value: string): string {
  // Match the full userinfo segment up to the LAST `@` before the first `/`
  // (or end-of-string), so passwords containing un-encoded `@` are still fully
  // masked (e.g. `mongodb+srv://user:p@ss@host/db` → `mongodb+srv://***@host/db`).
  return value.replace(
    /^(mongodb(?:\+srv)?:\/\/)[^/]*@(?=[^/]*(?:\/|$))/i,
    (_all, proto: string) => `${proto}***@`,
  );
}

function hashPii(value: string): string {
  const h = createHash("sha1").update(value).digest("hex");
  return `sha1:${h.slice(0, 8)}`;
}

function truncateStr(s: string, max: number): string {
  return s.length <= max ? s : `${s.slice(0, max)}…`;
}

function defaultRedact(value: unknown, depth = 0): unknown {
  if (depth > 3) return "[max-depth]";
  if (value === null || value === undefined) return value;
  if (typeof value === "string") {
    if (JWT_LIKE.test(value)) return "jwt:***";
    if (value.startsWith("mongodb://") || value.startsWith("mongodb+srv://")) {
      return maskMongoUri(value);
    }
    return value;
  }
  if (typeof value !== "object") return value;
  if (Array.isArray(value)) {
    return value.map((v) => defaultRedact(v, depth + 1));
  }
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    const keyLower = k.toLowerCase();
    if (SENSITIVE_KEY.test(k) || SENSITIVE_KEY.test(keyLower)) {
      out[k] = "***";
      continue;
    }
    if (keyLower === "email" || keyLower === "phone" || keyLower === "ssn") {
      out[k] = typeof v === "string" ? hashPii(v) : defaultRedact(v, depth + 1);
      continue;
    }
    if (keyLower === "query" || keyLower === "message") {
      if (typeof v === "string") {
        out[k] = truncateStr(v, 256);
        continue;
      }
    }
    out[k] = defaultRedact(v, depth + 1);
  }
  return out;
}

export type LogChannel = "app" | "audit";

export type LoggerOptions = {
  redactor?: (ctx?: Record<string, unknown>) => Record<string, unknown> | undefined;
  channel?: LogChannel;
};

export class Logger {
  constructor(
    private readonly base?: Record<string, unknown>,
    private readonly opts?: LoggerOptions,
  ) {}

  audit(): Logger {
    return new Logger(this.base, { ...this.opts, channel: "audit" });
  }

  child(base: Record<string, unknown>): Logger {
    return new Logger({ ...this.base, ...base }, this.opts);
  }

  error(msg: string, ctx?: Record<string, unknown>): void {
    this.emit("error", msg, ctx);
  }
  warn(msg: string, ctx?: Record<string, unknown>): void {
    this.emit("warn", msg, ctx);
  }
  info(msg: string, ctx?: Record<string, unknown>): void {
    this.emit("info", msg, ctx);
  }
  debug(msg: string, ctx?: Record<string, unknown>): void {
    this.emit("debug", msg, ctx);
  }

  private emit(level: Level, msg: string, ctx?: Record<string, unknown>): void {
    const service = process.env.OTEL_SERVICE_NAME;
    if (RANK[level] > resolveLevelForService(service)) return;

    const span = trace.getActiveSpan();
    const sc = span?.spanContext();

    let traceFlagsHex: string | undefined;
    if (sc?.traceFlags !== undefined) {
      traceFlagsHex = sc.traceFlags.toString(16).padStart(2, "0");
    }

    const redactedCtx = ctx
      ? this.opts?.redactor?.(ctx) ?? (defaultRedact(ctx) as Record<string, unknown>)
      : undefined;

    const entry: Record<string, unknown> = {
      level,
      ts: new Date().toISOString(),
      msg,
      ...(service ? { service } : {}),
      channel: this.opts?.channel ?? "app",
      ...(sc?.traceId ? { trace_id: sc.traceId } : {}),
      ...(sc?.spanId ? { span_id: sc.spanId } : {}),
      ...(traceFlagsHex !== undefined ? { trace_flags: traceFlagsHex } : {}),
      ...this.base,
      ...redactedCtx,
    };

    // strip undefined keys for cleaner JSON
    for (const k of Object.keys(entry)) {
      if (entry[k] === undefined) delete entry[k];
    }

    const line = JSON.stringify(entry);
    if (level === "error" || level === "warn") {
      process.stderr.write(line + "\n");
    } else {
      process.stdout.write(line + "\n");
    }
  }
}

export const logger = new Logger(undefined, { redactor: (ctx) => defaultRedact(ctx) as Record<string, unknown> });
