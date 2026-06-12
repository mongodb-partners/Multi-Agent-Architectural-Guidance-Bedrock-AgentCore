/**
 * `string | MultimodalItem` → embedding for `mongodb_vector_search` and
 * write-side indexing (LTM, chat-message mirror).
 *
 * Strict provider selection — `EMBEDDINGS_PROVIDER` (in `.env`) is the single
 * source of truth and is mandatory. There is **no cross-provider fallback**
 * under any circumstance:
 *
 *   1. `voyage` — Voyage AI multimodal on SageMaker via
 *      `VOYAGE_SAGEMAKER_ENDPOINT`. Supports text and image segments
 *      (URL or inline base64).
 *   2. `titan` — Bedrock Titan / Cohere via `EMBEDDING_MODEL_ID`. Text-only.
 *      Titan + image input is rejected with `titan_no_multimodal` — there
 *      is no silent down-cast to text.
 *   3. anything else — `no_provider_configured`.
 *
 * Existing text-only call sites (`embedQueryText("hello")`,
 * `embedDocumentText(text)`) keep working unchanged — `string` arguments
 * auto-wrap via `textToMultimodal()` before crossing the typed adapter
 * boundary. Image-capable call sites pass a `MultimodalItem` directly.
 *
 * Vector dimensions must match the Atlas Vector Search index for the
 * collection — 1024-d by default, configurable via `VOYAGE_OUTPUT_DIM`
 * (`getVoyageEmbeddingDims()`).
 */

import { logger } from "./logger.ts";
import {
  isVoyageConfigured,
  getVoyageEndpoint,
  getVoyageModelName,
  voyageGenerateEmbedding,
  textToMultimodal,
  hasImageSegment,
  redactBase64Segments,
  type MultimodalItem,
  type VoyageInputType,
} from "../adapters/voyage-embedding.ts";
import { bedrockGenerateEmbedding } from "../adapters/bedrock-retrieval.ts";

/** Result of an embedding attempt. Either a vector + provenance, or a structured error. */
export type EmbedResult =
  | { ok: true; source: "voyage" | "bedrock"; modelId: string; vector: number[] }
  | { ok: false; code: EmbedErrorCode; message: string };

export type EmbedErrorCode =
  | "no_provider_configured"
  | "voyage_strict_failed"
  | "titan_strict_failed"
  | "titan_no_multimodal"
  | "embed_threw";

/** Accept either a plain string (auto-wrapped to a single-text-segment
 *  MultimodalItem) or a fully-typed MultimodalItem from a caller that
 *  needs image segments. */
export type EmbeddableInput = string | MultimodalItem;

/**
 * Run the configured embedding provider against `input`.
 *
 * Empty / whitespace-only string input is a caller bug; we return a
 * structured error so the LLM sees a clean tool error rather than an
 * opaque downstream failure.
 *
 * Titan + image input is rejected (`titan_no_multimodal`). The provider
 * gate is the choke point — no caller has to know.
 */
export async function embedQueryText(
  input: EmbeddableInput,
  abortSignal?: AbortSignal,
): Promise<EmbedResult> {
  return embedWithInputType(input, "query", abortSignal);
}

/**
 * Write-side embedder. Same provider rules as `embedQueryText` but passes
 * `input_type: "document"` to Voyage so resulting vectors land in the
 * same semantic space as the offline seed pipeline.
 */
export async function embedDocumentText(
  input: EmbeddableInput,
  abortSignal?: AbortSignal,
): Promise<EmbedResult> {
  return embedWithInputType(input, "document", abortSignal);
}

function declaredProvider(): "voyage" | "titan" | "" {
  const raw = (process.env.EMBEDDINGS_PROVIDER ?? "").trim().toLowerCase();
  if (raw === "voyage" || raw === "titan") return raw;
  return "";
}

/** Normalize EmbeddableInput → MultimodalItem and the plain string used
 *  for Titan (which is text-only). Returns null on empty text. */
function normalize(input: EmbeddableInput): { item: MultimodalItem; plainText: string } | null {
  if (typeof input === "string") {
    const trimmed = input.trim();
    if (!trimmed) return null;
    return { item: textToMultimodal(trimmed), plainText: trimmed };
  }
  if (!Array.isArray(input) || input.length === 0) return null;
  // Plain-text extraction for the Titan path: concatenate text segments.
  const plainText = input
    .filter((s): s is { type: "text"; text: string } => s.type === "text")
    .map((s) => s.text)
    .join(" ")
    .trim();
  return { item: input, plainText };
}

