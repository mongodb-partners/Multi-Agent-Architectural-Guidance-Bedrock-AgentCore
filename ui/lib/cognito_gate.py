"""Optional AWS Cognito sign-in for Streamlit (G4). Uses streamlit-cognito-auth when configured."""

from __future__ import annotations

import streamlit as st
import streamlit.components.v1 as components
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
    Return the Bearer token for API calls from Cognito, or ``None`` if Cognito is not configured
    on the UI side.

    The API enforces JWKS auth unconditionally (api/src/lib/jwt-verify.ts
    ``assertJwksAuthConfigured``), so in any real deployment the UI must point at the same
    Cognito pool. When ``STREAMLIT_COGNITO_POOL_ID`` + client id are set, shows the login UI
    and calls ``st.stop()`` until the user is authenticated.
    """
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
    if st.button("Sign out (Cognito)", key="cognito_logout", use_container_width=True):
        auth = _make_authenticator(cfg)
        auth.logout()
        st.session_state.pop("_streamlit_cognito_auth", None)
        st.rerun()

    # JavaScript-based sticky footer — finds the Sign Out button by text,
    # measures the sidebar's actual pixel width at runtime, then pins the
    # container to the bottom-left of the viewport so it never scrolls away.
    components.html(
        """
        <script>
        (function () {
            function applyFixedFooter() {
                var doc = window.parent.document;
                var sidebar = doc.querySelector('section[data-testid="stSidebar"]');
                if (!sidebar) { setTimeout(applyFixedFooter, 300); return; }

                // Measure real sidebar width + left offset at runtime
                var rect = sidebar.getBoundingClientRect();
                var sidebarW = rect.width;
                var sidebarL = rect.left;

                // Find the Sign Out button by label text
                var buttons = sidebar.querySelectorAll('button');
                var target = null;
                for (var i = 0; i < buttons.length; i++) {
                    if (buttons[i].innerText.toLowerCase().indexOf('sign out') !== -1) {
                        target = buttons[i];
                        break;
                    }
                }
                if (!target) { setTimeout(applyFixedFooter, 300); return; }

                // Walk up to the element-container wrapper
                var container = target.closest('.element-container');
                if (!container) { setTimeout(applyFixedFooter, 300); return; }

                // Add bottom padding to the sidebar scroll area so no content
                // hides behind the footer
                var scrollArea = sidebar.querySelector('div');
                if (scrollArea) scrollArea.style.paddingBottom = '4.5rem';

                // Pin the container to the bottom of the sidebar
                Object.assign(container.style, {
                    position:        'fixed',
                    bottom:          '0',
                    left:            sidebarL + 'px',
                    width:           sidebarW + 'px',
                    zIndex:          '9999',
                    backgroundColor: 'rgb(14, 17, 23)',
                    borderTop:       '1px solid rgba(250, 250, 250, 0.15)',
                    padding:         '0.6rem 1rem 0.9rem',
                    boxSizing:       'border-box',
                    margin:          '0'
                });
                target.style.width = '100%';
            }

            // Initial call + retry until sidebar is ready
            applyFixedFooter();

            // Re-apply on Streamlit re-renders and window resize
            var observer = new MutationObserver(function () { applyFixedFooter(); });
            observer.observe(window.parent.document.body, { childList: true, subtree: false });
            window.parent.addEventListener('resize', applyFixedFooter);
        })();
        </script>
        """,
        height=0,
    )
