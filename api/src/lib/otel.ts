/**
 * OpenTelemetry bootstrap.
 *
 * Two operating modes, selected by OTEL_EXPORTER_OTLP_ENDPOINT:
 *
 * 1. EXPORT MODE (env set, typical EC2):
 *    - NodeTracerProvider + BatchSpanProcessor + OTLPTraceExporter pointed
 *      at the ADOT Collector sidecar on 127.0.0.1:4318. The sidecar handles
 *      SigV4 signing outbound to the AWS X-Ray OTLP endpoint.
 *    - Strands TS SDK auto-attaches to the global tracer provider, so all
 *      gen_ai.* spans (Cycle / Model invoke / Tool) flow through here.
 *
 * 2. IN-PROCESS MODE (env unset, typical local dev / DEV_MOCK_BACKENDS=1):
 *    - NodeTracerProvider with no exporter — spans live in memory only.
 *      W3C trace_id / span_id still appear on every JSON log line, so
 *      docker compose / single-process dev keeps the same shape.
 *
 * Cross-service propagation via `traceparent` / `_trace` payload envelopes
 * works identically in both modes — that part has always been in-process
 * context manipulation, not exporter-dependent.
 */

import { context, propagation, trace, type Context } from "@opentelemetry/api";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";
import { W3CTraceContextPropagator } from "@opentelemetry/core";
import { BatchSpanProcessor } from "@opentelemetry/sdk-trace-base";
import { NodeTracerProvider } from "@opentelemetry/sdk-trace-node";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { Resource } from "@opentelemetry/resources";
import { ATTR_SERVICE_NAME } from "@opentelemetry/semantic-conventions";

let bootstrapped = false;

export type InitOtelOptions = {
  serviceName: string;
};

/** Returns the resolved OTLP traces endpoint or undefined if export is disabled. */
function resolveTracesEndpoint(): string | undefined {
  const explicit = process.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT?.trim();
  if (explicit) return explicit;
  const base = process.env.OTEL_EXPORTER_OTLP_ENDPOINT?.trim();
  if (!base) return undefined;
  // OTLP spec: traces endpoint is base + /v1/traces when only the base is set.
  return base.replace(/\/$/, "") + "/v1/traces";
}

export function initOtel(opts: InitOtelOptions): void {
  if (bootstrapped) return;
  bootstrapped = true;

  process.env.OTEL_SERVICE_NAME = opts.serviceName;

  const provider = new NodeTracerProvider({
    resource: new Resource({
      [ATTR_SERVICE_NAME]: opts.serviceName,
      "service.version": process.env.GIT_SHA?.trim() || "dev",
      "deployment.environment": process.env.ENVIRONMENT?.trim() || "dev",
    }),
  });

  const tracesEndpoint = resolveTracesEndpoint();
  if (tracesEndpoint) {
    // BatchSpanProcessor batches span exports — gentler on the sidecar than
    // SimpleSpanProcessor and matches AWS reference architecture for ADOT.
    provider.addSpanProcessor(
      new BatchSpanProcessor(
        new OTLPTraceExporter({
          url: tracesEndpoint,
          // Headers/sampling/timeout default to OTEL_EXPORTER_OTLP_HEADERS /
          // OTEL_EXPORTER_OTLP_TIMEOUT / OTEL_TRACES_SAMPLER* env vars.
        }),
      ),
    );
  }

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
