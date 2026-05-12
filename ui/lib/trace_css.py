"""Shared CSS for the Trace Viewer page + inline summary cards.

Keep this isolated so the trace UI can be themed/printed without spilling
styles into the rest of the app.
"""

from __future__ import annotations

import streamlit as st

TRACE_CSS = """
<style>
.trace-tile {
  background: rgba(255,255,255,0.04);
  border: 1px solid rgba(255,255,255,0.08);
  border-radius: 10px;
  padding: 12px 14px;
  min-width: 100px;
  display: inline-block;
  margin-right: 8px;
  margin-bottom: 8px;
}
.trace-tile-label {
  font-size: 11px;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  opacity: 0.65;
}
.trace-tile-value {
  font-size: 18px;
  font-weight: 600;
  margin-top: 4px;
}
.trace-tile-hint {
  font-size: 11px;
  opacity: 0.55;
  margin-top: 2px;
}
.trace-chip {
  display: inline-block;
  padding: 2px 8px;
  border-radius: 12px;
  background: rgba(100, 149, 237, 0.15);
  color: cornflowerblue;
  font-size: 12px;
  margin-right: 6px;
  margin-bottom: 4px;
}
.trace-chip.warn { background: rgba(255, 165, 0, 0.15); color: orange; }
.trace-chip.ok { background: rgba(60, 200, 100, 0.12); color: #4caf50; }
.trace-chip.err { background: rgba(255, 80, 80, 0.15); color: #ef5350; }
.trace-banner-mock {
  background: rgba(255, 165, 0, 0.10);
  border: 1px solid rgba(255, 165, 0, 0.35);
  border-radius: 8px;
  padding: 10px 14px;
  margin-bottom: 12px;
}
.trace-section-title {
  font-size: 14px;
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  opacity: 0.75;
  margin: 18px 0 6px;
}
.trace-mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px;
  white-space: pre-wrap;
  word-break: break-all;
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
    rgba(0,150,57,0.18) 0%,
    rgba(0,150,57,0.10) 35%,
    rgba(255,153,0,0.10) 65%,
    rgba(255,153,0,0.18) 100%);
  border: 1px solid rgba(255,255,255,0.10);
  font-size: 12px;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  opacity: 0.85;
}
.trace-brand-pill {
  padding: 2px 8px;
  border-radius: 10px;
  background: rgba(0,0,0,0.25);
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

/* Replay overlay — toggled via [data-replay-active] on <body>, driven from
   replay_controller.py. Highlights the currently active span, dims the rest. */
body[data-replay-active="1"] .trace-tile { opacity: 0.35; transition: opacity 200ms; }
body[data-replay-active="1"] .trace-tile.trace-replay-current {
  opacity: 1;
  box-shadow: 0 0 0 2px rgba(0,150,57,0.85);
}

@media print {
  /* Strip the demo polish so the printed PDF is purely the data. */
  .trace-tile, .trace-banner-mock { box-shadow: none !important; border-color: #999 !important; }
  .trace-brand-strip { display: none !important; }
  .trace-tile[data-just-loaded="1"] { animation: none !important; }
  body[data-replay-active="1"] .trace-tile { opacity: 1 !important; box-shadow: none !important; }
  /* Hide replay controls + the catch-all developer-details expander. */
  [data-testid="stExpander"]:has(summary:contains("Developer details")) { display: none !important; }
  .trace-replay-controls { display: none !important; }
  details { page-break-inside: avoid; }
}
</style>
"""


def inject_trace_css() -> None:
    st.markdown(TRACE_CSS, unsafe_allow_html=True)
