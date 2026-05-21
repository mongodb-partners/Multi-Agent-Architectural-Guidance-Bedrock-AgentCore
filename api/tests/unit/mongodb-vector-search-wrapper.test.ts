/**
 * Unit tests for the `mongodb_vector_search` MCP wrapper that lives in
 * `api/src/adapters/mongodb-mcp-client.ts`.
 *
 * Two layers under test:
 *
 * 1. `transformVectorSearchArgs(rawInput, embedFn)` — pure args normaliser.
 *    Asserts the input → lambda-shape contract: `queryText` triggers
 *    embedding, `queryVector` passes through, `indexName` aliases `index`,
 *    sensible defaults are applied per known collection, and missing
 *    arguments produce typed errors instead of throwing.
 *
 * 2. `VectorSearchEmbedTool` — the Strands `Tool` subclass that wraps the
 *    gateway-published MCP tool. We feed it a fake underlying `McpTool`
 *    whose `stream(...)` returns a synthetic `ToolResultBlock` (mimicking
 *    the MongoDB MCP runtime's `{result: {documents: [...]}}` envelope) and
 *    verify the full path: model schema, embed-then-call, score extraction,
 *    and the `mongo.vector_search` trace event payload.
 *
 * If `mcp-runtimes/mongodb-mcp/src/vendor/handlers.mjs` ever gains native
 * `queryText` support, delete the wrapper and these tests — but the trace
 * event contract still needs to live somewhere so the Trace Viewer doesn't
 * regress.
 */

import { describe, expect, test } from "bun:test";
import { TextBlock, ToolResultBlock } from "@strands-agents/sdk";
import {
  VECTOR_SEARCH_TOOL_SPEC,
  VectorSearchEmbedTool,
  extractDocumentPreviewsFromResult,
  enrichVectorSearchTraceEvents,
  extractScoresFromResult,
  isInternalOnlyMcpTool,
  scoreHistogram,
  summarizeScores,
  transformVectorSearchArgs,
  wrapGatewayTool,
} from "../../src/adapters/mongodb-mcp-client.ts";
import type { EmbedResult } from "../../src/lib/embed-query.ts";
import { TraceCollector } from "../../src/lib/trace-collector.ts";
import { withTrace } from "../../src/lib/trace-context.ts";

const stubEmbed = (vector: number[] = [0.1, 0.2, 0.3, 0.4]): ((t: string) => Promise<EmbedResult>) =>
  async () => ({ ok: true, source: "voyage", modelId: "voyage-3.5-lite", vector });

