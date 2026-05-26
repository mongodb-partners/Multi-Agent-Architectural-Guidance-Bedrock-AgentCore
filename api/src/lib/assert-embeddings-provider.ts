/**
 * Boot-time assertion that the embedding provider declared by `.env` is
 * actually wired into the runtime env.
 *
 * Strict-only — `EMBEDDINGS_PROVIDER` is **mandatory** in every environment
 * (deployed and local). There is no implicit default and no cross-provider
 * fallback at runtime. The container fails to start rather than serving
 * silently-degraded embeddings.
 *
 * Allowed values:
 *
 *   - `voyage` — Voyage multimodal default. Requires `VOYAGE_SAGEMAKER_ENDPOINT`. The API
 *     will refuse Bedrock fallback even if `EMBEDDING_MODEL_ID` is also set
 *     (and we warn so the operator can clean up `.env.live`).
 *   - `titan` — Explicit deviation. Requires `EMBEDDING_MODEL_ID`
 *     (`amazon.titan-embed-text-v2:0`). The API will refuse Voyage fallback
 *     even if `VOYAGE_SAGEMAKER_ENDPOINT` is also set.
 *
 * Empty / missing / unrecognised values throw — no escape hatch.
 *
 * Boot-guard call sites: `api/src/index.ts` and (when bundled into AgentCore)
 * `api/src/agent-runtime-code.ts`.
 */

import { logger } from "./logger.ts";

export function assertEmbeddingsProvider(): void {
  const declared = (process.env.EMBEDDINGS_PROVIDER ?? "").trim().toLowerCase();
  const voyageEndpoint = (process.env.VOYAGE_SAGEMAKER_ENDPOINT ?? "").trim();
  const bedrockModelId = (process.env.EMBEDDING_MODEL_ID ?? "").trim();

  if (!declared) {
    throw new Error(
      "EMBEDDINGS_PROVIDER is required. Set it to 'voyage' or 'titan' in .env. " +
        "Strict mode — no implicit default, no cross-provider fallback.",
    );
  }

  switch (declared) {
    case "voyage": {
      if (!voyageEndpoint) {
        throw new Error(
          "EMBEDDINGS_PROVIDER=voyage but VOYAGE_SAGEMAKER_ENDPOINT is empty. " +
            "Refusing to start — the Voyage provider is not actually wired. " +
            "Either provision the SageMaker endpoint or switch EMBEDDINGS_PROVIDER=titan.",
        );
      }
      logger.info("[embeddings] strict voyage mode — no Bedrock fallback", {
        endpoint: voyageEndpoint,
        format: process.env.VOYAGE_REQUEST_FORMAT ?? "multimodal",
        voyageMultimodal: true,
      });
      if (bedrockModelId) {
        logger.warn(
          "[embeddings] EMBEDDING_MODEL_ID is set but ignored in voyage mode — clean up .env.live to avoid confusion",
          { modelId: bedrockModelId },
        );
      }
      return;
    }
    case "titan": {
      if (!bedrockModelId) {
        throw new Error(
          "EMBEDDINGS_PROVIDER=titan but EMBEDDING_MODEL_ID is empty. " +
            "Refusing to start — Bedrock fallback is not wired.",
        );
      }
      logger.warn("[embeddings] strict titan mode — no Voyage fallback (EXPLICIT TITAN MODE)", {
        modelId: bedrockModelId,
        voyageMultimodal: false,
        note: "amazon.titan-embed-text-v2:0 — set EMBEDDINGS_PROVIDER=voyage to use voyage-multimodal-3",
      });
      if (voyageEndpoint) {
        logger.warn(
          "[embeddings] VOYAGE_SAGEMAKER_ENDPOINT is set but ignored in titan mode — clean up .env.live to avoid confusion",
          { endpoint: voyageEndpoint },
        );
      }
      return;
    }
    default:
      throw new Error(
        `EMBEDDINGS_PROVIDER='${declared}' is not recognised. Use 'voyage' or 'titan'. ` +
          "Strict mode — no implicit default, no cross-provider fallback.",
      );
  }
}
