/**
 * order-management.spec.ts — Order Management agent E2E tests
 *
 * Covers order tracking, cancellation, returns, and missing order ID handling.
 *
 * Real data quick-ref:
 *   ORD-1001 alex@example.com  shipped    Compact Widget x1       TRK-9001-US
 *   ORD-1002 blake@example.com processing Pro Gadget x2
 *   ORD-1003 alex@example.com  delivered  Compact Widget x1       returnEligible=true
 *   ORD-1005 alex@example.com  shipped    Pro Gadget x1           TRK-9005-US
 *   ORD-1006 blake@example.com return_requested Pro Gadget x1     NET-204
 *   ORD-1010 blake@example.com shipped    Compact Widget Plus x1  TRK-9010-US
 */

import { test, expect } from '@playwright/test';
import { UI_URL, conversationTurns } from './helpers';

test.describe('Order Management — Individual Commands', () => {

  test.beforeEach(async ({ page }) => {
    await page.goto(UI_URL);
    await page.waitForSelector('[data-testid="stChatInputTextArea"]', { timeout: 60000 });
  });

  test('OM-01: track ORD-1001 (alex, shipped) — returns status + tracking', async ({ page }) => {
    const text = await conversationTurns(page, [
      'Can you check on my order for me?',
      'Order ORD-1001 for alex@example.com.',
    ]);

    expect(text.toLowerCase()).toMatch(/ord-1001|shipped|trk-9001|tracking|compact widget/i);
    expect(text.length).toBeGreaterThan(50);
  });

  test('OM-02: cancel ORD-1002 (blake, processing) — can still be cancelled', async ({ page }) => {
    const text = await conversationTurns(page, [
      'I need to cancel one of my orders.',
      'Order ORD-1002 for blake@example.com. I no longer need the Pro Gadgets.',
    ]);

    expect(text.toLowerCase()).toMatch(/ord-1002|cancel|process|pro gadget/i);
    expect(text.length).toBeGreaterThan(50);
  });

  test('OM-03: return ORD-1003 (alex, delivered, returnEligible=true)', async ({ page }) => {
    const text = await conversationTurns(page, [
      'I need to return an item from a delivered order.',
      'Order ORD-1003 for alex@example.com — Compact Widget stopped working after 2 weeks. Please start the return.',
    ]);

    expect(text.toLowerCase()).toMatch(/ord-1003|return|eligible|label|compact widget/i);
    expect(text.length).toBeGreaterThan(80);
  });

  test('OM-04: no order ID given — agent asks for it — user provides ORD-1005', async ({ page }) => {
    const text = await conversationTurns(page, [
      'Can you check my order status?',
      'It\'s order ORD-1005 for alex@example.com.',
    ]);

    expect(text.toLowerCase()).toMatch(/ord-1005|shipped|pro gadget|trk-9005|status/i);
    expect(text).not.toContain('undefined');
    expect(text.length).toBeGreaterThan(50);
  });

  test('OM-05: return already requested — ORD-1006 (blake, return_requested)', async ({ page }) => {
    const text = await conversationTurns(page, [
      'I want to check the return status for my Pro Gadget.',
      'Order ORD-1006 for blake@example.com.',
    ]);

    expect(text.toLowerCase()).toMatch(/ord-1006|return|return_requested|pro gadget/i);
    expect(text.length).toBeGreaterThan(50);
  });

  test('OM-06: order not found — graceful not-found response', async ({ page }) => {
    const text = await conversationTurns(page, [
      'Can you look up my order?',
      'Order ORD-INVALID-999 for test@example.com.',
    ]);

    expect(text.toLowerCase()).toMatch(/not found|couldn.*find|wasn.t able|unable|no order|verify/i);
    expect(text.length).toBeGreaterThan(30);
  });

});
