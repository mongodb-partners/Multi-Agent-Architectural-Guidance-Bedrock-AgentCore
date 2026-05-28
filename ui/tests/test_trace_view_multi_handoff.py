"""Tests for the multi-handoff client trace view rendering."""

from __future__ import annotations

import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Any

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib import client_trace_view as trace_view_module  # noqa: E402
from lib import trace_view_helpers as helpers_module  # noqa: E402
from lib.client_trace_view import render_routing  # noqa: E402


class _Recorder:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []
        self.session_state: dict[str, Any] = {}

    def _rec(self, name: str, *args: Any, **kwargs: Any) -> None:
        self.calls.append((name, args, kwargs))

    def markdown(self, *a: Any, **kw: Any) -> None:
        self._rec("markdown", *a, **kw)

    def caption(self, *a: Any, **kw: Any) -> None:
        self._rec("caption", *a, **kw)

    def code(self, *a: Any, **kw: Any) -> None:
        self._rec("code", *a, **kw)

    def info(self, *a: Any, **kw: Any) -> None:
        self._rec("info", *a, **kw)

    def warning(self, *a: Any, **kw: Any) -> None:
        self._rec("warning", *a, **kw)

    def write(self, *a: Any, **kw: Any) -> None:
        self._rec("write", *a, **kw)

    @contextmanager
    def expander(self, *a: Any, **kw: Any):
        self._rec("expander", *a, **kw)
        yield self


def _markdown_lines(rec: _Recorder) -> list[str]:
    return [
        args[0]
        for name, args, _kw in rec.calls
        if name == "markdown" and args
    ]


def _ev(t: str, payload: dict, eid: str = "") -> dict:
    return {"type": t, "payload": payload, "id": eid or f"{t}-1", "ts": 0}


def _patch(monkeypatch, rec: _Recorder) -> None:
    monkeypatch.setattr(trace_view_module, "st", rec)
    monkeypatch.setattr(helpers_module, "st", rec)


def test_render_routing_multi_path(monkeypatch) -> None:
    """Synthesis path renders the path label, all selected specialists,
    each draft status, and the synthesis summary."""
    rec = _Recorder()
    _patch(monkeypatch, rec)

    events = [
        _ev(
            "orchestrator.multi_route_decision",
            {
                "pathTaken": "synthesis",
                "selected": [
                    {"agentId": "order-management", "agentName": "Order Management", "score": 5.2, "source": "heuristic"},
                    {"agentId": "product-recommendation", "agentName": "Product Recommendation", "score": 4.1, "source": "heuristic"},
                ],
                "rejected": [],
            },
            "decision-1",
        ),
        _ev(
            "orchestrator.specialist_draft",
            {
                "agentId": "order-management",
                "agentName": "Order Management",
                "status": "success",
                "answerBytes": 124,
                "latencyMs": 800,
            },
            "draft-1",
        ),
        _ev(
            "orchestrator.specialist_draft",
            {
                "agentId": "product-recommendation",
                "agentName": "Product Recommendation",
                "status": "success",
                "answerBytes": 200,
                "latencyMs": 950,
            },
            "draft-2",
        ),
        _ev(
            "orchestrator.synthesis",
            {
                "modelId": "claude-haiku",
                "inputSpecialists": [
                    {"agentId": "order-management", "agentName": "Order Management"},
                    {"agentId": "product-recommendation", "agentName": "Product Recommendation"},
                ],
                "omittedSpecialists": [],
                "outputBytes": 280,
                "latencyMs": 600,
            },
            "synth-1",
        ),
    ]

    render_routing(events)

    md = "\n".join(_markdown_lines(rec))
    assert "Multi-specialist synthesis (2 specialists)" in md
    assert "Order Management" in md
    assert "Product Recommendation" in md
    assert "Synthesizer agent" in md
    assert "claude-haiku" in md


def test_render_routing_fast_path_single_specialist(monkeypatch) -> None:
    """Fast path renders the single label and one specialist chip, with
    no synthesis summary."""
    rec = _Recorder()
    _patch(monkeypatch, rec)

    events = [
        _ev(
            "orchestrator.multi_route_decision",
            {
                "pathTaken": "single",
                "selected": [
                    {"agentId": "troubleshooting", "agentName": "Troubleshooting", "score": 5.5, "source": "heuristic"},
                ],
                "rejected": [],
            },
            "decision-1",
        ),
        _ev(
            "orchestrator.specialist_draft",
            {
                "agentId": "troubleshooting",
                "agentName": "Troubleshooting",
                "status": "final",
                "answerBytes": 320,
                "latencyMs": 1100,
            },
            "draft-1",
        ),
    ]

    render_routing(events)

    md = "\n".join(_markdown_lines(rec))
    assert "Single specialist (fast path)" in md
    assert "Troubleshooting" in md
    assert "Synthesizer agent" not in md


def test_render_routing_failed_specialist_shows_caveat(monkeypatch) -> None:
    rec = _Recorder()
    _patch(monkeypatch, rec)

    events = [
        _ev(
            "orchestrator.multi_route_decision",
            {
                "pathTaken": "synthesis",
                "selected": [
                    {"agentId": "order-management", "agentName": "Order Management", "score": 5.2, "source": "heuristic"},
                    {"agentId": "product-recommendation", "agentName": "Product Recommendation", "score": 4.1, "source": "heuristic"},
                ],
                "rejected": [],
            },
            "decision-1",
        ),
        _ev(
            "orchestrator.specialist_draft",
            {
                "agentId": "product-recommendation",
                "agentName": "Product Recommendation",
                "status": "failed",
                "answerBytes": 0,
                "latencyMs": 50,
                "failureMessage": "model timed out",
            },
            "draft-1",
        ),
    ]

    render_routing(events)

    captions = [args[0] for name, args, _kw in rec.calls if name == "caption" and args]
    assert any("model timed out" in c for c in captions)


def test_render_routing_legacy_handoff_decision_still_works(monkeypatch) -> None:
    """Older single-handoff traces (no orchestrator.multi_*) still render
    via the legacy handoff.decision path."""
    rec = _Recorder()
    _patch(monkeypatch, rec)

    events = [
        _ev(
            "handoff.decision",
            {"from": "orchestrator", "to": "order-management", "label": "classifier:heuristic"},
            "h1",
        ),
    ]

    render_routing(events)
    md = "\n".join(_markdown_lines(rec))
    # Legacy path renders something — exact wording depends on the helper,
    # but we just need it to NOT have hit the multi-handoff section AND
    # to have produced output.
    assert "Multi-specialist synthesis" not in md
    assert "Single specialist (fast path)" not in md
    assert len(rec.calls) > 0


def test_render_routing_with_no_relevant_events_is_noop(monkeypatch) -> None:
    rec = _Recorder()
    _patch(monkeypatch, rec)
    render_routing([_ev("model.request", {"modelId": "x"})])
    # No routing events => function should bail before any st.* calls.
    md_calls = [c for c in rec.calls if c[0] == "markdown"]
    assert md_calls == []
