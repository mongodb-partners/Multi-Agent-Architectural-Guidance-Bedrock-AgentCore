/**
 * Boot-time assertion that the embedding provider declared by the deploy
 * pipeline matches what is actually wired in the runtime env.
 *
 * Why this exists:
 *   The SoW pins this stack to voyage-multimodal-3. deploy.sh now refuses to
 *   ship unless EMBEDDINGS_PROVIDER is set explicitly to either "voyage"
 *   (SoW-aligned, VOYAGE_SAGEMAKER_ENDPOINT provisioned) or "titan" (an
 *   explicit, written deviation that falls back to amazon.titan-embed-text-v2:0).
 *
 *   At runtime we re-check that the env we received agrees with the declared
 *   provider so that nothing silently flips between deploys (e.g. the manifest
 *   says "voyage" but the endpoint env var was dropped). The container fails
 *   to start rather than serving silently-degraded embeddings.
 *
 * Set EMBEDDINGS_PROVIDER="" to skip the check (local dev only).
 */

import { logger } from "./logger.ts";

export function assertEmbeddingsProvider(): void {
  const declared = (process.env.EMBEDDINGS_PROVIDER ?? "").trim().toLowerCase();
  const voyageEndpoint = (process.env.VOYAGE_SAGEMAKER_ENDPOINT ?? "").trim();
  const bedrockModelId = (process.env.EMBEDDING_MODEL_ID ?? "").trim();

  if (!declared) {
    logger.warn(
      "[embeddings] EMBEDDINGS_PROVIDER is empty — boot-time assertion skipped. " +
        "This is acceptable for local dev but must NEVER happen in deployed stacks " +
        "(deploy.sh injects an explicit value).",
    );
    return;
  }

  switch (declared) {
    case "voyage": {
      if (!voyageEndpoint) {
        throw new Error(
          "EMBEDDINGS_PROVIDER=voyage but VOYAGE_SAGEMAKER_ENDPOINT is empty. " +
            "Refusing to start — the SoW-aligned provider is not actually wired. " +
            "Either provision the SageMaker endpoint or switch EMBEDDINGS_PROVIDER=titan.",
        );
      }
      logger.info("[embeddings] provider=voyage", {
        endpoint: voyageEndpoint,
        format: process.env.VOYAGE_REQUEST_FORMAT ?? "multimodal",
        sowAligned: true,
      });
      return;
    }
    case "titan": {
      if (!bedrockModelId) {
        throw new Error(
          "EMBEDDINGS_PROVIDER=titan but EMBEDDING_MODEL_ID is empty. " +
            "Refusing to start — Bedrock fallback is not wired.",
        );
      }
      logger.warn("[embeddings] provider=titan (EXPLICIT SoW DEVIATION)", {
        modelId: bedrockModelId,
        sowAligned: false,
        note: "amazon.titan-embed-text-v2:0 — restore voyage-multimodal-3 to align with SoW",
      });
      return;
    }
    default:
      throw new Error(
        `EMBEDDINGS_PROVIDER='${declared}' is not recognised. Use 'voyage' or 'titan'.`,
      );
  }
}
