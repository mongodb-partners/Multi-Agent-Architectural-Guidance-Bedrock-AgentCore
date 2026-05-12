/**
 * Per-1M-token USD pricing for the Bedrock models the framework actually uses.
 *
 * Sourced from AWS public pricing pages for on-demand inference in us-east-1
 * (representative; pricing is region-dependent, but the relative cost shape is
 * stable). Update this table when AWS adjusts list prices.
 *
 * Unknown model id → `priceFor(id) === undefined` so the collector surfaces
 * `costEstimateComplete: false` rather than guessing.
 */

export type ModelPrice = {
  /** USD per 1,000,000 input tokens. */
  input: number;
  /** USD per 1,000,000 output tokens. */
  output: number;
  /** USD per 1,000,000 cache-read input tokens (typically 10% of input). */
  cacheRead: number;
  /** USD per 1,000,000 cache-write input tokens (typically 25% premium). */
  cacheWrite: number;
};

/**
 * Canonical USD/1M-token table. Aliases (e.g. ":1" suffix or region prefix)
 * are resolved by `priceFor()` via prefix matching against the canonical key.
 */
export const MODEL_PRICING: Record<string, ModelPrice> = {
  // Anthropic Claude
  "anthropic.claude-sonnet-4": { input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite: 3.75 },
  "anthropic.claude-sonnet-4-5": { input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite: 3.75 },
  "anthropic.claude-haiku-4-5": { input: 1.0, output: 5.0, cacheRead: 0.1, cacheWrite: 1.25 },

  // Amazon Nova
  "amazon.nova-micro": { input: 0.035, output: 0.14, cacheRead: 0.00875, cacheWrite: 0.04375 },
  "amazon.nova-lite": { input: 0.06, output: 0.24, cacheRead: 0.015, cacheWrite: 0.075 },
  "amazon.nova-pro": { input: 0.8, output: 3.2, cacheRead: 0.2, cacheWrite: 1.0 },
};

/**
 * Lookup pricing for a Bedrock model id, including inference-profile prefixes
 * (e.g. `us.anthropic.claude-sonnet-4-5-20250929-v1:0` → `anthropic.claude-sonnet-4-5`).
 *
 * Returns `undefined` for unknown ids — caller is responsible for the partial-
 * estimate flag.
 */
export function priceFor(modelId: string | undefined | null): ModelPrice | undefined {
  if (!modelId) return undefined;
  const id = modelId.toLowerCase();

  // Direct match first.
  if (MODEL_PRICING[id]) return MODEL_PRICING[id];

  // Drop any inference-profile prefix like "us." / "eu." / "apac.".
  const stripped = id.replace(/^[a-z]{2,4}\./, "");
  if (MODEL_PRICING[stripped]) return MODEL_PRICING[stripped];

  // Match the longest canonical key that is a prefix of either form.
  let best: { key: string; price: ModelPrice } | undefined;
  for (const [key, price] of Object.entries(MODEL_PRICING)) {
    if (id.includes(key) || stripped.includes(key)) {
      if (!best || key.length > best.key.length) {
        best = { key, price };
      }
    }
  }
  return best?.price;
}

/**
 * Compute the USD cost of a single usage event. Returns `undefined` when the
 * model is unknown (caller should set `costEstimateComplete=false`).
 */
export function costOfUsage(usage: {
  modelId: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadInputTokens?: number;
  cacheWriteInputTokens?: number;
}): number | undefined {
  const p = priceFor(usage.modelId);
  if (!p) return undefined;
  return (
    (usage.inputTokens * p.input +
      usage.outputTokens * p.output +
      (usage.cacheReadInputTokens ?? 0) * p.cacheRead +
      (usage.cacheWriteInputTokens ?? 0) * p.cacheWrite) /
    1_000_000
  );
}
