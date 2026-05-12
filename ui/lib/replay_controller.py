"""Step-through replay for the Trace Viewer.

Renders a small HTML/JS bridge that walks through the captured trace events
in order — without triggering a Streamlit rerun per step. The bridge:

  * sets ``data-replay-active="1"`` on ``<body>`` while replay is active;
  * toggles ``.trace-replay-current`` on the tile matching the current
    span's id;
  * advances on a wall-clock timer scaled to each event's ``durationMs``,
    or jumps with the keyboard:

      | Key       | Action                       |
      |-----------|------------------------------|
      | ``Space`` | pause / resume               |
      | ``→``     | next event                   |
      | ``←``     | previous event               |
      | ``R``     | restart from event 0         |

The companion CSS (``ui/lib/trace_css.py``) provides the dim / highlight
styles. Tiles must carry ``data-event-id="<event.id>"`` for the highlight to
attach (see :func:`event_anchor` below).
"""

from __future__ import annotations

import html
import json
from dataclasses import dataclass
from typing import Iterable

import streamlit as st
import streamlit.components.v1 as components


@dataclass(frozen=True)
class ReplayStep:
    spanId: str
    durationMs: int
    label: str


def steps_from_events(events: Iterable[dict]) -> list[ReplayStep]:
    """Pick a sensible subset of trace events to step through.

    Excludes high-frequency low-signal events (e.g. ``model.text_delta_batch``)
    that would just blur the playback.
    """
    boring = {"model.text_delta_batch", "model.thinking_block"}
    out: list[ReplayStep] = []
    for ev in events:
        ty = ev.get("type") or ""
        if ty in boring:
            continue
        out.append(
            ReplayStep(
                spanId=str(ev.get("id") or ""),
                durationMs=int(ev.get("durationMs") or 0),
                label=ty,
            )
        )
    return out


def event_anchor(event_id: str) -> str:
    """HTML attribute string to splat onto a tile so replay can highlight it.

    Usage in render functions::

        f'<div class="trace-tile" {event_anchor(ev["id"])}>…</div>'
    """
    return f'data-event-id="{html.escape(event_id, quote=True)}"'


def render_replay_controls(events: list[dict]) -> None:
    """Render the replay control strip + JS bridge."""
    steps = steps_from_events(events)
    if not steps:
        return

    steps_json = json.dumps(
        [{"spanId": s.spanId, "durationMs": s.durationMs, "label": s.label} for s in steps]
    )

    components.html(
        f"""
        <div class="trace-replay-controls" style="display:flex;gap:8px;align-items:center;margin:6px 0 12px;">
          <button id="trace-replay-play" type="button"
                  style="padding:4px 12px;border-radius:6px;border:1px solid #888;background:#222;color:#eee;cursor:pointer;">
            ▶ Play
          </button>
          <button id="trace-replay-restart" type="button"
                  style="padding:4px 10px;border-radius:6px;border:1px solid #888;background:#222;color:#eee;cursor:pointer;">
            ↺ Restart
          </button>
          <span id="trace-replay-status" style="font-size:12px;opacity:0.7;">
            Space = play/pause · ← → step · R restart
          </span>
        </div>
        <script>
          (function() {{
            const steps = {steps_json};
            if (!steps.length) return;
            const body = window.parent.document.body;
            const doc  = window.parent.document;

            let i = 0;
            let timer = null;

            function clearHighlights() {{
              doc.querySelectorAll(".trace-replay-current").forEach(el =>
                el.classList.remove("trace-replay-current"));
            }}
            function paint() {{
              clearHighlights();
              const step = steps[i];
              if (!step) return;
              const tile = doc.querySelector('[data-event-id="' + step.spanId + '"]');
              if (tile) tile.classList.add("trace-replay-current");
              const status = doc.getElementById("trace-replay-status");
              if (status) status.textContent =
                "Step " + (i + 1) + "/" + steps.length + " — " + step.label;
            }}
            function setActive(active) {{
              if (active) body.setAttribute("data-replay-active", "1");
              else body.removeAttribute("data-replay-active");
            }}
            function stop() {{
              if (timer) {{ clearTimeout(timer); timer = null; }}
            }}
            function next() {{
              stop();
              i = Math.min(i + 1, steps.length - 1);
              paint();
            }}
            function prev() {{
              stop();
              i = Math.max(i - 1, 0);
              paint();
            }}
            function tick() {{
              paint();
              if (i >= steps.length - 1) {{ stop(); return; }}
              const delay = Math.max(280, Math.min(steps[i].durationMs || 600, 1800));
              timer = setTimeout(() => {{ i += 1; tick(); }}, delay);
            }}
            function play() {{
              setActive(true);
              if (timer) stop();
              else tick();
            }}
            function restart() {{
              stop();
              i = 0;
              setActive(true);
              tick();
            }}

            doc.getElementById("trace-replay-play").onclick = play;
            doc.getElementById("trace-replay-restart").onclick = restart;

            doc.addEventListener("keydown", (e) => {{
              if (e.target && /input|textarea/i.test(e.target.tagName)) return;
              if (e.code === "Space") {{ e.preventDefault(); play(); }}
              else if (e.code === "ArrowRight") {{ next(); }}
              else if (e.code === "ArrowLeft")  {{ prev(); }}
              else if (e.key === "r" || e.key === "R") {{ restart(); }}
            }});
          }})();
        </script>
        """,
        height=42,
    )
