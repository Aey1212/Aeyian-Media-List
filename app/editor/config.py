"""Settings for the editor, read from the environment.

The editor is a separate app from the public site. On the server it is reached only
through admin.aeyempire.com/aml/, behind Aey's admin login: nginx checks the login and
passes the signed-in user in a header. The editor refuses every request without that
header, so a wrong nginx route fails closed. Locally, AML_EDITOR_DEV=1 lifts that.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

from app.config import DEV_DATABASE_URL, DEV_MEDIA_DIR


@dataclass(frozen=True)
class EditorSettings:
    # Path the editor lives under on admin.aeyempire.com (Aey: /aml; /chatline is kept for the chat).
    root_path: str = "/aml"
    # A connection that may write (the public site's is read-only).
    database_url: str = DEV_DATABASE_URL
    # Where the public pages are, for "view on the site" links.
    public_url: str = "https://aeyempire.com/AML"
    # Header nginx sets to the signed-in user after the admin login check.
    auth_header: str = "X-Auth-User"
    # Local development only: no login header needed.
    dev: bool = False
    media_dir: str = DEV_MEDIA_DIR


def load_editor_settings() -> EditorSettings:
    root_path = os.environ.get("AML_EDITOR_ROOT", "/aml").rstrip("/")
    if not root_path.startswith("/") or root_path == "":
        raise ValueError(f"AML_EDITOR_ROOT must start with '/' and not be '/', got {root_path!r}")
    return EditorSettings(
        root_path=root_path,
        database_url=os.environ.get("AML_EDIT_DATABASE_URL", os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)),
        public_url=os.environ.get("AML_PUBLIC_URL", "https://aeyempire.com/AML").rstrip("/"),
        auth_header=os.environ.get("AML_EDITOR_AUTH_HEADER", "X-Auth-User"),
        dev=os.environ.get("AML_EDITOR_DEV", "").lower() in ("1", "true", "yes"),
        media_dir=os.environ.get("AML_MEDIA_DIR", DEV_MEDIA_DIR),
    )
