"""Developer harness for the debug-grade "Developer details" panel.

Run from the repo root:

    streamlit run ui/scripts/render_dev_fixture.py -- \
        --fixture ui/tests/fixtures/dev_trace_full_kitchen_sink.json

Or pick a fixture from the sidebar dropdown when no flag is set. The harness
pre-toggles `st.session_state[f"dev_open_{traceId}"] = True` so the dev
surface renders on first paint — saves you a click when iterating.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import streamlit as st

_repo_root = Path(__file__).resolve().parents[2]
_ui_root = _repo_root / "ui"
for path in (_ui_root, _repo_root):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from lib.brand_css import inject_brand_css  # noqa: E402
from lib.trace_css import inject_trace_css  # noqa: E402
from lib.client_trace_view import (  # noqa: E402
    render_summary_header,
    render_trace_meta,
)
from lib.developer_trace_view import render_developer_details  # noqa: E402

_FIXTURE_DIR = _ui_root / "tests" / "fixtures"
_FIXTURE_GLOB = "dev_trace_*.json"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--fixture",
        default=None,
        help="Path to a fixture JSON, or filename inside ui/tests/fixtures/",
    )
    known, _ = parser.parse_known_args()
    return known


def _load_fixture(name_or_path: str) -> dict:
    candidate = Path(name_or_path)
    if not candidate.is_absolute():
        if (_FIXTURE_DIR / candidate.name).exists():
            candidate = _FIXTURE_DIR / candidate.name
        elif candidate.exists():
            candidate = candidate.resolve()
    return json.loads(candidate.read_text())


def main() -> None:
    st.set_page_config(page_title="Dev fixture render harness", layout="wide")
    inject_trace_css()
    inject_brand_css()

    args = _parse_args()
    fixtures = sorted(p.name for p in _FIXTURE_DIR.glob(_FIXTURE_GLOB))
    if not fixtures:
        st.error(
            f"No `{_FIXTURE_GLOB}` fixtures found under `{_FIXTURE_DIR}`. "
            "Add one or pass --fixture <path>."
        )
        return
    default_index = 0
    if args.fixture and Path(args.fixture).name in fixtures:
        default_index = fixtures.index(Path(args.fixture).name)

    choice = st.sidebar.selectbox("Fixture", fixtures, index=default_index)
    trace = _load_fixture(choice)

    # Pre-toggle the dev panel so it renders on first paint — saves a click
    # when iterating on a sub-renderer.
    trace_id = trace.get("traceId") or ""
    if trace_id:
        st.session_state.setdefault(f"dev_open_{trace_id}", True)
        st.session_state.setdefault(f"dev_trace_{trace_id}", trace)

    st.title("Developer details fixture harness")
    st.caption(f"Source: `ui/tests/fixtures/{choice}`")

    render_trace_meta(trace)
    render_summary_header(trace)
    st.markdown(
        "<hr class='trace-developer-divider'/>",
        unsafe_allow_html=True,
    )
    # `settings=None` short-circuits the on-demand fetch — `dev_trace_<id>`
    # in session_state above is what the panel reads.
    render_developer_details(trace, settings=None, api_token=None)

    with st.expander("Raw fixture JSON", expanded=False):
        st.json(trace)


if __name__ == "__main__":
    main()
