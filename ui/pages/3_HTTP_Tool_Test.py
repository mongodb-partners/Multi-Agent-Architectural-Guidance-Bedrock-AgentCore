"""HTTP Tool Test — invoke any JSON-configured global HTTP tool directly.

Debug-section utility. Renders one testable section per tool defined in the
global `config/http-tools.json` (discovered via `GET /http-tools`). Each section
has typed inputs, an Execute button, and the raw result below it.

Calls the API's `POST /http-tools/<name>/invoke` endpoint, which runs the
configured HTTP tool server-side with **no LLM/agent in the loop**, then
surfaces the resolved URL, HTTP status, and raw JSON the tool returned.

Wiring under test:
  config/http-tools.json (any tool) -> POST /http-tools/<name>/invoke
  -> SSRF-guarded fetch to the configured Lambda Function URL -> raw response.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import streamlit as st

_ui_root = Path(__file__).resolve().parent.parent
if str(_ui_root) not in sys.path:
    sys.path.insert(0, str(_ui_root))

from lib.api_client import get_http_tools, invoke_http_tool
from lib.brand_css import inject_brand_css, inject_hide_builtin_sidebar_nav
from lib.cognito_gate import ensure_api_bearer_token
from lib.config import load_settings
from lib.session_state import ensure_defaults

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
    f"API: `{settings.api_base}` — invokes any global HTTP tool from "
    "`config/http-tools.json` **directly** (no agent) via "
    "`POST /http-tools/<name>/invoke`."
)


def _build_named_input(tool_name: str, parameters: list[dict]) -> tuple[dict[str, Any], list[str]]:
    """Read the per-param widgets back from session state, coerce by type.

    Returns ``(tool_input, errors)``. Optional fields left empty are omitted;
    required fields are always sent. ``object`` fields are parsed as JSON.
    """
    tool_input: dict[str, Any] = {}
    errors: list[str] = []
    for p in parameters:
        pname = p.get("name", "")
        if not pname:
            continue
        ptype = p.get("type", "string")
        required = bool(p.get("required", True))
        key = f"param_{tool_name}_{pname}"
        raw = st.session_state.get(key)

        if ptype == "number":
            if raw is None:
                if required:
                    errors.append(f"`{pname}` is required.")
                continue
            # Preserve integer fidelity: send whole numbers as int (1 not 1.0).
            # Zod `z.number()` accepts both; this just keeps the request body clean.
            if isinstance(raw, float) and raw.is_integer():
                tool_input[pname] = int(raw)
            else:
                tool_input[pname] = raw
        elif ptype == "boolean":
            tool_input[pname] = bool(raw)
        elif ptype == "object":
            text = (raw or "").strip()
            if not text:
                if required:
                    errors.append(f"`{pname}` is required (JSON object).")
                continue
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError as exc:
                errors.append(f"`{pname}` is not valid JSON: {exc}")
                continue
            if not isinstance(parsed, dict):
                errors.append(f"`{pname}` must be a JSON object.")
                continue
            tool_input[pname] = parsed
        else:  # string
            text = raw or ""
            if not text and not required:
                continue
            tool_input[pname] = text
    return tool_input, errors


def _build_passthrough_input(tool_name: str) -> tuple[dict[str, Any] | None, list[str]]:
    """Parse the raw JSON body textarea into ``{"body": <object>}``."""
    key = f"body_{tool_name}"
    text = (st.session_state.get(key) or "").strip()
    if not text:
        return None, ["Request body is required (a JSON object)."]
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        return None, [f"Request body is not valid JSON: {exc}"]
    if not isinstance(parsed, dict):
        return None, ["Request body must be a JSON object."]
    return {"body": parsed}, []


def _render_result(name: str) -> None:
    """Render the stored invocation result for a tool (survives reruns)."""
    stored = st.session_state.get(f"result_{name}")
    if not stored:
        return
    status_code = stored.get("status_code")
    resp = stored.get("resp") or {}
    call_error = stored.get("error")
    input_errors = stored.get("input_errors") or []

    st.markdown("**Result**")

    if input_errors:
        for msg in input_errors:
            st.error(msg)
        return

    if call_error:
        st.error(f"Request error: {call_error}")
        return

    if status_code == 404 or (isinstance(resp, dict) and resp.get("error") == "tool_not_found"):
        st.error(f"Tool not found on the API: `{name}`. Redeploy the API after editing config/http-tools.json.")
        st.json(resp)
        return

    if status_code == 400 or (isinstance(resp, dict) and resp.get("error") == "invalid_input"):
        st.error("Invalid input — the API rejected the parameters (HTTP 400).")
        issues = resp.get("issues") if isinstance(resp, dict) else None
        if issues:
            st.json(issues)
        else:
            st.json(resp)
        return

    result = resp.get("result") if isinstance(resp, dict) else None
    tool_http_status = result.get("httpStatus") if isinstance(result, dict) else None
    tool_status = result.get("status") if isinstance(result, dict) else None
    tool_code = result.get("code") if isinstance(result, dict) else None
    tool_message = result.get("message") if isinstance(result, dict) else None

    is_2xx = isinstance(tool_http_status, int) and 200 <= tool_http_status < 300
    if status_code == 200 and tool_status == "ok" and is_2xx:
        st.success(f"PASS — `{name}` returned HTTP {tool_http_status}. Round-trip worked.")
    elif tool_code:
        st.warning(f"Tool returned `{tool_code}`" + (f": {tool_message}" if tool_message else ""))
    elif status_code != 200:
        st.error(f"API returned HTTP {status_code} — see the raw response below.")
    else:
        st.warning("Tool call completed but did not return a clean 2xx — see details below.")

    resolved_url = resp.get("url") if isinstance(resp, dict) else None
    if resolved_url:
        st.markdown("**Resolved URL (which endpoint was called)**")
        st.code(resolved_url, language="text")

    st.markdown("**Raw API response**")
    st.json(resp)


# ── Load configured tools ──────────────────────────────────────────────────────
global_tools: list[dict] = []
try:
    tools_doc = get_http_tools(settings.api_base, api_token)
    global_tools = tools_doc.get("globalTools") or []
except Exception as exc:  # noqa: BLE001 — surface any API/network error verbatim
    st.error(f"Could not load /http-tools: {exc}")
    st.stop()

if not global_tools:
    st.info(
        "No HTTP tools are configured in `config/http-tools.json`. "
        "Add a tool entry, redeploy the API, then reload this page."
    )
    st.stop()

st.caption(f"{len(global_tools)} global tool(s) configured.")

# ── One testable section per tool ──────────────────────────────────────────────
for tool in global_tools:
    name = tool.get("name", "?")
    method = tool.get("method", "?")
    description = tool.get("description", "")
    url_configured = bool(tool.get("urlConfigured"))
    pass_through = bool(tool.get("passThroughBody"))
    parameters = tool.get("parameters") or []
    timeout_ms = tool.get("timeoutMs") or 30000

    with st.expander(f"{name}  ·  {method}", expanded=len(global_tools) == 1):
        if description:
            st.caption(description)
        if not url_configured:
            st.warning(
                "`urlConfigured` is false — the tool URL did not resolve on the API. "
                "The call will return `url_not_configured`."
            )

        with st.form(key=f"form_{name}"):
            if pass_through:
                st.text_area(
                    "Request body (JSON object)",
                    value="{\n  \n}",
                    key=f"body_{name}",
                    help="Sent verbatim as the HTTP request body to the tool's URL.",
                    height=140,
                )
            elif parameters:
                for p in parameters:
                    pname = p.get("name", "")
                    ptype = p.get("type", "string")
                    required = bool(p.get("required", True))
                    pdesc = p.get("description", "")
                    label = f"{pname}{' *' if required else ''}  ({ptype})"
                    wkey = f"param_{name}_{pname}"
                    if ptype == "number":
                        # value=None -> field starts empty; an untouched optional
                        # number is then omitted from the request (see _build_named_input).
                        st.number_input(label, key=wkey, help=pdesc, value=None)
                    elif ptype == "boolean":
                        st.checkbox(label, key=wkey, help=pdesc)
                    elif ptype == "object":
                        st.text_area(label, key=wkey, help=pdesc, value="", height=120)
                    else:
                        st.text_input(label, key=wkey, help=pdesc, value="")
            else:
                st.caption("This tool takes no parameters.")

            submitted = st.form_submit_button(
                f"Execute {name}",
                type="primary",
                disabled=not url_configured,
            )

        if submitted:
            input_errors: list[str] = []
            tool_input: dict[str, Any] | None = {}

            if pass_through:
                tool_input, input_errors = _build_passthrough_input(name)
            elif parameters:
                tool_input, input_errors = _build_named_input(name, parameters)
            else:
                tool_input = {}

            if input_errors:
                st.session_state[f"result_{name}"] = {"input_errors": input_errors}
            else:
                status_code: int | None = None
                resp: dict = {}
                call_error: str | None = None
                timeout_s = float(timeout_ms) / 1000.0 + 15.0
                with st.status(f"Invoking {name} directly…", expanded=False) as status:
                    try:
                        status_code, resp = invoke_http_tool(
                            settings.api_base,
                            name,
                            tool_input or {},
                            access_token=api_token,
                            timeout=timeout_s,
                        )
                        status.update(label=f"HTTP {status_code}", state="complete")
                    except Exception as exc:  # noqa: BLE001
                        call_error = str(exc)
                        status.update(label="Request failed", state="error")
                st.session_state[f"result_{name}"] = {
                    "status_code": status_code,
                    "resp": resp,
                    "error": call_error,
                }

        _render_result(name)
