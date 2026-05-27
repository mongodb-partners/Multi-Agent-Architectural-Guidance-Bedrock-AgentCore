/**
 * Smoke test: assert that the `embed_multimodal_content` Strands tool's
 * `inputSchema` (a `z.discriminatedUnion("type", […])` per the Voyage SDK
 * segment shape) serializes through Strands' tool-spec converter into a
 * non-empty JSON schema that still exposes the `type` discriminator.
 *
 * Why this matters: Claude (the default chat model) consumes the tool
 * spec verbatim. If Strands' `zodSchemaToJsonSchema` drops the
 * discriminator or flattens the union, the model has no way to express
 * `{ type: "image_url", … }` vs `{ type: "image_base64", … }` and the
 * agent loop quietly degrades multimodal intent to a single shape (or
 * fails tool validation entirely at chat time).
 *
 * Catching this at validate-time, not chat-time, is the whole point.
 *
 * Run with `bun run scripts/validate-strands-tool-schema.ts`. Exits 0 on
 * success, 2 on a missing-discriminator regression. Add to the
 * `validate:strands-*` family in `api/package.json` (`validate:strands-tools`).
 *
 * No network required. The tool's `callback` is never executed.
 */

import { embedMultimodalContentTool } from "../src/lib/base-tools.ts";

type JsonSchema = Record<string, unknown> & {
  type?: string;
  properties?: Record<string, JsonSchema>;
  items?: JsonSchema | JsonSchema[];
  anyOf?: JsonSchema[];
  oneOf?: JsonSchema[];
  allOf?: JsonSchema[];
  required?: string[];
  enum?: unknown[];
  const?: unknown;
};

const toolAny = embedMultimodalContentTool as {
  toolSpec?: {
    name?: string;
    description?: string;
    inputSchema?: JsonSchema;
  };
};
const spec = toolAny.toolSpec;
if (!spec || !spec.inputSchema || typeof spec.inputSchema !== "object") {
  console.error(
    "validate-strands-tool-schema: embed_multimodal_content has no toolSpec.inputSchema — " +
      "Strands' Zod→JSON-Schema converter may have failed silently.",
  );
  process.exit(2);
}

// 0. Name + description are required by every Bedrock/Claude tool-call API.
//    A missing or empty description is a silent regression — the model will
//    still see the tool but with no idea when to call it.
if (!spec.name || spec.name !== "embed_multimodal_content") {
  console.error(
    `validate-strands-tool-schema: toolSpec.name="${spec.name}" — expected "embed_multimodal_content"`,
  );
  process.exit(2);
}
if (typeof spec.description !== "string" || spec.description.trim().length < 40) {
  console.error(
    `validate-strands-tool-schema: toolSpec.description is missing or too short (${(spec.description ?? "").length} chars). ` +
      "Claude needs a substantive description to route correctly.",
  );
  process.exit(2);
}

const schema = spec.inputSchema;

// 1. Schema must be a non-empty object.
const keys = Object.keys(schema);
if (keys.length === 0) {
  console.error("validate-strands-tool-schema: inputSchema is empty");
  process.exit(2);
}

