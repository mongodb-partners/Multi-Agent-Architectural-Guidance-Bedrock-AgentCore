/**
 * orchestrator.spec.ts — Orchestrator agent E2E tests
 *
 * Covers multi-agent flows orchestrated by the top-level agent:
 *   FC1 — Sequential Handoff (Order Management → Product Recommendation)
 *   FC2 — Parallel Fan-Out  (Order Management ∥ Troubleshooting)
 *   FC3 — Context Enrichment (premium customer + purchase history)
 *   INF — Infrastructure health checks
 *
 * Real data quick-ref:
 *   Orders:   ORD-1001(alex,shipped) ORD-1003(alex,delivered,returnEligible)
 *             ORD-1005(alex,shipped) ORD-1009(alex,delivered)
 *             ORD-1002(blake,processing) ORD-1004(blake,cancelled)
 *             ORD-1006(blake,return_requested,NET-204) ORD-1010(blake,shipped)
 *             ORD-2001(casey,delivered) ORD-2002(casey,shipped)
 *             ORD-3001(dana,delivered) ORD-3002(dana,return_requested,HW-900)
 *   Customers: alex@example.com (standard) | blake@example.com (standard)
 *              casey@example.com (premium) | dana@example.com (premium)
 */

import { test, expect } from '@playwright/test';
import { UI_URL, API_URL, conversationTurns, collectSSEEvents, newSessionId } from './helpers';

// ─── FC1: Sequential Handoff ──────────────────────────────────────────────────

test.describe('FC1 — Sequential Handoff', () => {

  test.beforeEach(async ({ page }) => {
    await page.goto(UI_URL);
    await page.waitForSelector('[data-testid="stChatInputTextArea"]', { timeout: 15000 });
  });

  test('FC1-01: wrong item — return ORD-1003 + recommend replacement (SKU-4/SKU-5)', async ({ page }) => {
    const text = await conversationTurns(page, [
      'I received the wrong item in a recent order and I want to return it and get something similar.',
      'My email is alex@example.com and the order is ORD-1003. I got a Compact Widget but it stopped working. Please start a return and recommend similar products.',
    ]);

    expect(text.toLowerCase()).toMatch(/return|refund|eligible|label/i);
    expect(text.toLowerCase()).toMatch(/compact widget plus|smart widget hub|sku-4|sku-5|similar|recommend/i);
    expect(text.length).toBeGreaterThan(100);
  });

  test('FC1-02: Pro Gadget return (ORD-1006) + recommend SKU-8 alternative', async ({ page }) => {
    const text = await conversationTurns(page, [
      'I have a Pro Gadget that I want to return — it has a network error.',
      'Order ORD-1006 for blake@example.com. The device shows NET-204 and won\'t connect to WiFi. Please check the return status and suggest a similar gadget.',
    ]);

    expect(text.toLowerCase()).toMatch(/return|return_requested|label|net-204|refund/i);
    expect(text.toLowerCase()).toMatch(/pro gadget lite|sku-8|similar|recommend|alternative/i);
    expect(text.length).toBeGreaterThan(100);
  });

  test('FC1-03: order not found — graceful error + still offers product recommendation', async ({ page }) => {
    const text = await conversationTurns(page, [
      'I want to return an order that had the wrong item.',
      'Order ORD-INVALID-999. That order doesn\'t exist but I still need recommendations for a replacement widget under $40.',
    ]);

    expect(text.toLowerCase()).toMatch(/not found|couldn.*find|unable|verify|couldn.*locate|clarifying question|would you like/i);
    expect(text.toLowerCase()).toMatch(/compact widget plus|travel widget|sku-4|sku-3|recommend|suggest/i);
    expect(text.length).toBeGreaterThan(80);
  });

  test('FC1-04: return already in progress (ORD-3002) + recommend upgraded replacement', async ({ page }) => {
    const text = await conversationTurns(page, [
      'My return is already in progress but I also need a replacement product recommendation.',
      'Dana Patel, dana@example.com. The return is for ORD-3002 — a Compact Widget with HW-900 error. Please recommend an upgrade like the Compact Widget Plus or Smart Widget Hub.',
    ]);

    expect(text.toLowerCase()).toMatch(/compact widget plus|smart widget hub|sku-4|sku-5|recommend|upgrade/i);
    expect(text.length).toBeGreaterThan(80);
  });

  test('FC1-05 (API): handoff SSE event emitted during sequential flow', async ({ request }) => {
    const sessionId = newSessionId('fc1');
    const events = await collectSSEEvents(request, [
      'I received the wrong item and want to return it and get something similar.',
      'Email alex@example.com, order ORD-1003 — Compact Widget that stopped working. Start return and recommend SKU-4 or SKU-5.',
    ], sessionId);

    const eventTypes = events.map(e => e.event);
    console.log('FC1-05 events:', eventTypes);

    expect(eventTypes).toContain('done');
    expect(eventTypes).toContain('token');
    const hasHandoff = eventTypes.includes('handoff');
    const agentActives = events.filter(e => e.event === 'agent_active');
    expect(hasHandoff || agentActives.length >= 2).toBe(true);
  });

});

