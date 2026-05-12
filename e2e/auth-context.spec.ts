import { test, expect } from '@playwright/test';
import {
  API_URL,
  collectSSEEvents,
  getCognitoIdTokenFromEnvOrAwsCli,
  newSessionId,
  tokenTextFromEvents,
} from './helpers';

test.describe('Auth Context — API E2E', () => {
  let idToken: string | null = null;
  let authHeaders: Record<string, string> = {};
  let sessionId = '';

  test.beforeAll(() => {
    idToken = getCognitoIdTokenFromEnvOrAwsCli();
    if (idToken) {
      authHeaders = { Authorization: `Bearer ${idToken}` };
      sessionId = newSessionId('authctx');
    }
  });

  test('AC-01: "my orders" resolves via authenticated identity', async ({ request }) => {
    test.skip(!idToken, 'Provide E2E_AUTH_ID_TOKEN or Cognito env credentials to run auth E2E.');
    const events = await collectSSEEvents(request, ['Show my orders.'], sessionId, authHeaders);
    const handoff = events.find((e) => e.event === 'handoff')?.data;
    const text = tokenTextFromEvents(events).toLowerCase();

    expect(events.map((e) => e.event)).toContain('done');
    expect(handoff).toBeTruthy();
    expect(String(handoff?.to ?? '')).toContain('order-management');
    expect(text).toMatch(/ord-|order|tracking|shipped|delivered/i);
    expect(text).not.toMatch(/provide.*email|share.*email|enter.*email/i);
  });

  test('AC-02: "my open tickets" resolves via authenticated identity', async ({ request }) => {
    test.skip(!idToken, 'Provide E2E_AUTH_ID_TOKEN or Cognito env credentials to run auth E2E.');
    const events = await collectSSEEvents(request, ['Show my open tickets.'], sessionId, authHeaders);
    const handoff = events.find((e) => e.event === 'handoff')?.data;
    const text = tokenTextFromEvents(events).toLowerCase();

    expect(events.map((e) => e.event)).toContain('done');
    expect(handoff).toBeTruthy();
    expect(String(handoff?.to ?? '')).toContain('troubleshooting');
    expect(text).toMatch(/ticket|open|support|no open/i);
    expect(text).not.toMatch(/provide.*email|share.*email|enter.*email/i);
  });

  test('AC-03: history-based recommendations use authenticated user profile', async ({ request }) => {
    test.skip(!idToken, 'Provide E2E_AUTH_ID_TOKEN or Cognito env credentials to run auth E2E.');
    const events = await collectSSEEvents(
      request,
      ['Give me top three product recommendations based on my previous orders.'],
      sessionId,
      authHeaders,
    );
    const handoff = events.find((e) => e.event === 'handoff')?.data;
    const text = tokenTextFromEvents(events).toLowerCase();

    expect(events.map((e) => e.event)).toContain('done');
    expect(handoff).toBeTruthy();
    expect(String(handoff?.to ?? '')).toContain('product-recommendation');
    expect(text).toMatch(/top 3|recommend|sku-|based on.*(history|orders|purchased|previous)/i);
  });

  test('AC-04: session endpoint includes auth-bound userId', async ({ request }) => {
    test.skip(!idToken, 'Provide E2E_AUTH_ID_TOKEN or Cognito env credentials to run auth E2E.');
    const res = await request.get(`${API_URL}/sessions/${sessionId}`, {
      headers: authHeaders,
    });
    expect(res.status()).toBe(200);
    const body = await res.json();
    expect(typeof body.userId).toBe('string');
    expect((body.userId as string).length).toBeGreaterThan(8);
    expect(Array.isArray(body.messages)).toBe(true);
    expect(body.messages.length).toBeGreaterThan(0);
  });
});