// 2. Look for the discriminator anywhere in the schema tree. The Strands
//    converter wraps z.discriminatedUnion as `anyOf` / `oneOf` of objects
//    each containing a literal `type` property. We search for ANY object
//    in the tree whose properties include a `type` enum or literal so
//    that future converter changes (e.g. moving from oneOf → anyOf or
//    adding a wrapper) still pass as long as the discriminator survives.
function findDiscriminator(node: unknown, path = "$"): { path: string; values: string[] } | null {
  if (!node || typeof node !== "object") return null;
  const s = node as JsonSchema;

  // Direct hit: this object has a `type` property whose schema is a const
  // / enum / literal listing the segment kinds.
  if (s.properties && typeof s.properties === "object") {
    const typeProp = s.properties.type as JsonSchema | undefined;
    if (typeProp) {
      const candidate =
        (Array.isArray((typeProp as { enum?: unknown[] }).enum) &&
          ((typeProp as { enum?: unknown[] }).enum as unknown[])) ||
        ((typeProp as { const?: unknown }).const !== undefined
          ? [(typeProp as { const?: unknown }).const]
          : null);
      if (candidate && candidate.length > 0) {
        const values = candidate.map((v) => String(v));
        if (
          values.includes("text") ||
          values.includes("image_url") ||
          values.includes("image_base64")
        ) {
          return { path: `${path}.properties.type`, values };
        }
      }
    }
  }

  for (const k of Object.keys(s)) {
    const child = (s as Record<string, unknown>)[k];
    if (Array.isArray(child)) {
      for (let i = 0; i < child.length; i++) {
        const r = findDiscriminator(child[i], `${path}.${k}[${i}]`);
        if (r) return r;
      }
    } else if (child && typeof child === "object") {
      const r = findDiscriminator(child, `${path}.${k}`);
      if (r) return r;
    }
  }
  return null;
}

const found = findDiscriminator(schema);
if (!found) {
  console.error(
    "validate-strands-tool-schema: NO `type` discriminator found in serialized JSON Schema. " +
      "Strands SDK's Zod→JSON-Schema converter collapsed z.discriminatedUnion. " +
      "Claude tool calls will not be able to differentiate text vs image segments.",
  );
  console.error("---serialized inputSchema---");
  console.error(JSON.stringify(schema, null, 2).slice(0, 4000));
  process.exit(2);
}

// 3. Confirm all three expected discriminator values are represented
//    somewhere in the schema tree (across however many oneOf/anyOf
//    branches the converter chose).
function collectDiscriminatorValues(node: unknown, acc: Set<string>): void {
  if (!node || typeof node !== "object") return;
  const s = node as JsonSchema;
  if (s.properties && typeof s.properties === "object") {
    const typeProp = s.properties.type as JsonSchema | undefined;
    if (typeProp) {
      const enumVals = (typeProp as { enum?: unknown[] }).enum;
      if (Array.isArray(enumVals)) {
        for (const v of enumVals) acc.add(String(v));
      }
      const constVal = (typeProp as { const?: unknown }).const;
      if (constVal !== undefined) acc.add(String(constVal));
    }
  }
  for (const k of Object.keys(s)) {
    const child = (s as Record<string, unknown>)[k];
    if (Array.isArray(child)) {
      for (const item of child) collectDiscriminatorValues(item, acc);
    } else if (child && typeof child === "object") {
      collectDiscriminatorValues(child, acc);
    }
  }
}

const allValues = new Set<string>();
collectDiscriminatorValues(schema, allValues);
const required = ["text", "image_url", "image_base64"];
const missing = required.filter((v) => !allValues.has(v));
if (missing.length > 0) {
  console.error(
    `validate-strands-tool-schema: discriminator missing values: ${missing.join(", ")}. ` +
      `Found: ${[...allValues].join(", ")}`,
  );
  console.error("---serialized inputSchema---");
  console.error(JSON.stringify(schema, null, 2).slice(0, 4000));
  process.exit(2);
}