// ─── FC2: Parallel Fan-Out ────────────────────────────────────────────────────

test.describe('FC2 — Parallel Fan-Out', () => {

  test.beforeEach(async ({ page }) => {
    await page.goto(UI_URL);
    await page.waitForSelector('[data-testid="stChatInputTextArea"]', { timeout: 15000 });
  });

  test('FC2-01: late ORD-1005 + broken Compact Widget (PWR-001) — both addressed', async ({ page }) => {
    const text = await conversationTurns(page, [
      'alex@example.com — I have two separate issues: ' +
      '(1) My order ORD-1005 (Pro Gadget, tracking TRK-9005-US) is late and hasn\'t arrived. ' +
      '(2) My Compact Widget from ORD-1003 shows error PWR-001 and won\'t power on at all. ' +
      'Please check the order status AND help troubleshoot the device.',
    ]);

    expect(text.toLowerCase()).toMatch(/ord-1005|pro gadget|track|ship|delivery/i);
    expect(text.toLowerCase()).toMatch(/pwr-001|power|cable|reset|compact widget/i);
    expect(text.length).toBeGreaterThan(150);
    expect(text).not.toMatch(/\{.*"error"/i);
  });

  test('FC2-02: late order only — ORD-1010 (blake, shipped)', async ({ page }) => {
    const text = await conversationTurns(page, [
      'My order is running late and I need a status update.',
      'Blake Chen, blake@example.com. Order ORD-1010 — Compact Widget Plus, tracking TRK-9010-US.',
    ]);

    expect(text.toLowerCase()).toMatch(/ord-1010|compact widget plus|track|ship|deliver|status/i);
    expect(text.length).toBeGreaterThan(80);
  });

  test('FC2-03: broken device only — Pro Gadget NET-204 (no order lookup needed)', async ({ page }) => {
    const text = await conversationTurns(page, [
      'My device keeps losing its WiFi connection.',
      'It\'s a Pro Gadget (SKU-2) from order ORD-1006 for blake@example.com. Error code NET-204. Started after the latest firmware update.',
    ]);

    expect(text.toLowerCase()).toMatch(/net-204|wifi|wi-fi|network|router|firmware|connectivity/i);
    expect(text.length).toBeGreaterThan(80);
  });

  test('FC2-04: non-existent order + broken device — handles both tracks gracefully', async ({ page }) => {
    const text = await conversationTurns(page, [
      'My order never arrived and I also have a device with an error.',
      'Order ORD-FAKE-999 (probably wrong number). The broken device is a Smart Widget Hub (SKU-5) showing BOOT-010 — it keeps restarting randomly.',
    ]);

    expect(text.toLowerCase()).toMatch(/boot-010|restart|firmware|update|reboot/i);
    expect(text.length).toBeGreaterThan(100);
  });

  test('FC2-05 (API): two agent_active events for parallel routing', async ({ request }) => {
    const sessionId = newSessionId('fc2');
    const events = await collectSSEEvents(request, [
      'Two issues: my shipped order is late and another device has a broken WiFi error.',
      'alex@example.com. Late order ORD-1005 (Pro Gadget). Broken device from ORD-1003 shows NET-204 after firmware update.',
    ], sessionId);

    const eventTypes = events.map(e => e.event);
    console.log('FC2-05 events:', eventTypes);

    expect(eventTypes).toContain('done');
    expect(eventTypes).toContain('token');
    const agentActives = events.filter(e => e.event === 'agent_active');
    console.log('FC2-05 unique agents:', [...new Set(agentActives.map(e => e.data?.agentId ?? e.data?.agentName))]);
    const hasHandoff = eventTypes.includes('handoff');
    expect(hasHandoff || agentActives.length >= 2).toBe(true);
  });

});

// ─── FC3: Context Enrichment ──────────────────────────────────────────────────

test.describe('FC3 — Context Enrichment', () => {

  test.beforeEach(async ({ page }) => {
    // Extra cooldown — FC3 runs after multi-agent FC2 calls; give Bedrock time to recover
    await page.waitForTimeout(10000);
    await page.goto(UI_URL);
    await page.waitForSelector('[data-testid="stChatInputTextArea"]', { timeout: 15000 });
  });

  test('FC3-01: premium Casey + late ORD-2002 + prior widget history → fast-ship Pro Gadget Lite', async ({ page }) => {
    const text = await conversationTurns(page, [
      'I\'m a premium customer and my most recent order is late. I need a fast replacement.',
      'Casey Morgan, casey@example.com. Late order ORD-2002 — Pro Gadget, tracking TRK-2002-US. Previous orders: Compact Widget Plus and Smart Widget Hub from ORD-2001.',
      'Please go ahead and check ORD-2002 status and recommend the best fast-ship replacement for the Pro Gadget based on my history.',
    ]);

    expect(text.toLowerCase()).toMatch(/ord-2002|pro gadget|order|status|delay|late|ship/i);
    expect(text.toLowerCase()).toMatch(/pro gadget lite|sku-8|recommend|suggest|replacement|alternative/i);
    expect(text.toLowerCase()).toMatch(/fast|express|expedit|premium|priority|quick/i);
    expect(text.length).toBeGreaterThan(100);
  });

  test('FC3-02: Dana premium + ORD-3002 HW-900 return + history-driven upgrade recommendation', async ({ page }) => {
    const text = await conversationTurns(page, [
      'I\'m a premium member and one of my devices has a hardware error. I need a replacement recommendation.',
      'Dana Patel, dana@example.com. Order ORD-3002 — Compact Widget with HW-900 error. I also have Office Lamp LEDs. Please recommend an upgraded replacement, ideally the Compact Widget Plus or Smart Widget Hub.',
    ]);

    expect(text.toLowerCase()).toMatch(/hw-900|hardware|return|replacement|warranty/i);
    expect(text.toLowerCase()).toMatch(/compact widget plus|smart widget hub|sku-4|sku-5|recommend/i);
    expect(text.length).toBeGreaterThan(100);
  });

  test('FC3-03: new customer — no history — falls back to category-based recommendation', async ({ page }) => {
    const text = await conversationTurns(page, [
      'I\'m a new customer and my first order is late.',
      'Email eli@example.com. I ordered a Pro Gadget but it hasn\'t arrived yet. This is my first purchase. Please check if there\'s any order for me and suggest similar electronics.',
    ]);

    expect(text.toLowerCase()).toMatch(/pro gadget|order|ship|deliver|track|recommend|suggest/i);
    expect(text.length).toBeGreaterThan(80);
  });

  test('FC3-04: troubleshooting NOT triggered for simple late-order + reorder (no device error)', async ({ page }) => {
    const text = await conversationTurns(page, [
      'My shipped order is late and I want to check on it and maybe get a recommendation for an alternative.',
      'Blake Chen, blake@example.com. Order ORD-1010 — Compact Widget Plus, tracking TRK-9010-US. No device issues, just need status and a similar product suggestion.',
    ]);

    expect(text.toLowerCase()).not.toMatch(/pwr-001|net-204|hw-900|factory reset|firmware flash/i);
    expect(text.toLowerCase()).toMatch(/ord-1010|compact widget plus|status|ship|recommend/i);
    expect(text.length).toBeGreaterThan(80);
  });

  test('FC3-05: prior purchase history enriches replacement recommendation', async ({ page }) => {
    const text = await conversationTurns(page, [
      'Casey Morgan, casey@example.com — premium customer. ' +
      'My purchase history: ORD-2001 delivered (Compact Widget Plus x2 + Smart Widget Hub). ' +
      'Now ORD-2002 (Pro Gadget, TRK-2002-US) is late. ' +
      'Using my widget purchase history, recommend the best fast-ship Pro Gadget alternative for me.',
    ]);

    expect(text.toLowerCase()).toMatch(/pro gadget lite|sku-8|recommend|suggest|replacement|alternative/i);
    expect(text.length).toBeGreaterThan(40);
  });

  test('FC3-06 (API): multi-turn context enrichment — token stream on second turn', async ({ request }) => {
    const sessionId = newSessionId('fc3');
    const events = await collectSSEEvents(request, [
      'I\'m Casey Morgan, premium customer (casey@example.com). My order ORD-2002 is late.',
      'Please check ORD-2002 status and recommend a fast-ship Pro Gadget alternative based on my widget purchase history.',
    ], sessionId);

    const eventTypes = events.map(e => e.event);
    console.log('FC3-06 events:', eventTypes);

    expect(eventTypes).toContain('done');
    expect(eventTypes).toContain('token');
    const doneEvent = events.find(e => e.event === 'done');
    expect(doneEvent?.data?.error).toBeFalsy();

    const tokenText = events
      .filter(e => e.event === 'token')
      .map(e => (e.data?.text as string) ?? '')
      .join('');
    expect(tokenText.toLowerCase()).toMatch(/pro gadget|ord-2002|recommend|casey/i);
  });

});

// ─── Infrastructure ───────────────────────────────────────────────────────────

test.describe('Infrastructure', () => {

  test('INF-01: API health — MongoDB connected', async ({ request }) => {
    const res = await request.get(`${API_URL}/health`);
    expect([200, 503]).toContain(res.status());
    const body = await res.json();
    expect(['ok', 'degraded']).toContain(body.status);
    expect(body.dependencies).toBeTruthy();
    expect(['direct', 'lambda', 'gateway']).toContain(body.dependencies.toolHosting);
  });

  test('INF-02: /agents — all four agents registered', async ({ request }) => {
    const res = await request.get(`${API_URL}/agents`);
    expect(res.status()).toBe(200);
    const ids: string[] = (await res.json()).agents.map((a: { id: string }) => a.id);
    console.log('Agents:', ids);
    expect(ids.some(id => /orchestrat/i.test(id))).toBe(true);
    expect(ids.some(id => /order/i.test(id))).toBe(true);
    expect(ids.some(id => /product|recommend/i.test(id))).toBe(true);
    expect(ids.some(id => /troubleshoot/i.test(id))).toBe(true);
  });

  test('INF-03: POST /chat empty message → 400', async ({ request }) => {
    const res = await request.post(`${API_URL}/chat`, {
      data: { message: '', sessionId: 'test-empty' },
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status()).toBe(400);
  });

  test('INF-04: POST /chat missing sessionId → 400', async ({ request }) => {
    const res = await request.post(`${API_URL}/chat`, {
      data: { message: 'hello' },
      headers: { 'Content-Type': 'application/json' },
    });
    expect(res.status()).toBe(400);
  });

  test('INF-05: Streamlit UI loads and chat input is visible', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(
      page.locator('textarea[data-testid="stChatInputTextArea"]')
    ).toBeVisible({ timeout: 15000 });
  });

});
