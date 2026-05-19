"""MongoDB Atlas brand CSS injected on every Streamlit page.

Defines CSS custom properties (tokens) and global overrides that align the
Streamlit chrome with the MongoDB Atlas dark-navy / mint-green palette.
All targeted data-testid attributes are from Streamlit >=1.32 (pinned in
requirements.txt). Each rule also carries a class-name fallback so a minor
Streamlit testid rename doesn't break the theme entirely.
"""

from __future__ import annotations

import streamlit as st

BRAND_CSS = """
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');

/* ── Reduce default Streamlit top padding ────────────────────────────────── */
/* Streamlit reserves top space in both the header and the main block
   container. Target both older and newer Streamlit DOM names. */
header[data-testid="stHeader"] {
  height: 0 !important;
  background: transparent !important;
}
[data-testid="stAppViewContainer"] > section > div:first-child,
[data-testid="block-container"],
[data-testid="stMainBlockContainer"],
.block-container,
.stMainBlockContainer {
  padding-top: 0.25rem !important;
}
/* The first heading inside the main block shouldn't add its own top margin */
[data-testid="block-container"] > div:first-child h1,
[data-testid="block-container"] > div:first-child h2,
[data-testid="block-container"] [data-testid="stMarkdownContainer"]:first-child h1,
[data-testid="stMainBlockContainer"] h1:first-child,
.stMainBlockContainer h1:first-child {
  margin-top: 0 !important;
  padding-top: 0 !important;
}

/* ── Tokens ──────────────────────────────────────────────────────────────── */
:root {
  --bg:          #001E2B;
  --bg-sidebar:  #00141C;
  --surface:     #00242E;
  --surface-2:   #0E2932;
  --border:      rgba(255, 255, 255, 0.08);
  --text:        #FFFFFF;
  --text-muted:  #B1B5BA;
  --primary:     #00ED64;
  --link:        #016BF8;
  --warn:        #FFC010;
  --err:         #FF6B6B;
  --muted-dot:   #5C6970;
}

/* ── Typography ──────────────────────────────────────────────────────────── */
/* Scoped to html/body only — CSS inheritance propagates Inter to all text
   without clobbering the st-* icon spans Streamlit uses for Material Symbols. */
html, body {
  font-family: 'Inter', system-ui, -apple-system, sans-serif;
}

/* Mint headings — matches the Atlas "Chatbot Demo Builder" title style */
h1, h2, h3,
[data-testid="stHeading"] h1,
[data-testid="stHeading"] h2,
[data-testid="stHeading"] h3 {
  color: var(--primary) !important;
  font-weight: 700;
  letter-spacing: -0.01em;
}

/* Link blue */
a, a:hover {
  color: var(--link) !important;
}

/* Subtle horizontal rule matching Atlas page dividers */
hr {
  border: none;
  border-top: 1px solid var(--border);
  margin: 1rem 0;
}

/* ── Sidebar section captions (uppercase, letter-spaced, muted) ──────────── */
[data-testid="stSidebar"] [data-testid="stCaptionContainer"] p,
[data-testid="stSidebar"] [class*="stCaptionContainer"] p {
  text-transform: uppercase;
  letter-spacing: 0.06em;
  font-size: 10px;
  color: var(--text-muted);
  font-weight: 600;
}

/* ── Cards and tiles ─────────────────────────────────────────────────────── */
.brand-tile {
  background: var(--surface-2);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 10px 14px;
  min-width: 90px;
  display: inline-block;
  margin-right: 8px;
  margin-bottom: 8px;
  vertical-align: top;
}
.brand-tile-label {
  font-size: 11px;
  color: var(--text-muted);
  letter-spacing: 0.05em;
  text-transform: uppercase;
}
.brand-tile-value {
  font-size: 17px;
  font-weight: 600;
  color: var(--primary);
  margin-top: 3px;
}
.brand-tile-hint {
  font-size: 11px;
  color: var(--text-muted);
  margin-top: 2px;
}

.brand-card {
  background: var(--surface-2);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 14px 16px;
  margin-bottom: 10px;
}

/* ── Pills ───────────────────────────────────────────────────────────────── */
.brand-pill {
  display: inline-block;
  padding: 2px 10px;
  border-radius: 12px;
  background: var(--surface-2);
  border: 1px solid var(--border);
  color: var(--text-muted);
  font-size: 12px;
  font-weight: 500;
  letter-spacing: 0.02em;
}
.brand-pill--success {
  background: var(--primary);
  border-color: var(--primary);
  color: var(--bg);
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  font-size: 11px;
}

/* ── Status dots (sidebar health + narrative warnings) ───────────────────── */
.brand-status {
  display: inline-block;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--muted-dot);
  margin-right: 5px;
  vertical-align: middle;
  position: relative;
  top: -1px;
  flex-shrink: 0;
}
.brand-status--ok      { background: var(--primary); }
.brand-status--warn    { background: var(--warn); }
.brand-status--err     { background: var(--err); }
.brand-status--muted   { background: var(--muted-dot); }

/* ── Focus rings ─────────────────────────────────────────────────────────── */
*:focus-visible {
  outline: 2px solid var(--primary) !important;
  outline-offset: 2px !important;
}

/* ── Chat messages ───────────────────────────────────────────────────────── */
[data-testid="stChatMessage"],
[class*="stChatMessage"] {
  background: var(--surface) !important;
  border: 1px solid var(--border) !important;
  border-radius: 10px !important;
  margin-bottom: 6px !important;
}
/* Mint left accent on assistant messages (avatar alt="assistant") */
[data-testid="stChatMessage"]:has(img[alt="assistant"]) {
  border-left: 3px solid var(--primary) !important;
}

/* ── Chat input ──────────────────────────────────────────────────────────── */
[data-testid="stChatInput"],
[class*="stChatInput"] {
  background: var(--surface-2) !important;
  border: 1px solid var(--border) !important;
  border-radius: 8px !important;
}

/* ── st.status (streaming progress widget in chat) ───────────────────────── */
[data-testid="stStatusWidget"],
[class*="stStatusWidget"] {
  background: var(--surface-2) !important;
  border: 1px solid var(--border) !important;
  border-radius: 8px !important;
}
[data-testid="stStatusWidget"] [data-testid="stStatusWidgetLabel"],
[data-testid="stStatusWidget"] p {
  color: var(--text-muted) !important;
}

/* ── Expanders ───────────────────────────────────────────────────────────── */
[data-testid="stExpander"],
[class*="stExpander"] {
  background: var(--surface-2) !important;
  border: 1px solid var(--border) !important;
  border-radius: 8px !important;
}

/* ── Alert banners (st.info / st.warning / st.error / st.success) ────────── */
[data-testid="stAlert"],
[class*="stAlert"] {
  background: var(--surface-2) !important;
  border: 1px solid var(--border) !important;
  border-radius: 8px !important;
}
/* Restore semantic left-border accent per alert type */
[data-testid="stAlert"][data-baseweb="notification"][kind="info"],
div[class*="stAlert"]:has(svg[data-testid="basewei-icon-Info"]) {
  border-left: 3px solid var(--link) !important;
}
[data-testid="stAlert"][kind="success"],
div[class*="stAlert"]:has(svg[data-testid="basewei-icon-Check"]) {
  border-left: 3px solid var(--primary) !important;
}
[data-testid="stAlert"][kind="warning"] {
  border-left: 3px solid var(--warn) !important;
}
[data-testid="stAlert"][kind="error"] {
  border-left: 3px solid var(--err) !important;
}

/* ── Selectbox / multiselect ─────────────────────────────────────────────── */
[data-testid="stSelectbox"] > div,
[data-testid="stSelectbox"] [data-baseweb="select"] > div {
  background: var(--surface-2) !important;
  border-color: var(--border) !important;
}
/* Floating dropdown popover (BaseWeb) */
[data-baseweb="popover"] [data-baseweb="menu"],
[data-baseweb="select"] [role="listbox"] {
  background: var(--surface-2) !important;
  border: 1px solid var(--border) !important;
}
[data-baseweb="popover"] [data-baseweb="menu"] li:hover,
[data-baseweb="select"] [role="option"]:hover {
  background: var(--surface) !important;
}
/* Multiselect chips */
[data-testid="stMultiSelect"] span[data-baseweb="tag"] {
  background: rgba(0, 237, 100, 0.15) !important;
  color: var(--primary) !important;
  border: 1px solid rgba(0, 237, 100, 0.3) !important;
}

/* ── Sidebar navigation links (st.page_link) ─────────────────────────────── */
[data-testid="stSidebarNavLink"],
[class*="stSidebarNavLink"] {
  color: var(--text-muted) !important;
  border-radius: 6px !important;
  transition: background 0.15s;
}
[data-testid="stSidebarNavLink"]:hover,
[class*="stSidebarNavLink"]:hover {
  background: var(--surface-2) !important;
  color: var(--text) !important;
}
[data-testid="stSidebarNavLink"][aria-current="page"],
[class*="stSidebarNavLink"][aria-current="page"] {
  color: var(--primary) !important;
  background: rgba(0, 237, 100, 0.08) !important;
  font-weight: 600;
}

/* ── Code blocks ─────────────────────────────────────────────────────────── */
[data-testid="stCodeBlock"],
[class*="stCodeBlock"] {
  background: var(--surface-2) !important;
  border: 1px solid var(--border) !important;
  border-radius: 6px !important;
}

/* ── Metric values ───────────────────────────────────────────────────────── */
[data-testid="stMetricValue"],
[class*="stMetricValue"] {
  color: var(--primary) !important;
  font-weight: 700;
}

/* ── Buttons ─────────────────────────────────────────────────────────────── */
button[kind="primary"],
[data-testid="baseButton-primary"] {
  background: var(--primary) !important;
  color: var(--bg) !important;
  border: none !important;
  font-weight: 600 !important;
}
button[kind="secondary"],
[data-testid="baseButton-secondary"] {
  background: var(--surface-2) !important;
  border: 1px solid var(--border) !important;
  color: var(--text) !important;
}

/* ── Spinner ─────────────────────────────────────────────────────────────── */
[data-testid="stSpinner"] svg,
[class*="stSpinner"] svg {
  stroke: var(--primary) !important;
  color: var(--primary) !important;
}

/* ── Divider ─────────────────────────────────────────────────────────────── */
[data-testid="stDivider"] hr,
[class*="stDivider"] hr {
  border-top-color: var(--border) !important;
}
</style>
"""


HIDE_BUILTIN_SIDEBAR_NAV_CSS = """
<style>
/* Streamlit auto page list (app / Sessions / Trace Viewer) at sidebar top */
[data-testid="stSidebarNav"] {
  display: none !important;
}
</style>
"""


def inject_brand_css() -> None:
    """Inject MongoDB Atlas brand tokens and global overrides into the page."""
    st.markdown(BRAND_CSS, unsafe_allow_html=True)


def inject_hide_builtin_sidebar_nav() -> None:
    """Hide Streamlit's multipage sidebar nav (use on sub-pages with custom links)."""
    st.markdown(HIDE_BUILTIN_SIDEBAR_NAV_CSS, unsafe_allow_html=True)