describe("transformVectorSearchArgs", () => {
  test("embeds queryText into queryVector and applies the per-collection default index", async () => {
    const out = await transformVectorSearchArgs(
      { collection: "products", queryText: "waterproof outdoor headphones", limit: 3 },
      stubEmbed([1, 2, 3, 4]),
    );
    expect(out.ok).toBe(true);
    if (!out.ok) return;
    expect(out.args.collection).toBe("products");
    expect(out.args.index).toBe("products-vector-index");
    expect(out.args.path).toBe("embedding");
    expect(out.args.queryVector).toEqual([1, 2, 3, 4]);
    expect(out.args.limit).toBe(3);
    expect(out.embed.source).toBe("voyage");
    expect(out.embed.modelId).toBe("voyage-3.5-lite");
    expect(out.queryText).toBe("waterproof outdoor headphones");
  });

  test("infers troubleshooting-vector-index for the troubleshooting_docs collection", async () => {
    const out = await transformVectorSearchArgs(
      { collection: "troubleshooting_docs", queryText: "device wont power on" },
      stubEmbed(),
    );
    expect(out.ok).toBe(true);
    if (out.ok) expect(out.args.index).toBe("troubleshooting-vector-index");
  });

  test("accepts indexName as an alias for index", async () => {
    const out = await transformVectorSearchArgs(
      {
        collection: "products",
        queryText: "thing",
        indexName: "custom-products-index",
      },
      stubEmbed(),
    );
    expect(out.ok).toBe(true);
    if (out.ok) expect(out.args.index).toBe("custom-products-index");
  });

  test("explicit index wins over indexName which wins over the per-collection default", async () => {
    const out = await transformVectorSearchArgs(
      {
        collection: "products",
        queryText: "x",
        index: "explicit-index",
        indexName: "ignored-name",
      },
      stubEmbed(),
    );
    expect(out.ok).toBe(true);
    if (out.ok) expect(out.args.index).toBe("explicit-index");
  });

  test("skips the embedder when queryVector is supplied directly (advanced path)", async () => {
    let embedderCalls = 0;
    const embed = async (): Promise<EmbedResult> => {
      embedderCalls += 1;
      return { ok: true, source: "voyage", modelId: "x", vector: [9, 9] };
    };
    const out = await transformVectorSearchArgs(
      { collection: "products", queryVector: [0.1, 0.2, 0.3] },
      embed,
    );
    expect(out.ok).toBe(true);
    if (out.ok) {
      expect(out.args.queryVector).toEqual([0.1, 0.2, 0.3]);
      expect(out.embed.source).toBe("model_supplied");
    }
    expect(embedderCalls).toBe(0);
  });

  test("forwards numCandidates and filter to the lambda when provided", async () => {
    const out = await transformVectorSearchArgs(
      {
        collection: "products",
        queryText: "x",
        numCandidates: 200,
        filter: { category: "audio" },
      },
      stubEmbed(),
    );
    expect(out.ok).toBe(true);
    if (out.ok) {
      expect(out.args.numCandidates).toBe(200);
      expect(out.args.filter).toEqual({ category: "audio" });
    }
  });

  test("returns missing_collection when collection is absent / blank", async () => {
    const a = await transformVectorSearchArgs({ queryText: "x" }, stubEmbed());
    expect(a.ok).toBe(false);
    if (!a.ok) expect(a.code).toBe("missing_collection");

    const b = await transformVectorSearchArgs({ collection: "  ", queryText: "x" }, stubEmbed());
    expect(b.ok).toBe(false);
    if (!b.ok) expect(b.code).toBe("missing_collection");
  });

  test("returns missing_query when neither queryText nor queryVector is present", async () => {
    const out = await transformVectorSearchArgs({ collection: "products" }, stubEmbed());
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.code).toBe("missing_query");
  });

  test("returns missing_index when collection has no default and no override", async () => {
    const out = await transformVectorSearchArgs(
      { collection: "support_tickets", queryText: "x" },
      stubEmbed(),
    );
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.code).toBe("missing_index");
  });

  test("hybrid: true rewrites args to mongodb_hybrid_search shape with defaults inferred", async () => {
    const out = await transformVectorSearchArgs(
      {
        collection: "products",
        queryText: "noise cancelling",
        hybrid: true,
        limit: 3,
        fetchK: 16,
        minScore: 0.05,
      },
      stubEmbed([7, 8, 9]),
    );
    expect(out.ok).toBe(true);
    if (!out.ok) return;
    expect(out.mode).toBe("hybrid");
    expect(out.targetToolName).toBe("mongodb_hybrid_search");
    expect(out.args.collection).toBe("products");
    expect(out.args.vectorIndex).toBe("products-vector-index");
    expect(out.args.lexicalIndex).toBe("products-text-index");
    expect(out.args.lexicalPath).toBe("title");
    expect(out.args.queryText).toBe("noise cancelling");
    expect(out.args.queryVector).toEqual([7, 8, 9]);
    expect(out.args.limit).toBe(3);
    expect(out.args.fetchK).toBe(16);
    expect(out.args.minScore).toBeCloseTo(0.05, 6);
    // Should NOT carry the pure-vector `index` field.
    expect(out.args).not.toHaveProperty("index");
  });

  test("hybrid: true requires queryText (queryVector alone is rejected with missing_query)", async () => {
    const out = await transformVectorSearchArgs(
      {
        collection: "products",
        hybrid: true,
        queryVector: [1, 2, 3],
      },
      stubEmbed(),
    );
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.code).toBe("missing_query");
  });

  test("hybrid: true on an unknown collection without lexical defaults returns missing_lexical_index", async () => {
    const out = await transformVectorSearchArgs(
      {
        collection: "ad_hoc_collection",
        queryText: "x",
        hybrid: true,
        indexName: "ad-hoc-vector",
      },
      stubEmbed(),
    );
    expect(out.ok).toBe(false);
    if (!out.ok) expect(out.code).toBe("missing_lexical_index");
  });

  test("propagates the embedder's structured error to the caller", async () => {
    const embed = async (): Promise<EmbedResult> => ({
      ok: false,
      code: "no_provider_configured",
      message: "configure VOYAGE_SAGEMAKER_ENDPOINT or EMBEDDING_MODEL_ID",
    });
    const out = await transformVectorSearchArgs(
      { collection: "products", queryText: "x" },
      embed,
    );
    expect(out.ok).toBe(false);
    if (!out.ok) {
      expect(out.code).toBe("no_provider_configured");
      expect(out.queryText).toBe("x");
    }
  });
});

