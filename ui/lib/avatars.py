"""Chat-message avatars that match the MongoDB Atlas theme.

Emoji strings are passed directly to Streamlit's ``st.chat_message(avatar=...)``
parameter — no image files or network calls needed.
"""

from __future__ import annotations

USER_AVATAR: str = "👤"   # neutral person silhouette
BOT_AVATAR: str = "🍃"    # MongoDB leaf — assistant identity
