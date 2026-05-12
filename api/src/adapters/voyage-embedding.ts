/**
 * Voyage AI embedding adapter — calls a SageMaker endpoint hosting a Voyage model
 * (voyage-3.5-lite or voyage-3) deployed from the MongoDB AWS Marketplace listing.
 *
 * The endpoint receives:
 *   { "input": ["text"], "input_type": "query" | "document" }
 *
 * And responds with:
 *   { "data": [{ "embedding": [...], "index": 0 }], "model": "voyage-3.5-lite", "usage": {...} }
 *
 * Set VOYAGE_SAGEMAKER_ENDPOINT to the SageMaker endpoint name (the name, not the ARN).
 * voyage-3.5-lite default output dimensions: 1024 (matches Atlas vector index + Titan v2).
 * Subscribe at: https://aws.amazon.com/marketplace/seller-profile?id=c9032c7b-70dd-459f-834f-c1e23cf3d092
 */

import { SageMakerRuntimeClient, InvokeEndpointCommand } from "@aws-sdk/client-sagemaker-runtime";
import type { JSONValue } from "@strands-agents/sdk";

export type VoyageInputType = "query" | "document";

let _client: SageMakerRuntimeClient | null = null;

function getClient(): SageMakerRuntimeClient {
  if (!_client) {
    _client = new SageMakerRuntimeClient({ region: process.env.AWS_REGION ?? "us-east-1" });
  }
  return _client;
}

/** Output dimensions to request from voyage-3.5-lite. 1024 keeps wire compat
 *  with the existing Atlas vector index sized for Bedrock Titan v2 (1024-d).
 *  Allowed values: 2048 (default), 1024, 512, 256.
 */
const VOYAGE_OUTPUT_DIM = Number(process.env.VOYAGE_OUTPUT_DIM ?? 1024);

export async function voyageGenerateEmbedding(
  text: string,
  endpointName: string,
  inputType: VoyageInputType = "document",
): Promise<JSONValue> {
  const body = JSON.stringify({
    input: [text.slice(0, 32000)],
    input_type: inputType,
    output_dimension: VOYAGE_OUTPUT_DIM,
  });

  const cmd = new InvokeEndpointCommand({
    EndpointName: endpointName,
    ContentType: "application/json",
    Accept: "application/json",
    Body: Buffer.from(body),
  });

  const res = await getClient().send(cmd);
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
