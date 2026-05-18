/**
 * AsyncLocalStorage scope for the verified JWT `sub` (userId) for the current
 * chat turn.
 *
 * Why this exists: the MongoDB MCP client's `callTool` wrapper needs to
 * inject `{ userId }` into every query filter so the database never returns
 * another user's documents — even when the LLM omits or incorrectly specifies
 * the filter. This mirrors the same pattern used by `gateway-auth-context.ts`
 * for JWT forwarding.
 *
 * Usage in route handler (chat.ts):
 *   return withCurrentUserId(userId, () => runWithTrace(...));
 *
 * Usage in adapters:
 *   const uid = currentUserId();
 *   if (uid) args.filter = { ...args.filter, userId: uid };
 */

import { AsyncLocalStorage } from "node:async_hooks";

const storage = new AsyncLocalStorage<{ userId: string }>();

/** Run `fn` with `userId` scoped as the active tenant for any MCP/data calls. */
export function withCurrentUserId<T>(userId: string | undefined, fn: () => T): T {
  if (!userId) return fn();
  return storage.run({ userId }, fn);
}

/** Returns the userId scoped by the nearest `withCurrentUserId(...)` ancestor, or undefined. */
export function currentUserId(): string | undefined {
  return storage.getStore()?.userId;
}
