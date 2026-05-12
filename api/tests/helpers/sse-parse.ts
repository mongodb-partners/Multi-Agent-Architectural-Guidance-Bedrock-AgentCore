/** Parse a full SSE response body into event + raw data lines (for integration tests). */
export function parseSseResponse(body: string): { event: string; data: string }[] {
  const out: { event: string; data: string }[] = [];
  let event = "message";
  for (const line of body.split(/\r?\n/)) {
    if (line.startsWith("event:")) {
      event = line.slice(6).trim();
      continue;
    }
    if (line.startsWith("data:")) {
      out.push({ event, data: line.slice(5).trim() });
    }
  }
  return out;
}

export function tokensFromSse(body: string): string {
  let text = "";
  for (const { event, data } of parseSseResponse(body)) {
    if (event !== "token") continue;
    try {
      const j = JSON.parse(data) as { text?: string };
      if (typeof j.text === "string") text += j.text;
    } catch {
      /* ignore */
    }
  }
  return text;
}
