"""Public addresses (/04/0001/002) to entities."""

from __future__ import annotations

from typing import Any

import psycopg


def resolve(conn: psycopg.Connection, path: str) -> dict[str, Any] | None:
    """{entity_id, canonical, redirected} for a live or retired address; None if unknown."""
    return conn.execute(
        "SELECT entity_id, canonical, redirected FROM core.resolve(%(path)s)",
        {"path": path},
    ).fetchone()
