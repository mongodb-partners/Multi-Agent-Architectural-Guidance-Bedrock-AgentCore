/**
 * Strands SDK 0.7 retry hook **contract** test.
 *
 * Background: the Strands TS SDK 0.7 hook surface (`AfterModelCallEvent.retry`)
 * is a *user-driven* application retry flag — it lets the application ask
 * Strands to re-run the model call after a tool error. It is **not** an
 * SDK-level observer for AWS SDK v3 Bedrock retries (`ThrottlingException`,
 * `InternalServerException`, `ModelStreamErrorException`, …). Those retries
 * happen one layer down, inside the `BedrockRuntimeClient`, and Strands has
 * no native hook for them. `api/scripts/validate-strands-retries.ts`
 * documents this decision and serves as the upgrade alarm.
 *
 * Per plan §5a step 5, we ship the **SDK v3 middleware fallback**:
 * `resolveModel(...)` constructs the `BedrockModel` with a custom
 * `retryStrategy = new TracingRetryStrategy(maxAttempts, modelId)` so every
 * Bedrock retry surfaces as a `model.retry` trace event.
 *
 * This contract test pins three invariants that have to hold for the
 * Developer details "Retries" sub-section to keep working:
 *
 *   1. `resolveModel(...)` wires a `TracingRetryStrategy` into the
 *      Bedrock client's `clientConfig.retryStrategy` (not the default
 *      AWS SDK v3 `StandardRetryStrategy`).
 *   2. The strategy emits exactly one `model.retry` event per
 *      `refreshRetryTokenForRetry` call, with the documented payload
 *      shape (`provider`, `modelId`, `attempt`, `previousErrorClass`,
 *      `backoffMs`).
 *   3. A Strands SDK upgrade that flips `_config` or removes
 *      `ConfiguredRetryStrategy` from `@smithy/util-retry` would break
 *      this test before it breaks production traces.
 *
 * Doubles as a regression alarm on the SDK upgrade path: when this test
 * starts failing, the message points the upgrader at `validate-strands-retries`
 * and the AGENTS.md "Strands / Bedrock touchpoints" section.
 */

import { describe, expect, test, beforeEach } from "bun:test";
import type { RetryErrorInfo, StandardRetryToken } from "@smithy/types";
import {
  TracingRetryStrategy,
  resetResolveModelCacheForTests,
  resolveModel,
} from "../../src/adapters/resolve-model.ts";
import type { AgentDetail } from "../../src/lib/config-scan.ts";
import { TraceCollector } from "../../src/lib/trace-collector.ts";
import { withTrace } from "../../src/lib/trace-context.ts";

function fakeAgentConfig(): AgentDetail {
  return {
    id: "contract-test-agent",
    file: "/dev/null/contract-test-agent.agent.md",
    relativePath: "contract-test-agent.agent.md",
    description: "fixture",
    body: "",
    model: "anthropic.claude-sonnet-4-5",
    maxTokens: 512,
    temperature: 0.1,
    tools: [],
    skills: [],
    memory: { shortTerm: true, longTerm: false },
  } as unknown as AgentDetail;
}

function makeToken(retryCount = 1): StandardRetryToken {
  return {
    getRetryTokenCount: () => 0,
    getRetryDelay: () => 250,
    getRetryCount: () => retryCount,
    retryCount,
  } as unknown as StandardRetryToken;
}

function makeErrorInfo(): RetryErrorInfo {
  return {
    errorType: "THROTTLING",
    error: { name: "ThrottlingException", message: "rate exceeded" } as Error,
    retryAfterHint: undefined,
  } as unknown as RetryErrorInfo;
}