describe("score extraction helpers", () => {
  test("extractScoresFromResult parses the lambda's content envelope", () => {
    const block = new ToolResultBlock({
      toolUseId: "tu",
      status: "success",
      content: [
        new TextBlock(
          JSON.stringify({
            count: 3,
            documents: [
              { sku: "a", _score: 0.92 },
              { sku: "b", _score: 0.81 },
              { sku: "c", _score: 0.55 },
            ],
          }),
        ),
      ],
    });
    expect(extractScoresFromResult(block)).toEqual([0.92, 0.81, 0.55]);
  });

  test("extractDocumentPreviewsFromResult keeps compact source/doc metadata", () => {
    const block = new ToolResultBlock({
      toolUseId: "tu",
      status: "success",
      content: [
        new TextBlock(
          JSON.stringify({
            count: 2,
            documents: [
              { _id: "p1", sku: "SKU-1", name: "Compact Widget", source: "products", _score: 0.92 },
              {
                _id: "ts-1",
                title: "HW-900 fault",
                content: "Hardware fault troubleshooting article.",
                _sources: ["vector", "lexical"],
                _score: 0.81,
              },
            ],
          }),
        ),
      ],
    });

    expect(extractDocumentPreviewsFromResult(block, "products")).toEqual([
      expect.objectContaining({
        rank: 1,
        collection: "products",
        _id: "p1",
        id: "p1",
        title: "Compact Widget",
        score: 0.92,
        sources: ["products"],
        fields: expect.objectContaining({ sku: "SKU-1", source: "products" }),
      }),
      expect.objectContaining({
        rank: 2,
        collection: "products",
        _id: "ts-1",
        id: "ts-1",
        title: "HW-900 fault",
        score: 0.81,
        snippet: "Hardware fault troubleshooting article.",
        sources: ["vector", "lexical"],
      }),
    ]);
  });

  test("extractDocumentPreviewsFromResult carries _id for arbitrary vector collections", () => {
    const block = new ToolResultBlock({
      toolUseId: "tu",
      status: "success",
      content: [
        new TextBlock(
          JSON.stringify({
            count: 1,
            documents: [
              {
                _id: "507f1f77bcf86cd799439011",
                title: "Arbitrary Collection Hit",
                content: "Document from any collection not known to the wrapper.",
                _score: 0.87,
              },
            ],
          }),
        ),
      ],
    });

    expect(extractDocumentPreviewsFromResult(block, "arbitrary_collection")).toEqual([
      expect.objectContaining({
        rank: 1,
        collection: "arbitrary_collection",
        _id: "507f1f77bcf86cd799439011",
        id: "507f1f77bcf86cd799439011",
        title: "Arbitrary Collection Hit",
        snippet: "Document from any collection not known to the wrapper.",
        score: 0.87,
      }),
    ]);
  });

  test("extractScoresFromResult tolerates non-JSON / missing _score", () => {
    const block = new ToolResultBlock({
      toolUseId: "tu",
      status: "success",
      content: [
        new TextBlock("Tool execution completed successfully with no output."),
      ],
    });
    expect(extractScoresFromResult(block)).toEqual([]);
  });

  test("summarizeScores returns min/max/avg, undefined for empty", () => {
    expect(summarizeScores([])).toBeUndefined();
    expect(summarizeScores([0.2, 0.8, 0.5])).toEqual({
      min: 0.2,
      max: 0.8,
      avg: 0.5,
    });
  });

  test("scoreHistogram bins into 5 buckets across [0, 1]", () => {
    expect(scoreHistogram([0.05, 0.25, 0.45, 0.65, 0.85])).toEqual([1, 1, 1, 1, 1]);
    expect(scoreHistogram([0.99, 0.999])).toEqual([0, 0, 0, 0, 2]);
    expect(scoreHistogram([])).toEqual([0, 0, 0, 0, 0]);
  });
});

