import { describe, expect, test } from "bun:test";
import { useOrchestratorSwarm } from "../../src/lib/orchestrator-mode.ts";

describe("useOrchestratorSwarm", () => {
  test("true only for orchestrator + swarm + live", () => {
    expect(
      useOrchestratorSwarm("orchestrator", {
        ORCHESTRATOR_MODE: "swarm",
        CHAT_MODE: "live",
      }),
    ).toBe(true);
  });

  test("false for specialist even when swarm", () => {
    expect(
      useOrchestratorSwarm("order-management", {
        ORCHESTRATOR_MODE: "swarm",
        CHAT_MODE: "live",
      }),
    ).toBe(false);
  });

  test("false when CHAT_MODE is stub", () => {
    expect(
      useOrchestratorSwarm("orchestrator", {
        ORCHESTRATOR_MODE: "swarm",
        CHAT_MODE: "stub",
      }),
    ).toBe(false);
  });

  test("false when ORCHESTRATOR_MODE unset", () => {
    expect(
      useOrchestratorSwarm("orchestrator", {
        CHAT_MODE: "live",
      }),
    ).toBe(false);
  });

  test("true when CHAT_MODE unset (live is the new default)", () => {
    expect(
      useOrchestratorSwarm("orchestrator", {
        ORCHESTRATOR_MODE: "swarm",
      }),
    ).toBe(true);
  });
});
