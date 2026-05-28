# Multi-specialist UI checklist

Manual end-to-end check of the multi-specialist orchestration changes in the deployed Streamlit UI. Run this **after** the automated phases of the deploy-and-test plan have landed green ([`docs/status/debugging.md`](../status/debugging.md) has the standing playbook for any single failure surfaced here).

This walk validates four behaviors that are only fully visible in the browser:

1. **Single-domain fast path** — orchestrator hands off to one specialist, no synthesizer card.
2. **Cross-domain synthesis** — two specialist drafts stream live, then a single synthesized final answer replaces them.
3. **Full-trace Routing Decisions** block renders the multi-specialist layout.
4. **Developer Trace Viewer** exposes the raw multi-specialist event payloads.

It should take ~5–7 minutes.

---

## 0. Prerequisites

| Item | Value |
|---|---|
| UI URL | `http://44.215.34.82:8501` |
| Cognito email | `alex@example.com` |
| Cognito password | `DemoUser#2026` |
| Cognito pool id | `us-east-1_oPpqw8ty0` (`STREAMLIT_COGNITO_POOL_ID` in [`.env.live`](../../.env.live)) |
| Seeded order id used in step 1 + 2 | `ORD-1001` (from [`db-seeding/seed-orders.ts:14`](../../db-seeding/seed-orders.ts)) |

> The Streamlit UI lives on port **8501**. The API on port **3000** is not directly browseable.

### Optional Cognito user health check

```bash
source .env.live
aws cognito-idp list-users \
  --user-pool-id "$STREAMLIT_COGNITO_POOL_ID" \
  --filter 'email = "alex@example.com"' \
  --query 'Users[0].{u:Username,s:UserStatus}'
```

Expect `s: CONFIRMED`. If you see `RESET_REQUIRED` or `FORCE_CHANGE_PASSWORD`:

```bash
aws cognito-idp admin-set-user-password \
  --user-pool-id "$STREAMLIT_COGNITO_POOL_ID" \
  --username alex@example.com \
  --password 'DemoUser#2026' \
  --permanent
```

---

## 1. Sign in and select the Orchestrator persona

1. Open `http://44.215.34.82:8501`.
2. Sign in with the credentials above.
3. In the left sidebar, **select the "Orchestrator" persona**.

> **Why this matters:** if you pick a specialist (Order Management, Product Recommendation, Troubleshooting) directly, the API skips the classifier entirely. The multi-specialist layout and the new trace events never appear. Steps 2 and 3 below rely on the orchestrator path.

---

## 2. Single-domain fast path

**Send this prompt:**

```
Where is my order ORD-1001?
```

**Expected:**

- One assistant bubble appears.
- The agent badge on the bubble resolves to **Order Management** (the orchestrator hands off via the fast path).
- **No specialist-draft cards** are rendered (only single-specialist routing happened).
- The reply mentions order `ORD-1001` and its shipping/tracking status.

**Capture for the test log:** the `x-trace-id` from this turn (visible in the trace card or via "View full trace" → URL).

---

## 3. Cross-domain synthesis with live specialist drafts

**Send this prompt:**

```
Track my order ORD-1001 AND recommend a waterproof outdoor headphone under $80
```

**Expected (watch the streaming behavior closely):**

- Two **specialist-draft blocks** render live as the specialists stream their answers — one attributed to Order Management, one to Product Recommendation.
- After both specialists finish, the two draft blocks are **replaced** (or collapsed/superseded) by a single **synthesized final answer**. The synthesized answer should mention both the order status AND a headphone recommendation.
- Only the **synthesized final answer** is persisted in the chat history (refresh and re-open the session to confirm — the specialist drafts should not appear in the persisted thread).

**Capture for the test log:** the `x-trace-id` from this turn.

---

## 4. "View full trace" → Routing Decisions block

1. On the cross-domain reply from step 3, click **"View full trace"**.
2. In the Routing Decisions section, confirm the **multi-specialist layout** renders. Specifically:
   - A **path label** (e.g. "synthesis").
   - **Chips** for each selected specialist (Order Management, Product Recommendation).
   - A **specialist-drafts expander** showing both drafts with their attribution.
   - A **synthesizer agent block** showing the synthesizer's role and contribution.
   - A **rejected alternatives** list (any specialists the classifier considered but did not pick — Troubleshooting is the likely candidate here).

Reference: [`docs/trace-viewer-guide.md`](../trace-viewer-guide.md).

**Failure modes to flag:**

- The Routing Decisions section is missing or shows the old single-handoff layout → trace UI did not pick up the new event types.
- Specialist drafts expander is empty even though step 3 showed live drafts → `trace-projection.ts` is stripping the wrong fields, or `orchestrator.specialist_draft` events are not being persisted.

---

## 5. Developer Trace Viewer multi-specialist internals

1. From the same trace (still on the cross-domain turn from step 3), open the **Developer Trace Viewer**.
2. Locate the **"Multi-specialist orchestration internals"** section.
3. Confirm it renders three raw payloads:
   - `orchestrator.multi_route_decision` — shows the classifier's input + every candidate's score + which were selected.
   - `orchestrator.specialist_draft` — one per selected specialist, with timing, status, and answer preview.
   - `orchestrator.synthesis` — synthesizer agent metadata, input specialists summary, timing.

Reference: [`docs/trace-viewer-developer-guide.md`](../trace-viewer-developer-guide.md).

**Failure modes to flag:**

- Any of the three event types is missing from the section → an upstream code change dropped one of the trace emissions in `multi-specialist-orchestrator.ts` or `specialist-answer-synthesizer.ts`.
- Section renders but payloads are empty (`{}`) → trace projection in `?include=dev` mode is stripping fields that should be retained.

---

## What to capture and where to file it

| Step | Capture | Where to file |
|---|---|---|
| 2 | Trace id + first-screen screenshot | Comment on the PR or paste into the deploy-and-test final report |
| 3 | Trace id + screenshot showing both specialist drafts live + screenshot of the final synthesized answer | Same as above |
| 4 | Screenshot of the Routing Decisions block | Same as above |
| 5 | Screenshot of the Multi-specialist orchestration internals section showing all three payloads expanded | Same as above |

If anything fails: pull the trace JSON from `GET /trace/<trace-id>?include=dev` and attach it. That JSON, plus the screenshot, is enough for a backend engineer to root-cause.

---

## Quick rollback if this walk surfaces a critical UI regression

Backend rollback is documented in the [deploy-and-test plan's Rollback section](../../README.md) — the short version: `git checkout $(cat /tmp/preroll_git_sha) && ./deploy/deploy-api.sh --auto-approve && ./deploy/deploy-agents.sh --auto-approve`.

If only the UI is broken (backend trace JSON looks right but the UI doesn't render it), the issue is likely in `ui/lib/inline_summary.py`, `ui/pages/2_Trace_Viewer.py`, `ui/lib/client_trace_view.py`, or `ui/lib/developer_trace_view.py`. Fix forward via `./deploy/deploy-ui.sh` (UI-only redeploy, ~3 min, no AgentCore touch).
