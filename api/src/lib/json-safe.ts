import type { JSONValue } from "@strands-agents/sdk";

/** Serialize MongoDB/BSON-friendly values into JSON-safe structures for tools. */
export function toJsonValue(value: unknown): JSONValue {
  return JSON.parse(
    JSON.stringify(value, (_k, v) => {
      if (v != null && typeof v === "object" && "toHexString" in v && typeof (v as { toHexString: () => string }).toHexString === "function") {
        return (v as { toHexString: () => string }).toHexString();
      }
      if (typeof v === "bigint") return v.toString();
      return v;
    }),
  ) as JSONValue;
}
