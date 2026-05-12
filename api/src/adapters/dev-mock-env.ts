/** True when local dev should use mock LLM + fixture data instead of AWS / Atlas. */
export function isDevMockBackends(): boolean {
  const v = process.env.DEV_MOCK_BACKENDS?.trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}
