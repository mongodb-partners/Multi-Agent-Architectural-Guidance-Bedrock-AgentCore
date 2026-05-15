/**
 * OpenTelemetry bootstrap — in-process trace context only (no OTLP/collector).
 * Used for W3C trace_id / span_id on every structured log line and for
 * cross-service propagation via `traceparent` / `_trace` payload envelopes.
 */

import { context, propagation, trace, type Context } from "@opentelemetry/api";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";
import { W3CTraceContextPropagator } from "@opentelemetry/core";
import { BasicTracerProvider } from "@opentelemetry/sdk-trace-base";
import { Resource } from "@opentelemetry/resources";
import { ATTR_SERVICE_NAME } from "@opentelemetry/semantic-conventions";

let bootstrapped = false;

export type InitOtelOptions = {
  serviceName: string;
};

export function initOtel(opts: InitOtelOptions): void {
  if (bootstrapped) return;
  bootstrapped = true;

  process.env.OTEL_SERVICE_NAME = opts.serviceName;

  const provider = new BasicTracerProvider({
    resource: new Resource({
      [ATTR_SERVICE_NAME]: opts.serviceName,
      "service.version": process.env.GIT_SHA?.trim() || "dev",
      "deployment.environment": process.env.ENVIRONMENT?.trim() || "dev",
    }),
  });

  const cm = new AsyncLocalStorageContextManager();
  cm.enable();
  context.setGlobalContextManager(cm);
  propagation.setGlobalPropagator(new W3CTraceContextPropagator());
  trace.setGlobalTracerProvider(provider);
}

export function tracer() {
  return trace.getTracer("multiagent");
}

const textMapSetter = {
  set(carrier: Record<string, string>, key: string, value: string): void {
    carrier[key] = value;
  },
};

const textMapGetter = {
  get(carrier: Record<string, string | undefined>, key: string): string | string[] | undefined {
    return carrier[key];
  },
  keys(carrier: Record<string, string | undefined>): string[] {
    return Object.keys(carrier);
  },
};

/** Inject W3C trace context into a plain carrier (e.g. `_trace` JSON object). */
export function injectTraceContextToCarrier(out: Record<string, string>): void {
  propagation.inject(context.active(), out, textMapSetter);
}

/** Extract remote parent context from `_trace` / carrier map. */
export function extractContextFromCarrier(carrier: Record<string, string | undefined>): Context {
  return propagation.extract(context.active(), carrier, textMapGetter);
}

/** Merge active trace into HTTP Headers (MCP StreamableHTTP fetch). */
export function appendTraceContextHeaders(headers: Headers): void {
  const carrier: Record<string, string> = {};
  propagation.inject(context.active(), carrier, textMapSetter);
  if (carrier.traceparent) headers.set("traceparent", carrier.traceparent);
  if (carrier.tracestate) headers.set("tracestate", carrier.tracestate);
}

/** Extract trace context from incoming Fetch API Headers. */
export function extractContextFromHeaders(h: Headers): Context {
  const carrier: Record<string, string | undefined> = {};
  h.forEach((value, key) => {
    carrier[key.toLowerCase()] = value;
  });
  return propagation.extract(context.active(), carrier, textMapGetter);
}
