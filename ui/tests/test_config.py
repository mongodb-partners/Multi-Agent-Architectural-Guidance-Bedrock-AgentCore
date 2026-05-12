"""Unit tests for ui/lib/config.py — no Streamlit runtime required."""

from __future__ import annotations

import os
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Ensure ui/ root is on sys.path so `lib.config` resolves correctly.
_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib.config import (  # noqa: E402
    CognitoUIConfig,
    UISettings,
    _load_cognito_optional,
    _read_env_or_streamlit_secret,
    load_settings,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _clean_cognito_env():
    """Remove all STREAMLIT_COGNITO_* vars from the environment."""
    for k in list(os.environ):
        if k.startswith("STREAMLIT_COGNITO_"):
            del os.environ[k]


# ---------------------------------------------------------------------------
# _read_env_or_streamlit_secret
# ---------------------------------------------------------------------------


class TestReadEnvOrSecret:
    def test_returns_env_var_when_set(self, monkeypatch):
        monkeypatch.setenv("MY_VAR", "from_env")
        assert _read_env_or_streamlit_secret("MY_VAR") == "from_env"

    def test_returns_empty_when_unset_and_no_secrets(self, monkeypatch):
        monkeypatch.delenv("MY_VAR", raising=False)
        # Simulate Streamlit not available by removing it from sys.modules
        real_st = sys.modules.pop("streamlit", None)
        sys.modules["streamlit"] = None  # type: ignore[assignment]
        try:
            result = _read_env_or_streamlit_secret("MY_VAR", "MY_VAR")
        finally:
            if real_st is not None:
                sys.modules["streamlit"] = real_st
            else:
                sys.modules.pop("streamlit", None)
        assert result == ""

    def test_falls_back_to_streamlit_secret(self, monkeypatch):
        monkeypatch.delenv("MY_VAR", raising=False)
        mock_secrets = {"MY_VAR": "from_secret"}
        mock_st = MagicMock()
        mock_st.secrets = mock_secrets
        with patch.dict("sys.modules", {"streamlit": mock_st}):
            result = _read_env_or_streamlit_secret("MY_VAR", "MY_VAR")
        assert result == "from_secret"

    def test_env_takes_precedence_over_secret(self, monkeypatch):
        monkeypatch.setenv("MY_VAR", "env_wins")
        mock_secrets = {"MY_VAR": "secret_loses"}
        mock_st = MagicMock()
        mock_st.secrets = mock_secrets
        with patch.dict("sys.modules", {"streamlit": mock_st}):
            result = _read_env_or_streamlit_secret("MY_VAR", "MY_VAR")
        assert result == "env_wins"

    def test_strips_whitespace(self, monkeypatch):
        monkeypatch.setenv("MY_VAR", "  padded  ")
        assert _read_env_or_streamlit_secret("MY_VAR") == "padded"

    def test_ignores_blank_secret(self, monkeypatch):
        monkeypatch.delenv("MY_VAR", raising=False)
        mock_secrets = {"MY_VAR": "   "}
        mock_st = MagicMock()
        mock_st.secrets = mock_secrets
        with patch.dict("sys.modules", {"streamlit": mock_st}):
            result = _read_env_or_streamlit_secret("MY_VAR", "MY_VAR")
        assert result == ""


# ---------------------------------------------------------------------------
# _load_cognito_optional
# ---------------------------------------------------------------------------


class TestLoadCognitoOptional:
    def setup_method(self):
        _clean_cognito_env()

    def teardown_method(self):
        _clean_cognito_env()

    def test_returns_none_when_pool_id_missing(self, monkeypatch):
        monkeypatch.setenv("STREAMLIT_COGNITO_CLIENT_ID", "client123")
        assert _load_cognito_optional() is None

    def test_returns_none_when_client_id_missing(self, monkeypatch):
        monkeypatch.setenv("STREAMLIT_COGNITO_POOL_ID", "us-east-1_abc")
        assert _load_cognito_optional() is None

    def test_returns_config_with_pool_and_client(self, monkeypatch):
        monkeypatch.setenv("STREAMLIT_COGNITO_POOL_ID", "us-east-1_abc")
        monkeypatch.setenv("STREAMLIT_COGNITO_CLIENT_ID", "client123")
        cfg = _load_cognito_optional()
        assert isinstance(cfg, CognitoUIConfig)
        assert cfg.pool_id == "us-east-1_abc"
        assert cfg.client_id == "client123"
        assert cfg.client_secret is None
        assert cfg.domain is None
        assert cfg.redirect_uri is None

    def test_includes_optional_secret(self, monkeypatch):
        monkeypatch.setenv("STREAMLIT_COGNITO_POOL_ID", "us-east-1_abc")
        monkeypatch.setenv("STREAMLIT_COGNITO_CLIENT_ID", "client123")
        monkeypatch.setenv("STREAMLIT_COGNITO_CLIENT_SECRET", "shh")
        cfg = _load_cognito_optional()
        assert cfg is not None
        assert cfg.client_secret == "shh"

    def test_hosted_ui_requires_both_domain_and_redirect(self, monkeypatch):
        monkeypatch.setenv("STREAMLIT_COGNITO_POOL_ID", "us-east-1_abc")
        monkeypatch.setenv("STREAMLIT_COGNITO_CLIENT_ID", "client123")
        monkeypatch.setenv("STREAMLIT_COGNITO_CLIENT_SECRET", "shh")
        monkeypatch.setenv("STREAMLIT_COGNITO_DOMAIN", "myapp.auth.us-east-1.amazoncognito.com")
        # redirect_uri missing — domain should be nulled out
        cfg = _load_cognito_optional()
        assert cfg is not None
        assert cfg.domain is None
        assert cfg.redirect_uri is None

    def test_hosted_ui_full_config(self, monkeypatch):
        monkeypatch.setenv("STREAMLIT_COGNITO_POOL_ID", "us-east-1_abc")
        monkeypatch.setenv("STREAMLIT_COGNITO_CLIENT_ID", "client123")
        monkeypatch.setenv("STREAMLIT_COGNITO_CLIENT_SECRET", "shh")
        monkeypatch.setenv("STREAMLIT_COGNITO_DOMAIN", "myapp.auth.us-east-1.amazoncognito.com")
        monkeypatch.setenv("STREAMLIT_COGNITO_REDIRECT_URI", "http://localhost:8501")
        cfg = _load_cognito_optional()
        assert cfg is not None
        assert cfg.domain == "myapp.auth.us-east-1.amazoncognito.com"
        assert cfg.redirect_uri == "http://localhost:8501"


# ---------------------------------------------------------------------------
# load_settings
# ---------------------------------------------------------------------------


class TestLoadSettings:
    def setup_method(self):
        _clean_cognito_env()

    def teardown_method(self):
        _clean_cognito_env()

    def test_default_api_base(self, monkeypatch):
        monkeypatch.delenv("STREAMLIT_API_URL", raising=False)
        s = load_settings()
        assert s.api_base == "http://127.0.0.1:3000"

    def test_custom_api_base_strips_trailing_slash(self, monkeypatch):
        monkeypatch.setenv("STREAMLIT_API_URL", "http://api.example.com/")
        s = load_settings()
        assert s.api_base == "http://api.example.com"

    def test_cognito_none_when_not_configured(self, monkeypatch):
        monkeypatch.delenv("STREAMLIT_API_URL", raising=False)
        s = load_settings()
        assert s.cognito is None

    def test_cognito_populated_when_configured(self, monkeypatch):
        monkeypatch.setenv("STREAMLIT_COGNITO_POOL_ID", "us-east-1_abc")
        monkeypatch.setenv("STREAMLIT_COGNITO_CLIENT_ID", "client123")
        s = load_settings()
        assert isinstance(s.cognito, CognitoUIConfig)

    def test_settings_is_frozen(self, monkeypatch):
        monkeypatch.delenv("STREAMLIT_API_URL", raising=False)
        s = load_settings()
        with pytest.raises((AttributeError, TypeError)):
            s.api_base = "mutated"  # type: ignore[misc]
