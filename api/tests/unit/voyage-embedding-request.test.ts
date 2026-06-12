/**
 * Unit tests for `buildVoyageRequestBody` — the ONE point where the
 * typed `MultimodalItem[]` boundary is unwrapped to the SageMaker
 * container's wire envelope.
 *
 * The legacy `{input:[string], output_dimension}` envelope is gone;
 * there is exactly one shape (`{inputs:[{content:[…]}], …}`). All format
 * / VOYAGE_REQUEST_FORMAT cases have been deleted; new cases cover the
 * multimodal segment types (text, image_url, image_base64), the per-text
 * truncation budget, the base64 header rejection, and the 4 MB body cap.
 */

import { describe, expect, test } from "bun:test";
import {
  buildVoyageRequestBody,
  textToMultimodal,
  multimodalSegmentSchema,
  type MultimodalItem,
} from "../../src/adapters/voyage-embedding.ts";

describe("buildVoyageRequestBody — single multimodal envelope", () => {
  test("text-only input produces the canonical inputs[].content[] envelope", () => {
    const body = JSON.parse(buildVoyageRequestBody([textToMultimodal("Hello world")], "query"));
    expect(body.inputs).toEqual([{ content: [{ type: "text", text: "Hello world" }] }]);
    expect(body.input_type).toBe("query");
    expect(body.truncation).toBe(true);
    expect(body.output_encoding).toBeNull();
    // Legacy fields must NOT appear.
    expect(body.input).toBeUndefined();
    expect(body.output_dimension).toBeUndefined();
  });

  test("text segment is truncated at 32K chars", () => {
    const long = "x".repeat(40_000);
    const body = JSON.parse(buildVoyageRequestBody([textToMultimodal(long)], "document"));
    expect(body.inputs[0].content[0].text.length).toBe(32_000);
  });

  test("image_url segment passes through verbatim", () => {
    const item: MultimodalItem = [
      { type: "text", text: "describe this product" },
      { type: "image_url", image_url: "https://example.com/sku-123.jpg" },
    ];
    const body = JSON.parse(buildVoyageRequestBody([item], "document"));
    expect(body.inputs).toEqual([
      {
        content: [
          { type: "text", text: "describe this product" },
          { type: "image_url", image_url: "https://example.com/sku-123.jpg" },
        ],
      },
    ]);
  });

  test("image_base64 with required header passes through", () => {
    const tinyPng =
      "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=";
    const item: MultimodalItem = [
      { type: "text", text: "alt text" },
      { type: "image_base64", image_base64: tinyPng },
    ];
    const body = JSON.parse(buildVoyageRequestBody([item], "query"));
    expect(body.inputs[0].content[1]).toEqual({ type: "image_base64", image_base64: tinyPng });
  });

  test("bare base64 (no data:image header) is rejected at schema parse", () => {
    expect(() => multimodalSegmentSchema.parse({ type: "image_base64", image_base64: "iVBORw0KGgo" })).toThrow();
  });

  test("invalid HTTPS URL is rejected at schema parse", () => {
    expect(() => multimodalSegmentSchema.parse({ type: "image_url", image_url: "not-a-url" })).toThrow();
  });

  test("batch of multiple items produces multiple inputs", () => {
    const body = JSON.parse(
      buildVoyageRequestBody(
        [textToMultimodal("alpha"), textToMultimodal("beta")],
        "document",
      ),
    );
    expect(body.inputs).toHaveLength(2);
    expect(body.inputs[0].content[0].text).toBe("alpha");
    expect(body.inputs[1].content[0].text).toBe("beta");
  });

  test("4 MB body cap rejects oversized image_base64 payloads with actionable hint", () => {
    // Build a base64 string > 4 MB (5 MB of 'A' chars + header).
    const big = `data:image/png;base64,${"A".repeat(5 * 1024 * 1024)}`;
    expect(() =>
      buildVoyageRequestBody([[{ type: "image_base64", image_base64: big }]], "document"),
    ).toThrow(/voyage_body_too_large/);
  });

  test("rejects empty items array", () => {
    expect(() => buildVoyageRequestBody([], "document")).toThrow(
      /non-empty MultimodalItem/,
    );
  });
});

describe("buildVoyageRequestBody — VOYAGE_OUTPUT_DIM override", () => {
  const saved = {
    dim: process.env.VOYAGE_OUTPUT_DIM,
    model: process.env.VOYAGE_MARKETPLACE_MODEL,
    legacyModel: process.env.VOYAGE_MODEL_NAME,
  };

  function restore() {
    if (saved.dim === undefined) delete process.env.VOYAGE_OUTPUT_DIM;
    else process.env.VOYAGE_OUTPUT_DIM = saved.dim;
    if (saved.model === undefined) delete process.env.VOYAGE_MARKETPLACE_MODEL;
    else process.env.VOYAGE_MARKETPLACE_MODEL = saved.model;
    if (saved.legacyModel === undefined) delete process.env.VOYAGE_MODEL_NAME;
    else process.env.VOYAGE_MODEL_NAME = saved.legacyModel;
  }

  test("default dim (1024) omits output_dimension", () => {
    delete process.env.VOYAGE_OUTPUT_DIM;
    try {
      const body = JSON.parse(buildVoyageRequestBody([textToMultimodal("hi")], "query"));
      expect(body.output_dimension).toBeUndefined();
    } finally {
      restore();
    }
  });

  test("non-default dim on voyage-multimodal-3.5 emits output_dimension", () => {
    process.env.VOYAGE_MARKETPLACE_MODEL = "voyage-multimodal-3.5";
    process.env.VOYAGE_OUTPUT_DIM = "512";
    try {
      const body = JSON.parse(buildVoyageRequestBody([textToMultimodal("hi")], "query"));
      expect(body.output_dimension).toBe(512);
    } finally {
      restore();
    }
  });

  test("non-default dim on voyage-multimodal-3 (1024-only) is rejected", () => {
    process.env.VOYAGE_MARKETPLACE_MODEL = "voyage-multimodal-3";
    process.env.VOYAGE_OUTPUT_DIM = "512";
    try {
      expect(() => buildVoyageRequestBody([textToMultimodal("hi")], "query")).toThrow(
        /voyage-multimodal-3/,
      );
    } finally {
      restore();
    }
  });

  test("unsupported dim value is rejected", () => {
    process.env.VOYAGE_MARKETPLACE_MODEL = "voyage-multimodal-3.5";
    process.env.VOYAGE_OUTPUT_DIM = "999";
    try {
      expect(() => buildVoyageRequestBody([textToMultimodal("hi")], "query")).toThrow(
        /not a supported Voyage output dimension/,
      );
    } finally {
      restore();
    }
  });
});
