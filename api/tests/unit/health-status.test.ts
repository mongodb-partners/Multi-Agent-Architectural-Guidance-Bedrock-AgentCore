import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

const mockState = { failConnect: false, failPing: false };

mock.module("../../src/lib/mongo-client.ts", () => ({
  getMongoDb: async () => {
    if (!process.env.MONGODB_URI?.trim()) return null;
    if (mockState.failConnect) throw new Error("connect failed");
    return {
      admin: () => ({
        command: async () => {
          if (mockState.failPing) throw new Error("ping failed");
          return { ok: 1 };
        },
      }),
      collection: () => ({
        createIndex: async () => ({}),
        findOne: async () => null,
        replaceOne: async () => ({ modifiedCount: 0, upsertedCount: 0 }),
        deleteOne: async () => ({ deletedCount: 0 }),
        find: () => ({
          project: () => ({
            toArray: async () => [],
          }),
        }),
      }),
    };
  },
  resetMongoClientForTests: () => {},
}));

// Mock just the AgentCore SDK *client* so we can drive the probe with
// synthetic errors, while leaving every other named export
// (`CreateEventCommand`, `ListEventsCommand`, etc.) intact for the rest of
// the codebase. Replacing the entire module would break the long-term
// memory + short-term memory modules that import from the same package.
//
// The probe must classify "Actor not found" as `connected` (the API
// responded successfully — we asked about a fake actor on purpose) and
// everything else (network, auth, throttling, missing memory store) as
// `unreachable`.
const agentcoreSdk = await import("@aws-sdk/client-bedrock-agentcore");
const agentcoreState: { error?: Error & { name: string } } = {};
mock.module("@aws-sdk/client-bedrock-agentcore", () => ({
  ...agentcoreSdk,
  BedrockAgentCoreClient: class {
    async send() {
      if (agentcoreState.error) throw agentcoreState.error;
      return { sessionSummaries: [] };
    }
  },
}));

const makeAwsError = (name: string, message: string): Error & { name: string } => {
  const e = new Error(message) as Error & { name: string };
  e.name = name;
  return e;
};

const {
  buildHealthPayload,
  resolveMongoDependencyStatus,
  resolveLongTermMemoryStatus,
  resolveAgentcoreDependencyStatus,
} = await import("../../src/lib/health-status.ts");

