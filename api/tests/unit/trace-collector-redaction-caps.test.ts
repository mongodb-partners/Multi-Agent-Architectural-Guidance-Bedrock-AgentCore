/**
 * Tests for the tiered per-event-type truncation caps in `TraceCollector`.
 *
 * Pre-PR1, every string was capped at 512 chars — that silently killed
 * developer-grade prompt bodies in the Trace Viewer. PR1 introduces a 64 KB
 * cap for explicitly debug-tagged fields (`prompt.assembled.body`,
 * `model.request.userMessage`, `agentcore.invoke.payload`, …) and keeps
 * the 512-char default everywhere else. PII redaction (`email`, `phone`,
 * `name`, …) is orthogonal and runs on every event regardless of `TRACE_REDACT`.
 *
 * These tests pin those two invariants so the cap table can't drift.
 */

import { describe, expect, test } from "bun:test";
import { TraceCollector } from "../../src/lib/trace-collector.ts";

function makeCollector() {
  return new TraceCollector({ sessionId: "s", messageId: "m", agentId: "orchestrator" });
}

describe("TraceCollector — tiered truncation caps", () => {
  test("debug-tagged field gets the 64 KB cap, not the 512-char default", () => {
    // The per-event byte cap (16 KB default) would otherwise gate this body
    // via `shrinkPayload` and we'd be testing the cap path rather than the
    // truncation path. Raise it so we isolate the field-level cap.
    process.env.TRACE_MAX_EVENT_BYTES = "200000";
    const c = makeCollector();
    const body = "a".repeat(40_000);
    c.event("prompt.assembled", {
      body,
      bodyBytes: body.length,
      totalBytes: body.length,
      personaBytes: 0,
      discoveryBytes: 0,
      memoryContextBytes: 0,
    });
    const ev = c.getEvents().find((e) => e.type === "prompt.assembled");
    expect(ev).toBeDefined();
    const got = (ev?.payload as any).body as string;
    expect(typeof got).toBe("string");
    // Full 40 KB body survives (well under the 64 KB cap).
    expect(got.length).toBe(40_000);
    delete process.env.TRACE_MAX_EVENT_BYTES;
  });

  test("non-debug field on the same event type still caps at 512 chars", () => {
    const c = makeCollector();
    const body = "a".repeat(2_000);
    c.event("prompt.assembled", {
      body: "ok",
      bodyBytes: 2,
      totalBytes: 2,
      personaBytes: 0,
      discoveryBytes: 0,
      memoryContextBytes: 0,
      // Synthetic stray field — should be capped at TRUNCATION_CAP_DEFAULT (512).
      // (Hand-rolling a non-typed key is intentional here; the cap path
      // operates on actual string size, not type defs.)
      stray: body,
    } as Record<string, unknown>);
    const ev = c.getEvents().find((e) => e.type === "prompt.assembled");
    const stray = (ev?.payload as any).stray as string;
    expect(stray.length).toBe(512 + "…[truncated]".length);
    expect(stray.endsWith("…[truncated]")).toBe(true);
  });

  test("nested values under a debug-tagged field inherit the 64 KB cap", () => {
    const c = makeCollector();
    const big = "x".repeat(8_000);
    c.event("model.request", {
      modelId: "anthropic.claude-sonnet-4-5",
      region: "us-east-1",
      systemPromptHash: "abc",
      systemPromptBytes: 1,
      priorTurnsCount: 1,
      // `messagesSeed` is a debug field — the nested `contentPreview` (a
      // string inside an object inside an array) should inherit the larger
      // cap instead of getting clamped to 512.
      messagesSeed: [{ role: "user", contentBytes: big.length, contentPreview: big }],
    });
    const ev = c.getEvents().find((e) => e.type === "model.request");
    const seed = (ev?.payload as any).messagesSeed as Array<{ contentPreview: string }>;
    expect(seed[0].contentPreview.length).toBe(8_000);
  });

  test("PII keys are always redacted (independent of TRACE_REDACT)", () => {
    delete process.env.TRACE_REDACT;
    const c = makeCollector();
    c.event("auth.context_build", {
      userId: "u",
      customersResolved: 1,
      ordersResolved: 0,
      jwtClaims: { sub: "u", email: "x@y.z", phone: "+1-555", name: "Alice" },
    });
    const ev = c.getEvents()[0];
    const claims = (ev.payload as any).jwtClaims;
    expect(claims.email).toBe("[redacted]");
    expect(claims.phone).toBe("[redacted]");
    expect(claims.name).toBe("[redacted]");
    // Non-PII keys survive verbatim.
    expect(claims.sub).toBe("u");
  });

  test("strings on non-debug event types stay clamped at 512 chars", () => {
    const c = makeCollector();
    c.event("error", { class: "TestError", message: "z".repeat(2_000) });
    const ev = c.getEvents().find((e) => e.type === "error");
    const msg = (ev?.payload as any).message as string;
    expect(msg.length).toBe(512 + "…[truncated]".length);
  });
});
