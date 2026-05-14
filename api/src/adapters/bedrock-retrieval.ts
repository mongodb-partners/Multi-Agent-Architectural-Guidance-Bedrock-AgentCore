/**
 * Bedrock retrieval helpers used by Strands tools:
 *   - Bedrock Knowledge Base retrieve (`bedrock_kb_retrieve` tool)
 *   - Bedrock embedding generation (Titan / Cohere) for vector search
 */

import {
  BedrockRuntimeClient,
  InvokeModelCommand,
} from "@aws-sdk/client-bedrock-runtime";
import {
  BedrockAgentRuntimeClient,
  RetrieveCommand,
} from "@aws-sdk/client-bedrock-agent-runtime";
import type { JSONValue } from "@strands-agents/sdk";
import { logger } from "../lib/logger.ts";

let kbClient: BedrockAgentRuntimeClient | undefined;

function getKbClient(): BedrockAgentRuntimeClient {
  if (!kbClient) {
    const region = process.env.AWS_REGION?.trim() || "us-east-1";
    kbClient = new BedrockAgentRuntimeClient({ region });
  }
  return kbClient;
}

/** Retrieve chunks from a Bedrock Knowledge Base. */
export async function bedrockKbRetrieve(
  query: string,
  knowledgeBaseId: string,
  numberOfResults = 5,
): Promise<JSONValue> {
  try {
    const cmd = new RetrieveCommand({
      knowledgeBaseId,
      retrievalQuery: { text: query },
      retrievalConfiguration: {
        vectorSearchConfiguration: { numberOfResults },
      },
    });
    const resp = await getKbClient().send(cmd);
    const results = (resp.retrievalResults ?? []).map((r) => ({
      content: r.content?.text ?? "",
      score: r.score ?? 0,
      location: r.location ?? {},
      metadata: r.metadata ?? {},
    }));
    return { status: "ok", source: "bedrock_kb", knowledgeBaseId, results };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    logger.error("[kb-retrieve] Bedrock KB retrieve failed", { knowledgeBaseId, error: msg });
    return { status: "error", source: "bedrock_kb", error: msg };
  }
}

let embedClient: BedrockRuntimeClient | undefined;

function getEmbedClient(): BedrockRuntimeClient {
  if (!embedClient) {
    const region = process.env.AWS_REGION?.trim() || "us-east-1";
    embedClient = new BedrockRuntimeClient({ region });
  }
  return embedClient;
}

/**
 * Generate an embedding using Amazon Bedrock.
 * Supports Titan Text Embeddings v2 (amazon.titan-embed-text-v2:0)
 * and Cohere Embed models (cohere.embed-english-v3 / cohere.embed-multilingual-v3).
 */
export async function bedrockGenerateEmbedding(
  text: string,
  modelId: string,
): Promise<JSONValue> {
  try {
    let body: string;
    const isTitan = modelId.startsWith("amazon.titan-embed");
    const isCohere = modelId.startsWith("cohere.embed");

    if (isTitan) {
      body = JSON.stringify({ inputText: text });
    } else if (isCohere) {
      body = JSON.stringify({ texts: [text], input_type: "search_query" });
    } else {
      // Generic fallback — try Titan-style payload
      body = JSON.stringify({ inputText: text });
    }

    const cmd = new InvokeModelCommand({
      modelId,
      body: new TextEncoder().encode(body),
      contentType: "application/json",
      accept: "application/json",
    });

    const resp = await getEmbedClient().send(cmd);
    const decoded = new TextDecoder().decode(resp.body);
    const parsed = JSON.parse(decoded) as Record<string, unknown>;

    let embedding: number[];
    if (isTitan && Array.isArray(parsed.embedding)) {
      embedding = parsed.embedding as number[];
    } else if (isCohere && Array.isArray((parsed as Record<string, unknown[]>).embeddings?.[0])) {
      embedding = (parsed as { embeddings: number[][] }).embeddings[0];
    } else if (Array.isArray(parsed.embedding)) {
      embedding = parsed.embedding as number[];
    } else {
      return { status: "error", error: "Unrecognized embedding response shape", raw: parsed as JSONValue };
    }

    return { status: "ok", source: "bedrock", modelId, embedding, dimensions: embedding.length };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    logger.error("[generate-embedding] Bedrock embedding failed", { modelId, error: msg });
    return { status: "error", source: "bedrock", error: msg };
  }
}
