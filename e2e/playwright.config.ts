/// <reference types="node" />
import { defineConfig } from "@playwright/test";

// e2e/ runs Playwright tests against an already-deployed stack — set
// API_URL (and optionally UI_URL) before running. There is no in-tree stub
// server: production code requires AWS credentials + a real AgentCore
// Runtime ARN, so we never spin up a local API in CI.
const apiBaseUrl = process.env["API_URL"] ?? "http://localhost:3000";

export default defineConfig({
  testDir: ".",
  testMatch: ["tests/api.spec.ts"],
  timeout: 240000,
  retries: 0,
  fullyParallel: false,
  workers: 1,
  outputDir: process.env["PW_OUTPUT_DIR"] ?? "test-results",
  reporter: [["list"], ["html", { open: "never", outputFolder: "playwright-report" }]],
  use: {
    baseURL: apiBaseUrl,
    headless: true,
    screenshot: "only-on-failure",
  },
  projects: [{ name: "chromium", use: { browserName: "chromium" } }],
});
