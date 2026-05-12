import { describe, expect, test } from "bun:test";
import { costOfUsage, priceFor, MODEL_PRICING } from "../../src/lib/model-pricing.ts";

describe("priceFor", () => {
  test("exact match returns canonical entry", () => {
    expect(priceFor("anthropic.claude-sonnet-4-5")).toBe(MODEL_PRICING["anthropic.claude-sonnet-4-5"]);
  });

  test("strips us. inference-profile prefix", () => {
    expect(priceFor("us.anthropic.claude-sonnet-4-5-20250929-v1:0")).toBe(
      MODEL_PRICING["anthropic.claude-sonnet-4-5"],
    );
  });

  test("matches Nova micro full id", () => {
    expect(priceFor("amazon.nova-micro-v1:0")).toBe(MODEL_PRICING["amazon.nova-micro"]);
  });

  test("matches Nova lite via inference profile prefix", () => {
    expect(priceFor("us.amazon.nova-lite-v1:0")).toBe(MODEL_PRICING["amazon.nova-lite"]);
  });

  test("unknown model id returns undefined", () => {
    expect(priceFor("openai.gpt-5")).toBeUndefined();
  });

  test("null / empty / undefined → undefined", () => {
    expect(priceFor(null)).toBeUndefined();
    expect(priceFor(undefined)).toBeUndefined();
    expect(priceFor("")).toBeUndefined();
  });
});

describe("costOfUsage", () => {
  test("Sonnet 4.5 — 1k in / 1k out → 0.003 + 0.015 = 0.018 USD", () => {
    const c = costOfUsage({
      modelId: "anthropic.claude-sonnet-4-5",
      inputTokens: 1_000,
      outputTokens: 1_000,
    });
    expect(c).toBeCloseTo(0.018, 6);
  });

  test("Haiku 4.5 — 1M in / 1M out → 1 + 5 = 6 USD", () => {
    const c = costOfUsage({
      modelId: "anthropic.claude-haiku-4-5",
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
    });
    expect(c).toBeCloseTo(6, 6);
  });

  test("Sonnet — cache-read + cache-write contribute the discount rates", () => {
    // 1k cached read @ $0.30/M = 0.0003; 1k cache write @ $3.75/M = 0.00375.
    const c = costOfUsage({
      modelId: "anthropic.claude-sonnet-4-5",
      inputTokens: 0,
      outputTokens: 0,
      cacheReadInputTokens: 1_000,
      cacheWriteInputTokens: 1_000,
    });
    expect(c).toBeCloseTo(0.0003 + 0.00375, 8);
  });

  test("Nova micro — 1M tokens out → $0.14", () => {
    const c = costOfUsage({
      modelId: "amazon.nova-micro",
      inputTokens: 0,
      outputTokens: 1_000_000,
    });
    expect(c).toBeCloseTo(0.14, 6);
  });

  test("Nova pro — 100k in / 50k out → 0.08 + 0.16 = 0.24 USD", () => {
    const c = costOfUsage({
      modelId: "amazon.nova-pro",
      inputTokens: 100_000,
      outputTokens: 50_000,
    });
    expect(c).toBeCloseTo(0.24, 6);
  });

  test("unknown model id → undefined", () => {
    const c = costOfUsage({
      modelId: "openai.gpt-5",
      inputTokens: 1_000,
      outputTokens: 1_000,
    });
    expect(c).toBeUndefined();
  });
});
