import { type Page, type APIRequestContext } from '@playwright/test';
import { execSync } from 'node:child_process';

export const UI_URL = process.env.UI_URL ?? 'http://localhost:8501';
export const API_URL = process.env.API_URL ?? 'http://localhost:3000';

export async function sendChatMessage(page: Page, message: string) {
  const input = page.locator('textarea[data-testid="stChatInputTextArea"]');
  await input.waitFor({ state: 'visible', timeout: 10000 });
  await input.fill(message);
  await input.press('Enter');
}

export async function waitForAgentResponse(page: Page, timeoutMs = 150000): Promise<string> {
  // Streamlit rendering can differ by version:
  // - some builds show a streaming cursor ("▌")
  // - others do not. In both cases, detect completion by text stabilization.
  const STABILITY_MS = 12000;
  const POLL_MS = 1000;
  const deadline = Date.now() + timeoutMs;
  let lastText = "";
  let lastChangedAt = Date.now();
  let sawAnyResponse = false;

  while (Date.now() < deadline) {
    const { hasCursor, text } = await page.evaluate(() => {
      const hasCursor = document.body.innerText.includes("▌");
      const messages = document.querySelectorAll('[data-testid="stChatMessage"]');
      const last = messages.length > 0 ? messages[messages.length - 1] : null;
      return {
        hasCursor,
        text: (last?.textContent ?? "").trim(),
      };
    });

    if (text && text !== lastText) {
      lastText = text;
      lastChangedAt = Date.now();
      sawAnyResponse = true;
    }

    if (sawAnyResponse && !hasCursor && Date.now() - lastChangedAt >= STABILITY_MS) {
      break;
    }

    await page.waitForTimeout(POLL_MS);
  }

  // After the full multi-agent response is done, capture the specialist's answer.
  // Streamlit re-renders the last assistant message as a single static markdown block.
  // Wait a tick to let that re-render flush before querying.
  await page.waitForTimeout(500);

  const messages = page.locator('[data-testid="stChatMessage"]');
  const count = await messages.count();
  const lastMsg = messages.nth(count - 1);
  // Use .last() — the specialist's response is in the last block; the first block
  // is the orchestrator's routing text.
  const textBlocks = lastMsg.locator('[data-testid="stMarkdownContainer"]');
  const blockCount = await textBlocks.count();
  const lastBlock = textBlocks.nth(Math.max(blockCount - 1, 0));
  const text = (await lastBlock.innerText()).trim();
  // Fallback: if lastBlock returned empty (no stMarkdownContainer, or short responses
  // rendered differently), grab the full message text instead.
  if (!text) {
    return (await lastMsg.innerText()).trim();
  }
  return text;
}

/**
 * Runs a multi-turn conversation. Each turn sends a message and waits for
 * the agent to finish before the next message is sent.
 * Returns the final agent response.
 */
export async function conversationTurns(
  page: Page,
  turns: string[],
  perTurnTimeout = 300000  // 5 min per turn — Nova Pro is slower than Claude
): Promise<string> {
  let lastResponse = '';
  for (let i = 0; i < turns.length; i++) {
    await sendChatMessage(page, turns[i]);
    lastResponse = await waitForAgentResponse(page, perTurnTimeout);
    console.log(`  ↳ turn ${i + 1}:`, lastResponse.substring(0, 200));
  }
  return lastResponse;
}

export async function collectSSEEvents(
  request: APIRequestContext,
  messages: string[],
  sessionId: string,
  headers?: Record<string, string>
): Promise<Array<{ event: string; data: Record<string, unknown> }>> {
  let lastEvents: Array<{ event: string; data: Record<string, unknown> }> = [];
  for (const message of messages) {
    const res = await request.post(`${API_URL}/chat`, {
      data: { message, sessionId },
      headers: { 'Content-Type': 'application/json', ...(headers ?? {}) },
      timeout: 180000,
    });
    const body = await res.text();
    lastEvents = [];
    let currentEvent = '';
    for (const line of body.split('\n')) {
      if (line.startsWith('event: ')) currentEvent = line.slice(7).trim();
      else if (line.startsWith('data: ')) {
        try { lastEvents.push({ event: currentEvent, data: JSON.parse(line.slice(6).trim()) }); }
        catch { /* ignore */ }
      }
    }
  }
  return lastEvents;
}

export function newSessionId(prefix = 'e2e'): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
}

export function tokenTextFromEvents(
  events: Array<{ event: string; data: Record<string, unknown> }>,
): string {
  return events
    .filter((e) => e.event === 'token')
    .map((e) => {
      const maybe = e.data?.text;
      return typeof maybe === 'string' ? maybe : '';
    })
    .join('');
}

export function getCognitoIdTokenFromEnvOrAwsCli(): string | null {
  const explicit = process.env['E2E_AUTH_ID_TOKEN']?.trim();
  if (explicit) return explicit;

  const clientId = process.env['COGNITO_APP_CLIENT_ID']?.trim();
  const username = process.env['E2E_AUTH_USERNAME']?.trim();
  const password = process.env['E2E_AUTH_PASSWORD']?.trim();
  if (!clientId || !username || !password) return null;

  try {
    const cmd = [
      'aws cognito-idp initiate-auth',
      `--client-id "${clientId}"`,
      '--auth-flow USER_PASSWORD_AUTH',
      `--auth-parameters USERNAME="${username}",PASSWORD="${password}"`,
      '--query "AuthenticationResult.IdToken"',
      '--output text',
    ].join(' ');
    const out = execSync(cmd, { stdio: ['ignore', 'pipe', 'pipe'] }).toString().trim();
    return out || null;
  } catch {
    return null;
  }
}
