/**
 * Minimal structured JSON logger wired to LOG_LEVEL env var.
 *
 * LOG_LEVEL: error | warn | info | debug  (default: info)
 *
 * Each line is a JSON object: { level, ts, msg, ...ctx }
 * error/warn go to stderr; info/debug go to stdout.
 *
 * logger.child(ctx) creates a child logger that merges ctx into every entry.
 * Useful for request-scoped logging: const log = logger.child({ requestId });
 */

type Level = "error" | "warn" | "info" | "debug";

const RANK: Record<Level, number> = { error: 0, warn: 1, info: 2, debug: 3 };

function resolveLevel(): number {
  const raw = (process.env.LOG_LEVEL ?? "info").toLowerCase().trim();
  return RANK[raw as Level] ?? RANK.info;
}

function emit(level: Level, msg: string, ctx?: Record<string, unknown>): void {
  if (RANK[level] > resolveLevel()) return;
  const entry: Record<string, unknown> = { level, ts: new Date().toISOString(), msg, ...ctx };
  const line = JSON.stringify(entry);
  if (level === "error" || level === "warn") {
    process.stderr.write(line + "\n");
  } else {
    process.stdout.write(line + "\n");
  }
}

export type Logger = {
  error: (msg: string, ctx?: Record<string, unknown>) => void;
  warn:  (msg: string, ctx?: Record<string, unknown>) => void;
  info:  (msg: string, ctx?: Record<string, unknown>) => void;
  debug: (msg: string, ctx?: Record<string, unknown>) => void;
  /** Returns a child logger that merges `base` into every log entry. */
  child: (base: Record<string, unknown>) => Logger;
};

function makeLogger(base?: Record<string, unknown>): Logger {
  function withBase(ctx?: Record<string, unknown>): Record<string, unknown> | undefined {
    if (!base && !ctx) return undefined;
    return { ...base, ...ctx };
  }
  return {
    error: (msg, ctx) => emit("error", msg, withBase(ctx)),
    warn:  (msg, ctx) => emit("warn",  msg, withBase(ctx)),
    info:  (msg, ctx) => emit("info",  msg, withBase(ctx)),
    debug: (msg, ctx) => emit("debug", msg, withBase(ctx)),
    child: (childBase) => makeLogger({ ...base, ...childBase }),
  };
}

export const logger: Logger = makeLogger();
