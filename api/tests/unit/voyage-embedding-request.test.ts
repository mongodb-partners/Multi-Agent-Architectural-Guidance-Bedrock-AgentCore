import { describe, expect, test, afterEach } from "bun:test";
import { buildVoyageRequestBody } from "../../src/adapters/voyage-embedding.ts";

describe("buildVoyageRequestBody", () => {
  const original = process.env.VOYAGE_REQUEST_FORMAT;

  afterEach(() => {
    if (original === undefined) {
      delete process.env.VOYAGE_REQUEST_FORMAT;
    } else {
      process.env.VOYAGE_REQUEST_FORMAT = original;
    }
  });

  test("multimodal format (default) wraps text in the inputs[].content[] envelope", () => {
    const body = JSON.parse(buildVoyageRequestBody("Hello world", "query"));
    expect(body.inputs).toEqual([
      { content: [{ type: "text", text: "Hello world" }] },
    ]);
    expect(body.input_type).toBe("query");
    expect(body.truncation).toBe(true);
    expect(body.output_encoding).toBeNull();
    expect(body.input).toBeUndefined();
    expect(body.output_dimension).toBeUndefined();
  });

  test("multimodal format truncates text at 32K chars", () => {
    const long = "x".repeat(40_000);
    const body = JSON.parse(buildVoyageRequestBody(long, "document", "multimodal"));
    expect(body.inputs[0].content[0].text.length).toBe(32_000);
  });

  test("legacy format uses the voyage-3.5-lite envelope with output_dimension", () => {
    const body = JSON.parse(buildVoyageRequestBody("Hi", "document", "legacy"));
    expect(body.input).toEqual(["Hi"]);
    expect(body.input_type).toBe("document");
    expect(typeof body.output_dimension).toBe("number");
    expect(body.inputs).toBeUndefined();
  });

  test("VOYAGE_REQUEST_FORMAT=legacy switches the default", () => {
    process.env.VOYAGE_REQUEST_FORMAT = "legacy";
    const body = JSON.parse(buildVoyageRequestBody("Hi", "query"));
    expect(body.input).toEqual(["Hi"]);
    expect(body.inputs).toBeUndefined();
  });

  test("unknown VOYAGE_REQUEST_FORMAT value falls back to multimodal", () => {
    process.env.VOYAGE_REQUEST_FORMAT = "rubbish";
    const body = JSON.parse(buildVoyageRequestBody("Hi", "query"));
    expect(body.inputs).toBeDefined();
    expect(body.input).toBeUndefined();
  });
});
