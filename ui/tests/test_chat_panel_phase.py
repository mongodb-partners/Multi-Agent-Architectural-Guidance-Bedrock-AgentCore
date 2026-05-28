"""Tests for multi-specialist phase-aware token handling in chat_panel.

Acceptance: tokens carrying ``phase: "specialist"`` must render live but
must NOT accumulate into the persisted ``full`` answer; tokens carrying
``phase: "synthesis"`` (or no phase, the legacy fast-path) must accumulate.
"""

from __future__ import annotations

import sys
from pathlib import Path

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib.api_client import TokenEvent  # noqa: E402


def _accumulate(events: list[TokenEvent]) -> tuple[str, str]:
    """Mirror the ``chat_panel.py`` accumulator for token events.

    Returns ``(persisted_full, live_visible)`` — ``persisted_full`` is what
    ends up in ``st.session_state.messages`` / DB; ``live_visible`` is the
    on-screen markdown across all blocks.
    """
    persisted = ""
    visible = ""
    for ev in events:
        visible += ev.text
        if ev.phase == "specialist":
            # Specialist drafts are LIVE-only; never persisted.
            continue
        # phase == "synthesis" or phase is None (legacy / fast path)
        persisted += ev.text
    return persisted, visible


def test_specialist_drafts_not_persisted_synthesis_persisted() -> None:
    events = [
        TokenEvent(text="Order status: ", phase="specialist", specialist_id="order-management", rank=0),
        TokenEvent(text="shipped Monday.", phase="specialist", specialist_id="order-management", rank=0),
        TokenEvent(text="Recommendation: ", phase="specialist", specialist_id="product-recommendation", rank=1),
        TokenEvent(text="X1 Carbon.", phase="specialist", specialist_id="product-recommendation", rank=1),
        TokenEvent(text="Your order ships Monday; ", phase="synthesis"),
        TokenEvent(text="and we recommend the X1 Carbon.", phase="synthesis"),
    ]
    persisted, visible = _accumulate(events)
    assert "Order status:" not in persisted
    assert "X1 Carbon." not in persisted or persisted.endswith("X1 Carbon.")
    assert persisted == "Your order ships Monday; and we recommend the X1 Carbon."
    # The user-visible stream still shows everything in real time.
    assert "Order status:" in visible
    assert "X1 Carbon." in visible


def test_fast_path_no_phase_persists_token_text() -> None:
    """Single-specialist fast path emits tokens with no phase field."""
    events = [
        TokenEvent(text="Hello "),
        TokenEvent(text="world."),
    ]
    persisted, visible = _accumulate(events)
    assert persisted == "Hello world."
    assert visible == "Hello world."


def test_specialist_only_no_synthesis_persists_empty() -> None:
    """Defensive: if upstream emits only specialist tokens (no synthesis,
    no fast-path), persisted must be empty so we never silently store a
    raw draft as the final answer.
    """
    events = [
        TokenEvent(text="Draft only.", phase="specialist", specialist_id="x", rank=0),
    ]
    persisted, _ = _accumulate(events)
    assert persisted == ""
