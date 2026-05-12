import { describe, expect, test } from "bun:test";
import { chatMode, persistChatSessions } from "../../src/lib/runtime-defaults.ts";

describe("chatMode", () => {
  test("unset → live (default)", () => {
    expect(chatMode({})).toBe("live");
  });

  test("empty string → live", () => {
    expect(chatMode({ CHAT_MODE: "" })).toBe("live");
  });

  test("whitespace → live", () => {
    expect(chatMode({ CHAT_MODE: "   " })).toBe("live");
  });

  test("'live' → live", () => {
    expect(chatMode({ CHAT_MODE: "live" })).toBe("live");
  });

  test("'LIVE' (uppercase) → live", () => {
    expect(chatMode({ CHAT_MODE: "LIVE" })).toBe("live");
  });

  test("'stub' → stub", () => {
    expect(chatMode({ CHAT_MODE: "stub" })).toBe("stub");
  });

  test("'STUB' (uppercase) → stub", () => {
    expect(chatMode({ CHAT_MODE: "STUB" })).toBe("stub");
  });

  test("'  stub  ' (padded) → stub", () => {
    expect(chatMode({ CHAT_MODE: "  stub  " })).toBe("stub");
  });

  test("garbage value (unrecognized) → live", () => {
    expect(chatMode({ CHAT_MODE: "foo" })).toBe("live");
  });
});

describe("persistChatSessions", () => {
  test("MONGODB_URI unset → false", () => {
    expect(persistChatSessions({})).toBe(false);
  });

  test("MONGODB_URI empty/whitespace → false", () => {
    expect(persistChatSessions({ MONGODB_URI: "   " })).toBe(false);
  });

  test("MONGODB_URI set, PERSIST_CHAT_SESSIONS unset → true (default-on)", () => {
    expect(persistChatSessions({ MONGODB_URI: "mongodb://x" })).toBe(true);
  });

  test("MONGODB_URI set, PERSIST_CHAT_SESSIONS=1 → true", () => {
    expect(persistChatSessions({ MONGODB_URI: "mongodb://x", PERSIST_CHAT_SESSIONS: "1" })).toBe(true);
  });

  test("MONGODB_URI set, PERSIST_CHAT_SESSIONS='true' → true", () => {
    expect(
      persistChatSessions({ MONGODB_URI: "mongodb://x", PERSIST_CHAT_SESSIONS: "true" }),
    ).toBe(true);
  });

  test("MONGODB_URI set, PERSIST_CHAT_SESSIONS=0 → false (explicit opt-out)", () => {
    expect(persistChatSessions({ MONGODB_URI: "mongodb://x", PERSIST_CHAT_SESSIONS: "0" })).toBe(false);
  });

  test("MONGODB_URI set, PERSIST_CHAT_SESSIONS='false' → false", () => {
    expect(
      persistChatSessions({ MONGODB_URI: "mongodb://x", PERSIST_CHAT_SESSIONS: "false" }),
    ).toBe(false);
  });

  test("MONGODB_URI set, PERSIST_CHAT_SESSIONS='FALSE' (uppercase) → false", () => {
    expect(
      persistChatSessions({ MONGODB_URI: "mongodb://x", PERSIST_CHAT_SESSIONS: "FALSE" }),
    ).toBe(false);
  });

  test("PERSIST_CHAT_SESSIONS=1 but MONGODB_URI unset → false (still gated)", () => {
    expect(persistChatSessions({ PERSIST_CHAT_SESSIONS: "1" })).toBe(false);
  });
});
