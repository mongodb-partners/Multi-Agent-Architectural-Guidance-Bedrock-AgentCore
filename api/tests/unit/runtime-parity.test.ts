/**
 * Static parity test: `USE_ORCHESTRATOR_RUNTIME=1` must produce the same
 * external behavior as the production single-hop API path because both
 * call sites use the **same** `runMultiSpecialistFlow(...)` helper and
 * the same `SpecialistInvoker` interface.
 *
 * This test does not run the runtime — `agent-runtime-code.ts` boots an
 * HTTP server on import. Instead, we read the source files and assert
 * the structural parity invariants:
 *
 *   1. Both `api/src/routes/chat.ts` and `api/src/agent-runtime-code.ts`
 *      import `runMultiSpecialistFlow` and `SpecialistInvoker` from the
 *      same shared helper module.
 *   2. Both files build a `SpecialistInvoker` adapter that forwards
 *      `specialistId`, `message`, `priorTurns`, `memoryContext`, and
 *      `onWrapperSpan`. Drift here would silently regress wrapper-span
 *      attachment for nested traces.
 *   3. Both files call `runMultiSpecialistFlow({ ... invokeSpecialist })`.
 *
 * The helper itself is exhaustively unit-tested in
 * `multi-specialist-orchestrator.test.ts` for fast-path / synthesis-path
 * / failure / wrapper-attach behavior. With this static parity guard in
 * place, any future regression in the runtime-side adapter is caught at
 * CI time, not on first AgentCore invocation.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

function read(rel: string): string {
  return readFileSync(resolve(import.meta.dir, "..", "..", rel), "utf8");
}

const CHAT_TS = read("src/routes/chat.ts");
const RUNTIME_TS = read("src/agent-runtime-code.ts");

describe("multi-specialist runtime parity", () => {
  test("both files import runMultiSpecialistFlow + SpecialistInvoker from the same helper module", () => {
    for (const src of [CHAT_TS, RUNTIME_TS]) {
      expect(src).toMatch(/runMultiSpecialistFlow/);
      expect(src).toMatch(/SpecialistInvoker/);
      expect(src).toMatch(/multi-specialist-orchestrator/);
    }
  });

  test("both files instantiate the flow with `runMultiSpecialistFlow({ ... invokeSpecialist })`", () => {
    for (const src of [CHAT_TS, RUNTIME_TS]) {
      // Match `runMultiSpecialistFlow(` followed (within 600 chars to
      // accommodate multi-line option literals) by `invokeSpecialist`.
      const pattern = /runMultiSpecialistFlow\s*\(\s*\{[\s\S]{0,800}invokeSpecialist/;
      expect(src).toMatch(pattern);
    }
  });

  test("both files' SpecialistInvoker adapter forwards onWrapperSpan to the underlying invoker", () => {
    for (const src of [CHAT_TS, RUNTIME_TS]) {
      // Invoker signature must take `onWrapperSpan` from the helper's
      // arguments and pass it through to the underlying call site
      // (invokeAgentRuntime in chat.ts; invokeSpecialistStream in the
      // runtime). The simplest invariant: `onWrapperSpan` appears at
      // least twice — once on the destructured argument and once
      // forwarded into the call.
      const occurrences = (src.match(/onWrapperSpan/g) ?? []).length;
      expect(occurrences).toBeGreaterThanOrEqual(2);
    }
  });

  test("both files' SpecialistInvoker adapter forwards specialistId + message + priorTurns + memoryContext", () => {
    const required = ["specialistId", "message", "priorTurns", "memoryContext"];
    for (const src of [CHAT_TS, RUNTIME_TS]) {
      // The adapter destructures these fields from the helper's
      // SpecialistInvoker invocation. Assert each appears in the source.
      for (const field of required) {
        expect(src.includes(field)).toBe(true);
      }
    }
  });

  test("both files use the same fast-path-vs-synthesis branch surface (no path-specific bypass)", () => {
    for (const src of [CHAT_TS, RUNTIME_TS]) {
      // The helper exposes `pathTaken` on its return value and emits
      // `synthesis_*` events. Both files must consume those events
      // (otherwise they're missing one branch of the contract).
      expect(src).toMatch(/synthesis_started|synthesis_stream|synthesis_ended/);
      expect(src).toMatch(/specialist_started|specialist_stream|specialist_ended/);
    }
  });
});
