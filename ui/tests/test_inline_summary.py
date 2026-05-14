"""Tests for inline_summary.aggregate_summary — pure aggregation."""

from __future__ import annotations

import sys
from pathlib import Path

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib.api_client import TraceEvent  # noqa: E402
from lib.inline_summary import aggregate_summary  # noqa: E402


def _ev(t: str, payload: dict, ts: int = 0, eid: str = "e") -> TraceEvent:
    return TraceEvent(type=t, id=eid, ts=ts, payload=payload)


class TestAggregateSummary:
    def test_empty_input_returns_no_signal(self) -> None:
        s = aggregate_summary([])
        assert not s.has_signal()
        assert s.total_tokens == 0
        assert s.cost_usd is None

    def test_token_aggregation_and_cost(self) -> None:
        events = [
            _ev(
                "model.usage",
                {
                    "modelId": "anthropic.claude-sonnet-4-5",
                    "inputTokens": 1000,
                    "outputTokens": 500,
                    "totalTokens": 1500,
                },
            ),
            _ev(
                "model.usage",
                {
                    "modelId": "anthropic.claude-sonnet-4-5",
                    "inputTokens": 200,
                    "outputTokens": 100,
                    "totalTokens": 300,
                },
            ),
        ]
        s = aggregate_summary(events)
        assert s.input_tokens == 1200
        assert s.output_tokens == 600
        assert s.total_tokens == 1800
        assert s.cost_usd is not None
        assert s.cost_estimate_complete is True
        assert "anthropic.claude-sonnet-4-5" in s.model_ids

    def test_unknown_model_marks_incomplete(self) -> None:
        s = aggregate_summary(
            [
                _ev(
                    "model.usage",
                    {
                        "modelId": "openai.gpt-5",
                        "inputTokens": 1000,
                        "outputTokens": 500,
                        "totalTokens": 1500,
                    },
                ),
            ],
        )
        assert s.cost_estimate_complete is False
        assert s.cost_usd is None

    def test_tools_used_dedup_on_end_phase(self) -> None:
        events = [
            _ev("tool.call", {"toolName": "lookup", "phase": "start"}),
            _ev("tool.call", {"toolName": "lookup", "phase": "end"}),
            _ev("tool.call", {"toolName": "lookup", "phase": "end"}),
            _ev("tool.call", {"toolName": "translate", "phase": "end"}),
        ]
        s = aggregate_summary(events)
        assert s.tools_used == ["lookup", "translate"]

    def test_mongo_ops_capture(self) -> None:
        events = [
            _ev("mongo.result", {"docCount": 3, "latencyMs": 12, "status": "ok"}),
            _ev("mongo.result", {"docCount": 0, "latencyMs": 8, "status": "empty"}),
        ]
        s = aggregate_summary(events)
        assert len(s.mongo_ops) == 2
        assert s.mongo_ops[0]["docCount"] == 3

    def test_handoff_capture(self) -> None:
        events = [
            _ev(
                "handoff.decision",
                {"fromAgentId": "orchestrator", "toAgentId": "order-management"},
            ),
        ]
        s = aggregate_summary(events)
        assert s.handoffs == [("orchestrator", "order-management")]

    def test_classification_reasoning_captured(self) -> None:
        events = [
            _ev(
                "agentcore.classification",
                {
                    "inputMessage": "where is my order",
                    "chosenSpecialist": "order-management",
                    "reasoning": "Detected order-tracking intent.",
                    "latencyMs": 240,
                },
            ),
            _ev(
                "agentcore.classification",
                {
                    "chosenSpecialist": "product-recommendation",
                    "reasoning": "",
                    "latencyMs": 180,
                },
            ),
            _ev(
                "agentcore.classification",
                {"chosenSpecialist": "", "reasoning": ""},
            ),
        ]
        s = aggregate_summary(events)
        assert len(s.classifications) == 2
        assert s.classifications[0]["chosen"] == "order-management"
        assert s.classifications[0]["reasoning"].startswith("Detected")
        assert s.classifications[0]["latency_ms"] == 240
        assert s.classifications[1]["chosen"] == "product-recommendation"
        assert s.classifications[1]["reasoning"] == ""
        assert s.has_reasoning() is True
        assert s.has_signal() is True

    def test_thinking_blocks_captured_and_empty_dropped(self) -> None:
        events = [
            _ev("model.thinking_block", {"text": "Step 1: parse query.", "bytes": 20}),
            _ev("model.thinking_block", {"text": "  ", "bytes": 2}),
            _ev("model.thinking_block", {"text": "Step 2: pick collection.", "bytes": 24}),
        ]
        s = aggregate_summary(events)
        assert s.thinking_blocks == [
            "Step 1: parse query.",
            "Step 2: pick collection.",
        ]
        assert s.has_reasoning() is True

    def test_no_reasoning_means_has_reasoning_false(self) -> None:
        s = aggregate_summary([])
        assert s.has_reasoning() is False

    def test_memory_facts_read_and_written(self) -> None:
        events = [
            _ev(
                "memory.scoped_read",
                {
                    "scope": "scoped",
                    "userId": "u",
                    "facts": [],
                    "entryCount": 3,
                    "bytesInjected": 100,
                    "collectionsQueried": [],
                    "injectionPoint": "system_prompt",
                    "latencyMs": 10,
                    "backend": "mongodb",
                },
            ),
            _ev(
                "memory.long_term_write",
                {
                    "userId": "u",
                    "agentId": "a",
                    "ts": "now",
                    "factCandidates": [],
                    "factsExtracted": ["x"],
                    "collection": "agent_memory_facts",
                    "op": "insertMany",
                    "docsInserted": 1,
                    "primaryBackend": "mongodb",
                    "primaryOutcome": "persisted",
                    "userMessageBytes": 0,
                    "userMessageBytesStored": 0,
                    "assistantReplyBytes": 0,
                    "assistantReplyBytesStored": 0,
                    "priorEntryCount": 0,
                    "newEntryCount": 1,
                    "ttlExpiresAt": "",
                    "latencyMs": 12,
                },
            ),
        ]
        s = aggregate_summary(events)
        assert s.memory_facts_read == 3
        assert s.memory_facts_written == 1