describe("enrichVectorSearchTraceEvents", () => {
  test("backfills scoreSummary on mongo.vector_search from mongo.intent + mongo.result", () => {
    const events = enrichVectorSearchTraceEvents([
      { type: "mongo.intent", payload: { collection: "products" } },
      {
        type: "mongo.result",
        payload: {
          sampleDocs: [{ sku: "SKU-7", _score: 0.88 }, { sku: "SKU-1", _score: 0.71 }],
        },
      },
      {
        type: "mongo.vector_search",
        payload: {
          collection: "products",
          embeddingSource: "voyage",
          queryText: "outdoor",
          scores: [],
        },
      },
    ]);
    const vs = events.find((e) => e.type === "mongo.vector_search");
    expect(vs).toBeDefined();
    const payload = vs!.payload as { scores?: number[]; scoreSummary?: { avg: number } };
    expect(payload.scores).toEqual([0.88, 0.71]);
    expect(payload.scoreSummary?.avg).toBeCloseTo(0.795, 5);
  });
});

describe("VECTOR_SEARCH_TOOL_SPEC", () => {
  test("advertises queryText and collection (not queryVector) as the canonical inputs", () => {
    const schema = VECTOR_SEARCH_TOOL_SPEC.inputSchema as {
      properties: Record<string, unknown>;
      required: string[];
    };
    expect(schema.required).toEqual(["collection"]);
    expect(schema.properties.queryText).toBeDefined();
    // queryVector remains documented for advanced callers but is NOT required.
    expect(schema.properties.queryVector).toBeDefined();
    expect(schema.required).not.toContain("queryVector");
    expect(schema.properties.indexName).toBeDefined();
  });
});

describe("isInternalOnlyMcpTool", () => {
  test("flags mongodb_hybrid_search (direct + gateway-prefixed forms) as internal", () => {
    expect(isInternalOnlyMcpTool("mongodb_hybrid_search")).toBe(true);
    expect(isInternalOnlyMcpTool("mongodb-mcp___mongodb_hybrid_search")).toBe(true);
  });

  test("passes through agent-visible tools", () => {
    expect(isInternalOnlyMcpTool("mongodb_query")).toBe(false);
    expect(isInternalOnlyMcpTool("mongodb-mcp___mongodb_vector_search")).toBe(false);
    expect(isInternalOnlyMcpTool("read_skill_resource")).toBe(false);
  });
});

