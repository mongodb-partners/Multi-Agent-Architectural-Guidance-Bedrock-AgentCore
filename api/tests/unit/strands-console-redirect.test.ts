import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { installStrandsConsoleRedirect } from "../../src/lib/strands-console-redirect.ts";

const SAVED = {
  STRANDS_LOG_REDIRECT: process.env.STRANDS_LOG_REDIRECT,
  LOG_LEVEL: process.env.LOG_LEVEL,
};

let origConsoleError: typeof console.error;

beforeEach(() => {
  origConsoleError = console.error;
  process.env.LOG_LEVEL = "warn";
});

afterEach(() => {
  console.error = origConsoleError;
  if (SAVED.STRANDS_LOG_REDIRECT === undefined) delete process.env.STRANDS_LOG_REDIRECT;
  else process.env.STRANDS_LOG_REDIRECT = SAVED.STRANDS_LOG_REDIRECT;
  if (SAVED.LOG_LEVEL === undefined) delete process.env.LOG_LEVEL;
  else process.env.LOG_LEVEL = SAVED.LOG_LEVEL;
});

async function captureStderr(fn: () => void | Promise<void>): Promise<string> {
  const chunks: string[] = [];
  const orig = process.stderr.write.bind(process.stderr);
  process.stderr.write = (chunk: string | Uint8Array) => {
    chunks.push(typeof chunk === "string" ? chunk : new TextDecoder().decode(chunk));
    return true;
  };
  try {
    await fn();
  } finally {
    process.stderr.write = orig;
  }
  return chunks.join("");
}

describe("installStrandsConsoleRedirect — env-gated console.error capture", () => {
  test("is a no-op when STRANDS_LOG_REDIRECT is unset", () => {
    delete process.env.STRANDS_LOG_REDIRECT;
    const before = console.error;
    installStrandsConsoleRedirect();
    expect(console.error).toBe(before);
  });

  test("when STRANDS_LOG_REDIRECT=1, console.error emits a structured warn line and still forwards", async () => {
    process.env.STRANDS_LOG_REDIRECT = "1";
    // Swap console.error to a no-op sink BEFORE installing the redirect so the
    // redirect captures *that* as its "orig" and we don't spam test output.
    let forwardCalled = 0;
    console.error = (..._args: unknown[]) => {
      forwardCalled++;
    };
    installStrandsConsoleRedirect();
    expect(console.error).not.toBe(origConsoleError);

    const stderrText = await captureStderr(() => {
      console.error("strands sdk boom", { detail: "thing" });
    });

    expect(stderrText).toContain('"msg":"strands.console_error"');
    expect(stderrText).toContain('"level":"warn"');
    expect(stderrText).toContain("strands sdk boom");
    expect(forwardCalled).toBe(1);
  });
});
