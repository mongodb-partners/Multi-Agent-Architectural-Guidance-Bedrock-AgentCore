/**
 * Unit tests for the EMF metrics emitter.
 *
 * Locks down the on-the-wire shape expected by CloudWatch's EMF parser:
 *   - `_aws.CloudWatchMetrics[0].Namespace` matches the fleet dashboard
 *     namespaces (`Multiagent/Chat`, `Multiagent/Mongo`, `Multiagent/Memory`).
 *   - `_aws.CloudWatchMetrics[0].Metrics[*].Name` matches the metric names
 *     wired into widgets and alarms (`TurnsTotal`, `TurnErrors`,
 *     `TurnLatencyMs`, `QueryCount`, `VectorSearchLatencyMs`, `FactsWritten`,
 *     ...).
 *   - Each metric value lives at the top level keyed by metric name.
 *   - Dimensions live at the top level and are echoed in the Dimensions[][]
 *     header.
 *
 * If anyone renames a metric or moves the value off the top level, alarm
 * `INSUFFICIENT_DATA` will be the production symptom — far away in space and
 * time from the offending PR. This test fails fast in CI instead.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  recordAgentCoreInvoke,
  recordChatMirrorEmbeddingSkipped,
  recordChatTurn,
  recordMemoryEmbeddingSkipped,
  recordMemoryWrite,
  recordMongoQuery,
} from "../../src/lib/cw-metrics.ts";

type EmfRecord = {
  _aws: {
    Timestamp: number;
    CloudWatchMetrics: Array<{
      Namespace: string;
      Dimensions: string[][];
      Metrics: Array<{ Name: string; Unit: string }>;
    }>;
  };
  [k: string]: unknown;
};

const captured: EmfRecord[] = [];
const origWrite = process.stdout.write.bind(process.stdout);

beforeEach(() => {
  captured.length = 0;
  (process.stdout.write as unknown) = (chunk: string | Uint8Array) => {
    const s = typeof chunk === "string" ? chunk : Buffer.from(chunk).toString("utf8");
    for (const line of s.split("\n")) {
      if (!line.trim()) continue;
      try {
        const obj = JSON.parse(line);
        if (obj && typeof obj === "object" && "_aws" in obj) {
          captured.push(obj as EmfRecord);
        }
      } catch {
        // not EMF / not our line — ignore
      }
    }
    return true;
  };
});

afterEach(() => {
  process.stdout.write = origWrite;
});

describe("cw-metrics EMF emitter", () => {
  test("recordChatTurn always emits TurnsTotal + TurnLatencyMs + TurnErrors (success path: TurnErrors=0)", () => {
    // TurnErrors is emitted on EVERY turn with value 0 on success so the
    // dashboard line stays visible and the SLO-burn alarm can compute
    // error_rate even in quiet periods. See `recordChatTurn` in cw-metrics.ts.
    recordChatTurn({ agentId: "orchestrator", latencyMs: 1234 });
    expect(captured.length).toBe(1);
    const r = captured[0];
    expect(r._aws.CloudWatchMetrics[0].Namespace).toBe("Multiagent/Chat");
    const names = r._aws.CloudWatchMetrics[0].Metrics.map((m) => m.Name).sort();
    expect(names).toEqual(["TurnErrors", "TurnLatencyMs", "TurnsTotal"]);
    expect(r.TurnsTotal).toBe(1);
    expect(r.TurnLatencyMs).toBe(1234);
    expect(r.TurnErrors).toBe(0);
    expect(r.agentId).toBe("orchestrator");
    expect(r._aws.CloudWatchMetrics[0].Dimensions[0]).toContain("agentId");
  });

  test("recordChatTurn with error=true raises TurnErrors to 1 and includes errorClass context", () => {
    recordChatTurn({
      agentId: "order-management",
      latencyMs: 99,
      error: true,
      errorClass: "ThrottlingException",
    });
    expect(captured.length).toBe(1);
    const names = captured[0]._aws.CloudWatchMetrics[0].Metrics.map((m) => m.Name);
    expect(names).toContain("TurnErrors");
    expect(captured[0].TurnErrors).toBe(1);
    expect(captured[0].errorClass).toBe("ThrottlingException");
  });

  test("recordAgentCoreInvoke always emits Invokes + LatencyMs + Errors (success path: Errors=0)", () => {
    recordAgentCoreInvoke({ agentId: "orchestrator", mode: "ec2_to_orchestrator", latencyMs: 500 });
    expect(captured.length).toBe(1);
    const r = captured[0];
    expect(r._aws.CloudWatchMetrics[0].Namespace).toBe("Multiagent/Chat");
    const names = r._aws.CloudWatchMetrics[0].Metrics.map((m) => m.Name).sort();
    expect(names).toEqual(["AgentCoreInvokeErrors", "AgentCoreInvokeLatencyMs", "AgentCoreInvokes"]);
    expect(r.AgentCoreInvokes).toBe(1);
    expect(r.AgentCoreInvokeErrors).toBe(0);
    expect(r.mode).toBe("ec2_to_orchestrator");
  });

  test("recordMongoQuery vector_search emits VectorSearchLatencyMs in Multiagent/Mongo", () => {
    recordMongoQuery({ collection: "agent_memory_facts", kind: "vector_search", latencyMs: 42 });
    expect(captured.length).toBe(1);
    const r = captured[0];
    expect(r._aws.CloudWatchMetrics[0].Namespace).toBe("Multiagent/Mongo");
    const names = r._aws.CloudWatchMetrics[0].Metrics.map((m) => m.Name);
    expect(names).toContain("VectorSearchLatencyMs");
    expect(names).toContain("QueryLatencyMs");
    expect(names).toContain("QueryCount");
    expect(r.VectorSearchLatencyMs).toBe(42);
    expect(r.collection).toBe("agent_memory_facts");
    expect(r.kind).toBe("vector_search");
  });

  test("recordMongoQuery non-vector path does NOT emit VectorSearchLatencyMs", () => {
    recordMongoQuery({ collection: "orders", kind: "find", latencyMs: 10 });
    expect(captured.length).toBe(1);
    const names = captured[0]._aws.CloudWatchMetrics[0].Metrics.map((m) => m.Name);
    expect(names).not.toContain("VectorSearchLatencyMs");
  });

  test("recordMemoryWrite emits FactsExtracted/FactsWritten/EmbeddingFailures in Multiagent/Memory", () => {
    recordMemoryWrite({ agentId: "orchestrator", factsExtracted: 5, factsWritten: 3, embeddingFailures: 1 });
    expect(captured.length).toBe(1);
    const r = captured[0];
    expect(r._aws.CloudWatchMetrics[0].Namespace).toBe("Multiagent/Memory");
    expect(r.FactsExtracted).toBe(5);
    expect(r.FactsWritten).toBe(3);
    expect(r.EmbeddingFailures).toBe(1);
  });

  test("recordMemoryEmbeddingSkipped emits MemoryEmbeddingSkipped under Multiagent/Memory with code dimension", () => {
    // Strict-mode lock-down: when EMBEDDINGS_PROVIDER is unable to embed a
    // fact (e.g. voyage_strict_failed during a SageMaker outage), the LTM
    // write path keeps the row but emits this metric so the Memory dashboard
    // can distinguish a Voyage outage from a Bedrock outage from a
    // misconfigured EMBEDDINGS_PROVIDER. Renaming this metric or moving the
    // value off the top level breaks the alarm silently.
    recordMemoryEmbeddingSkipped({
      agentId: "orchestrator",
      code: "voyage_strict_failed",
      count: 2,
    });
    expect(captured.length).toBe(1);
    const r = captured[0];
    expect(r._aws.CloudWatchMetrics[0].Namespace).toBe("Multiagent/Memory");
    const names = r._aws.CloudWatchMetrics[0].Metrics.map((m) => m.Name);
    expect(names).toEqual(["MemoryEmbeddingSkipped"]);
    expect(r.MemoryEmbeddingSkipped).toBe(2);
    expect(r.agentId).toBe("orchestrator");
    expect(r.code).toBe("voyage_strict_failed");
    const dimKeys = r._aws.CloudWatchMetrics[0].Dimensions[0];
    expect(dimKeys).toContain("agentId");
    expect(dimKeys).toContain("code");
  });

  test("recordChatMirrorEmbeddingSkipped emits ChatMirrorEmbeddingSkipped under Multiagent/Chat with code dimension", () => {
    // Strict-mode lock-down: per-message counter for chat-mirror embedding
    // failures. Distinct namespace from Memory so the Chat dashboard can show
    // both turn-level and embedding-level health on one panel.
    recordChatMirrorEmbeddingSkipped({
      agentId: "order-management",
      code: "voyage_strict_failed",
    });
    expect(captured.length).toBe(1);
    const r = captured[0];
    expect(r._aws.CloudWatchMetrics[0].Namespace).toBe("Multiagent/Chat");
    const names = r._aws.CloudWatchMetrics[0].Metrics.map((m) => m.Name);
    expect(names).toEqual(["ChatMirrorEmbeddingSkipped"]);
    expect(r.ChatMirrorEmbeddingSkipped).toBe(1);
    expect(r.agentId).toBe("order-management");
    expect(r.code).toBe("voyage_strict_failed");
    const dimKeys = r._aws.CloudWatchMetrics[0].Dimensions[0];
    expect(dimKeys).toContain("agentId");
    expect(dimKeys).toContain("code");
  });

  test("recordMemoryEmbeddingSkipped defaults agentId to 'unknown' when omitted", () => {
    recordMemoryEmbeddingSkipped({ code: "no_provider_configured", count: 1 });
    expect(captured.length).toBe(1);
    expect(captured[0].agentId).toBe("unknown");
    expect(captured[0].code).toBe("no_provider_configured");
  });

  test("METRICS_EMITTER_ENABLED=0 silences all emission", () => {
    process.env.METRICS_EMITTER_ENABLED = "0";
    try {
      recordChatTurn({ agentId: "x", latencyMs: 1 });
      recordMongoQuery({ collection: "c", kind: "find", latencyMs: 1 });
      expect(captured.length).toBe(0);
    } finally {
      delete process.env.METRICS_EMITTER_ENABLED;
    }
  });
});