async function embedWithInputType(
  input: EmbeddableInput,
  inputType: VoyageInputType,
  abortSignal?: AbortSignal,
): Promise<EmbedResult> {
  const norm = normalize(input);
  if (!norm) {
    return {
      ok: false,
      code: "no_provider_configured",
      message: "embedding input is empty",
    };
  }
  const { item, plainText } = norm;
  const hasImage = hasImageSegment(item);

  const provider = declaredProvider();

  if (provider === "voyage") {
    return embedVoyageStrict(item, inputType, abortSignal);
  }
  if (provider === "titan") {
    if (hasImage) {
      logger.warn("[embed-query] titan + image input rejected (titan is text-only)", {
        inputType,
        sample: previewJson(redactBase64Segments([item])[0]),
      });
      return {
        ok: false,
        code: "titan_no_multimodal",
        message:
          "EMBEDDINGS_PROVIDER=titan but input contains image segments. Titan is text-only — " +
          "set EMBEDDINGS_PROVIDER=voyage for image embedding.",
      };
    }
    if (!plainText) {
      return {
        ok: false,
        code: "no_provider_configured",
        message: "titan path requires at least one non-empty text segment",
      };
    }
    return embedTitanStrict(plainText, abortSignal);
  }

  return {
    ok: false,
    code: "no_provider_configured",
    message:
      "EMBEDDINGS_PROVIDER must be set to 'voyage' or 'titan'. Strict mode — no implicit default, no cross-provider fallback.",
  };
}

async function embedVoyageStrict(
  item: MultimodalItem,
  inputType: VoyageInputType,
  abortSignal?: AbortSignal,
): Promise<EmbedResult> {
  if (!isVoyageConfigured()) {
    return {
      ok: false,
      code: "voyage_strict_failed",
      message:
        "EMBEDDINGS_PROVIDER=voyage but VOYAGE_SAGEMAKER_ENDPOINT is empty. Refusing to fall back to Bedrock.",
    };
  }
  try {
    const r = await voyageGenerateEmbedding(item, getVoyageEndpoint(), inputType, abortSignal);
    const v = extractEmbedding(r);
    if (v) {
      const modelId = v.modelId ?? getVoyageModelName();
      return { ok: true, source: "voyage", modelId, vector: v.embedding };
    }
    logger.warn("[embed-query] voyage returned unrecognized shape (strict mode — no fallback)", {
      sample: previewJson(r),
      inputType,
    });
    return {
      ok: false,
      code: "voyage_strict_failed",
      message: `Voyage returned unrecognized embedding shape: ${previewJson(r)}`,
    };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.warn("[embed-query] voyage call threw (strict mode — no fallback)", {
      error: message,
      inputType,
      itemPreview: previewJson(redactBase64Segments([item])[0]),
    });
    return { ok: false, code: "voyage_strict_failed", message };
  }
}

async function embedTitanStrict(
  text: string,
  abortSignal?: AbortSignal,
): Promise<EmbedResult> {
  const bedrockModelId = process.env.EMBEDDING_MODEL_ID?.trim();
  if (!bedrockModelId) {
    return {
      ok: false,
      code: "titan_strict_failed",
      message:
        "EMBEDDINGS_PROVIDER=titan but EMBEDDING_MODEL_ID is empty. Refusing to fall back to Voyage.",
    };
  }
  try {
    const r = await bedrockGenerateEmbedding(text, bedrockModelId, abortSignal);
    const v = extractEmbedding(r);
    if (v) {
      return { ok: true, source: "bedrock", modelId: v.modelId ?? bedrockModelId, vector: v.embedding };
    }
    return {
      ok: false,
      code: "titan_strict_failed",
      message: `Bedrock returned unrecognized embedding shape: ${previewJson(r)}`,
    };
  } catch (err) {
    return {
      ok: false,
      code: "titan_strict_failed",
      message: err instanceof Error ? err.message : String(err),
    };
  }
}

/**
 * Compact preview of a vector for trace events. Atlas vector indexes are
 * routinely 1024-d / 1536-d — we record only length + the first 4 + last 4
 * entries so the per-event byte cap doesn't strip the whole field.
 */
export function previewVector(vector: number[]): {
  length: number;
  head: number[];
  tail: number[];
} {
  const head = vector.slice(0, 4).map(round6);
  const tail = vector.length > 8 ? vector.slice(-4).map(round6) : [];
  return { length: vector.length, head, tail };
}

function round6(n: number): number {
  if (!Number.isFinite(n)) return n;
  return Math.round(n * 1e6) / 1e6;
}

function previewJson(value: unknown): string {
  try {
    const s = JSON.stringify(value);
    return s.length > 200 ? `${s.slice(0, 200)}…` : s;
  } catch {
    return "[unserializable]";
  }
}

/**
 * Both `voyageGenerateEmbedding` and `bedrockGenerateEmbedding` return JSONValue
 * shapes ({ status: "ok", embedding, model? } | { status: "error", ... }) and
 * test mocks may pass through untyped objects. Narrow defensively here so the
 * caller always gets `number[]` or undefined.
 */
function extractEmbedding(
  raw: unknown,
): { embedding: number[]; modelId?: string } | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const obj = raw as Record<string, unknown>;
  if (obj.status && obj.status !== "ok") return undefined;
  const emb = obj.embedding;
  if (!Array.isArray(emb) || emb.length === 0) return undefined;
  if (!emb.every((n) => typeof n === "number" && Number.isFinite(n))) return undefined;
  const modelId =
    typeof obj.model === "string"
      ? obj.model
      : typeof obj.modelId === "string"
        ? obj.modelId
        : undefined;
  return { embedding: emb as number[], modelId };
}
