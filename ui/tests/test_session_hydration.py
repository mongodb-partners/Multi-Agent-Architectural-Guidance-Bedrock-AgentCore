"""Tests for session URL hydration helpers."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib import session_hydration as hydration  # noqa: E402


class TestQuerySessionId:
    def test_reads_scalar_param(self, monkeypatch) -> None:
        monkeypatch.setattr(hydration.st, "query_params", {"sessionId": "sess_abc"})
        assert hydration.query_session_id() == "sess_abc"

    def test_reads_list_param(self, monkeypatch) -> None:
        monkeypatch.setattr(
            hydration.st, "query_params", {"sessionId": ["sess_list"]}
        )
        assert hydration.query_session_id() == "sess_list"


class TestEnsureChatSessionHydrated:
    @patch("lib.session_hydration._fetch_session_messages")
    def test_refresh_loads_when_url_matches_empty_messages(
        self, mock_fetch, monkeypatch
    ) -> None:
        mock_fetch.return_value = [{"role": "user", "content": "hi"}]

        class FakeSessionState:
            def __init__(self) -> None:
                self.session_id = "sess_old"
                self.messages: list = []

            def get(self, key: str, default=None):
                return getattr(self, key, default)

            def pop(self, key: str, default=None):
                if hasattr(self, key):
                    val = getattr(self, key)
                    delattr(self, key)
                    return val
                return default

        ss = FakeSessionState()
        mock_st = MagicMock()
        mock_st.session_state = ss
        mock_st.query_params = {"sessionId": "sess_old"}
        monkeypatch.setattr(hydration, "st", mock_st)

        hydration.ensure_chat_session_hydrated("http://api", "tok")

        mock_fetch.assert_called_once_with("http://api", "sess_old", "tok")
        assert ss.messages == [{"role": "user", "content": "hi"}]
        assert ss._hydrated_session_id == "sess_old"

    @patch("lib.session_hydration.enrich_messages_with_traces")
    @patch("lib.session_hydration._fetch_session_messages")
    def test_new_empty_session_does_not_fetch(
        self, mock_fetch, mock_enrich, monkeypatch
    ) -> None:
        session_state = {
            "session_id": "sess_new",
            "messages": [],
        }
        monkeypatch.setattr(hydration, "st", MagicMock())
        hydration.st.session_state = session_state
        hydration.st.query_params = {}

        hydration.ensure_chat_session_hydrated("http://api", "tok")

        mock_fetch.assert_not_called()
        mock_enrich.assert_not_called()
