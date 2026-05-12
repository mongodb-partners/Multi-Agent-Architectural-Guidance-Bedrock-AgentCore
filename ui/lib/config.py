"""Environment-driven settings for the Streamlit UI."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class CognitoUIConfig:
    """When pool + client id are set, the UI can authenticate via streamlit-cognito-auth."""

    pool_id: str
    client_id: str
    client_secret: str | None
    domain: str | None
    redirect_uri: str | None


@dataclass(frozen=True)
class UISettings:
    api_base: str
    cognito: CognitoUIConfig | None


def _read_env_or_streamlit_secret(env_var: str, *streamlit_keys: str) -> str:
    v = os.environ.get(env_var, "").strip()
    if v:
        return v
    try:
        import streamlit as st

        sec = st.secrets
        for k in streamlit_keys:
            if k in sec:
                raw = sec[k]
                if isinstance(raw, str) and raw.strip():
                    return raw.strip()
    except (RuntimeError, FileNotFoundError, KeyError, TypeError, ImportError):
        pass
    return ""


def _load_cognito_optional() -> CognitoUIConfig | None:
    pool = _read_env_or_streamlit_secret(
        "STREAMLIT_COGNITO_POOL_ID",
        "STREAMLIT_COGNITO_POOL_ID",
        "COGNITO_POOL_ID",
    )
    cid = _read_env_or_streamlit_secret(
        "STREAMLIT_COGNITO_CLIENT_ID",
        "STREAMLIT_COGNITO_CLIENT_ID",
        "COGNITO_CLIENT_ID",
    )
    if not pool or not cid:
        return None

    secret = (
        _read_env_or_streamlit_secret(
            "STREAMLIT_COGNITO_CLIENT_SECRET",
            "STREAMLIT_COGNITO_CLIENT_SECRET",
            "COGNITO_CLIENT_SECRET",
        )
        or None
    )
    domain = (
        _read_env_or_streamlit_secret(
            "STREAMLIT_COGNITO_DOMAIN",
            "STREAMLIT_COGNITO_DOMAIN",
            "COGNITO_DOMAIN",
        )
        or None
    )
    redirect = (
        _read_env_or_streamlit_secret(
            "STREAMLIT_COGNITO_REDIRECT_URI",
            "STREAMLIT_COGNITO_REDIRECT_URI",
            "COGNITO_REDIRECT_URI",
        )
        or None
    )

    if domain and not redirect:
        domain = None

    return CognitoUIConfig(
        pool_id=pool,
        client_id=cid,
        client_secret=secret,
        domain=domain,
        redirect_uri=redirect,
    )


def load_settings() -> UISettings:
    base = os.environ.get("STREAMLIT_API_URL", "http://127.0.0.1:3000").rstrip("/")
    cognito = _load_cognito_optional()
    return UISettings(api_base=base, cognito=cognito)
