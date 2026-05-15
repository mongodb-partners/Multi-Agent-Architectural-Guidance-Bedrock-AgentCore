import { afterEach, describe, expect, test } from "bun:test";
import { agentcoreSpecialistArn } from "../../src/adapters/agentcore-runtime.ts";

const SAVED_ENV = { ...process.env };

describe("agentcoreSpecialistArn", () => {
  afterEach(() => {
    process.env = { ...SAVED_ENV };
  });

  test("resolves runtime ARN convention for arbitrary specialist ids", () => {
    process.env.AGENTCORE_RUNTIME_ARN_RETURNS_TRIAGE = " arn:runtime ";

    expect(agentcoreSpecialistArn("returns-triage")).toBe("arn:runtime");
  });

  test("resolves deploy output convention for arbitrary specialist ids", () => {
    process.env.AGENTCORE_RETURNS_TRIAGE_ARN = " arn:deploy ";

    expect(agentcoreSpecialistArn("returns-triage")).toBe("arn:deploy");
  });
});
