"""Developer harness for the debug-grade LTM trace section.

Usage (from repo root):
    streamlit run ui/scripts/render_ltm_fixture.py -- \
        --fixture ui/tests/fixtures/ltm_trace_read_redacted.json

Or pick a fixture from the dropdown in the rendered page when no flag is set.
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
    render_memory,
    render_prompt_and_skills,
    render_summary_header,
    render_trace_meta,
)

_FIXTURE_DIR = _ui_root / "tests" / "fixtures"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", default=None, help="Path to a fixture JSON, or filename inside ui/tests/fixtures/")
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
    st.set_page_config(page_title="LTM fixture render harness", layout="wide")
    inject_trace_css()
    inject_brand_css()

    args = _parse_args()
    fixtures = sorted(p.name for p in _FIXTURE_DIR.glob("ltm_trace_*.json"))
    default_index = 0
    if args.fixture and Path(args.fixture).name in fixtures:
        default_index = fixtures.index(Path(args.fixture).name)

    choice = st.sidebar.selectbox("Fixture", fixtures, index=default_index)
    trace = _load_fixture(choice)

    st.title("LTM fixture render harness")
    st.caption(f"Source: `ui/tests/fixtures/{choice}`")
    events = trace.get("events") or []

    render_trace_meta(trace)
    render_summary_header(trace)
    render_prompt_and_skills(events)
    render_memory(events)

    with st.expander("Raw fixture JSON", expanded=False):
        st.json(trace)


if __name__ == "__main__":
    main()
