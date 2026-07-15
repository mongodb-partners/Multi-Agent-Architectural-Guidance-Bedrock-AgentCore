"""HTTP Tool Test — invoke the JSON-configured `echo_lambda` HTTP tool directly.

Debug-section utility. Calls the API's `POST /http-tools/<name>/invoke` endpoint,
which runs the configured HTTP tool server-side with **no LLM/agent in the loop**,
then surfaces the resolved URL, HTTP status, and raw JSON the tool returned.

Wiring under test:
  config/http-tools.json (echo_lambda) -> POST /http-tools/echo_lambda/invoke
  -> SSRF-guarded fetch to the configured Lambda Function URL -> raw echo response.
"""

from __future__ import annotations

import sys
from pathlib import Path

import streamlit as st

_ui_root = Path(__file__).resolve().parent.parent
if str(_ui_root) not in sys.path:
    sys.path.insert(0, str(_ui_root))

from lib.api_client import get_http_tools, invoke_http_tool
from lib.brand_css import inject_brand_css, inject_hide_builtin_sidebar_nav
from lib.cognito_gate import ensure_api_bearer_token
from lib.config import load_settings
from lib.session_state import ensure_defaults

TEST_TOOL_NAME = "echo_lambda"

st.set_page_config(page_title="HTTP Tool Test", layout="wide")
inject_brand_css()
inject_hide_builtin_sidebar_nav()

settings = load_settings()
api_token = ensure_api_bearer_token(settings)
ensure_defaults()

with st.sidebar:
    st.page_link("app.py", label="← Chat")

st.title("HTTP Tool Test")
st.caption(
    f"API: `{settings.api_base}` — invokes the JSON-configured **{TEST_TOOL_NAME}** "
    "HTTP tool **directly** (no agent) via `POST /http-tools/<name>/invoke`."
)

# ── 1. Show the configured tool (GET /http-tools) ──────────────────────────────
st.subheader("1. Configured HTTP tool")
echo_tool: dict | None = None
try:
    tools_doc = get_http_tools(settings.api_base, api_token)
    all_tools = tools_doc.get("tools") or tools_doc.get("globalTools") or []
    echo_tool = next((t for t in all_tools if t.get("name") == TEST_TOOL_NAME), None)
except Exception as exc:  # noqa: BLE001 — surface any API/network error verbatim
    st.error(f"Could not load /http-tools: {exc}")

if echo_tool is None:
    st.warning(
        f"`{TEST_TOOL_NAME}` is not registered on this API. "
        "Add it to config/http-tools.json and redeploy the API."
    )
else:
    cols = st.columns(3)
    cols[0].metric("Tool", echo_tool.get("name", "?"))
    cols[1].metric("Method", echo_tool.get("method", "?"))
    cols[2].metric("URL configured", "yes" if echo_tool.get("urlConfigured") else "NO")
    if not echo_tool.get("urlConfigured"):
        st.warning(
            "`urlConfigured` is false — the tool URL did not resolve on the API. "
            "The call will return `url_not_configured`."
        )

st.divider()

# ── 2. Run the direct tool call ────────────────────────────────────────────────
st.subheader("2. Run direct tool call")
message_text = st.text_input(
    "Message to echo",
    value="hello from the http tool test",
    help="Sent as the `message` parameter to echo_lambda. No LLM is involved.",
)
run = st.button(
    f"Invoke {TEST_TOOL_NAME}",
    type="primary",
    disabled=echo_tool is None,
)

if run:
    status_code: int | None = None
    resp: dict = {}
    call_error: str | None = None

    with st.status(f"Invoking {TEST_TOOL_NAME} directly…", expanded=False) as status:
        try:
            status_code, resp = invoke_http_tool(
                settings.api_base,
                TEST_TOOL_NAME,
                {"message": message_text},
                access_token=api_token,
                timeout=60.0,
            )
            status.update(label=f"HTTP {status_code}", state="complete")
        except Exception as exc:  # noqa: BLE001
            call_error = str(exc)
            status.update(label="Request failed", state="error")

    # ── 3. Results ──────────────────────────────────────────────────────────────
    st.subheader("3. Result")

    result = resp.get("result") if isinstance(resp, dict) else None
    tool_http_status = result.get("httpStatus") if isinstance(result, dict) else None
    tool_status = result.get("status") if isinstance(result, dict) else None

    if call_error:
        st.error(f"Request error: {call_error}")
    elif status_code == 200 and tool_http_status == 200 and tool_status == "ok":
        st.success(f"PASS — {TEST_TOOL_NAME} returned HTTP 200. Lambda round-trip worked.")
    elif status_code != 200:
        st.error(f"API returned HTTP {status_code} — see the raw response below.")
    else:
        st.warning("Tool call completed but did not return a clean 200 — see details below.")

    # Which endpoint was actually hit (resolved server-side).
    resolved_url = resp.get("url") if isinstance(resp, dict) else None
    if resolved_url:
        st.markdown("**Resolved URL (which Lambda was called)**")
        st.code(resolved_url, language="text")

    st.markdown("**Raw API response**")
    st.json(resp)
