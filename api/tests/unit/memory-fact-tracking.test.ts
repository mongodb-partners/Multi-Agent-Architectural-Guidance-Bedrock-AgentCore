import { describe, expect, test } from "bun:test";
import { extractFactCandidates } from "../../src/lib/long-term-memory.ts";

describe("extractFactCandidates", () => {
  test("returns both accepted facts and full considered list", () => {
    const msg = [
      "hi",                                       // too_short
      "my email is alice@example.com",            // accepted (identity + topic)
      "the weather is nice today and not relevant", // no_pattern_match
      "my email is alice@example.com",            // duplicate
    ].join("\n");
    const { accepted, considered } = extractFactCandidates(msg);
    expect(accepted).toEqual(["my email is alice@example.com"]);
    expect(considered.length).toBe(4);
    expect(considered[0].rejectedReason).toBe("too_short");
    expect(considered[1].matched).toBe(true);
    expect(considered[1].matchedPatterns).toContain("identity");
    expect(considered[1].matchedPatterns).toContain("topic");
    expect(considered[2].rejectedReason).toBe("no_pattern_match");
    expect(considered[3].rejectedReason).toBe("duplicate");
    expect(considered[3].matched).toBe(true);
  });

  test("rejects lines over 220 chars", () => {
    const longLine = "i prefer " + "x".repeat(230);
    const { accepted, considered } = extractFactCandidates(longLine);
    expect(accepted).toEqual([]);
    expect(considered[0].rejectedReason).toBe("too_long");
  });

  test("matches identity-style phrasing", () => {
    const { accepted, considered } = extractFactCandidates("i prefer dark roast coffee");
    expect(accepted).toEqual(["i prefer dark roast coffee"]);
    expect(considered[0].matchedPatterns).toContain("identity");
  });

  test("matches topic-keyword phrasing without identity verb", () => {
    const { accepted } = extractFactCandidates("the phone number 555-1234 is correct");
    expect(accepted).toEqual(["the phone number 555-1234 is correct"]);
  });

  test("caps accepted candidates at 6 per turn", () => {
    const lines = Array.from({ length: 10 }, (_, i) => `my preference number ${i + 1} is nice`);
    const { accepted } = extractFactCandidates(lines.join("\n"));
    expect(accepted.length).toBe(6);
  });

  test("returns empty accepted when message contains no relevant phrases", () => {
    const { accepted, considered } = extractFactCandidates("hello there friend, how are you doing");
    expect(accepted).toEqual([]);
    expect(considered[0].rejectedReason).toBe("no_pattern_match");
  });
});
