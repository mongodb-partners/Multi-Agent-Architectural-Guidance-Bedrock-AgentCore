/**
 * Wire format for AgentCore runtime ↔ Hono API streaming.
 *
 * Each AgentCore Runtime invocation now responds with `text/event-stream`
 * instead of a single `application/json` body. The runtime container writes
 * one of three SSE event types per frame:
 *
 *   event: stream    data: <ChatStreamPart JSON>
 *   event: trace     data: <TraceEvent JSON>
 *   event: done      data: <RuntimeDonePayload JSON>   (always last; exactly one)
 *
 * The Hono `chat` route forwards `stream` parts to the client SSE channel
 * (token / handoff / agent_active / etc), forwards `trace` events to the UI
 * for live display, accumulates them, and on `done` splices the accumulated
 * trace events into the parent collector via `attachEventsNested(...)`.
 */

import type { ChatStreamPart } from "./chat-stream-types.ts";
import type { TraceEvent } from "./trace-types.ts";

export type RuntimeDonePayload = {
  agentId?: string;
  handoffs?: string[];
  /** Nested trace id created by the runtime collector (for cross-referencing). */
  nestedTraceId?: string;
  /** How many trace events the runtime had to drop under its byte cap. */
  nestedEventsDropped?: number;
  /** Terminal error if the runtime failed mid-stream. */
  error?: { code: string; message: string };
};

export type RuntimeStreamEvent =
  | { kind: "stream"; part: ChatStreamPart }
  | { kind: "trace"; event: TraceEvent }
  | { kind: "done"; payload: RuntimeDonePayload };

/**
 * Serialize one SSE frame. Includes the trailing `\n\n` terminator. Exported
 * for the runtime container so it can write directly to the http response
 * without pulling in Hono's stream abstraction.
 */
export function formatSseFrame(event: string, data: unknown): string {
  const json = typeof data === "string" ? data : JSON.stringify(data);
  return `event: ${event}\ndata: ${json}\n\n`;
}

/**
 * Async generator that parses an SSE byte stream into `RuntimeStreamEvent`s.
 * Tolerates frames split across chunks. Unknown event names are ignored so
 * future runtime versions can add fields without breaking older clients.
 */
export async function* parseRuntimeSseStream(
  source: AsyncIterable<Uint8Array>,
): AsyncGenerator<RuntimeStreamEvent> {
  const decoder = new TextDecoder();
  let buf = "";
  for await (const chunk of source) {
    buf += decoder.decode(chunk, { stream: true });
    let idx: number;
    while ((idx = buf.indexOf("\n\n")) !== -1) {
      const block = buf.slice(0, idx);
      buf = buf.slice(idx + 2);
      const parsed = parseFrame(block);
      if (parsed) yield parsed;
    }
  }
  // Flush any final partial frame (rare; AgentCore terminates with \n\n).
  buf += decoder.decode();
  if (buf.trim()) {
    const parsed = parseFrame(buf);
    if (parsed) yield parsed;
  }
}

function parseFrame(block: string): RuntimeStreamEvent | null {
  let event = "message";
  const dataLines: string[] = [];
  for (const line of block.split("\n")) {
    if (!line) continue;
    if (line.startsWith(":")) continue; // comment
    if (line.startsWith("event:")) {
      event = line.slice(6).trim();
    } else if (line.startsWith("data:")) {
      // SSE strips a single leading space after the colon.
      const v = line.slice(5);
      dataLines.push(v.startsWith(" ") ? v.slice(1) : v);
    }
  }
  if (dataLines.length === 0) return null;
  const dataStr = dataLines.join("\n");
  let data: unknown;
  try {
    data = JSON.parse(dataStr);
  } catch {
    return null;
  }
  if (event === "stream") {
    return { kind: "stream", part: data as ChatStreamPart };
  }
  if (event === "trace") {
    return { kind: "trace", event: data as TraceEvent };
  }
  if (event === "done") {
    return { kind: "done", payload: data as RuntimeDonePayload };
  }
  return null;
}
