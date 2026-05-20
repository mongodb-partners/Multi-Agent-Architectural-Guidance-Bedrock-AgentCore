# `ui/` — Streamlit demo client

Python + Streamlit chat UI for the Bedrock Multi-Agent stack. Connects to the API at `API_BASE_URL` and streams SSE chat responses, with a Sessions page, a debug-grade Trace Viewer, and a Cognito hosted-UI / embedded login gate.

> **Authoritative docs:**
>
> - [`docs/demo-mode-guide.md`](../docs/demo-mode-guide.md) — demo flow + env knobs
> - [`docs/trace-viewer-client-guide.md`](../docs/trace-viewer-client-guide.md) — client-friendly Trace Viewer walkthrough
> - [`docs/trace-viewer-developer-guide.md`](../docs/trace-viewer-developer-guide.md) — debug-grade Trace Viewer
> - [`docs/configuration-guide.md`](../docs/configuration-guide.md) + [`docs/reference/env-vars.md`](../docs/reference/env-vars.md) — env vars

## Quick start (local)

```bash
cd ui
pip install -r requirements.txt
export API_BASE_URL=http://localhost:3000
streamlit run app.py
```

The UI runs on `http://localhost:8501`. With `DEV_MOCK_BACKENDS=1` on the API and no Cognito env vars set, you can chat anonymously (the API issues a stub user). For live AWS, set `STREAMLIT_COGNITO_POOL_ID` + `STREAMLIT_COGNITO_CLIENT_ID` (+ `STREAMLIT_COGNITO_CLIENT_SECRET` when the client is configured "with secret"; the region is encoded in the pool id). For the hosted UI flow, also set `STREAMLIT_COGNITO_DOMAIN` + `STREAMLIT_COGNITO_REDIRECT_URI`.

## Layout

| Path | Role |
|---|---|
| `app.py` | Streamlit entrypoint — chat panel, demo prompts, sidebar agent picker. |
| `pages/1_Sessions.py` | Lists past sessions for the signed-in user; resume / delete actions. |
| `pages/2_Trace_Viewer.py` | Debug-grade Trace Viewer — fetches `?include=core` by default and `?include=dev` on demand. |
| `lib/api_client.py` | Typed HTTP client for the API (SSE chat, sessions, agents, traces, health). |
| `lib/cognito_gate.py` | Hosted-UI redirect or embedded login (uses `streamlit-cognito-auth` when configured). |
| `lib/inline_summary.py` | Per-turn summary card on the chat panel (skills, vector search previews, LTM toast). |
| `lib/client_trace_view.py` | Demo-friendly Trace Viewer renderers (default mode). |
| `lib/developer_trace_view.py` | Debug-grade Trace Viewer renderers (`?include=dev` lazy-loaded). |
| `lib/trace_view_helpers.py` | Shared Trace Viewer helpers — handles `_omittedForCoreMode` sentinels, byte-cap badges, projection enforcement. |
| `lib/log.py` | Structured JSON logging (`log.info / warn / error / debug`) — grep the same way as the API. |
| `lib/cognito_gate.py` | Hosted UI / embedded login (skip when `STREAMLIT_AUTH_DISABLED=1` for local dev). |
| `scripts/render_dev_fixture.py` | Renders a captured trace fixture into the Developer Trace Viewer for screenshot/visual review. |
| `scripts/render_ltm_fixture.py` | Renders a long-term memory fixture in isolation. |
| `tests/` | Pytest suites for Streamlit-side helpers + Cognito gate. |
| `Dockerfile` | Streamlit container image. Build context = `ui/`. |

## Auth modes

| Mode | Trigger | Behavior |
|---|---|---|
| **Anonymous (local)** | `STREAMLIT_AUTH_DISABLED=1` or no Cognito env vars set | UI calls the API with no Bearer token; API issues a stub `userId` when `DEV_MOCK_BACKENDS=1`. |
| **Cognito hosted UI** | `STREAMLIT_COGNITO_DOMAIN` + `STREAMLIT_COGNITO_REDIRECT_URI` set | Redirect to Cognito hosted UI; access token cached server-side. |
| **Cognito embedded login** | `STREAMLIT_COGNITO_POOL_ID` + `STREAMLIT_COGNITO_CLIENT_ID` set, no domain | Username/password form rendered in-page via `streamlit-cognito-auth`. |

All authenticated modes send `Authorization: Bearer <cognito-access-token>` to the API.

## Trace Viewer modes

The Trace Viewer fetches `?include=core` on initial load (lite projection — dev-only event types + heavy fields replaced with `{ _omittedForCoreMode: true, bytesAvailable: N, wasRedacted? }` sentinels) and `?include=dev` on demand when the user clicks **Show developer details**.

`lib/api_client.py:get_trace` asserts the response header `X-Trace-Include: core|dev|full` matches the requested projection so a routing regression that silently downgrades a request becomes a UI-test failure. Audit log channel emits `[trace] fetch` with the `include` field for SOC2 review.

## Logging

For Streamlit-side diagnostics, prefer `lib/log.py` (`log.info / warn / error / debug`) so support engineers can grep the same JSON format as the API stdout. `print()` and `st.write(...)` are fine for transient debug.
