# Playwright E2E (API)

Starts the **Bun API** from `../api` with `CHAT_MODE=stub` and `PORT=3456` (no Bedrock, no Streamlit).

```bash
cd api && bun install
cd ../e2e && bun install && bunx playwright install chromium
bun run test
```

CI runs `playwright install --with-deps chromium` for system deps on Linux.
