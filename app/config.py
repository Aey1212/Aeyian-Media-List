"""Settings read from the environment."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


DEV_DATABASE_URL = "postgresql://aml@127.0.0.1:55432/aml"   # db/dev.sh
DEV_MEDIA_DIR = str(Path(__file__).resolve().parent.parent / "media")   # <sha256>.<format> files, not in git
FLAGS_DIR = str(Path(__file__).resolve().parent / "static" / "flags")   # square language flags, in git


@dataclass(frozen=True)
class Settings:
    # Path the site lives under on aeyempire.com and m.aeyempire.com.
    root_path: str
    database_url: str = DEV_DATABASE_URL
    # Language pages prefer for titles and labels; others are used when it is missing.
    lang: str = "en"
    # Show a notice that scores, playtime and outside ratings are placeholders (dev seed).
    sample_notice: bool = False
    # Host names that get the mobile pages (the Empire keeps separate mobile pages).
    mobile_hosts: tuple[str, ...] = ("m.aeyempire.com",)
    # Where desktop pages send phones; the path, query and fragment are appended.
    mobile_origin: str = "https://m.aeyempire.com"
    # Folder holding image files named <sha256>.<format>, served at <root_path>/media/.
    media_dir: str = DEV_MEDIA_DIR
    # Square language flags named by language code (JA.png, ja.svg ...), served at <root_path>/flags/.
    flags_dir: str = FLAGS_DIR


def load_settings() -> Settings:
    root_path = os.environ.get("AML_ROOT_PATH", "/AML").rstrip("/")
    if not root_path.startswith("/") or root_path == "":
        raise ValueError(f"AML_ROOT_PATH must start with '/' and not be '/', got {root_path!r}")
    return Settings(
        root_path=root_path,
        database_url=os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL),
        lang=os.environ.get("AML_LANG", "en"),
        sample_notice=os.environ.get("AML_SAMPLE_NOTICE", "").lower() in ("1", "true", "yes"),
        mobile_hosts=tuple(
            h.strip().lower() for h in os.environ.get("AML_MOBILE_HOSTS", "m.aeyempire.com").split(",") if h.strip()
        ),
        mobile_origin=os.environ.get("AML_MOBILE_ORIGIN", "https://m.aeyempire.com").rstrip("/"),
        media_dir=os.environ.get("AML_MEDIA_DIR", DEV_MEDIA_DIR),
        flags_dir=os.environ.get("AML_FLAGS_DIR", FLAGS_DIR),
    )
