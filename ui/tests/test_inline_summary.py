"""Tests for inline_summary.aggregate_summary — pure aggregation."""

from __future__ import annotations

from contextlib import contextmanager
import sys
from pathlib import Path
from typing import Any

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib.api_client import TraceEvent  # noqa: E402
from lib import inline_summary as inline_summary_module  # noqa: E402
from lib.inline_summary import (  # noqa: E402
    TurnSummary,
    _dedupe_vector_searches,
    _render_vector_sources_panel,
    aggregate_summary,
)


def _ev(t: str, payload: dict, ts: int = 0, eid: str = "e") -> TraceEvent:
    return TraceEvent(type=t, id=eid, ts=ts, payload=payload)


class _StreamlitRecorder:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []

    def _record(self, name: str, *args: Any, **kwargs: Any) -> None:
        self.calls.append((name, args, kwargs))

    def caption(self, *args: Any, **kwargs: Any) -> None:
        self._record("caption", *args, **kwargs)

    def markdown(self, *args: Any, **kwargs: Any) -> None:
        self._record("markdown", *args, **kwargs)

    @contextmanager
    def expander(self, *args: Any, **kwargs: Any):
        self._record("expander", *args, **kwargs)
        yield self


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

    def test_memory_hybrid_retrieval_payload_back_compat(self) -> None:
        """Enriched hybrid retrieval payload (mode/embeddingSource/retrieval/...) must keep
        the original entryCount + docsInserted/op fields the inline summary aggregator
        consumes, so the Trace UI does not regress when the LTM read/write path is upgraded."""
        events = [
            _ev(
                "memory.scoped_read",
                {
                    "scope": "scoped",
                    "userId": "u",
                    "facts": [],
                    "entryCount": 5,
                    "bytesInjected": 320,
                    "collectionsQueried": [
                        "agent_memory_facts",
                        "chat_messages",
                    ],
                    "injectionPoint": "system_prompt",
                    "latencyMs": 42,
                    "backend": "mongodb",
                    "mode": "hybrid",
                    "queryText": "any tips for my pup on long drives?",
                    "embeddingSource": "voyage-sagemaker",
                    "embeddingModel": "voyage-3.5-lite",
                    "retrieval": {
                        "topK": 5,
                        "fetchK": 24,
                        "vectorHits": 8,
                        "lexicalHits": 6,
                        "rrfMergedCount": 12,
                        "perCollection": [
                            {"name": "agent_memory_facts", "vectorHits": 5, "lexicalHits": 3},
                            {"name": "chat_messages", "vectorHits": 3, "lexicalHits": 3},
                        ],
                    },
                },
            ),
            _ev(
                "memory.long_term_write",
                {
                    "userId": "u",
                    "agentId": "a",
                    "ts": "now",
                    "factCandidates": ["x", "y"],
                    "factsExtracted": ["x", "y"],
                    "collection": "agent_memory_facts",
                    "op": "bulkWrite",
                    "docsInserted": 2,
                    "duplicatesSkipped": 1,
                    "embeddedCount": 2,
                    "embeddingModel": "voyage-3.5-lite",
                    "primaryBackend": "mongodb",
                    "primaryOutcome": "persisted",
                    "userMessageBytes": 0,
                    "userMessageBytesStored": 0,
                    "assistantReplyBytes": 0,
                    "assistantReplyBytesStored": 0,
                    "priorEntryCount": 0,
                    "newEntryCount": 2,
                    "ttlExpiresAt": "",
                    "latencyMs": 87,
                },
            ),
        ]
        s = aggregate_summary(events)
        assert s.memory_facts_read == 5
        assert s.memory_facts_written == 2

    def test_vector_search_previews_captured(self) -> None:
        events = [
            _ev(
                "mongo.vector_search",
                {
                    "collection": "products",
                    "queryText": "portable home widgets",
                    "scores": [0.92, 0.74],
                    "documentPreviews": [
                        {
                            "rank": 1,
                            "collection": "products",
                            "id": "p1",
                            "title": "Compact Widget",
                            "score": 0.92,
                            "sources": ["products"],
                        },
                        {
                            "rank": 2,
                            "collection": "products",
                            "id": "p2",
                            "title": "Travel Widget",
                            "score": 0.74,
                            "sources": ["catalog"],
                        },
                    ],
                },
            )
        ]

        s = aggregate_summary(events)

        assert s.has_signal() is True
        assert len(s.vector_searches) == 1
        search = s.vector_searches[0]
        assert search["collection"] == "products"
        assert search["hit_count"] == 2
        assert search["previews"][0]["title"] == "Compact Widget"
        assert search["previews"][0]["score"] == 0.92
        assert search["previews"][0]["sources"] == ["products"]

    def test_vector_search_falls_back_to_sample_docs(self) -> None:
        events = [
            _ev(
                "mongo.result",
                {
                    "status": "ok",
                    "docCount": 1,
                    "latencyMs": 12,
                    "sampleDocs": [
                        {
                            "_id": "ts-3",
                            "docId": "ts-3",
                            "title": "Hardware fault - HW-900",
                            "body": "HW-900 means the hardware fault path should be escalated.",
                            "source": "troubleshooting_docs",
                            "_score": 0.91,
                        }
                    ],
                },
            ),
            _ev(
                "mongo.vector_search",
                {
                    "collection": "troubleshooting_docs",
                    "queryText": "HW-900",
                    "scores": [0.91],
                },
            ),
        ]

        s = aggregate_summary(events)
        preview = s.vector_searches[0]["previews"][0]

        assert preview["collection"] == "troubleshooting_docs"
        assert preview["title"] == "Hardware fault - HW-900"
        assert preview["sources"] == ["troubleshooting_docs"]
        assert preview["score"] == 0.91
        assert preview["snippet"].startswith("HW-900 means")

    def test_vector_source_rendering_uses_plain_markdown_and_dedupes(self, monkeypatch) -> None:
        recorder = _StreamlitRecorder()
        monkeypatch.setattr(inline_summary_module, "st", recorder)
        search = {
            "collection": "products",
            "query_text": "recommend similar product",
            "hit_count": 1,
            "previews": [
                {
                    "rank": 1,
                    "collection": "products",
                    "id": "p1",
                    "title": "Compact <span>Widget</span>",
                    "score": 0.52,
                    "snippet": 'Useful "widget" for small spaces.\nSecond line.',
                    "fields": {"sku": "SKU-1", "category": "home"},
                }
            ],
        }
        summary = TurnSummary(vector_searches=[search, dict(search)])

        _render_vector_sources_panel(summary)

        captions = [args[0] for name, args, _kwargs in recorder.calls if name == "caption"]
        markdowns = [args[0] for name, args, _kwargs in recorder.calls if name == "markdown"]
        assert captions.count("Sources from vector search - 1 hit on `products`") == 1
        assert len([m for m in markdowns if "#1 Compact" in m]) == 1
        assert all("vec-source-pill" not in m for m in markdowns)
        assert all("<span class=" not in m for m in markdowns)
        assert any("Fields: sku=SKU-1, category=home" in c for c in captions)

    def test_vector_search_dedupe_keeps_distinct_queries(self) -> None:
        base = {
            "collection": "products",
            "query_text": "compact widget",
            "hit_count": 1,
            "previews": [{"rank": 1, "id": "p1", "title": "Compact Widget"}],
        }
        searches = [base, dict(base), {**base, "query_text": "travel widget"}]

        deduped = _dedupe_vector_searches(searches)

        assert len(deduped) == 2
        assert [s["query_text"] for s in deduped] == ["compact widget", "travel widget"]
