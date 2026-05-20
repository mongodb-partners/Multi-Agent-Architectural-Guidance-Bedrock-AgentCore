# `e2e/` — Playwright E2E smoke tests

These Playwright specs run against an **already-deployed** API. There is no in-tree stub server: the production code requires AWS credentials and a real AgentCore Runtime, so we never spin up a local API in CI.

> **Companion:** [`e2e-smoke/`](../e2e-smoke/) holds the **Python** post-deploy smoke tests (`post-deploy-smoke.py`, `memory-recall-diagnostic.py`) that run against live AWS. See [`docs/reference/smoke-tests.md`](../docs/reference/smoke-tests.md) for the canonical inventory.

## Quick start

```bash
cd e2e
bun install
bunx playwright install chromium

API_URL=http://your-api-host:3000 bun run test
```

The default `tests/api.spec.ts` only hits read-only public endpoints (`/health`, `/agents`, `/skills`) so it's safe to run against any environment. Add chat-flow specs as needed for environments where you control auth and billing.

## When to run

| Scenario | Run |
|---|---|
| Post-deploy gate on a feature branch | `API_URL=… bun run test` after `deploy-api.sh` |
| Local dev against `bun run dev` | `API_URL=http://localhost:3000 bun run test` |
| CI on PRs | Not in the default `ci.yml` matrix today (no public deployed env in CI); promote to `deploy.yml` once a long-lived `dev` environment exists. |

## Adding chat-flow specs

Authenticated chat tests need a Cognito access token. Wire `AUTH_BEARER` into the request headers in your spec — never embed real credentials in the repo. For local dev with `DEV_MOCK_BACKENDS=1` and `REQUIRE_AUTH=true`, any non-empty string works as a stub token.
