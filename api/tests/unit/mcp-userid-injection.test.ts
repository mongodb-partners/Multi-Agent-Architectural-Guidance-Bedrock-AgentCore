/**
 * mcp-userid-injection.test.ts
 * ─────────────────────────────────────────────────────────────────────────────
 * Unit tests for `injectUserIdIntoArgs` — the MCP-layer tenant-isolation guard
 * that forces `{ userId: jwt.sub }` into every MongoDB tool call regardless of
 * what the LLM generated in the tool arguments.
 *
 * Coverage matrix:
 *   READ     — mongodb_query / mongodb_find / mongodb_vector_search
 *   WRITE    — mongodb_update_one / update_many / delete_one / delete_many / replace_one
 *   INSERT   — mongodb_insert_one / mongodb_insert_many
 *   AGG      — mongodb_aggregate (prepend $match stage)
 *   GATEWAY  — gateway-prefixed names (mongodb-mcp___*) stripped before matching
 *   PUBLIC   — products / troubleshooting_docs skipped (catalog / KB)
 *   UNKNOWN  — unrecognised tool names pass through unchanged
 *   OVERRIDE — attacker-supplied filter.userId is overwritten with jwt.sub
 *   AGG-GAP  — aggregate bypass when pipeline[0].$match.userId already set
 *              (documented known limitation — injection is skipped to avoid
 *               double-wrapping; callers must not trust LLM-supplied $match.userId)
 * ─────────────────────────────────────────────────────────────────────────────
 */

import { describe, expect, test } from "bun:test";
import { injectUserIdIntoArgs } from "../../src/adapters/mongodb-mcp-client.ts";

const USER = "user-alice-sub-abc123";
const VICTIM = "user-bob-sub-xyz456";

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function inject(tool: string, args: unknown, userId = USER): unknown {
  return injectUserIdIntoArgs(tool, args, userId);
}

function assertUserIdFilter(result: unknown, expectedUserId = USER): void {
  const r = result as Record<string, unknown>;
  const filter = r.filter as Record<string, unknown>;
  expect(filter).toBeDefined();
  expect(filter.userId).toBe(expectedUserId);
}

