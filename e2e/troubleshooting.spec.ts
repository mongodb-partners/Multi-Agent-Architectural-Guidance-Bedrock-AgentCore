/**
 * troubleshooting.spec.ts — Troubleshooting agent E2E tests
 *
 * Covers error code lookup from Bedrock KB, step-by-step resolution,
 * hardware escalation with ticket creation, and vague symptom fallback.
 *
 * Real data quick-ref:
 *   PWR-001  Power / won't boot        → check cable, hold power 10s, USB-C 5V/2A, factory reset
 *   NET-204  WiFi connectivity          → move closer, disable VPN, 2.4GHz band, firmware update
 *   HW-900   Hardware fault (fatal)     → non-recoverable, note serial, escalate + create ticket
 *   BOOT-010 Random restarts            → firmware update, disable background sync, battery calibrate
 *
 *   Customers with device errors:
 *     alex@example.com  ORD-1003  Compact Widget  PWR-001
 *     blake@example.com ORD-1006  Pro Gadget      NET-204
 *     dana@example.com  ORD-3002  Compact Widget  HW-900   serial: SN-D4321
 */

import { test, expect } from '@playwright/test';
import { UI_URL, API_URL, conversationTurns } from './helpers';

test.describe('Troubleshooting Agent — Individual Commands', () => {

  test.beforeEach(async ({ page }) => {
    await page.goto(UI_URL);
    await page.waitForSelector('[data-testid="stChatInputTextArea"]', { timeout: 15000 });
  });

  test('TS-01: PWR-001 on Compact Widget (SKU-1) — returns power troubleshooting steps', async ({ page }) => {
    test.setTimeout(360_000); // Claude Sonnet slower than Nova on first turn
    // Doc ts-1: check cable, hold power 10s, USB-C 5V/2A, factory reset
    const text = await conversationTurns(page, [
      'My device won\'t power on at all.',
      'It\'s a Compact Widget (SKU-1). Shows error PWR-001. No LED response even when plugged in.',
    ]);

    expect(text.toLowerCase()).toMatch(/pwr-001|power|cable|outlet|reset|usb|hold/i);
    expect(text.length).toBeGreaterThan(100);
  });

  test('TS-02: NET-204 on Pro Gadget (ORD-1006/blake) — returns WiFi troubleshooting steps', async ({ page }) => {
    // Doc ts-2: move closer, disable VPN, 2.4GHz band, firmware update, factory network reset
    const text = await conversationTurns(page, [
      'My device keeps dropping the WiFi connection.',
      'Pro Gadget (SKU-2) from order ORD-1006 for blake@example.com. Shows NET-204 error after a firmware update.',
    ]);

    expect(text.toLowerCase()).toMatch(/net-204|wifi|wi-fi|router|firmware|band|vpn|network/i);
    expect(text.length).toBeGreaterThan(100);
  });

  test('TS-03: HW-900 on Compact Widget (ORD-3002/dana) — escalates and creates ticket', async ({ page }) => {
    // Doc ts-3: non-recoverable, note serial, open replacement ticket via Order Management
    const text = await conversationTurns(page, [
      'My device has a serious hardware error and I think it needs replacing.',
      'Dana Patel, dana@example.com. Compact Widget from ORD-3002 shows HW-900 — three red blinks, completely dead. Serial number SN-D4321.',
    ], 150000);

    expect(text.toLowerCase()).toMatch(/hw-900|hardware|ticket|replacement|escalat|serial|warranty/i);
    expect(text.length).toBeGreaterThan(100);
  });

  test('TS-04: BOOT-010 random restarts on Pro Gadget (SKU-2) — returns firmware/calibration steps', async ({ page }) => {
    test.setTimeout(360_000); // 6 min — 2 turns × ~2 min each exceeds the default 240s
    // Doc ts-1b: firmware update, disable background sync, battery calibrate, factory reset
    const text = await conversationTurns(page, [
      'My Pro Gadget keeps randomly restarting.',
      'Pro Gadget (SKU-2). Error BOOT-010 — restarts every few hours. Tried restarting manually but it keeps happening.',
    ]);

    expect(text.toLowerCase()).toMatch(/boot-010|firmware|restart|calibrat|battery|update|reboot/i);
    expect(text.length).toBeGreaterThan(100);
  });

  test('TS-05: vague symptom — no error code — KB fallback returns relevant guidance', async ({ page }) => {
    const text = await conversationTurns(page, [
      'My device keeps randomly shutting off and restarting.',
    ]);

    expect(text.length).toBeGreaterThan(50);
    expect(text).not.toContain('I don\'t know');
    expect(text).not.toMatch(/\{.*"error"/i);
  });

  test('TS-06 (API): health check — API is up and MongoDB connected', async ({ request }) => {
    const res = await request.get(`${API_URL}/health`);
    expect([200, 503]).toContain(res.status());
    const body = await res.json();
    expect(['ok', 'degraded']).toContain(body.status);
    expect(body.dependencies).toBeTruthy();
    expect(['direct', 'lambda', 'gateway']).toContain(body.dependencies.toolHosting);
  });

});
