import type { MiddlewareHandler } from "hono";
import { context, trace, SpanKind, SpanStatusCode } from "@opentelemetry/api";
import { extractContextFromHeaders, tracer } from "../lib/otel.ts";

function shouldSkipOtelSpan(pathname: string, method: string): boolean {
  if (method === "OPTIONS") return true;
  if (method !== "GET") return false;
  if (pathname === "/health" || pathname.startsWith("/health/")) return true;
  if (pathname === "/demo-prompts") return true;
  if (pathname === "/agents" || pathname.startsWith("/agents/")) return true;
  if (pathname === "/skills") return true;
  if (pathname === "/traces" || pathname.startsWith("/traces/")) return true;
  if (pathname === "/trace" || pathname.startsWith("/trace/")) return true;
  if (pathname === "/http-tools") return true;
  return false;
}

/**
 * HTTP server span + W3C trace context extraction/injection.
 * Sets X-Trace-Id on every response that creates a span.
 */
export const otelServerSpanMiddleware: MiddlewareHandler = async (c, next) => {
  const url = new URL(c.req.url);
  const pathname = url.pathname;
  const method = c.req.method;

  if (shouldSkipOtelSpan(pathname, method)) {
    await next();
    return;
  }

  const parentCtx = extractContextFromHeaders(c.req.raw.headers);

  await context.with(parentCtx, async () => {
    const t = tracer();
    const routeLabel = `${method} ${pathname}`;
    await t.startActiveSpan(
      routeLabel,
      {
        kind: SpanKind.SERVER,
        attributes: {
          "http.request.method": method,
          "http.route": pathname,
          "request.id": c.get("requestId") ?? "",
        },
      },
      async (span) => {
        c.header("X-Trace-Id", span.spanContext().traceId);
        try {
          await next();
          const sub = c.get("jwtPayload")?.sub;
          if (typeof sub === "string" && sub.length > 0) {
            span.setAttribute("user.id", sub);
          }
        } catch (err) {
          span.recordException(err instanceof Error ? err : new Error(String(err)));
          span.setStatus({
            code: SpanStatusCode.ERROR,
            message: err instanceof Error ? err.message : String(err),
          });
          throw err;
        } finally {
          span.setAttribute("http.response.status_code", c.res.status);
          if (c.res.status >= 400) {
            span.setStatus({ code: SpanStatusCode.ERROR });
          }
          span.end();
        }
      },
    );
  });
};
