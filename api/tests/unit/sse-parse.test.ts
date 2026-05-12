import { describe, expect, test } from "bun:test";
import { parseSseResponse, tokensFromSse } from "../helpers/sse-parse.ts";

describe("sse-parse", () => {
  test("tokensFromSse concatenates token event payloads", () => {
    const body = [
      "event: agent_info",
      'data: {"agentId":"x","agentName":"X"}',
      "",
      "event: token",
      'data: {"text":"Hello "}',
      "",
      "event: token",
      'data: {"text":"world"}',
      "",
    ].join("\n");
    expect(tokensFromSse(body)).toBe("Hello world");
  });

  test("parseSseResponse preserves event names", () => {
    const body = "event: handoff\ndata: {\"from\":\"a\",\"to\":\"b\"}\n\n";
    const ev = parseSseResponse(body);
    expect(ev.some((e) => e.event === "handoff" && e.data.includes("a"))).toBe(true);
  });
});
