"""Optional AWS Cognito sign-in for Streamlit (G4). Uses streamlit-cognito-auth when configured."""

from __future__ import annotations

import os

import streamlit as st
from streamlit_cognito_auth import CognitoAuthenticator, CognitoHostedUIAuthenticator

from lib.config import CognitoUIConfig, UISettings


def _make_authenticator(cfg: CognitoUIConfig):
    common = dict(
        pool_id=cfg.pool_id,
        app_client_id=cfg.client_id,
        app_client_secret=cfg.client_secret,
        use_cookies=False,
    )
    if cfg.domain and cfg.redirect_uri:
        if not cfg.client_secret:
            st.error(
                "Cognito **hosted UI** requires **STREAMLIT_COGNITO_CLIENT_SECRET** "
                "(token endpoint uses HTTP Basic auth). "
                "Either add a client secret, or remove DOMAIN / REDIRECT_URI to use username/password login."
            )
            st.stop()
        dom = cfg.domain.strip()
        if not dom.startswith("http://") and not dom.startswith("https://"):
            dom = "https://" + dom
        if not dom.endswith("/"):
            dom += "/"
        redir = cfg.redirect_uri.rstrip("/") + "/"
        return CognitoHostedUIAuthenticator(
            cognito_domain=dom,
            redirect_uri=redir,
            **common,
        )
    return CognitoAuthenticator(**common)


def ensure_api_bearer_token(settings: UISettings) -> str | None:
    """
    Return the Bearer token for API calls from Cognito, or ``None`` if Cognito is not configured.

    When ``STREAMLIT_COGNITO_POOL_ID`` + client id are set, shows login UI and calls ``st.stop()``
    until the user is authenticated.
    """
    # If API auth is disabled, skip UI login gate even when Cognito vars exist.
    require_auth = os.environ.get("REQUIRE_AUTH", "false").strip().lower() == "true"
    if not require_auth:
        st.session_state.pop("_streamlit_cognito_auth", None)
        return None

    cfg = settings.cognito
    if not cfg:
        st.session_state.pop("_streamlit_cognito_auth", None)
        return None

    auth = _make_authenticator(cfg)
    st.session_state["_streamlit_cognito_auth"] = True

    if auth.is_logged_in():
        creds = auth.get_credentials()
        # Prefer ID token for API bearer auth because it reliably carries email/user profile claims.
        # Fall back to access token when id_token is unavailable.
        if creds and getattr(creds, "id_token", None):
            return creds.id_token
        if creds and creds.access_token:
            return creds.access_token
        auth.logout()
        st.rerun()

    logged_in = auth.login()
    if not logged_in:
        st.stop()

    creds = auth.get_credentials()
    if not creds:
        st.stop()
    if getattr(creds, "id_token", None):
        return creds.id_token
    if not creds.access_token:
        st.stop()
    return creds.access_token


def render_cognito_logout(settings: UISettings) -> None:
    """Sidebar logout when Cognito is configured (primary UI auth path)."""
    if not settings.cognito:
        return
    if not st.session_state.get("_streamlit_cognito_auth"):
        return
    cfg = settings.cognito
    if st.button("Sign out (Cognito)", key="cognito_logout"):
        auth = _make_authenticator(cfg)
        auth.logout()
        st.session_state.pop("_streamlit_cognito_auth", None)
        st.rerun()
