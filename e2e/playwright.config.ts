/// <reference types="node" />
import { defineConfig } from '@playwright/test';

const isCI = !!process.env['CI'];
const apiBaseUrl = process.env['API_URL'] ?? 'http://localhost:3000';
const useExternalTargets =
  process.env['PW_SKIP_WEBSERVER'] === '1' ||
  !!process.env['UI_URL'] ||
  !!process.env['API_URL'];

export default defineConfig({
  testDir: '.',
  // In CI only run the stub API tests — browser tests need live Bedrock + Streamlit
  testMatch: isCI ? ['tests/api.spec.ts'] : ['**/*.spec.ts'],
  timeout: 240000,
  retries: 0,
  fullyParallel: false,
  workers: 1,                   // one test at a time to avoid rate limiting
  outputDir: process.env['PW_OUTPUT_DIR'] ?? 'test-results',
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }]],
  use: {
    baseURL: apiBaseUrl,  // API base — browser tests use full UI_URL from helpers.ts
    headless: true,
    launchOptions: { slowMo: isCI ? 0 : 200 },
    screenshot: 'only-on-failure',
    video: (process.env['PW_VIDEO'] as 'off' | 'on' | 'retain-on-failure' | 'on-first-retry') ?? 'retain-on-failure',
  },
  webServer: useExternalTargets ? undefined : {
    command: 'CHAT_MODE=stub bun run src/index.ts',
    cwd: '../api',
    port: 3000,
    reuseExistingServer: true,   // reuse local dev server if already running
    timeout: 30000,
  },
  projects: [
    { name: 'chromium', use: { browserName: 'chromium' } },
  ],
});
