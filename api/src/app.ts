import { Hono } from "hono";
import { cors } from "hono/cors";
import { authMiddleware } from "./middleware/auth.ts";
import { rateLimitMiddleware } from "./middleware/rate-limit.ts";
import { requestIdMiddleware } from "./middleware/request-id.ts";
import { otelServerSpanMiddleware } from "./middleware/otel.ts";
import { accessLogMiddleware } from "./middleware/access-log.ts";
import { resolveCorsOrigins } from "./lib/environment-config.ts";
import { logger } from "./lib/logger.ts";
import { agentsRoutes } from "./routes/agents.ts";
import { chatRoutes } from "./routes/chat.ts";
import { healthRoutes } from "./routes/health.ts";
import { skillsRoutes } from "./routes/skills.ts";
import { sessionsRoutes } from "./routes/sessions.ts";
import { httpToolsMetaRoutes } from "./routes/http-tools-meta.ts";
import { traceRoutes } from "./routes/trace.ts";
import { demoPromptsRoutes } from "./routes/demo-prompts.ts";

export function createApp(): Hono {
  const app = new Hono();

  app.onError((err, c) => {
    logger.error("[api] unhandled error", {
      requestId: c.get("requestId") ?? "unknown",
      error: err instanceof Error ? err.message : String(err),
    });
    return c.json(
      {
        error: {
          code: "INTERNAL",
          message: err instanceof Error ? err.message : "Unexpected error",
          requestId: c.get("requestId") ?? "unknown",
        },
      },
      500,
    );
  });

  const corsOrigins = resolveCorsOrigins();

  app.use("*", requestIdMiddleware);
  app.use("*", otelServerSpanMiddleware);
  app.use("*", accessLogMiddleware);
  app.use(
    "*",
    cors({
      origin: corsOrigins,
      allowMethods: ["GET", "POST", "DELETE", "OPTIONS"],
      allowHeaders: ["Authorization", "Content-Type", "Accept", "X-Request-Id", "traceparent", "tracestate"],
      exposeHeaders: ["X-Request-Id", "X-Trace-Id"],
    }),
  );

  app.route("/", healthRoutes);
  // Demo prompts are public — they're literally the suggested-prompt strings
  // the sidebar renders pre-login. No PII; no secrets.
  app.route("/", demoPromptsRoutes);

  const protectedApp = new Hono();
  protectedApp.use("*", rateLimitMiddleware);
  protectedApp.use("*", authMiddleware);
  protectedApp.route("/", chatRoutes);
  protectedApp.route("/", agentsRoutes);
  protectedApp.route("/", skillsRoutes);
  protectedApp.route("/", sessionsRoutes);
  protectedApp.route("/", httpToolsMetaRoutes);
  protectedApp.route("/", traceRoutes);

  app.route("/", protectedApp);

  return app;
}
