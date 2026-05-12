import type { MiddlewareHandler } from "hono";

export const requestIdMiddleware: MiddlewareHandler = async (c, next) => {
  const id = `req_${crypto.randomUUID().slice(0, 12)}`;
  c.set("requestId", id);
  c.header("X-Request-Id", id);
  await next();
};
