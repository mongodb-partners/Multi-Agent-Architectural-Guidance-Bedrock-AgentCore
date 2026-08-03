"""Metrics sidebar aggregation — the fields must match the API's summary shape.

Latency (`durationMs`) and MongoDB ops (`mongoQueries`) both read blank when
the field names drift from `/traces`, which is exactly what this pins.
"""

from __future__ import annotations

import sys
from contextlib import contextmanager
from pathlib import Path

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib import metrics_sidebar  # noqa: E402


class _FakeSt:
    """Records st.metric(label, value) so the block can be asserted on."""

    def __init__(self) -> None:
        self.metrics: dict[str, str] = {}

    @contextmanager
    def expander(self, *_a, **_kw):
        yield self

    def metric(self, label: str, value: str) -> None:
        self.metrics[label] = value

    def caption(self, *_a, **_kw) -> None:
        pass


def _render(traces: list[dict], monkeypatch) -> dict[str, str]:
    fake = _FakeSt()
    monkeypatch.setattr(metrics_sidebar, "st", fake)
    monkeypatch.setattr(metrics_sidebar, "_recent", lambda *_a: traces)
    metrics_sidebar.render_metrics_block("http://api", None)
    return fake.metrics


def _trace(**summary) -> dict:
    return {"summary": summary}


def test_latency_and_mongo_ops_use_api_field_names(monkeypatch) -> None:
    metrics = _render(
        [
            _trace(durationMs=2000, mongoQueries=3, totalTokens=100, estimatedCostUsd=0.01),
            _trace(durationMs=4000, mongoQueries=1, totalTokens=50, estimatedCostUsd=0.02),
        ],
        monkeypatch,
    )

    assert metrics["Avg latency"] == "3.00s"
    assert metrics["MongoDB ops"] == "4"
    assert metrics["Total tokens"] == "150"
    assert metrics["Total cost (USD)"] == "$0.0300"


def test_avg_latency_ignores_turns_without_a_duration(monkeypatch) -> None:
    # A trace persisted before the API folded durationMs into the summary must
    # not halve the average.
    metrics = _render([_trace(durationMs=2000), _trace(mongoQueries=2)], monkeypatch)

    assert metrics["Avg latency"] == "2.00s"
    assert metrics["MongoDB ops"] == "2"
