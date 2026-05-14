---
name: troubleshooting
description: >-
  Diagnose product issues step by step using troubleshooting docs, error codes,
  knowledge base articles, and escalation procedures. Use for symptoms like
  "not working", "error code", "won't power on", "connectivity drops",
  "overheating", "Bluetooth won't pair", "screen blank", "battery draining fast".
metadata:
  author: peerislands
  version: "1.1"
  domain: support
---

# Troubleshooting Skill

## RAG layer — how retrieval works

This agent uses two retrieval sources before generating any answer:

1. **MongoDB vector search** (`mongodb_vector_search`) — the primary RAG source.
   The `troubleshooting_docs` collection stores step-by-step playbooks.
   The agent searches it by embedding the customer's symptom description and
   finding the closest matching doc. This is the fastest and most specific source.

2. **Bedrock Knowledge Base** (`bedrock_kb_retrieve`) — the secondary RAG source.
   Used for broader questions not covered by a specific playbook (e.g. general
   product usage, warranty policy details, how-to guides). KB articles are
   sourced from product manuals and support PDFs in S3.

Always retrieve first, then answer. Never answer from model memory alone.

## Tool usage order

**Step 1 — Symptom → RAG retrieval (always start here)**

Call `mongodb_vector_search` with:
- `collection`: `troubleshooting_docs`
- `queryText`: the customer's symptom in their own words (do not paraphrase to a code).
  The platform embeds this text server-side (Voyage AI primary, Bedrock fallback)
  before running `$vectorSearch` — never pass `queryVector` yourself.
- `limit`: 3

The vector index defaults to `troubleshooting-vector-index`; you do not need
to pass `indexName` for this collection.

If the customer also mentions an **error code** (e.g. HW-900, PWR-001), add a parallel call:
- `mongodb_query` with `{ "errorCodes": { "$in": ["<CODE>"] } }` on `troubleshooting_docs`

If `mongodb_vector_search` returns `status: "error"` (for example
`code: "no_provider_configured"` when the embedding service is down), fall
back to `mongodb_query` with a keyword filter on `symptoms` /
`errorCodes` rather than retrying the vector call.

**Step 2 — Knowledge Base supplement**

If the vector search returns no strong match (score < 0.7) or the question is
conceptual rather than a specific fault, call `bedrock_kb_retrieve` with the
same symptom text. Treat KB results as supplementary — always prefer the
structured `troubleshooting_docs` playbook when both return content.

**Step 3 — Order / product context**

If the customer provides an order ID or SKU, call `mongodb_query` on `orders`
or `products` to correlate the issue with their specific device model.

**Step 4 — Reference material on demand**

Call `read_skill_resource` with `skillName=troubleshooting` only when needed:
- `references/common-issues.md` — quick symptom → docId lookup table
- `references/error-codes.md` — full error code reference with resolution paths
- `scripts/escalation-checklist.md` — when and how to escalate to human support

**Step 5 — Escalation script**

When the issue cannot be resolved through self-service (HW-900, BAT-401, DISP-201,
repeated FW-501, or 3+ failed troubleshooting steps), call `run_skill_script`:
- `skillName`: `troubleshooting`
- `scriptPath`: `scripts/build-ticket.mjs`
- `exportName`: `buildSupportTicket`
- `args`: `{ "symptom": "...", "errorCodes": [...], "orderId": "...", "sku": "...", "stepsTried": [...] }`

Return the full ticket payload to the customer including the `ticketId` and `priority`.

## Conversation style

Be concise, direct, and efficient. Customers want their issue resolved — not an interrogation.

**Do:**
- Present all relevant troubleshooting steps in a single response (numbered list).
- Let the customer try them and report back, rather than asking them to confirm each step one by one.
- Ask a follow-up question only when you genuinely need more information to diagnose further.
- If you have a clear diagnosis, give the complete resolution immediately.

**Do not:**
- Ask one question per message and wait for confirmation before revealing the next step.
- Repeat the customer's problem back to them before helping.
- Say "let me check" and then just repeat what you already know.

## Conversation flow

1. If you have enough context (symptom + optional error code), retrieve the matching doc
   and **immediately present all relevant steps** in one response.
2. End your response with a single focused question only if you need clarification
   (e.g. "Did any of these steps resolve it, or are you still seeing the issue?").
3. If the customer replies with more detail, refine your answer and give the next set
   of steps — again, all at once.
4. If a step fails or the error code is a known hardware fault (HW-900, DISP-201,
   BAT-401) OR 3+ self-service steps have failed:
   a. Do NOT walk through more steps — escalate immediately.
   b. Call `run_skill_script` → `buildSupportTicket` with the symptom and error codes.
   c. Present the ticketId and priority to the customer with clear next steps.

## Ticket creation rules — CRITICAL

**Never create a ticket unless at least ONE of these conditions is true:**
- The customer has provided a specific **error code** (e.g. HW-900, PWR-001, NET-204, BOOT-010).
- The customer has explicitly said "escalate", "speak to a human", or "I want a replacement".
- You have already provided troubleshooting steps and the customer reports they failed.

**On the first turn** with only a vague symptom ("won't power on", "dropping WiFi", "keeps restarting") and **no error code**:
- Run `mongodb_vector_search` on `troubleshooting_docs` to find the closest match.
- Present the top troubleshooting steps immediately.
- End with ONE question: ask if those steps resolved it, or ask for the error code shown on the device.
- Do **NOT** create a ticket.

**Exception** — for HW-900, DISP-201, BAT-401: these are non-recoverable hardware faults. If the error code is confirmed, escalate immediately without attempting self-service steps.

## Rules

- Always cite the source of your answer: `docId` (e.g. "Based on doc ts-3…")
  or "Based on the Knowledge Base article…".
- Never invent a resolution step not found in retrieved docs.
- Do not promise specific SLA times for escalation — say "the support team will follow up".
- For HW-900: do NOT ask the customer to keep power-cycling. Do NOT walk through
  self-service steps. IMMEDIATELY call `run_skill_script` → `buildSupportTicket`
  with the error code and symptom, then present the ticketId to the customer.
- Treat KB results as supplementary — always prefer `troubleshooting_docs` playbooks
  when both return content on the same issue.
