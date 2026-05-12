import { Hono } from "hono";
import { buildHealthPayload } from "../lib/health-status.ts";

export const healthRoutes = new Hono();

healthRoutes.get("/health", async (c) => {
  const body = await buildHealthPayload();
  return c.json(body, body.status === "degraded" ? 503 : 200);
});
