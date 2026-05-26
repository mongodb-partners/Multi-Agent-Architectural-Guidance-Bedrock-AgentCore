/**
 * Voyage AI embedding adapter — calls a SageMaker endpoint hosting a Voyage
 * model deployed from the MongoDB AWS Marketplace listing.
 *
 * Two listings are supported and selected by `VOYAGE_REQUEST_FORMAT`:
 *
 * - `multimodal` (default — voyage-multimodal-3):
 *     Request:  { "inputs": [{ "content": [{ "type": "text", "text": "..." }] }],
 *                 "input_type": "query" | "document",
 *                 "truncation": true,
 *                 "output_encoding": null }
 *
 * - `legacy` (voyage-3.5-lite / voyage-3 — the older text-only listing):
 *     Request:  { "input": ["..."], "input_type": "query" | "document",
 *                 "output_dimension": <int> }
 *
 * Both listings respond with the same envelope:
 *     { "data": [{ "embedding": [...], "index": 0 }], "model": "...", "usage": {...} }
 *
 * Set VOYAGE_SAGEMAKER_ENDPOINT to the SageMaker endpoint name (not the ARN).
 * voyage-multimodal-3 returns **1024-d** embeddings (matches the Atlas vector
 * index + Bedrock Titan v2). The legacy listing exposes `output_dimension` to
 * pick {256, 512, 1024, 2048}.
 *
 * Subscribe to voyage-multimodal-3 at:
 *   https://aws.amazon.com/marketplace/pp/prodview-hrid2zxusacxy
 * (one-time EULA acceptance per AWS account; ARN discovered via
 *  deploy/scripts/setup-voyage-marketplace.sh --model voyage-multimodal-3).
 */

import { SageMakerRuntimeClient, InvokeEndpointCommand } from "@aws-sdk/client-sagemaker-runtime";
import type { JSONValue } from "@strands-agents/sdk";

export type VoyageInputType = "query" | "document";
export type VoyageRequestFormat = "multimodal" | "legacy";

let _client: SageMakerRuntimeClient | null = null;

function getClient(): SageMakerRuntimeClient {
  if (!_client) {
    _client = new SageMakerRuntimeClient({ region: process.env.AWS_REGION ?? "us-east-1" });
  }
  return _client;
}

/** Output dimensions for the legacy listing. 1024 keeps wire compat with the
 *  Atlas vector index sized for Bedrock Titan v2 (1024-d). Allowed values:
 *  2048 (default), 1024, 512, 256. Ignored for `multimodal` request format
 *  because voyage-multimodal-3 returns a fixed 1024-d vector. */
const VOYAGE_OUTPUT_DIM = Number(process.env.VOYAGE_OUTPUT_DIM ?? 1024);

/** Request envelope shape — defaults to "multimodal" (voyage-multimodal-3).
 *  Set VOYAGE_REQUEST_FORMAT=legacy to fall back to the voyage-3.5-lite shape
 *  for environments that still subscribe to that older Marketplace listing. */
function requestFormat(): VoyageRequestFormat {
  const raw = (process.env.VOYAGE_REQUEST_FORMAT ?? "multimodal").trim().toLowerCase();
  return raw === "legacy" ? "legacy" : "multimodal";
}

const VOYAGE_TEXT_MAX_CHARS = 32_000;

export function buildVoyageRequestBody(
  text: string,
  inputType: VoyageInputType,
  format: VoyageRequestFormat = requestFormat(),
): string {
  const truncated = text.slice(0, VOYAGE_TEXT_MAX_CHARS);
  if (format === "legacy") {
    return JSON.stringify({
      input: [truncated],
      input_type: inputType,
      output_dimension: VOYAGE_OUTPUT_DIM,
    });
  }
  // multimodal (voyage-multimodal-3) — wraps each piece of content in the
  // inputs[].content[] array. For a text-only call we send a single text piece.
  return JSON.stringify({
    inputs: [{ content: [{ type: "text", text: truncated }] }],
    input_type: inputType,
    truncation: true,
    output_encoding: null,
  });
}

export async function voyageGenerateEmbedding(
  text: string,
  endpointName: string,
  inputType: VoyageInputType = "document",
  abortSignal?: AbortSignal,
): Promise<JSONValue> {
  const body = buildVoyageRequestBody(text, inputType);

  const cmd = new InvokeEndpointCommand({
    EndpointName: endpointName,
    ContentType: "application/json",
    Accept: "application/json",
    Body: Buffer.from(body),
  });

  const res = await getClient().send(cmd, abortSignal ? { abortSignal } : undefined);
  const decoded = JSON.parse(new TextDecoder().decode(res.Body)) as {
    data: { embedding: number[]; index: number }[];
    model: string;
    usage: { total_tokens: number };
  };

  const embedding = decoded.data[0]?.embedding;
  if (!Array.isArray(embedding)) {
    return { status: "error", error: "Voyage AI returned no embedding", raw: decoded };
  }

  return { status: "ok", embedding, model: decoded.model, dimensions: embedding.length };
}

/** True when the Voyage AI SageMaker endpoint is configured. */
export function isVoyageConfigured(): boolean {
  return Boolean(process.env.VOYAGE_SAGEMAKER_ENDPOINT?.trim());
}

export function getVoyageEndpoint(): string {
  const ep = process.env.VOYAGE_SAGEMAKER_ENDPOINT?.trim();
  if (!ep) throw new Error("VOYAGE_SAGEMAKER_ENDPOINT is not set");
  return ep;
}
