"""Shared CSS for the Trace Viewer page + inline summary cards.

Keep this isolated so the trace UI can be themed/printed without spilling
styles into the rest of the app.
"""

from __future__ import annotations

import streamlit as st

TRACE_CSS = """
<style>
.trace-tile {
  background: var(--surface-2, #0E2932);
  border: 1px solid var(--border, rgba(255,255,255,0.08));
  border-radius: 10px;
  padding: 12px 14px;
  min-width: 100px;
  display: inline-block;
  margin-right: 8px;
  margin-bottom: 8px;
}
.trace-tile-label {
  font-size: 11px;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--text-muted, #B1B5BA);
}
.trace-tile-value {
  font-size: 18px;
  font-weight: 600;
  color: var(--primary, #00ED64);
  margin-top: 4px;
}
.trace-tile-hint {
  font-size: 11px;
  color: var(--text-muted, #B1B5BA);
  margin-top: 2px;
}
.trace-chip {
  display: inline-block;
  padding: 2px 8px;
  border-radius: 12px;
  background: rgba(0, 237, 100, 0.12);
  color: var(--primary, #00ED64);
  font-size: 12px;
  margin-right: 6px;
  margin-bottom: 4px;
}
.trace-chip.warn   { background: rgba(255, 192, 16, 0.15); color: var(--warn, #FFC010); }
.trace-chip.ok     { background: rgba(0, 237, 100, 0.12);  color: var(--primary, #00ED64); }
.trace-chip.err    { background: rgba(255, 107, 107, 0.15); color: var(--err, #FF6B6B); }
.trace-chip.danger {
  background: rgba(255, 107, 107, 0.2);
  color: var(--err, #FF6B6B);
  border: 1px solid rgba(255, 107, 107, 0.6);
  font-weight: 600;
}
.trace-section-title {
  font-size: 13px;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--text-muted, #B1B5BA);
  margin: 20px 0 8px;
}
.trace-mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px;
  white-space: pre-wrap;
  word-break: break-all;
}

/* Span tree (developer details → Span tree section). Each node is rendered
   as a flat <div class="trace-span-tree"> with leading non-breaking spaces
   for indentation, so the tree stays selectable as plain text. */
.trace-span-tree {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px;
  line-height: 1.6;
  color: var(--text-muted, #B1B5BA);
}
.trace-span-tree code {
  font-size: 12px;
  color: var(--primary, #00ED64);
}

/* Compact tabular row used inside developer-details tables (per-collection
   memory breakdown, retries, latency checkpoints, byte-cap drops). */
.trace-dev-table {
  font-size: 12px;
  line-height: 1.45;
}
.trace-dev-table th, .trace-dev-table td {
  padding: 4px 8px;
}

/* Subtle divider above the gated "Developer details" container so the
   visual boundary between the demo surface and the debug surface is clear
   without re-introducing an always-evaluating expander body. */
.trace-developer-divider {
  border-top: 1px dashed var(--border, rgba(255,255,255,0.18));
  margin: 24px 0 12px 0;
  padding-top: 10px;
  font-size: 11px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--text-muted, #B1B5BA);
}

/* MongoDB green / AWS orange brand strip (top of Trace Viewer). */
.trace-brand-strip {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 14px;
  margin: 0 0 14px 0;
  border-radius: 8px;
  background: linear-gradient(90deg,
    rgba(0, 237, 100, 0.14) 0%,
    rgba(0, 237, 100, 0.07) 35%,
    rgba(255, 153, 0, 0.07) 65%,
    rgba(255, 153, 0, 0.14) 100%);
  border: 1px solid var(--border, rgba(255,255,255,0.08));
  font-size: 12px;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--text-muted, #B1B5BA);
}
.trace-brand-pill {
  padding: 2px 8px;
  border-radius: 10px;
  background: var(--surface-2, #0E2932);
  border: 1px solid var(--border, rgba(255,255,255,0.08));
}

/* One-shot tile entry animation — scoped via `data-just-loaded` so it only
   fires on the first render, never on every rerun. */
.trace-tile[data-just-loaded="1"] {
  animation: trace-pop 320ms ease-out 1;
}
@keyframes trace-pop {
  from { transform: translateY(4px); opacity: 0; }
  to   { transform: translateY(0);   opacity: 1; }
}

@media print {
  /* Strip the demo polish so the printed PDF is purely the data. */
  .trace-tile { box-shadow: none !important; border-color: #999 !important; }
  .trace-brand-strip { display: none !important; }
  .trace-tile[data-just-loaded="1"] { animation: none !important; }
  /* Hide the catch-all developer-details expander. */
  [data-testid="stExpander"]:has(summary:contains("Developer details")) { display: none !important; }
  /* `:contains()` is non-standard; the catch-all below hides the *body* of
     every expander under the developer details container so summaries print
     (giving the reader an outline) without printing every body block — CSS
     can't toggle `<details open>` so this is the cleanest approximation. */
  [data-testid="stContainer"] [data-testid="stExpanderDetails"] { display: none !important; }
  .trace-developer-divider { color: #444 !important; border-color: #888 !important; }
  details { page-break-inside: avoid; }
}
</style>
"""


def inject_trace_css() -> None:
    st.markdown(TRACE_CSS, unsafe_allow_html=True)
