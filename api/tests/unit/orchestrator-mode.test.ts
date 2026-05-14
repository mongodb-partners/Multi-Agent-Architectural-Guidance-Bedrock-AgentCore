import { describe, expect, test } from "bun:test";
import { useOrchestratorSwarm } from "../../src/lib/orchestrator-mode.ts";

describe("useOrchestratorSwarm", () => {
  test("true for orchestrator with ORCHESTRATOR_MODE=swarm", () => {
    expect(
      useOrchestratorSwarm("orchestrator", {
        ORCHESTRATOR_MODE: "swarm",
      }),
    ).toBe(true);
  });

  test("true for orchestrator when ORCHESTRATOR_MODE is unset (swarm is the default)", () => {
    expect(useOrchestratorSwarm("orchestrator", {})).toBe(true);
  });

  test("false for specialist agents even when swarm is set", () => {
    expect(
      useOrchestratorSwarm("order-management", {
        ORCHESTRATOR_MODE: "swarm",
      }),
    ).toBe(false);
  });

  test("false when ORCHESTRATOR_MODE is set to anything other than 'swarm'", () => {
    expect(
      useOrchestratorSwarm("orchestrator", {
        ORCHESTRATOR_MODE: "single",
      }),
    ).toBe(false);
  });
});