// ─────────────────────────────────────────────────────────────────────────────
describe("READ filter injection — mongodb_query, mongodb_find, mongodb_vector_search", () => {
  for (const tool of ["mongodb_query", "mongodb_find", "mongodb_vector_search"]) {
    describe(tool, () => {
      test("injects userId into empty filter", () => {
        const result = inject(tool, { collection: "orders" });
        assertUserIdFilter(result);
      });

      test("merges userId with existing filter fields", () => {
        const result = inject(tool, {
          collection: "orders",
          filter: { status: "delivered" },
        }) as Record<string, unknown>;
        const filter = result.filter as Record<string, unknown>;
        expect(filter.status).toBe("delivered");
        expect(filter.userId).toBe(USER);
      });

      test("overwrites attacker-supplied filter.userId with jwt.sub", () => {
        const result = inject(tool, {
          collection: "orders",
          filter: { userId: VICTIM, status: "pending" },
        }) as Record<string, unknown>;
        const filter = result.filter as Record<string, unknown>;
        expect(filter.userId).toBe(USER);
        expect(filter.userId).not.toBe(VICTIM);
        expect(filter.status).toBe("pending");
      });

      test("preserves all other args (limit, sort, projection) unchanged", () => {
        const result = inject(tool, {
          collection: "chat_messages",
          filter: {},
          limit: 10,
          sort: { ts: -1 },
          projection: { content: 1 },
        }) as Record<string, unknown>;
        expect(result.limit).toBe(10);
        expect(result.sort).toEqual({ ts: -1 });
        expect(result.projection).toEqual({ content: 1 });
      });

      test("gateway-prefixed tool name is treated identically to bare name", () => {
        const gatewayTool = `mongodb-mcp___${tool}`;
        const bare = inject(tool, { collection: "orders" });
        const gw = inject(gatewayTool, { collection: "orders" });
        expect(gw).toEqual(bare);
      });
    });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
describe("WRITE filter injection — update_one/many, delete_one/many, replace_one", () => {
  const writeTools = [
    "mongodb_update_one",
    "mongodb_update_many",
    "mongodb_delete_one",
    "mongodb_delete_many",
    "mongodb_replace_one",
  ];

  for (const tool of writeTools) {
    describe(tool, () => {
      test("injects userId into write filter", () => {
        const result = inject(tool, {
          collection: "agent_memory_facts",
          filter: { factHash: "abc" },
        });
        assertUserIdFilter(result);
        const r = result as Record<string, unknown>;
        expect((r.filter as Record<string, unknown>).factHash).toBe("abc");
      });

      test("overwrites attacker-supplied filter.userId in write op", () => {
        const result = inject(tool, {
          collection: "agent_memory_facts",
          filter: { userId: VICTIM },
        }) as Record<string, unknown>;
        expect((result.filter as Record<string, unknown>).userId).toBe(USER);
      });

      test("gateway-prefixed name behaves identically", () => {
        const gw = inject(`mongodb-mcp___${tool}`, {
          collection: "agent_memory_facts",
          filter: { factHash: "x" },
        });
        const bare = inject(tool, {
          collection: "agent_memory_facts",
          filter: { factHash: "x" },
        });
        expect(gw).toEqual(bare);
      });
    });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
describe("INSERT injection — mongodb_insert_one", () => {
  test("injects userId into document", () => {
    const result = inject("mongodb_insert_one", {
      collection: "agent_memory_facts",
      document: { fact: "alice likes cats", factHash: "h1" },
    }) as Record<string, unknown>;
    const doc = result.document as Record<string, unknown>;
    expect(doc.userId).toBe(USER);
    expect(doc.fact).toBe("alice likes cats");
    expect(doc.factHash).toBe("h1");
  });

  test("overwrites attacker-supplied document.userId", () => {
    const result = inject("mongodb_insert_one", {
      collection: "agent_memory_facts",
      document: { userId: VICTIM, fact: "stolen fact" },
    }) as Record<string, unknown>;
    const doc = result.document as Record<string, unknown>;
    expect(doc.userId).toBe(USER);
    expect(doc.userId).not.toBe(VICTIM);
  });

  test("preserves non-document fields (collection, etc.)", () => {
    const result = inject("mongodb_insert_one", {
      collection: "agent_memory_facts",
      document: { fact: "x" },
    }) as Record<string, unknown>;
    expect(result.collection).toBe("agent_memory_facts");
  });

  test("gateway-prefixed insert behaves identically", () => {
    const gw = inject("mongodb-mcp___mongodb_insert_one", {
      collection: "agent_memory_facts",
      document: { fact: "x" },
    });
    const bare = inject("mongodb_insert_one", {
      collection: "agent_memory_facts",
      document: { fact: "x" },
    });
    expect(gw).toEqual(bare);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
describe("INSERT injection — mongodb_insert_many", () => {
  test("injects userId into every document in the array", () => {
    const result = inject("mongodb_insert_many", {
      collection: "agent_memory_facts",
      documents: [
        { fact: "fact-one", factHash: "h1" },
        { fact: "fact-two", factHash: "h2" },
      ],
    }) as Record<string, unknown>;
    const docs = result.documents as Record<string, unknown>[];
    expect(docs).toHaveLength(2);
    expect(docs[0]!.userId).toBe(USER);
    expect(docs[1]!.userId).toBe(USER);
    expect(docs[0]!.fact).toBe("fact-one");
    expect(docs[1]!.fact).toBe("fact-two");
  });

  test("overwrites attacker-supplied userId in every inserted document", () => {
    const result = inject("mongodb_insert_many", {
      collection: "agent_memory_facts",
      documents: [
        { userId: VICTIM, fact: "leaked fact 1" },
        { userId: VICTIM, fact: "leaked fact 2" },
      ],
    }) as Record<string, unknown>;
    const docs = result.documents as Record<string, unknown>[];
    expect(docs[0]!.userId).toBe(USER);
    expect(docs[1]!.userId).toBe(USER);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
describe("AGGREGATE injection — mongodb_aggregate", () => {
  test("prepends { $match: { userId } } when pipeline has no userId stage", () => {
    const result = inject("mongodb_aggregate", {
      collection: "agent_memory_facts",
      pipeline: [
        { $group: { _id: "$agentId", count: { $sum: 1 } } },
      ],
    }) as Record<string, unknown>;
    const pipeline = result.pipeline as Record<string, unknown>[];
    expect(pipeline[0]).toEqual({ $match: { userId: USER } });
    expect(pipeline[1]).toEqual({ $group: { _id: "$agentId", count: { $sum: 1 } } });
  });

  test("prepends $match when pipeline is empty", () => {
    const result = inject("mongodb_aggregate", {
      collection: "agent_memory_facts",
      pipeline: [],
    }) as Record<string, unknown>;
    const pipeline = result.pipeline as Record<string, unknown>[];
    expect(pipeline).toHaveLength(1);
    expect(pipeline[0]).toEqual({ $match: { userId: USER } });
  });

  test("prepends $match when first stage is not $match", () => {
    const result = inject("mongodb_aggregate", {
      collection: "agent_memory_facts",
      pipeline: [{ $sort: { ts: -1 } }],
    }) as Record<string, unknown>;
    const pipeline = result.pipeline as Record<string, unknown>[];
    expect(pipeline[0]).toEqual({ $match: { userId: USER } });
    expect(pipeline[1]).toEqual({ $sort: { ts: -1 } });
  });

  test("prepends $match when first stage is $match without userId key", () => {
    const result = inject("mongodb_aggregate", {
      collection: "agent_memory_facts",
      pipeline: [
        { $match: { agentId: "order-management" } },
        { $limit: 5 },
      ],
    }) as Record<string, unknown>;
    const pipeline = result.pipeline as Record<string, unknown>[];
    // First stage should now be the userId match
    expect(pipeline[0]).toEqual({ $match: { userId: USER } });
    // Caller's $match is pushed to [1]
    expect(pipeline[1]).toEqual({ $match: { agentId: "order-management" } });
  });

  test("gateway-prefixed aggregate behaves identically", () => {
    const gw = inject("mongodb-mcp___mongodb_aggregate", {
      collection: "agent_memory_facts",
      pipeline: [{ $limit: 10 }],
    });
    const bare = inject("mongodb_aggregate", {
      collection: "agent_memory_facts",
      pipeline: [{ $limit: 10 }],
    });
    expect(gw).toEqual(bare);
  });

  // ── Known limitation ─────────────────────────────────────────────────────
  // When the LLM (or an attacker) supplies a pipeline whose first stage is
  // { $match: { userId: "<victim-sub>" } }, the injection is SKIPPED because
  // `alreadyScoped === true`. This is a defence-in-depth gap: the Mongo query
  // will run against the LLM-supplied userId rather than jwt.sub.
  //
  // Impact is limited because:
  //   - The caller still needs a valid JWT (authMiddleware enforces this).
  //   - "orders" / "customers" don't have a userId field in seeded data,
  //     so injecting userId on those collections returns nothing anyway.
  //   - agent_memory_facts / chat_messages DO have userId — so a crafted
  //     aggregate with $match.userId: <victim> could read another user's facts
  //     IF the model follows an injected pipeline.
  //
  // This test DOCUMENTS the gap (does not fix it). See TASKS.md for remediation.
  test("[KNOWN GAP] aggregate with attacker-supplied $match.userId is NOT forced to jwt.sub", () => {
    const result = inject("mongodb_aggregate", {
      collection: "agent_memory_facts",
      pipeline: [
        { $match: { userId: VICTIM } }, // attacker-supplied victim userId
        { $project: { fact: 1 } },
      ],
    }) as Record<string, unknown>;
    const pipeline = result.pipeline as Record<string, unknown>[];
    // The gap: first stage still has victim's userId, NOT the caller's userId.
    const firstMatch = (pipeline[0] as Record<string, unknown>)["$match"] as Record<string, unknown>;
    expect(firstMatch.userId).toBe(VICTIM);
    // Confirming the injection was skipped (not doubled)
    expect(pipeline).toHaveLength(2);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
describe("PUBLIC collection bypass — no userId injection", () => {
  const publicCollections = ["products", "troubleshooting_docs"];
  const readTools = ["mongodb_query", "mongodb_find", "mongodb_vector_search"];

  for (const collection of publicCollections) {
    for (const tool of readTools) {
      test(`${tool} on '${collection}' passes through without userId`, () => {
        const args = { collection, filter: { category: "headphones" } };
        const result = inject(tool, args) as Record<string, unknown>;
        const filter = result.filter as Record<string, unknown>;
        // userId must NOT be injected
        expect(filter.userId).toBeUndefined();
        // Original filter field preserved
        expect(filter.category).toBe("headphones");
      });
    }

    test(`mongodb_aggregate on '${collection}' does not prepend userId $match`, () => {
      const args = {
        collection,
        pipeline: [{ $match: { category: "headphones" } }],
      };
      const result = inject("mongodb_aggregate", args) as Record<string, unknown>;
      const pipeline = result.pipeline as Record<string, unknown>[];
      // Pipeline must be unchanged — no userId stage prepended
      expect(pipeline).toHaveLength(1);
      const firstMatch = (pipeline[0] as Record<string, unknown>)["$match"] as Record<string, unknown>;
      expect(firstMatch.userId).toBeUndefined();
    });
  }

  test("collection name comparison is case-insensitive", () => {
    const result = inject("mongodb_query", {
      collection: "PRODUCTS",
      filter: { category: "test" },
    }) as Record<string, unknown>;
    const filter = result.filter as Record<string, unknown>;
    expect(filter.userId).toBeUndefined();
  });
});

// ─────────────────────────────────────────────────────────────────────────────
describe("UNKNOWN tool names pass through unchanged", () => {
  test("unrecognised tool name: args returned as-is (no userId injection)", () => {
    const args = { collection: "orders", query: "something" };
    const result = inject("some_unknown_tool", args);
    expect(result).toEqual(args);
  });

  test("read_skill_resource: no injection", () => {
    const args = { collection: "orders", filter: { orderId: "123" } };
    const result = inject("read_skill_resource", args);
    expect(result).toEqual(args);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
describe("Non-plain-object args are returned unchanged", () => {
  test("null args returned as null", () => {
    expect(inject("mongodb_query", null)).toBeNull();
  });

  test("string args returned as-is", () => {
    expect(inject("mongodb_query", "bad-args")).toBe("bad-args");
  });

  test("array args returned as-is", () => {
    const arr = [{ collection: "orders" }];
    expect(inject("mongodb_query", arr)).toBe(arr);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
describe("userId identity correctness", () => {
  test("different users get their own userId injected (no mixing)", () => {
    const aliceResult = injectUserIdIntoArgs("mongodb_query", { collection: "agent_memory_facts" }, "alice-sub");
    const bobResult = injectUserIdIntoArgs("mongodb_query", { collection: "agent_memory_facts" }, "bob-sub");

    expect(((aliceResult as Record<string, unknown>).filter as Record<string, unknown>).userId).toBe("alice-sub");
    expect(((bobResult as Record<string, unknown>).filter as Record<string, unknown>).userId).toBe("bob-sub");
  });

  test("injected args are a new object (original not mutated)", () => {
    const original = { collection: "agent_memory_facts", filter: { factHash: "h1" } };
    const result = inject("mongodb_query", original);

    // Result is a different reference
    expect(result).not.toBe(original);
    // Original filter is untouched
    expect((original.filter as Record<string, unknown>).userId).toBeUndefined();
    // Injected result has userId
    expect(((result as Record<string, unknown>).filter as Record<string, unknown>).userId).toBe(USER);
  });

  test("chat_messages is treated as a private collection (userId injected)", () => {
    const result = inject("mongodb_query", {
      collection: "chat_messages",
      filter: { role: "user" },
    }) as Record<string, unknown>;
    const filter = result.filter as Record<string, unknown>;
    expect(filter.userId).toBe(USER);
  });

  test("agent_memory_facts is treated as a private collection (userId injected)", () => {
    const result = inject("mongodb_query", {
      collection: "agent_memory_facts",
      filter: {},
    }) as Record<string, unknown>;
    const filter = result.filter as Record<string, unknown>;
    expect(filter.userId).toBe(USER);
  });

  test("orders is treated as a private collection (userId injected)", () => {
    const result = inject("mongodb_query", {
      collection: "orders",
      filter: { status: "pending" },
    }) as Record<string, unknown>;
    const filter = result.filter as Record<string, unknown>;
    expect(filter.userId).toBe(USER);
  });
});
