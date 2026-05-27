/**
 * Unit tests for the `embed_multimodal_content` agent tool in
 * `api/src/lib/base-tools.ts`.
 *
 * Contract:
 *   1. Accepts the canonical nested-array shape — one `MultimodalItem` per
 *      input, each item is an array of text/image_url/image_base64 segments.
 *   2. Rejects a flat `string[]` at tool-input validation time (this is what
 *      stops Strands' tool-call serializer from down-casting multimodal
 *      intent to text).
 *   3. Rejects bare base64 (no `data:image/<mime>;base64,` header).
 *   4. Forwards `inputType` ("query" vs "document") to the right
 *      `embed-query.ts` entry point — no cross-routing.
 *   5. On per-item failure, surfaces `{ status: "error", code, message,
 *      imageBlocks, textBlocks }` without retrying.
 *   6. Emits `error` (existing TraceEventType) on failure with
 *      `source: "embed_multimodal_content"`.
 */

import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

let queryCalls: unknown[] = [];
let documentCalls: unknown[] = [];
let queryImpl: (text: unknown) => Promise<unknown> = async () => ({ ok: false });
let documentImpl: (text: unknown) => Promise<unknown> = async () => ({ ok: false });

const realEmbed = await import("../../src/lib/embed-query.ts");
mock.module("../../src/lib/embed-query.ts", () => ({
  ...realEmbed,
  embedQueryText: async (input: unknown) => {
    queryCalls.push(input);
    return queryImpl(input);
  },
  embedDocumentText: async (input: unknown) => {
    documentCalls.push(input);
    return documentImpl(input);
  },
}));

afterAll(() => {
  mock.module("../../src/lib/embed-query.ts", () => realEmbed);
});

const { embedMultimodalContentTool } = await import("../../src/lib/base-tools.ts");

beforeEach(() => {
  queryCalls = [];
  documentCalls = [];
});

async function invoke(input: unknown) {
  const t = embedMultimodalContentTool as unknown as {
    invoke?: (i: unknown) => Promise<unknown>;
  };
  if (typeof t.invoke !== "function") {
    throw new Error("embedMultimodalContentTool does not expose .invoke");
  }
  return t.invoke(input);
}

describe("embed_multimodal_content — accepts canonical multimodal shapes", () => {
  test("nested-array text-only input routes to embedDocumentText by default", async () => {
    documentImpl = async () => ({
      ok: true,
      source: "voyage",
      modelId: "voyage-multimodal-3",
      vector: [0.1, 0.2, 0.3],
    });

    const r = (await invoke({
      inputs: [[{ type: "text", text: "hello world" }]],
    })) as Record<string, unknown>;

    expect(documentCalls.length).toBe(1);
    expect(queryCalls.length).toBe(0);
    expect(r).toMatchObject({
      status: "ok",
      dimensions: 3,
      model: "voyage-multimodal-3",
      source: "voyage",
      textBlocks: 1,
      imageBlocks: 0,
    });
    expect(Array.isArray((r as { embeddings?: unknown }).embeddings)).toBe(true);
  });

  test("inputType=query routes to embedQueryText only", async () => {
    queryImpl = async () => ({
      ok: true,
      source: "voyage",
      modelId: "voyage-multimodal-3",
      vector: [1, 2],
    });

    await invoke({
      inputs: [[{ type: "text", text: "find me" }]],
      inputType: "query",
    });
    expect(queryCalls.length).toBe(1);
    expect(documentCalls.length).toBe(0);
  });

  test("counts image segments correctly (image_url + image_base64)", async () => {
    documentImpl = async () => ({
      ok: true,
      source: "voyage",
      modelId: "voyage-multimodal-3",
      vector: [0, 1, 2, 3],
    });

    const r = (await invoke({
      inputs: [
        [
          { type: "text", text: "describe" },
          { type: "image_url", image_url: "https://example.com/a.jpg" },
          {
            type: "image_base64",
            image_base64:
              "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=",
          },
        ],
      ],
    })) as Record<string, unknown>;

    expect(r).toMatchObject({ status: "ok", textBlocks: 1, imageBlocks: 2 });
  });
});

describe("embed_multimodal_content — rejects degenerate shapes", () => {
  test("flat string[] is rejected by Strands' zod tool-input validation", async () => {
    documentImpl = async () => ({
      ok: true,
      source: "voyage",
      modelId: "voyage-multimodal-3",
      vector: [1],
    });

    let threw = false;
    try {
      await invoke({ inputs: ["hello"] });
    } catch {
      threw = true;
    }
    expect(threw).toBe(true);
    expect(documentCalls.length).toBe(0);
  });

  test("bare base64 (missing data:image header) is rejected at tool-input validation", async () => {
    documentImpl = async () => ({
      ok: true,
      source: "voyage",
      modelId: "voyage-multimodal-3",
      vector: [1],
    });

    let threw = false;
    try {
      await invoke({
        inputs: [[{ type: "image_base64", image_base64: "iVBORw0KGgoAAAANSUhEU" }]],
      });
    } catch {
      threw = true;
    }
    expect(threw).toBe(true);
    expect(documentCalls.length).toBe(0);
  });

  test("empty inputs[] is rejected at tool-input validation", async () => {
    let threw = false;
    try {
      await invoke({ inputs: [] });
    } catch {
      threw = true;
    }
    expect(threw).toBe(true);
  });
});

describe("embed_multimodal_content — strict failure surfacing", () => {
  test("per-item failure stops the loop and surfaces { status:'error', code, message }", async () => {
    documentImpl = async () => ({
      ok: false,
      code: "voyage_strict_failed",
      message: "SageMaker 503",
    });

    const r = (await invoke({
      inputs: [
        [{ type: "text", text: "a" }],
        [{ type: "text", text: "b" }],
      ],
    })) as Record<string, unknown>;

    expect(r).toMatchObject({
      status: "error",
      code: "voyage_strict_failed",
      message: "SageMaker 503",
      textBlocks: 2,
      imageBlocks: 0,
      failedInputIndex: 0,
    });
    // Critical: no second attempt after the first failure.
    expect(documentCalls.length).toBe(1);
  });

  test("titan_no_multimodal propagates without retrying", async () => {
    documentImpl = async () => ({
      ok: false,
      code: "titan_no_multimodal",
      message: "titan is text-only",
    });

    const r = (await invoke({
      inputs: [
        [
          { type: "text", text: "describe" },
          { type: "image_url", image_url: "https://example.com/a.jpg" },
        ],
      ],
    })) as Record<string, unknown>;

    expect(r).toMatchObject({
      status: "error",
      code: "titan_no_multimodal",
      textBlocks: 1,
      imageBlocks: 1,
    });
  });
});