describe("health-status", () => {
  const saved = { ...process.env };

  beforeEach(() => {
    mockState.failConnect = false;
    mockState.failPing = false;
    agentcoreState.error = undefined;
  });

  afterEach(() => {
    process.env = { ...saved };
  });

  test("mongodb not_configured when no URI", async () => {
    delete process.env.MONGODB_URI;
    expect(await resolveMongoDependencyStatus()).toBe("not_configured");
  });

  test("mongodb connected when URI set and ping succeeds", async () => {
    process.env.MONGODB_URI = "mongodb://localhost:27017";
    expect(await resolveMongoDependencyStatus()).toBe("connected");
  });

  test("mongodb unreachable when ping fails", async () => {
    process.env.MONGODB_URI = "mongodb://localhost:27017";
    mockState.failPing = true;
    expect(await resolveMongoDependencyStatus()).toBe("unreachable");
  });

  test("buildHealthPayload status degraded when mongo unreachable", async () => {
    process.env.MONGODB_URI = "mongodb://localhost:27017";
    process.env.PERSIST_CHAT_SESSIONS = "1";
    mockState.failPing = true;
    const body = await buildHealthPayload();
    expect(body.status).toBe("degraded");
    expect(body.dependencies.mongodb).toBe("unreachable");
    expect(body.dependencies.longTermMemory).toBe("unreachable");
    expect(body.dependencies.chatSessions).toBe("unavailable");
  });

  test("buildHealthPayload includes longTermMemory field when no URI", async () => {
    delete process.env.MONGODB_URI;
    delete process.env.PERSIST_CHAT_SESSIONS;
    const body = await buildHealthPayload();
    expect(body.status).toBe("ok");
    expect(typeof body.dependencies.longTermMemory).toBe("string");
    expect(["not_configured", "no_agents"]).toContain(body.dependencies.longTermMemory);
    expect(body.dependencies.chatSessions).toBe("memory");
    expect(body.dependencies.toolHosting).toBe("hybrid");
  });

  test("resolveLongTermMemoryStatus not_configured when mongo not_configured", () => {
    expect(resolveLongTermMemoryStatus("not_configured")).toBe("not_configured");
  });

  test("resolveLongTermMemoryStatus unreachable when mongo unreachable", () => {
    expect(resolveLongTermMemoryStatus("unreachable")).toBe("unreachable");
  });

  test("resolveLongTermMemoryStatus connected returns connected or no_agents", () => {
    const result = resolveLongTermMemoryStatus("connected");
    expect(["connected", "no_agents"]).toContain(result);
  });

  // --------------------------------------------------------------------
  // AgentCore probe — error classification
  //
  // History: an earlier probe treated every SDK error as `unreachable`,
  // which kept `/health` perpetually flagging `agentcore: "unreachable"`
  // against a fully-working stack. The probe asks AgentCore about a fake
  // `health-probe` actor; AgentCore correctly responds with
  // `ResourceNotFoundException — Actor … not found`. That response is
  // **proof the API round-trip succeeded** (DNS, TLS, SigV4, IAM, memory
  // store all worked) and must be classified as `connected`. Any other
  // error class — auth denied, network timeout, throttling, missing
  // memory store — is genuinely `unreachable`.
  // --------------------------------------------------------------------

  test("agentcore not_configured when AGENTCORE_MEMORY_STORE_ID is absent", async () => {
    delete process.env.AGENTCORE_MEMORY_STORE_ID;
    expect(await resolveAgentcoreDependencyStatus()).toBe("not_configured");
  });

  test("agentcore connected when SDK call succeeds (no error)", async () => {
    process.env.AGENTCORE_MEMORY_STORE_ID = "mem-fake";
    expect(await resolveAgentcoreDependencyStatus()).toBe("connected");
  });

  test("agentcore connected when probe gets ResourceNotFoundException for the actor", async () => {
    process.env.AGENTCORE_MEMORY_STORE_ID = "mem-fake";
    agentcoreState.error = makeAwsError(
      "ResourceNotFoundException",
      "Actor health-probe not found",
    );
    expect(await resolveAgentcoreDependencyStatus()).toBe("connected");
  });

  test("agentcore unreachable when ResourceNotFoundException is for the memory itself", async () => {
    process.env.AGENTCORE_MEMORY_STORE_ID = "mem-missing";
    agentcoreState.error = makeAwsError(
      "ResourceNotFoundException",
      "Memory mem-missing not found",
    );
    expect(await resolveAgentcoreDependencyStatus()).toBe("unreachable");
  });

  test("agentcore unreachable on AccessDeniedException (IAM mis-config)", async () => {
    process.env.AGENTCORE_MEMORY_STORE_ID = "mem-fake";
    agentcoreState.error = makeAwsError(
      "AccessDeniedException",
      "User is not authorized to perform: bedrock-agentcore:ListSessions",
    );
    expect(await resolveAgentcoreDependencyStatus()).toBe("unreachable");
  });

  test("agentcore unreachable on ThrottlingException", async () => {
    process.env.AGENTCORE_MEMORY_STORE_ID = "mem-fake";
    agentcoreState.error = makeAwsError("ThrottlingException", "Rate exceeded");
    expect(await resolveAgentcoreDependencyStatus()).toBe("unreachable");
  });

  test("agentcore unreachable on network timeout (TimeoutError)", async () => {
    process.env.AGENTCORE_MEMORY_STORE_ID = "mem-fake";
    agentcoreState.error = makeAwsError("TimeoutError", "Request timed out");
    expect(await resolveAgentcoreDependencyStatus()).toBe("unreachable");
  });
});
