/**
 * Local TTFB (time-to-first-token) benchmark for `POST /chat`.
 *
 * Measures the wall-clock interval between the client sending the POST
 * request and receiving the first SSE `event: token` frame. Reports both
 * the per-iteration distribution and the percentiles, plus total response
 * time so we can see the streaming win independent of overall latency.
 *
 * Run against a warm process (fire one cold request first; this script does
 * a single warm-up automatically) with a fresh `sessionId` per iteration so
 * we exercise the new-session path.
 *
 * Usage:
 *   API_URL=http://localhost:3001 \
 *   BEARER_TOKEN=eyJ...           \  # any non-empty bearer when REQUIRE_AUTH/jwt is enabled
 *   AGENT_ID=order-management     \  # optional; defaults to 'orchestrator' so direct routing fires
 *   ITERATIONS=10                 \
 *   bun run scripts/bench-chat-ttfb.ts
 *
 * Compare runs by exporting `BENCH_LABEL=before` / `BENCH_LABEL=after` and
 * piping the JSON output to a file.
 */

const API_URL = (process.env.API_URL ?? "http://localhost:3001").replace(/\/$/, "");
const BEARER = process.env.BEARER_TOKEN ?? "local-bench-user";
const AGENT_ID = process.env.AGENT_ID ?? "orchestrator";
const ITERATIONS = Math.max(1, Number(process.env.ITERATIONS ?? 10));
const PROMPT = process.env.BENCH_PROMPT ?? "where is order ORD-1001?";
const LABEL = process.env.BENCH_LABEL ?? "ttfb";

type Sample = {
  iteration: number;
  /** First complete SSE frame, regardless of event type. */
  firstEventMs: number;
  /** First non-token progress signal: trace/status/handoff/tool/error. */
  firstProgressMs: number;
  firstTraceMs: number;
  firstToolMs: number;
  firstTokenMs: number;
  /** Backward-compatible alias for firstTokenMs. */
  ttfbMs: number;
  totalMs: number;
  tokensSeen: number;
  bytesSeen: number;
  failed: boolean;
  error?: string;
  firstError?: { code?: string; message?: string };
};

async function oneShot(iteration: number): Promise<Sample> {
  const started = performance.now();
  const sessionId = `bench_${Date.now()}_${iteration}`;
  let firstEventAt: number | undefined;
  let firstProgressAt: number | undefined;
  let firstTraceAt: number | undefined;
  let firstToolAt: number | undefined;
  let firstTokenAt: number | undefined;
  let firstError: { code?: string; message?: string } | undefined;
  let tokensSeen = 0;
  let bytesSeen = 0;

  try {
    const res = await fetch(`${API_URL}/chat`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "text/event-stream",
        authorization: `Bearer ${BEARER}`,
      },
      body: JSON.stringify({ message: PROMPT, sessionId, agentId: AGENT_ID }),
    });
    if (!res.ok || !res.body) {
      const txt = await res.text().catch(() => "");
      return {
        iteration,
        firstEventMs: -1,
        firstProgressMs: -1,
        firstTraceMs: -1,
        firstToolMs: -1,
        firstTokenMs: -1,
        ttfbMs: -1,
        totalMs: performance.now() - started,
        tokensSeen,
        bytesSeen,
        failed: true,
        error: `HTTP ${res.status} ${txt.slice(0, 200)}`,
      };
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    let currentEvent = "message";

    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      bytesSeen += value.byteLength;
      buf += decoder.decode(value, { stream: true });
      let idx: number;
      while ((idx = buf.indexOf("\n\n")) !== -1) {
        const block = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        currentEvent = "message";
        for (const line of block.split("\n")) {
          if (line.startsWith("event:")) currentEvent = line.slice(6).trim();
          if (line.startsWith("data:")) {
            try {
              const parsed = JSON.parse(line.slice(5).trim());
              if (currentEvent === "error" && parsed && typeof parsed === "object") {
                firstError ??= {
                  code: typeof parsed.code === "string" ? parsed.code : undefined,
                  message: typeof parsed.message === "string" ? parsed.message : undefined,
                };
              }
            } catch {
              // Ignore malformed data in benchmark parsing; the stream parser
              // under test handles protocol correctness elsewhere.
            }
          }
        }
        firstEventAt ??= performance.now();
        if (
          currentEvent === "trace" ||
          currentEvent === "agent_info" ||
          currentEvent === "agent_active" ||
          currentEvent === "handoff" ||
          currentEvent === "skill_loaded" ||
          currentEvent === "tool_call" ||
          currentEvent === "error"
        ) {
          firstProgressAt ??= performance.now();
        }
        if (currentEvent === "trace") firstTraceAt ??= performance.now();
        if (currentEvent === "tool_call") firstToolAt ??= performance.now();
        if (currentEvent === "token") {
          tokensSeen += 1;
          if (firstTokenAt === undefined) firstTokenAt = performance.now();
        } else if (currentEvent === "done") {
          // Drain end of stream.
        }
      }
    }
  } catch (err) {
    return {
      iteration,
      firstEventMs: -1,
      firstProgressMs: -1,
      firstTraceMs: -1,
      firstToolMs: -1,
      firstTokenMs: -1,
      ttfbMs: -1,
      totalMs: performance.now() - started,
      tokensSeen,
      bytesSeen,
      failed: true,
      error: err instanceof Error ? err.message : String(err),
    };
  }

  return {
    iteration,
    firstEventMs: firstEventAt !== undefined ? Math.round(firstEventAt - started) : -1,
    firstProgressMs: firstProgressAt !== undefined ? Math.round(firstProgressAt - started) : -1,
    firstTraceMs: firstTraceAt !== undefined ? Math.round(firstTraceAt - started) : -1,
    firstToolMs: firstToolAt !== undefined ? Math.round(firstToolAt - started) : -1,
    firstTokenMs: firstTokenAt !== undefined ? Math.round(firstTokenAt - started) : -1,
    ttfbMs: firstTokenAt !== undefined ? Math.round(firstTokenAt - started) : -1,
    totalMs: Math.round(performance.now() - started),
    tokensSeen,
    bytesSeen,
    failed: firstTokenAt === undefined,
    ...(firstError ? { firstError } : {}),
  };
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
}

