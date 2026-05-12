"""Unit tests for ui/lib/cognito_gate.py — mocks Streamlit and streamlit-cognito-auth."""

from __future__ import annotations

import importlib
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest

_UI_ROOT = str(Path(__file__).resolve().parent.parent)
if _UI_ROOT not in sys.path:
    sys.path.insert(0, _UI_ROOT)

from lib.config import CognitoUIConfig, UISettings  # noqa: E402

# Save real module references once at import time so teardown can restore them.
_REAL_STREAMLIT = sys.modules.get("streamlit")
_REAL_SCA = sys.modules.get("streamlit_cognito_auth")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_settings(
    *,
    pool_id: str = "us-east-1_abc",
    client_id: str = "client123",
    client_secret: str | None = None,
    domain: str | None = None,
    redirect_uri: str | None = None,
) -> UISettings:
    return UISettings(
        api_base="http://localhost:3000",
        cognito=CognitoUIConfig(
            pool_id=pool_id,
            client_id=client_id,
            client_secret=client_secret,
            domain=domain,
            redirect_uri=redirect_uri,
        ),
    )


def _settings_no_cognito() -> UISettings:
    return UISettings(api_base="http://localhost:3000", cognito=None)


def _make_mock_st(session_state: dict | None = None) -> MagicMock:
    """Build a mock streamlit module with a plain dict as session_state."""
    mock_st = MagicMock()
    mock_st.session_state = {} if session_state is None else session_state
    return mock_st


def _load_gate(mock_st: MagicMock, mock_auth_cls=None, mock_hosted_cls=None):
    """
    Inject mock streamlit (and optionally mock auth classes) into sys.modules,
    then reload lib.cognito_gate so it binds to the mocks.
    Returns the reloaded gate module.
    """
    sys.modules["streamlit"] = mock_st
    mock_sca = MagicMock()
    mock_sca.CognitoAuthenticator = mock_auth_cls or MagicMock()
    mock_sca.CognitoHostedUIAuthenticator = mock_hosted_cls or MagicMock()
    sys.modules["streamlit_cognito_auth"] = mock_sca
    gate = importlib.import_module("lib.cognito_gate")
    importlib.reload(gate)
    return gate


def _restore_modules():
    """Restore sys.modules to the real streamlit / sca objects saved at import time.
    Does NOT reload lib.cognito_gate — the next test's _load_gate() will reload it fresh.
    """
    if _REAL_STREAMLIT is not None:
        sys.modules["streamlit"] = _REAL_STREAMLIT
    else:
        sys.modules.pop("streamlit", None)
    if _REAL_SCA is not None:
        sys.modules["streamlit_cognito_auth"] = _REAL_SCA
    else:
        sys.modules.pop("streamlit_cognito_auth", None)


# ---------------------------------------------------------------------------
# _make_authenticator — domain scheme normalization
# ---------------------------------------------------------------------------


class TestMakeAuthenticator:
    def teardown_method(self):
        _restore_modules()

    def test_uses_embedded_authenticator_when_no_domain(self):
        mock_embedded = MagicMock()
        mock_hosted = MagicMock()
        gate = _load_gate(_make_mock_st(), mock_auth_cls=mock_embedded, mock_hosted_cls=mock_hosted)
        cfg = CognitoUIConfig(
            pool_id="us-east-1_abc", client_id="cid",
            client_secret="sec", domain=None, redirect_uri=None,
        )
        gate._make_authenticator(cfg)
        mock_embedded.assert_called_once()
        mock_hosted.assert_not_called()

    def test_prepends_https_to_bare_domain(self):
        mock_hosted = MagicMock()
        gate = _load_gate(_make_mock_st(), mock_hosted_cls=mock_hosted)
        cfg = CognitoUIConfig(
            pool_id="us-east-1_abc", client_id="cid", client_secret="sec",
            domain="myapp.auth.us-east-1.amazoncognito.com",
            redirect_uri="http://localhost:8501",
        )
        gate._make_authenticator(cfg)
        mock_hosted.assert_called_once()
        assert mock_hosted.call_args.kwargs["cognito_domain"].startswith("https://")

    def test_does_not_double_prepend_https(self):
        mock_hosted = MagicMock()
        gate = _load_gate(_make_mock_st(), mock_hosted_cls=mock_hosted)
        cfg = CognitoUIConfig(
            pool_id="us-east-1_abc", client_id="cid", client_secret="sec",
            domain="https://myapp.auth.us-east-1.amazoncognito.com",
            redirect_uri="http://localhost:8501",
        )
        gate._make_authenticator(cfg)
        domain = mock_hosted.call_args.kwargs["cognito_domain"]
        assert not domain.startswith("https://https://")

    def test_hosted_ui_requires_client_secret_or_stops(self):
        mock_st = _make_mock_st()
        mock_st.stop.side_effect = SystemExit(0)
        mock_hosted = MagicMock()
        gate = _load_gate(mock_st, mock_hosted_cls=mock_hosted)
        cfg = CognitoUIConfig(
            pool_id="us-east-1_abc", client_id="cid",
            client_secret=None,
            domain="https://myapp.auth.us-east-1.amazoncognito.com",
            redirect_uri="http://localhost:8501",
        )
        with pytest.raises(SystemExit):
            gate._make_authenticator(cfg)
        mock_st.error.assert_called_once()
        mock_hosted.assert_not_called()

    def test_redirect_uri_gets_trailing_slash(self):
        mock_hosted = MagicMock()
        gate = _load_gate(_make_mock_st(), mock_hosted_cls=mock_hosted)
        cfg = CognitoUIConfig(
            pool_id="us-east-1_abc", client_id="cid", client_secret="sec",
            domain="myapp.auth.us-east-1.amazoncognito.com",
            redirect_uri="http://localhost:8501",
        )
        gate._make_authenticator(cfg)
        assert mock_hosted.call_args.kwargs["redirect_uri"].endswith("/")