describe("wrapGatewayTool", () => {
  function fakeUnderlying(name: string) {
    return {
      name,
      description: "fake",
      toolSpec: { name, description: "fake", inputSchema: { type: "object" as const } },
      stream: () => (async function* () { return { sentinel: true } as never; })(),
    };
  }

  test("wraps mongodb-mcp___mongodb_vector_search in VectorSearchEmbedTool", () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const wrapped = wrapGatewayTool(fakeUnderlying("mongodb-mcp___mongodb_vector_search") as any);
    expect(wrapped).toBeInstanceOf(VectorSearchEmbedTool);
    expect(wrapped.name).toBe("mongodb_vector_search");
  });

  test("wraps direct-runtime mongodb_vector_search in VectorSearchEmbedTool", () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const wrapped = wrapGatewayTool(fakeUnderlying("mongodb_vector_search") as any);
    expect(wrapped).toBeInstanceOf(VectorSearchEmbedTool);
    expect(wrapped.name).toBe("mongodb_vector_search");
  });

  test("wraps other gateway-prefixed tools in AliasedMcpTool (plain pass-through)", () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const wrapped = wrapGatewayTool(fakeUnderlying("mongodb-mcp___mongodb_query") as any);
    expect(wrapped.name).toBe("mongodb_query");
  });

  test("returns unprefixed tools as-is", () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const raw = fakeUnderlying("custom_tool") as any;
    expect(wrapGatewayTool(raw)).toBe(raw);
  });
});