describe("Strands SDK 0.7 retry hook contract — Bedrock invariants", () => {
  beforeEach(() => {
    resetResolveModelCacheForTests();
  });

  /**
   * Walk the runtime BedrockRuntimeClient (Strands stores it as `_client`)
   * to its resolved retry strategy. AWS SDK v3 wraps strategies in a
   * Provider function (`config.retryStrategy: () => Promise<RetryStrategyV2>`)
   * so we resolve it before asserting the class.
   */
  async function resolveRetryStrategyFromModel(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    model: any,
  ): Promise<unknown> {
    const client = model?._client ?? model?.client;
    expect(client?.constructor?.name).toBe("BedrockRuntimeClient");
    const stratOrProvider = client?.config?.retryStrategy;
    return typeof stratOrProvider === "function" ? await stratOrProvider() : stratOrProvider;
  }

  test("resolveModel wires a TracingRetryStrategy onto the BedrockRuntimeClient", async () => {
    const model = resolveModel(fakeAgentConfig());
    const strat = await resolveRetryStrategyFromModel(model);
    // If a Strands upgrade ever flips this back to the AWS SDK default
    // (`StandardRetryStrategy`), the upgrade alarm fires here — exactly
    // where the message points the upgrader at validate-strands-retries.ts
    // and the AGENTS.md "Strands / Bedrock touchpoints" block.
    expect(strat).toBeInstanceOf(TracingRetryStrategy);
  });

  test("resolveModel honors BEDROCK_MAX_ATTEMPTS for the retry strategy", async () => {
    process.env.BEDROCK_MAX_ATTEMPTS = "7";
    try {
      const model = resolveModel(fakeAgentConfig());
      const strat = (await resolveRetryStrategyFromModel(model)) as {
        // ConfiguredRetryStrategy stores maxAttempts as a resolver (Provider
        // pattern). We call it to get the configured number — same path
        // the SDK takes per request.
        maxAttempts?: () => Promise<number> | number;
      };
      const value = typeof strat.maxAttempts === "function"
        ? await strat.maxAttempts()
        : strat.maxAttempts;
      expect(value).toBe(7);
    } finally {
      delete process.env.BEDROCK_MAX_ATTEMPTS;
    }
  });

  test("strategy emits exactly one model.retry per refresh with the documented payload shape", async () => {
    const strat = new TracingRetryStrategy(5, "anthropic.claude-sonnet-4-5");
    // Stub the parent so this test doesn't reach into the SDK throttle bucket.
    const fresh = makeToken(1);
    const parentProto = Object.getPrototypeOf(Object.getPrototypeOf(strat));
    const original = parentProto.refreshRetryTokenForRetry;
    parentProto.refreshRetryTokenForRetry = async () => fresh;

    const collector = new TraceCollector({
      sessionId: "s",
      messageId: "m",
      agentId: "contract-test-agent",
    });
    try {
      await withTrace(collector, async () => {
        await strat.refreshRetryTokenForRetry(makeToken(0), makeErrorInfo());
      });
    } finally {
      parentProto.refreshRetryTokenForRetry = original;
    }

    const retries = collector.getEvents().filter((e) => e.type === "model.retry");
    expect(retries).toHaveLength(1);
    const p = retries[0].payload as Record<string, unknown>;
    // The keys here MUST match `ModelRetryPayload` in `trace-types.ts` and
    // the columns rendered by `_dev_retries` in `developer_trace_view.py`.
    // Any drift means the dev panel column breaks silently.
    for (const k of ["provider", "modelId", "attempt", "previousErrorClass", "backoffMs"]) {
      expect(k in p).toBe(true);
    }
    expect(p.provider).toBe("bedrock");
    expect(p.modelId).toBe("anthropic.claude-sonnet-4-5");
    expect(p.attempt).toBe(1);
  });

  test("strategy is a no-op for tracing when no collector is active (production safety)", async () => {
    const strat = new TracingRetryStrategy(5, "anthropic.claude-sonnet-4-5");
    const fresh = makeToken(1);
    const parentProto = Object.getPrototypeOf(Object.getPrototypeOf(strat));
    const original = parentProto.refreshRetryTokenForRetry;
    parentProto.refreshRetryTokenForRetry = async () => fresh;
    try {
      const out = await strat.refreshRetryTokenForRetry(makeToken(0), makeErrorInfo());
      expect(out).toBe(fresh);
    } finally {
      parentProto.refreshRetryTokenForRetry = original;
    }
  });

  test("@smithy/util-retry still exports ConfiguredRetryStrategy (upgrade alarm)", async () => {
    // If `@smithy/util-retry` ever drops `ConfiguredRetryStrategy` in a major
    // bump, `TracingRetryStrategy` won't even import. We assert the import
    // succeeds + the prototype chain still flows through it so this test
    // fails BEFORE production starts shipping retries without trace events.
    const mod = await import("@smithy/util-retry");
    expect(typeof mod.ConfiguredRetryStrategy).toBe("function");
    const strat = new TracingRetryStrategy(3, "m");
    let proto = Object.getPrototypeOf(strat);
    let foundConfigured = false;
    for (let i = 0; i < 5 && proto; i++) {
      if (proto?.constructor?.name === "ConfiguredRetryStrategy") {
        foundConfigured = true;
        break;
      }
      proto = Object.getPrototypeOf(proto);
    }
    expect(foundConfigured).toBe(true);
  });
});
