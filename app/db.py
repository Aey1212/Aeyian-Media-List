"""Database connections."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager

import psycopg
from psycopg.rows import dict_row


@contextmanager
def connect(database_url: str) -> Iterator[psycopg.Connection]:
    """A read-only connection whose rows come back as dicts."""
    with psycopg.connect(database_url, row_factory=dict_row) as conn:
        conn.read_only = True
        yield conn