# ---------------------------------------------------------------------------
# ensure_api_bearer_token
# ---------------------------------------------------------------------------


class TestEnsureApiBearerToken:
    def teardown_method(self):
        _restore_modules()

    def test_returns_none_when_cognito_not_configured(self):
        gate = _load_gate(_make_mock_st())
        assert gate.ensure_api_bearer_token(_settings_no_cognito()) is None

    def test_clears_cognito_flag_when_not_configured(self):
        mock_st = _make_mock_st({"_streamlit_cognito_auth": True})
        gate = _load_gate(mock_st)
        gate.ensure_api_bearer_token(_settings_no_cognito())
        assert "_streamlit_cognito_auth" not in mock_st.session_state

    def test_returns_access_token_when_already_logged_in(self):
        mock_creds = MagicMock()
        mock_creds.access_token = "tok_abc"
        mock_auth = MagicMock()
        mock_auth.is_logged_in.return_value = True
        mock_auth.get_credentials.return_value = mock_creds
        gate = _load_gate(_make_mock_st(), mock_auth_cls=MagicMock(return_value=mock_auth))
        assert gate.ensure_api_bearer_token(_make_settings()) == "tok_abc"

    def test_sets_cognito_session_flag(self):
        mock_st = _make_mock_st()
        mock_creds = MagicMock()
        mock_creds.access_token = "tok_xyz"
        mock_auth = MagicMock()
        mock_auth.is_logged_in.return_value = True
        mock_auth.get_credentials.return_value = mock_creds
        gate = _load_gate(mock_st, mock_auth_cls=MagicMock(return_value=mock_auth))
        gate.ensure_api_bearer_token(_make_settings())
        assert mock_st.session_state.get("_streamlit_cognito_auth") is True

    def test_stops_when_login_returns_false(self):
        mock_st = _make_mock_st()
        mock_st.stop.side_effect = SystemExit(0)
        mock_auth = MagicMock()
        mock_auth.is_logged_in.return_value = False
        mock_auth.login.return_value = False
        gate = _load_gate(mock_st, mock_auth_cls=MagicMock(return_value=mock_auth))
        with pytest.raises(SystemExit):
            gate.ensure_api_bearer_token(_make_settings())
        mock_st.stop.assert_called_once()

    def test_reruns_when_logged_in_but_no_credentials(self):
        mock_st = _make_mock_st()
        mock_st.rerun.side_effect = SystemExit(0)
        mock_auth = MagicMock()
        mock_auth.is_logged_in.return_value = True
        mock_auth.get_credentials.return_value = None
        gate = _load_gate(mock_st, mock_auth_cls=MagicMock(return_value=mock_auth))
        with pytest.raises(SystemExit):
            gate.ensure_api_bearer_token(_make_settings())
        mock_auth.logout.assert_called_once()
        mock_st.rerun.assert_called_once()

    def test_reruns_when_logged_in_but_token_empty(self):
        mock_st = _make_mock_st()
        mock_st.rerun.side_effect = SystemExit(0)
        mock_creds = MagicMock()
        mock_creds.access_token = ""
        mock_auth = MagicMock()
        mock_auth.is_logged_in.return_value = True
        mock_auth.get_credentials.return_value = mock_creds
        gate = _load_gate(mock_st, mock_auth_cls=MagicMock(return_value=mock_auth))
        with pytest.raises(SystemExit):
            gate.ensure_api_bearer_token(_make_settings())
        mock_auth.logout.assert_called_once()

    def test_stops_after_successful_login_but_no_credentials(self):
        mock_st = _make_mock_st()
        mock_st.stop.side_effect = SystemExit(0)
        mock_auth = MagicMock()
        mock_auth.is_logged_in.return_value = False
        mock_auth.login.return_value = True
        mock_auth.get_credentials.return_value = None
        gate = _load_gate(mock_st, mock_auth_cls=MagicMock(return_value=mock_auth))
        with pytest.raises(SystemExit):
            gate.ensure_api_bearer_token(_make_settings())
        mock_st.stop.assert_called_once()


# ---------------------------------------------------------------------------
# render_cognito_logout
# ---------------------------------------------------------------------------


class TestRenderCognitoLogout:
    def teardown_method(self):
        _restore_modules()

    def test_does_nothing_when_cognito_not_configured(self):
        mock_st = _make_mock_st()
        gate = _load_gate(mock_st)
        gate.render_cognito_logout(_settings_no_cognito())
        mock_st.button.assert_not_called()

    def test_does_nothing_when_cognito_flag_not_set(self):
        mock_st = _make_mock_st()
        gate = _load_gate(mock_st)
        gate.render_cognito_logout(_make_settings())
        mock_st.button.assert_not_called()

    def test_renders_button_when_cognito_active(self):
        mock_st = _make_mock_st({"_streamlit_cognito_auth": True})
        mock_st.button.return_value = False
        gate = _load_gate(mock_st)
        gate.render_cognito_logout(_make_settings())
        mock_st.button.assert_called_once()

    def test_logout_clears_flag_and_reruns(self):
        mock_st = _make_mock_st({"_streamlit_cognito_auth": True})
        mock_st.button.return_value = True
        mock_st.rerun.side_effect = SystemExit(0)
        mock_auth = MagicMock()
        gate = _load_gate(mock_st, mock_auth_cls=MagicMock(return_value=mock_auth))
        with pytest.raises(SystemExit):
            gate.render_cognito_logout(_make_settings())
        mock_auth.logout.assert_called_once()
        assert "_streamlit_cognito_auth" not in mock_st.session_state
        mock_st.rerun.assert_called_once()
