/**
 * Single-source-of-truth helpers for the framework's runtime-default behavior.
 *
 * Both `CHAT_MODE` and `PERSIST_CHAT_SESSIONS` default to the "live + persistent"
 * loop. Set `CHAT_MODE=stub` or `PERSIST_CHAT_SESSIONS=0` (or `=false`) to opt out.
 *
 * `persistChatSessions` is still gated on `MONGODB_URI` so a developer without a
 * cluster doesn't get spurious mongo errors on every turn.
 */

export type ChatModeValue = "live" | "stub";

export function chatMode(env: NodeJS.ProcessEnv = process.env): ChatModeValue {
  const v = env.CHAT_MODE?.trim().toLowerCase();
  return v === "stub" ? "stub" : "live";
}

export function persistChatSessions(env: NodeJS.ProcessEnv = process.env): boolean {
  const v = env.PERSIST_CHAT_SESSIONS?.trim().toLowerCase();
  if (v === "0" || v === "false") return false;
  return Boolean(env.MONGODB_URI?.trim());
}
