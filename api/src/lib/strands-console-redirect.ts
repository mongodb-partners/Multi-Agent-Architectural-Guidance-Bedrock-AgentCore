import { logger } from "./logger.ts";

/** Duplicate Strands/SDK `console.error` into structured logs when STRANDS_LOG_REDIRECT=1. */
export function installStrandsConsoleRedirect(): void {
  if (process.env.STRANDS_LOG_REDIRECT !== "1") return;
  const orig = console.error.bind(console);
  console.error = (...args: unknown[]) => {
    try {
      logger.warn("strands.console_error", {
        raw: args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" ").slice(0, 4000),
      });
    } catch {
      /* ignore */
    }
    orig(...args);
  };
}
