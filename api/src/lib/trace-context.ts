/**
 * AsyncLocalStorage carrying the active `TraceCollector` for the in-flight
 * chat turn. Adapters (`http-tools-runtime.ts`, etc.) call
 * `currentTrace()?.span(...)` without changing their public signatures.
 */

import { AsyncLocalStorage } from "node:async_hooks";
import { TraceCollector } from "./trace-collector.ts";

const storage = new AsyncLocalStorage<TraceCollector>();

export function withTrace<T>(collector: TraceCollector, fn: () => T): T {
  return storage.run(collector, fn);
}

export function currentTrace(): TraceCollector | undefined {
  return storage.getStore();
}