async function main(): Promise<void> {
  console.error(`[bench] warming up against ${API_URL} (agent=${AGENT_ID})…`);
  await oneShot(0);

  console.error(`[bench] running ${ITERATIONS} iterations…`);
  const samples: Sample[] = [];
  for (let i = 1; i <= ITERATIONS; i++) {
    const s = await oneShot(i);
    samples.push(s);
    console.error(
      `  iter ${i}: firstEvent=${s.firstEventMs}ms progress=${s.firstProgressMs}ms tool=${s.firstToolMs}ms token=${s.firstTokenMs}ms total=${s.totalMs}ms tokens=${s.tokensSeen} bytes=${s.bytesSeen}${s.failed ? ` FAILED (${s.error ?? s.firstError?.code ?? "no_token"})` : ""}`,
    );
  }

  const ok = samples.filter((s) => !s.failed);
  const allPositive = (values: number[]) => values.filter((v) => v >= 0).sort((a, b) => a - b);
  const firstEvents = allPositive(samples.map((s) => s.firstEventMs));
  const firstProgress = allPositive(samples.map((s) => s.firstProgressMs));
  const firstTraces = allPositive(samples.map((s) => s.firstTraceMs));
  const firstTools = allPositive(samples.map((s) => s.firstToolMs));
  const ttfbs = ok.map((s) => s.ttfbMs).sort((a, b) => a - b);
  const totals = ok.map((s) => s.totalMs).sort((a, b) => a - b);
  const summary = {
    label: LABEL,
    apiUrl: API_URL,
    agentId: AGENT_ID,
    prompt: PROMPT,
    iterations: ITERATIONS,
    completed: ok.length,
    failed: samples.length - ok.length,
    firstEventMs: {
      p50: percentile(firstEvents, 50),
      p90: percentile(firstEvents, 90),
      p99: percentile(firstEvents, 99),
      min: firstEvents[0] ?? -1,
      max: firstEvents[firstEvents.length - 1] ?? -1,
      mean: firstEvents.length ? Math.round(firstEvents.reduce((a, b) => a + b, 0) / firstEvents.length) : -1,
    },
    firstProgressMs: {
      p50: percentile(firstProgress, 50),
      p90: percentile(firstProgress, 90),
      p99: percentile(firstProgress, 99),
      min: firstProgress[0] ?? -1,
      max: firstProgress[firstProgress.length - 1] ?? -1,
      mean: firstProgress.length
        ? Math.round(firstProgress.reduce((a, b) => a + b, 0) / firstProgress.length)
        : -1,
    },
    firstTraceMs: {
      p50: percentile(firstTraces, 50),
      p90: percentile(firstTraces, 90),
      p99: percentile(firstTraces, 99),
      min: firstTraces[0] ?? -1,
      max: firstTraces[firstTraces.length - 1] ?? -1,
      mean: firstTraces.length ? Math.round(firstTraces.reduce((a, b) => a + b, 0) / firstTraces.length) : -1,
    },
    firstToolMs: {
      p50: percentile(firstTools, 50),
      p90: percentile(firstTools, 90),
      p99: percentile(firstTools, 99),
      min: firstTools[0] ?? -1,
      max: firstTools[firstTools.length - 1] ?? -1,
      mean: firstTools.length ? Math.round(firstTools.reduce((a, b) => a + b, 0) / firstTools.length) : -1,
    },
    ttfbMs: {
      p50: percentile(ttfbs, 50),
      p90: percentile(ttfbs, 90),
      p99: percentile(ttfbs, 99),
      min: ttfbs[0] ?? -1,
      max: ttfbs[ttfbs.length - 1] ?? -1,
      mean: ttfbs.length ? Math.round(ttfbs.reduce((a, b) => a + b, 0) / ttfbs.length) : -1,
    },
    totalMs: {
      p50: percentile(totals, 50),
      p90: percentile(totals, 90),
      p99: percentile(totals, 99),
      min: totals[0] ?? -1,
      max: totals[totals.length - 1] ?? -1,
      mean: totals.length ? Math.round(totals.reduce((a, b) => a + b, 0) / totals.length) : -1,
    },
    samples,
  };
  process.stdout.write(JSON.stringify(summary, null, 2) + "\n");
}

void main();
