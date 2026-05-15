import type { MiddlewareHandler } from "hono";

const INBOUND_REQUEST_ID = /^[a-zA-Z0-9_-]{1,64}$/;

export const requestIdMiddleware: MiddlewareHandler = async (c, next) => {
  const inbound = c.req.header("X-Request-Id") ?? c.req.header("x-request-id");
  const id =
    inbound && INBOUND_REQUEST_ID.test(inbound.trim())
      ? inbound.trim()
      : `req_${crypto.randomUUID().slice(0, 12)}`;
  c.set("requestId", id);
  c.header("X-Request-Id", id);
  await next();
};