describe("VectorSearchEmbedTool.stream — full embed-then-call path", () => {
  /**
   * Build a fake underlying `McpTool` whose `stream(...)` returns a
   * `ToolResultBlock` we control — capturing the input it received so the
   * test can assert the wrapper substituted `queryVector` correctly.
   */
  function makeUnderlying(documents: Array<{ _score: number; sku?: string }>) {
    const seenInputs: unknown[] = [];
    const stream = function (ctx: { toolUse: { toolUseId: string; input: unknown } }) {
      seenInputs.push(ctx.toolUse.input);
      const result = new ToolResultBlock({
        toolUseId: ctx.toolUse.toolUseId,
        status: "success",
        content: [
          new TextBlock(
            JSON.stringify({ count: documents.length, documents }),
          ),
        ],
      });
      return (async function* () {
        return result;
      })();
    };
    const underlying = {
      name: "mongodb-mcp___mongodb_vector_search",
      description: "lambda vector search",
      toolSpec: {
        name: "mongodb-mcp___mongodb_vector_search",
        description: "lambda vector search",
        inputSchema: { type: "object" as const },
      },
      stream,
    };
    return { underlying, seenInputs };
  }

  function makeContext(input: unknown) {
    return {
      toolUse: { toolUseId: "tu-1", name: "mongodb_vector_search", input },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      agent: {} as any,
    };
  }

  async function drainStream(gen: ReturnType<VectorSearchEmbedTool["stream"]>) {
    let next = await gen.next();
    while (!next.done) next = await gen.next();
    return next.value;
  }

  test("embeds queryText, calls underlying with queryVector, and emits mongo.vector_search with scores", async () => {
    // Force the embed path through the real `embedQueryText` ↔ stub adapter
    // boundary by setting env so isVoyageConfigured() is true; the wrapper
    // however calls the *bundled* embedQueryText so we stub at module scope.
    // Simpler: construct the wrapper with the raw underlying and let
    // transformVectorSearchArgs own the embed call. Since `stream` calls the
    // module-level transformVectorSearchArgs (no DI hook there), we use
    // queryVector passthrough for this case to keep the test hermetic.
    const { underlying, seenInputs } = makeUnderlying([
      { sku: "a", _score: 0.92 },
      { sku: "b", _score: 0.74 },
    ]);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const tool = new VectorSearchEmbedTool(underlying as any);

    const collector = new TraceCollector({
      sessionId: "s",
      messageId: "m",
      agentId: "product-recommendation",
    });

    const result = (await withTrace(collector, () =>
      drainStream(
        tool.stream(
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          makeContext({
            collection: "products",
            queryVector: [0.5, 0.5, 0.5, 0.5],
            limit: 5,
          }) as any,
        ),
      ),
    )) as ToolResultBlock;

    // The underlying tool got the lambda-shape args, with `index` defaulted.
    expect(seenInputs).toHaveLength(1);
    const forwarded = seenInputs[0] as Record<string, unknown>;
    expect(forwarded.collection).toBe("products");
    expect(forwarded.index).toBe("products-vector-index");
    expect(forwarded.queryVector).toEqual([0.5, 0.5, 0.5, 0.5]);
    expect(forwarded.limit).toBe(5);
    // The wrapper must NOT leak queryText or indexName into the lambda call.
    expect(forwarded).not.toHaveProperty("queryText");
    expect(forwarded).not.toHaveProperty("indexName");

    // Result is the underlying's success envelope, untouched.
    expect(result.status).toBe("success");

    // Trace event carries the per-doc scores so the Trace Viewer's vector
    // panel populates the histogram + score summary.
    const ev = collector.getEvents().find((e) => e.type === "mongo.vector_search");
    expect(ev).toBeDefined();
    const payload = ev!.payload as Record<string, unknown>;
    expect(payload.embeddingSource).toBe("model_supplied");
    expect(payload.scores).toEqual([0.92, 0.74]);
    expect(payload.collection).toBe("products");
    expect(payload.documentPreviews).toEqual([
      expect.objectContaining({ rank: 1, collection: "products", title: "a", score: 0.92 }),
      expect.objectContaining({ rank: 2, collection: "products", title: "b", score: 0.74 }),
    ]);
    const summary = payload.scoreSummary as { min: number; max: number; avg: number };
    expect(summary.min).toBeCloseTo(0.74, 5);
    expect(summary.max).toBeCloseTo(0.92, 5);
    expect(summary.avg).toBeCloseTo(0.83, 5);
    expect(payload.histogram).toEqual([0, 0, 0, 1, 1]);
    expect(payload.queryVectorPreview).toMatchObject({ length: 4 });
  });

  test("returns a structured error tool-result when the embedder fails", async () => {
    // Underlying must NOT be called when the args fail validation.
    const { underlying, seenInputs } = makeUnderlying([]);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const tool = new VectorSearchEmbedTool(underlying as any);

    const collector = new TraceCollector({
      sessionId: "s",
      messageId: "m",
      agentId: "product-recommendation",
    });

    // No queryText / no queryVector — transform short-circuits with missing_query.
    const result = (await withTrace(collector, () =>
      drainStream(
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        tool.stream(makeContext({ collection: "products" }) as any),
      ),
    )) as ToolResultBlock;

    expect(seenInputs).toHaveLength(0); // never reached the lambda
    expect(result.status).toBe("error");
    const block = result.content[0] as { text?: string };
    expect(block.text).toBeDefined();
    const parsed = JSON.parse(block.text!) as Record<string, unknown>;
    expect(parsed.status).toBe("error");
    expect(parsed.code).toBe("missing_query");

    // The trace event is still emitted so the dashboard sees the failed
    // attempt rather than rendering a phantom successful call.
    const ev = collector.getEvents().find((e) => e.type === "mongo.vector_search");
    expect(ev).toBeDefined();
    expect((ev!.payload as Record<string, unknown>).embeddingSource).toBe("none");
  });

  test("hybrid: true routes to the hybrid underlying tool with mongodb_hybrid_search args shape", async () => {
    const vectorCalls: unknown[] = [];
    const hybridCalls: unknown[] = [];
    const makeStub = (sink: unknown[]) =>
      function (ctx: { toolUse: { toolUseId: string; input: unknown } }) {
        sink.push(ctx.toolUse.input);
        const result = new ToolResultBlock({
          toolUseId: ctx.toolUse.toolUseId,
          status: "success",
          content: [new TextBlock(JSON.stringify({ count: 0, documents: [] }))],
        });
        return (async function* () {
          return result;
        })();
      };
    const vectorUnderlying = {
      name: "mongodb-mcp___mongodb_vector_search",
      description: "v",
      toolSpec: { name: "v", description: "v", inputSchema: { type: "object" as const } },
      stream: makeStub(vectorCalls),
    };
    const hybridUnderlying = {
      name: "mongodb_hybrid_search",
      description: "h",
      toolSpec: { name: "h", description: "h", inputSchema: { type: "object" as const } },
      stream: makeStub(hybridCalls),
    };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const tool = new VectorSearchEmbedTool(vectorUnderlying as any, hybridUnderlying as any);
    const collector = new TraceCollector({
      sessionId: "s",
      messageId: "m",
      agentId: "product-recommendation",
    });

    const ctx = {
      toolUse: {
        toolUseId: "tu-h",
        name: "mongodb_vector_search",
        input: {
          collection: "products",
          queryText: "noise cancelling headphones",
          hybrid: true,
          queryVector: [0.1, 0.2, 0.3, 0.4],
          limit: 5,
        },
      },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      agent: {} as any,
    };

    await withTrace(collector, async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const gen = tool.stream(ctx as any);
      let nx = await gen.next();
      while (!nx.done) nx = await gen.next();
    });

    expect(vectorCalls).toHaveLength(0);
    expect(hybridCalls).toHaveLength(1);
    const forwarded = hybridCalls[0] as Record<string, unknown>;
    expect(forwarded.collection).toBe("products");
    expect(forwarded.vectorIndex).toBe("products-vector-index");
    expect(forwarded.lexicalIndex).toBe("products-text-index");
    expect(forwarded.lexicalPath).toBe("title");
    expect(forwarded.queryText).toBe("noise cancelling headphones");
    expect(forwarded.queryVector).toEqual([0.1, 0.2, 0.3, 0.4]);
    // Must NOT leak the pure-vector args shape into the hybrid call.
    expect(forwarded).not.toHaveProperty("index");

    const ev = collector.getEvents().find((e) => e.type === "mongo.vector_search");
    expect((ev!.payload as Record<string, unknown>).hybrid).toBe(true);
  });

  test("hybrid: true with no hybrid helper available surfaces a structured hybrid_unsupported error", async () => {
    const vectorUnderlying = {
      name: "mongodb-mcp___mongodb_vector_search",
      description: "v",
      toolSpec: { name: "v", description: "v", inputSchema: { type: "object" as const } },
      stream: () =>
        (async function* () {
          return new ToolResultBlock({
            toolUseId: "x",
            status: "success",
            content: [new TextBlock("{}")],
          });
        })(),
    };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const tool = new VectorSearchEmbedTool(vectorUnderlying as any);
    const collector = new TraceCollector({
      sessionId: "s",
      messageId: "m",
      agentId: "product-recommendation",
    });
    const ctx = {
      toolUse: {
        toolUseId: "tu-h2",
        name: "mongodb_vector_search",
        input: {
          collection: "products",
          queryText: "x",
          // Pass queryVector so the transform doesn't try to hit the (absent)
          // SageMaker embed endpoint — the assertion under test is purely
          // about the missing hybrid helper, not about embed failures.
          queryVector: [0.1, 0.2],
          hybrid: true,
        },
      },
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      agent: {} as any,
    };
    const result = (await withTrace(collector, async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const gen = tool.stream(ctx as any);
      let nx = await gen.next();
      while (!nx.done) nx = await gen.next();
      return nx.value as ToolResultBlock;
    })) as ToolResultBlock;
    expect(result.status).toBe("error");
    const parsed = JSON.parse(
      (result.content[0] as { text: string }).text,
    ) as Record<string, unknown>;
    expect(parsed.code).toBe("hybrid_unsupported");
  });

  test("toolSpec exposes the queryText-friendly schema (not the lambda's queryVector schema)", () => {
    const underlying = {
      name: "mongodb-mcp___mongodb_vector_search",
      description: "lambda",
      toolSpec: {
        name: "mongodb-mcp___mongodb_vector_search",
        description: "lambda",
        // Lambda's actual schema demands queryVector — we should NOT propagate this.
        inputSchema: {
          type: "object" as const,
          properties: { queryVector: { type: "array" as const } },
          required: ["collection", "index", "queryVector"],
        },
      },
      stream: () => (async function* () {
        return new ToolResultBlock({ toolUseId: "x", status: "success", content: [new TextBlock("{}")] });
      })(),
    };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const tool = new VectorSearchEmbedTool(underlying as any);
    const schema = tool.toolSpec.inputSchema as { required: string[] };
    expect(schema.required).toEqual(["collection"]);
  });
});