// 4. Top-level shape: { inputs: array(array(segment)), inputType?: enum }.
//    Claude *must* see `inputs` as a required, array-of-array property — if
//    Strands collapses the outer array, the model will send `inputs:[segment]`
//    (flat) and the SageMaker container rejects it as a Pydantic schema error
//    — exactly the original client-side 400 we are guarding against.
const topLevelProps = schema.properties as Record<string, JsonSchema> | undefined;
if (!topLevelProps || typeof topLevelProps !== "object") {
  console.error("validate-strands-tool-schema: inputSchema has no `properties` map");
  process.exit(2);
}
const inputsProp = topLevelProps.inputs;
if (!inputsProp || typeof inputsProp !== "object") {
  console.error("validate-strands-tool-schema: inputSchema.properties.inputs is missing");
  process.exit(2);
}
if (inputsProp.type !== "array") {
  console.error(
    `validate-strands-tool-schema: inputs.type=${JSON.stringify(inputsProp.type)} — expected "array". ` +
      "Strands collapsed the outer array; multimodal batching will fail.",
  );
  process.exit(2);
}
const inputsItems = Array.isArray(inputsProp.items) ? inputsProp.items[0] : inputsProp.items;
if (!inputsItems || typeof inputsItems !== "object" || inputsItems.type !== "array") {
  console.error(
    "validate-strands-tool-schema: inputs.items is not itself an array. " +
      "MultimodalItem (Array<segment>) was flattened — each input must be an array of segments.",
  );
  console.error("---inputs prop---");
  console.error(JSON.stringify(inputsProp, null, 2).slice(0, 2000));
  process.exit(2);
}
const topLevelRequired = (schema.required as string[] | undefined) ?? [];
if (!topLevelRequired.includes("inputs")) {
  console.error(
    `validate-strands-tool-schema: top-level required=${JSON.stringify(topLevelRequired)} does not include "inputs". ` +
      "Claude may omit the field entirely.",
  );
  process.exit(2);
}

// 5. Per-branch required fields. Each discriminated branch must demand its
//    kind-specific payload, otherwise the model can emit `{type:"image_url"}`
//    with no actual URL and the runtime will be unhappy.
const KIND_FIELDS: Record<string, string> = {
  text: "text",
  image_url: "image_url",
  image_base64: "image_base64",
};
type BranchCheck = { kind: string; ok: boolean; reason?: string };
const branchChecks: BranchCheck[] = [];
function inspectBranches(node: unknown): void {
  if (!node || typeof node !== "object") return;
  const s = node as JsonSchema;
  if (s.properties && typeof s.properties === "object") {
    const typeProp = s.properties.type as JsonSchema | undefined;
    if (typeProp) {
      const kinds: string[] = Array.isArray(typeProp.enum)
        ? typeProp.enum.map((v) => String(v))
        : typeProp.const !== undefined
          ? [String(typeProp.const)]
          : [];
      for (const k of kinds) {
        const expected = KIND_FIELDS[k];
        if (!expected) continue;
        const hasField = s.properties[expected] !== undefined;
        const req = Array.isArray(s.required) ? s.required : [];
        const isRequired = req.includes(expected);
        branchChecks.push({
          kind: k,
          ok: hasField && isRequired,
          reason: !hasField
            ? `branch missing field "${expected}"`
            : !isRequired
              ? `branch has "${expected}" but does not mark it required`
              : undefined,
        });
      }
    }
  }
  for (const k of Object.keys(s)) {
    const child = (s as Record<string, unknown>)[k];
    if (Array.isArray(child)) {
      for (const item of child) inspectBranches(item);
    } else if (child && typeof child === "object") {
      inspectBranches(child);
    }
  }
}
inspectBranches(schema);
const seenKinds = new Set(branchChecks.map((b) => b.kind));
for (const k of Object.keys(KIND_FIELDS)) {
  if (!seenKinds.has(k)) {
    console.error(
      `validate-strands-tool-schema: no branch found for kind="${k}". ` +
        "Discriminated union was flattened away from the per-branch schema.",
    );
    process.exit(2);
  }
}
const branchFailures = branchChecks.filter((b) => !b.ok);
if (branchFailures.length > 0) {
  console.error("validate-strands-tool-schema: branch field requirements failed:");
  for (const b of branchFailures) console.error(`  - kind=${b.kind}: ${b.reason}`);
  process.exit(2);
}

console.log(
  `validate-strands-tool-schema: embed_multimodal_content OK ` +
    `(name="${spec.name}", desc=${spec.description.length}ch, ` +
    `discriminator at ${found.path}, ` +
    `values=${[...allValues].sort().join(",")}, ` +
    `inputs=array<array<segment>> required, ` +
    `branches=${branchChecks.length} all ok)`,
);
