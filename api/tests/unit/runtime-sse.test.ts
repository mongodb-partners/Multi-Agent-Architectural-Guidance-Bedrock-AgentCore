/**
 * Unit tests for the AgentCore-runtime ↔ Hono streaming wire format.
 *
 * The parser has to tolerate every edge case Node's HTTP/2 chunking can
 * throw at it: frames split mid-`data:` line, multi-line `data:` payloads,
 * SSE comments, blank events, and trailing partial frames. If any of those
 * mis-parse, we either lose tokens silently or crash the chat route.
 */

import { describe, expect, test } from "bun:test";
import {
  formatSseFrame,
  parseRuntimeSseStream,
  type RuntimeStreamEvent,
} from "../../src/lib/runtime-sse.ts";

function bytes(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

async function* fromChunks(chunks: string[]): AsyncGenerator<Uint8Array> {
  for (const c of chunks) yield bytes(c);
}

async function collect(source: AsyncIterable<Uint8Array>): Promise<RuntimeStreamEvent[]> {
  const out: RuntimeStreamEvent[] = [];
  for await (const ev of parseRuntimeSseStream(source)) out.push(ev);
  return out;
}

describe("runtime-sse: formatSseFrame", () => {
  test("serializes object data as JSON with trailing \\n\\n", () => {
    const frame = formatSseFrame("stream", { type: "token", text: "hi" });
    expect(frame).toBe(`event: stream\ndata: {"type":"token","text":"hi"}\n\n`);
  });

  test("passes through pre-stringified data", () => {
    const frame = formatSseFrame("done", "{}");
    expect(frame).toBe("event: done\ndata: {}\n\n");
  });

  test("done frame parses back to RuntimeStreamEvent", async () => {
    const out = await collect(fromChunks([formatSseFrame("done", { agentId: "x" })]));
    expect(out).toHaveLength(1);
    expect(out[0]).toEqual({ kind: "done", payload: { agentId: "x" } });
  });
});

describe("runtime-sse: parseRuntimeSseStream", () => {
  test("parses a sequence of stream + trace + done frames", async () => {
    const wire =
      formatSseFrame("stream", { type: "token", text: "Hello " }) +
      formatSseFrame("stream", { type: "token", text: "world" }) +
      formatSseFrame("trace", { id: "t1", type: "model.usage", ts: 1, payload: { modelId: "m", inputTokens: 1, outputTokens: 1, totalTokens: 2 } }) +
      formatSseFrame("done", { agentId: "spec", nestedEventsDropped: 0 });
    const out = await collect(fromChunks([wire]));
    expect(out.map((e) => e.kind)).toEqual(["stream", "stream", "trace", "done"]);
    expect((out[0] as { kind: "stream"; part: { text: string } }).part.text).toBe("Hello ");
    expect((out[3] as { kind: "done"; payload: { agentId: string } }).payload.agentId).toBe("spec");
  });

  test("tolerates frames split across arbitrary chunk boundaries", async () => {
    const wire =
      formatSseFrame("stream", { type: "token", text: "abc" }) +
      formatSseFrame("done", { agentId: "x" });
    // Split into 5-byte chunks so frames cross multiple boundaries.
    const chunks: string[] = [];
    for (let i = 0; i < wire.length; i += 5) chunks.push(wire.slice(i, i + 5));
    const out = await collect(fromChunks(chunks));
    expect(out).toHaveLength(2);
    expect(out[0].kind).toBe("stream");
    expect(out[1].kind).toBe("done");
  });

  test("handles multi-line data: payloads (joined with \\n)", async () => {
    // Per SSE spec, multiple `data:` lines in one frame join with \n.
    const block = "event: stream\ndata: {\"type\":\"token\",\ndata: \"text\":\"a\\nb\"}\n\n";
    const out = await collect(fromChunks([block]));
    expect(out).toHaveLength(1);
    const part = (out[0] as { kind: "stream"; part: { text: string } }).part;
    expect(part.text).toBe("a\nb");
  });

  test("ignores SSE comments and unknown event names", async () => {
    const wire =
      ":heartbeat\n\n" +
      formatSseFrame("unknown_event", { foo: "bar" }) +
      formatSseFrame("done", { agentId: "x" });
    const out = await collect(fromChunks([wire]));
    expect(out).toHaveLength(1);
    expect(out[0].kind).toBe("done");
  });

  test("skips frames with malformed JSON in data line", async () => {
    const wire =
      "event: stream\ndata: {not valid json\n\n" +
      formatSseFrame("done", { agentId: "x" });
    const out = await collect(fromChunks([wire]));
    expect(out).toHaveLength(1);
    expect(out[0].kind).toBe("done");
  });

  test("flushes trailing partial frame without \\n\\n terminator", async () => {
    // AgentCore may close the connection mid-frame; we still want the buffered
    // bytes parsed when valid (some upstreams omit the final blank line).
    const tail = "event: done\ndata: {\"agentId\":\"tail\"}";
    const out = await collect(fromChunks([tail]));
    expect(out).toHaveLength(1);
    expect((out[0] as { kind: "done"; payload: { agentId: string } }).payload.agentId).toBe("tail");
  });
});
