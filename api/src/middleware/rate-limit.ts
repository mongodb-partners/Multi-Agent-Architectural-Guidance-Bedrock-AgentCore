import type { MiddlewareHandler } from "hono";

const WINDOW_MS = 60_000;
const LIMIT = Math.max(1, Number(process.env.RATE_LIMIT_PER_MIN ?? 60));

type Bucket = { count: number; windowStart: number };
const buckets = new Map<string, Bucket>();

function simpleHash(s: string): string {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (Math.imul(31, h) + s.charCodeAt(i)) | 0;
  return String(h);
}

function clientKey(c: { req: { header: (n: string) => string | undefined } }): string {
  const auth = c.req.header("authorization") ?? "";
  if (auth.length > 20) return `b:${simpleHash(auth)}`;
  const xff = c.req.header("x-forwarded-for")?.split(",")[0]?.trim();
  return `ip:${xff || "local"}`;
}

export const rateLimitMiddleware: MiddlewareHandler = async (c, next) => {
  if (process.env.RATE_LIMIT_DISABLED === "true" || process.env.RATE_LIMIT_DISABLED === "1") {
    await next();
    return;
  }

  const now = Date.now();
  const key = clientKey(c);
  let b = buckets.get(key);
  if (!b || now - b.windowStart >= WINDOW_MS) {
    b = { count: 0, windowStart: now };
    buckets.set(key, b);
  }

  b.count += 1;
  const remaining = Math.max(0, LIMIT - b.count);
  const resetSec = Math.ceil((b.windowStart + WINDOW_MS) / 1000);
  c.header("X-RateLimit-Limit", String(LIMIT));
  c.header("X-RateLimit-Remaining", String(remaining));
  c.header("X-RateLimit-Reset", String(resetSec));

  if (b.count > LIMIT) {
    const retryAfter = Math.max(1, Math.ceil((b.windowStart + WINDOW_MS - now) / 1000));
    c.header("Retry-After", String(retryAfter));
    return c.json(
      {
        error: {
          code: "RATE_LIMIT_EXCEEDED",
          message: "Too many requests.",
          requestId: c.get("requestId"),
        },
      },
      429,
    );
  }

  await next();
};
