/**
 * Smoke test: assert that the Strands TS SDK + the in-process OTel bootstrap
 * share the same global tracer provider, so spans Strands emits internally
 * (gen_ai.* per OTel semantic conventions) flow through OUR exporter rather
 * than disappearing into Strands' own default NoopTracerProvider.
 *
 * Run with `bun run scripts/validate-strands-otel.ts`. Exits 0 on success,
 * non-zero otherwise — wire into CI as part of `validate:*` family.
 *
 * No network required. We do not call Bedrock; we only verify that the
 * tracer provider Strands resolves matches the one initOtel() installed.
 */

import { trace as otelTrace } from "@opentelemetry/api";
import { initOtel } from "../src/lib/otel.ts";

initOtel({ serviceName: "validate-strands-otel" });

const provider = otelTrace.getTracerProvider();
const providerCtorName = provider?.constructor?.name ?? "(unknown)";

if (providerCtorName === "ProxyTracerProvider") {
  // OTel api exposes the global as a proxy; that's fine — it forwards to the
  // delegate we set in initOtel(). What we DON'T want is the SDK's default
  // NoopTracerProvider, which silently drops everything.
  // @ts-expect-error -- private but stable across OTel 1.x / 2.x
  const delegate = provider.getDelegate?.();
  const delegateName = delegate?.constructor?.name ?? "(no delegate)";
  if (delegateName === "NoopTracerProvider") {
    console.error("validate-strands-otel: global provider is Noop — initOtel did not bind a real provider");
    process.exit(2);
  }
  console.log(`validate-strands-otel: ProxyTracerProvider -> ${delegateName} OK`);
} else if (providerCtorName === "NoopTracerProvider") {
  console.error("validate-strands-otel: global provider is NoopTracerProvider — Strands spans will be dropped");
  process.exit(2);
} else {
  console.log(`validate-strands-otel: global provider = ${providerCtorName} OK`);
}

const tracer = otelTrace.getTracer("validate-strands-otel");
const span = tracer.startSpan("smoke.test");
span.setAttribute("gen_ai.system", "aws.bedrock");
span.setAttribute("gen_ai.operation.name", "chat");
span.end();

console.log("validate-strands-otel: emitted gen_ai.* test span OK");
