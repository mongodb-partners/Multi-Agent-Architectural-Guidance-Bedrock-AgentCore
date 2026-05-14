import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

// ---------------------------------------------------------------------------
// Mock the Bedrock Runtime client BEFORE importing the module under test, so
// the extractor never reaches AWS.
//
// `mock.module(...)` is process-global in Bun, so the mock factory must
// preserve every other export from the real package (otherwise unrelated
// test files that load the SDK after this mock installs will explode with
// `Export named 'VideoFormat' not found in module ...`).
// ---------------------------------------------------------------------------

const realBedrockRuntime = await import("@aws-sdk/client-bedrock-runtime");

let mockSend: ReturnType<typeof mock> = mock(async () => ({}));

mock.module("@aws-sdk/client-bedrock-runtime", () => ({
  ...realBedrockRuntime,
  BedrockRuntimeClient: class {
    send(...args: unknown[]) {
      return mockSend(...args);
    }
  },
  ConverseCommand: class {
    input: unknown;
    constructor(input: unknown) {
      this.input = input;
    }
  },
}));

const {
  extractFactsWithLlm,
  resetLlmFactExtractorClientForTests,
} = await import("../../src/lib/llm-fact-extractor.ts");

function toolUseResponse(input: unknown, opts: { name?: string } = {}): unknown {
  return {
    output: {
      message: {
        role: "assistant",
        content: [
          {
            toolUse: {
              toolUseId: "tu-1",
              name: opts.name ?? "record_facts",
              input,
            },
          },
        ],
      },
    },
    usage: { inputTokens: 42, outputTokens: 17 },
  };
}

describe("extractFactsWithLlm", () => {
  beforeEach(() => {
    resetLlmFactExtractorClientForTests();
    mockSend = mock(async () => ({}));
  });

  afterEach(() => {
    delete process.env.MEMORY_EXTRACTION_MODEL_ID;
    delete process.env.MEMORY_EXTRACTION_MAX_FACTS;
  });

  test("maps a tool reply into accepted + considered with category and note", async () => {
    mockSend = mock(async () =>
      toolUseResponse({
        facts: [
          {
            text: "my email is alice@example.com",
            category: "contact",
            reason: "user-provided email address",
          },
          {
            text: "I drive a 2019 Honda Civic",
            category: "device",
            reason: "vehicle owned",
          },
        ],
        ignored: [{ text: "hi there", reason: "greeting" }],
      }),
    );

    const result = await extractFactsWithLlm(
      "hi there, my email is alice@example.com and I drive a 2019 Honda Civic",
    );

    expect(result.accepted).toEqual([
      "my email is alice@example.com",
      "I drive a 2019 Honda Civic",
    ]);
    expect(result.modelId).toContain("claude");
    expect(result.inputTokens).toBe(42);
    expect(result.outputTokens).toBe(17);

    const accepted = result.considered.filter((c) => c.matched);
    expect(accepted).toHaveLength(2);
    expect(accepted[0].category).toBe("contact");
    expect(accepted[0].note).toBe("user-provided email address");
    expect(accepted[0].matchedPatterns).toEqual(["contact"]);
    expect(accepted[1].category).toBe("device");

    const ignored = result.considered.filter((c) => !c.matched);
    expect(ignored).toHaveLength(1);
    expect(ignored[0].rejectedReason).toBe("llm_rejected");
    expect(ignored[0].text).toBe("hi there");
    expect(ignored[0].note).toBe("greeting");
  });

  test("dedupes accepted facts emitted twice by the model", async () => {
    mockSend = mock(async () =>
      toolUseResponse({
        facts: [
          { text: "my email is alice@example.com", category: "contact" },
          { text: "my email is alice@example.com", category: "contact" },
        ],
      }),
    );

    const result = await extractFactsWithLlm("my email is alice@example.com");
    expect(result.accepted).toEqual(["my email is alice@example.com"]);
    const dup = result.considered.find((c) => c.rejectedReason === "duplicate");
    expect(dup).toBeDefined();
  });

  test("drops facts that violate the length window", async () => {
    mockSend = mock(async () =>
      toolUseResponse({
        facts: [
          { text: "abc", category: "preference" },
          { text: "x".repeat(250), category: "preference" },
          { text: "I prefer dark mode", category: "preference" },
        ],
      }),
    );

    const result = await extractFactsWithLlm("anything");
    expect(result.accepted).toEqual(["I prefer dark mode"]);
    const tooShort = result.considered.find((c) => c.rejectedReason === "too_short");
    const tooLong = result.considered.find((c) => c.rejectedReason === "too_long");
    expect(tooShort).toBeDefined();
    expect(tooLong).toBeDefined();
  });

  test("respects MEMORY_EXTRACTION_MAX_FACTS env cap", async () => {
    process.env.MEMORY_EXTRACTION_MAX_FACTS = "2";
    mockSend = mock(async () =>
      toolUseResponse({
        facts: [
          { text: "I prefer fact one", category: "preference" },
          { text: "I prefer fact two", category: "preference" },
          { text: "I prefer fact three", category: "preference" },
        ],
      }),
    );

    const result = await extractFactsWithLlm("anything");
    expect(result.accepted).toHaveLength(2);
  });

  test("uses MEMORY_EXTRACTION_MODEL_ID when set", async () => {
    process.env.MEMORY_EXTRACTION_MODEL_ID = "anthropic.fake-model-v1";
    mockSend = mock(async () => toolUseResponse({ facts: [] }));

    const result = await extractFactsWithLlm("hello");
    expect(result.modelId).toBe("anthropic.fake-model-v1");
  });

  test("throws when the model returns no record_facts tool use", async () => {
    mockSend = mock(async () => ({
      output: {
        message: { role: "assistant", content: [{ text: "I refuse." }] },
      },
    }));

    await expect(extractFactsWithLlm("hello")).rejects.toThrow(/record_facts/);
  });

  test("propagates Bedrock client errors so the caller can skip the write", async () => {
    mockSend = mock(async () => {
      throw new Error("AccessDeniedException");
    });

    await expect(extractFactsWithLlm("hello")).rejects.toThrow("AccessDeniedException");
  });
});
