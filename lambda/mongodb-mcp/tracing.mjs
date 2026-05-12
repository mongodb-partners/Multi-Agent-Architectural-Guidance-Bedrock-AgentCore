// Per-invocation trace collector for the MongoDB MCP Lambda.
//
// Emitted events are shipped back to the API in the MCP tool response. The API
// side (api/src/adapters/mongodb-mcp-client.ts) extracts and replays them into
// `currentTrace()` so they appear in the Trace Viewer alongside in-process
// events — same shape, same type strings as api/src/lib/trace-types.ts.
//
// Plain ESM JS; no driver / SDK dependency.

const DEFAULT_BYTE_CAP = 64 * 1024;     // 64 KB per invocation
const DEFAULT_MAX_EVENTS = 64;

export class LambdaTraceCollector {
  /**
   * @param {object} [options]
   * @param {number} [options.byteCap]
   * @param {number} [options.maxEvents]
   */
  constructor(options = {}) {
    this._byteCap = options.byteCap ?? DEFAULT_BYTE_CAP;
    this._maxEvents = options.maxEvents ?? DEFAULT_MAX_EVENTS;
    this._events = [];
    this._bytes = 0;
    this._dropped = 0;
  }

  /**
   * Record an event. Silently drops if the per-invocation byte / event cap
   * is exceeded — we never want trace recording to break the user's call.
   *
   * @param {string} type   e.g. "mongo.schema", "mongo.plan"
   * @param {object} payload
   */
  event(type, payload) {
    if (this._events.length >= this._maxEvents) {
      this._dropped += 1;
      return;
    }
    const ev = { type, payload, ts: new Date().toISOString() };
    let serialized;
    try {
      serialized = JSON.stringify(ev);
    } catch {
      this._dropped += 1;
      return;
    }
    const size = serialized.length;
    if (this._bytes + size > this._byteCap) {
      this._dropped += 1;
      return;
    }
    this._events.push(ev);
    this._bytes += size;
  }

  events() {
    return this._events;
  }

  dropped() {
    return this._dropped;
  }
}

export function createLambdaTrace(options) {
  return new LambdaTraceCollector(options);
}
