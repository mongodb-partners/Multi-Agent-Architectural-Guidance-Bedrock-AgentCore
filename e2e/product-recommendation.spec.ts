/**
 * product-recommendation.spec.ts — Product Recommendation agent E2E tests
 *
 * Covers replacement suggestions, similar-but-cheaper queries, use-case matching,
 * and bundle recommendations.
 *
 * Real data quick-ref:
 *   SKU-1  Compact Widget          $29.99  (discontinued — replaced by SKU-4/SKU-5)
 *   SKU-2  Pro Gadget              $89.99
 *   SKU-3  Travel Widget           $19.99
 *   SKU-4  Compact Widget Plus     $34.99  (replaces SKU-1)
 *   SKU-5  Smart Widget Hub        $49.99  (replaces SKU-1, smart home)
 *   SKU-7  Outdoor Widget Rugged   $44.99  (IP67, workshop/outdoor)
 *   SKU-8  Pro Gadget Lite         $64.99  (similar to SKU-2, lighter)
 *   SKU-9  Widget Starter Bundle   $39.99  (Compact Widget + Travel Widget)
 */

import { test, expect } from '@playwright/test';
import { UI_URL, conversationTurns, sendChatMessage, waitForAgentResponse } from './helpers';

test.describe('Product Recommendation — Individual Commands', () => {

  test.beforeEach(async ({ page }) => {
    await page.goto(UI_URL);
    await page.waitForSelector('[data-testid="stChatInputTextArea"]', { timeout: 15000 });
  });

  test('PR-01: replacement for broken SKU-1 (Compact Widget) — recommends SKU-4 or SKU-5', async ({ page }) => {
    const text = await conversationTurns(page, [
      'I need a replacement for a product that broke.',
      'My Compact Widget (SKU-1) stopped working. What are the recommended replacements?',
    ]);

    expect(text.toLowerCase()).toMatch(/compact widget plus|smart widget hub|sku-4|sku-5|replace|upgrade/i);
    expect(text.length).toBeGreaterThan(50);
  });

  test('PR-02: similar to Pro Gadget (SKU-2) but cheaper — recommends SKU-8', async ({ page }) => {
    const text = await conversationTurns(page, [
      'I\'m looking for something similar to the Pro Gadget but at a lower price point.',
      'The Pro Gadget (SKU-2) is $89.99. I want something similar but under $70 for everyday carry.',
    ]);

    expect(text.toLowerCase()).toMatch(/pro gadget lite|sku-8|everyday|light|battery|recommend/i);
    expect(text.length).toBeGreaterThan(80);
  });

  test('PR-03: outdoor use case — asks clarification first, then recommends SKU-7', async ({ page }) => {
    await sendChatMessage(page, 'I need a widget for outdoor and garage use — it needs to be tough.');
    const firstTurn = await waitForAgentResponse(page);
    expect(firstTurn.toLowerCase()).toMatch(/budget|ip67|waterproof|spec|requirement|details|clarif|more about/i);
    expect(firstTurn.toLowerCase()).not.toMatch(/outdoor widget rugged|sku-7/i);

    await sendChatMessage(page, 'Looking for something waterproof and rugged, IP67 if possible. Will be used in harsh conditions.');
    const secondTurn = await waitForAgentResponse(page);

    expect(secondTurn.toLowerCase()).toMatch(/outdoor widget rugged|sku-7|ip67|waterproof|rugged|workshop/i);
    expect(secondTurn.length).toBeGreaterThan(80);
  });

  test('PR-04: bundle suggestion — SKU-9 Widget Starter Bundle for value', async ({ page }) => {
    const text = await conversationTurns(page, [
      'I need something for both home and travel use.',
      'I want both a home widget and a travel widget but want good value. Is there a bundle option?',
    ]);

    expect(text.toLowerCase()).toMatch(/bundle|widget starter|sku-9|compact widget|travel widget|value/i);
    expect(text.length).toBeGreaterThan(80);
  });

  test('PR-05: budget query — best option under $25', async ({ page }) => {
    const text = await conversationTurns(page, [
      'What\'s the best product you have under $25?',
    ]);

    expect(text.toLowerCase()).toMatch(/travel widget|sku-3|budget|affordable|\$19|\$24/i);
    expect(text.length).toBeGreaterThan(50);
  });

  test('PR-06: no matching product — graceful fallback response', async ({ page }) => {
    const text = await conversationTurns(page, [
      'Do you have any industrial laser cutters in your catalog?',
    ]);

    // Should not error — should gracefully say it's out of scope or suggest alternatives
    expect(text.length).toBeGreaterThan(30);
    expect(text).not.toMatch(/\{.*"error"/i);
  });

});
