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

import { context, propagation, trace, type AttributeValue, type Context } from "@opentelemetry/api";
import { AsyncLocalStorageContextManager } from "@opentelemetry/context-async-hooks";
import { W3CTraceContextPropagator } from "@opentelemetry/core";
import { BatchSpanProcessor, type ReadableSpan, type SpanProcessor } from "@opentelemetry/sdk-trace-base";
import { NodeTracerProvider } from "@opentelemetry/sdk-trace-node";
import { AWSXRayIdGenerator } from "@opentelemetry/id-generator-aws-xray";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { Resource } from "@opentelemetry/resources";
import { ATTR_SERVICE_NAME } from "@opentelemetry/semantic-conventions";
import { PII_ARG_KEYS, summariseValue, maskPiiInString } from "./logger.ts";

let bootstrapped = false;

export type InitOtelOptions = {
  serviceName: string;
};

// ---------------------------------------------------------------------------
// Span-attribute PII scrubber (CloudWatch /aws/spans).
//
// `TraceCollector.flattenAttrs` already redacts our own `multiagent.*` span
// attributes, but the Strands TS SDK auto-attaches to this same global tracer
// provider and emits its OWN `gen_ai.*` (Cycle / Model invoke / Tool) spans —
// and a gen_ai Tool span can carry the raw MongoDB tool-call arguments / result
// in its attributes or events. Those never pass through `flattenAttrs`, so we
// add a SpanProcessor that scrubs EVERY span (regardless of emitter) right
// before the BatchSpanProcessor exports it. This is the single choke point
// that guarantees no MongoDB arg/returned-doc PII reaches `/aws/spans`.
//
// Two layers, mirroring the log + TraceCollector paths (shared `logger.ts`
// helpers), gated off by `MCP_LOG_RAW_ARGS=true`:
//   A. Attribute keys whose final dotted segment names a sensitive carrier
//      (filter/document/queryVector/result/arguments/input/…) are summarised.
//   B. Every remaining string attribute value is run through `maskPiiInString`
//      so an email/phone hiding under an arbitrary key is still masked.
// ---------------------------------------------------------------------------

const SENSITIVE_SPAN_ATTR_SEGMENTS: ReadonlySet<string> = new Set<string>([
  ...[...PII_ARG_KEYS].map((k) => k.toLowerCase()),
  "normalizedfilter",
  "result",
  "sampledocs",
  "documentpreviews",
  // Strands / OTel gen_ai tool-call carriers (attribute or event keys).
  "arguments",
  "toolarguments",
  "tool_arguments",
  "input",
  "output",
  // gen_ai message-content carriers. Strands emits tool args, tool results,
  // prompts, and conversation messages as JSON blobs under these span/event
  // attribute keys (see @strands-agents/sdk telemetry/tracer.js:
  // gen_ai.tool.message{content}, gen_ai.choice{message},
  // gen_ai.client.inference.operation.details{gen_ai.input.messages,
  // gen_ai.output.messages, gen_ai.system_instructions}, system_prompt).
  // Summarising the whole blob is the only way to guarantee free-text PII
  // (names / addresses with no detectable pattern) never reaches /aws/spans.
  "content",
  "message",
  "messages",
  "system_instructions",
  "system_prompt",
]);

function lastSegment(key: string): string {
  const i = key.lastIndexOf(".");
  return (i === -1 ? key : key.slice(i + 1)).toLowerCase();
}

/**
 * Redact a mutable OTel attributes bag in place. Exported for unit tests.
 * No-op when `MCP_LOG_RAW_ARGS=true`. Wrapped callers must still try/catch —
 * redaction is best-effort and must never break span export.
 */
export function redactSpanAttributes(attrs: Record<string, AttributeValue | undefined>): void {
  if (process.env.MCP_LOG_RAW_ARGS === "true") return;
  for (const key of Object.keys(attrs)) {
    const v = attrs[key];
    if (v == null) continue;
    if (SENSITIVE_SPAN_ATTR_SEGMENTS.has(lastSegment(key))) {
      const summary = summariseValue(v);
      if (summary !== null) attrs[key] = summary;
      continue;
    }
    if (typeof v === "string") {
      attrs[key] = maskPiiInString(v);
    } else if (Array.isArray(v)) {
      attrs[key] = v.map((item) => (typeof item === "string" ? maskPiiInString(item) : item)) as AttributeValue;
    }
  }
}

/**
 * SpanProcessor that scrubs span + span-event attributes on end, before the
 * BatchSpanProcessor serializes and exports them. Register it BEFORE the batch
 * processor so the mutation is in place by export time.
 */
export class RedactingSpanProcessor implements SpanProcessor {
  onStart(): void {
    // No-op: tool args/results are set during the span's life, so we scrub at
    // end when the attribute bag is complete.
  }

  onEnd(span: ReadableSpan): void {
    try {
      redactSpanAttributes(span.attributes as Record<string, AttributeValue | undefined>);
      for (const ev of span.events) {
        if (ev.attributes) {
          redactSpanAttributes(ev.attributes as Record<string, AttributeValue | undefined>);
        }
      }
    } catch {
      // Redaction must never destabilize the export pipeline.
    }
  }

  shutdown(): Promise<void> {
    return Promise.resolve();
  }

  forceFlush(): Promise<void> {
    return Promise.resolve();
  }
}

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
    // X-Ray-native ids (first 8 hex = epoch). Required so OTLP-exported traces
    // are ingestible by X-Ray / CloudWatch Transaction Search and the console
    // `#xray:traces/1-<8hex>-<24hex>` deep-links resolve. Ids stay valid W3C
    // 32-hex, so traceparent propagation / log correlation are unaffected.
    idGenerator: new AWSXRayIdGenerator(),
  });

  const tracesEndpoint = resolveTracesEndpoint();
  if (tracesEndpoint) {
    // Scrub PII from EVERY span (ours + Strands gen_ai) before it leaves the
    // process. Registered first so the in-place redaction is applied before
    // the BatchSpanProcessor serializes/exports the same span objects.
    provider.addSpanProcessor(new RedactingSpanProcessor());
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
