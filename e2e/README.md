# Playwright E2E smoke tests

These Playwright specs run against an **already-deployed** API. There is no
in-tree stub server: the production code requires AWS credentials and a real
AgentCore Runtime, so we never spin up a local API in CI.

```bash
cd e2e && bun install && bunx playwright install chromium

# Point at your deployed API (EC2, ECS, etc.)
API_URL=http://your-api-host:3000 bun run test
```

The default `tests/api.spec.ts` only hits read-only public endpoints
(`/health`, `/agents`, `/skills`) so it's safe to run against any environment.
Add chat-flow specs as needed for environments where you control auth and
billing.
