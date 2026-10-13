"""Shared pieces of the edit operations: the change, its parameters, the entity it is about."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from decimal import Decimal
from typing import Any

import psycopg

DOORS = ("web", "chat", "terminal")


class EditError(Exception):
    """A change that cannot be made, with the reason in plain words."""


@dataclass
class Change:
    operation: str
    address: str
    label: str
    before: dict[str, Any] | None
    after: dict[str, Any] | None
    kept: bool = True

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class Param:
    # points (-50..+50), text, date, number, count, choice, bool, id, address, file
    kind: str
    description: str
    required: bool = False
    choices: Callable[[psycopg.Connection], list[str]] | None = None


@dataclass
class Operation:
    # run(conn, entity, **params) -> (before, after); an operation that creates an entity
    # takes no entity and returns (before, after, the new entity)
    run: Callable[..., tuple]
    description: str
    params: dict[str, Param] = field(default_factory=dict)
    creates: bool = False
    # the entity is gone afterwards: the log keeps its label, not a link to it
    deletes: bool = False


def codes(sql: str) -> Callable[[psycopg.Connection], list[str]]:
    """Choices read from an option table."""
    return lambda conn: [r["code"] for r in conn.execute(sql).fetchall()]


# --- the entity an edit is about ---------------------------------------------

def target(conn: psycopg.Connection, address: str) -> dict[str, Any]:
    """{id, kind, kind_label, address, title, rateable, progress} for an address, or EditError."""
    found = conn.execute("SELECT entity_id, canonical FROM core.resolve(%s)", (address,)).fetchone()
    if found is None:
        raise EditError(f"Nothing lives at {address}.")
    row = conn.execute(
        """
        SELECT e.id, e.kind, k.labels -> 'en' ->> 'text' AS kind_label, k.rateable,
               EXISTS (SELECT 1 FROM core.attach_kind a WHERE a.system = 'progress' AND a.kind = e.kind) AS progress,
               (SELECT t.text FROM core.title t WHERE t.entity_id = e.id
                 ORDER BY (t.lang = 'en' AND t.preferred) DESC, (t.lang = 'en') DESC, t.native DESC, t.id LIMIT 1) AS title
          FROM core.entity e JOIN core.entity_kind k ON k.name = e.kind
         WHERE e.id = %s
        """,
        (found["entity_id"],),
    ).fetchone()
    return {**row, "address": found["canonical"]}


def a(label: str, capital: bool = False) -> str:
    """"a Person", "an Anime"; "A Person" at the start of a sentence."""
    article = "an" if label[:1].lower() in "aeiou" else "a"
    return f"{article.capitalize() if capital else article} {label}"


def need_rateable(entity: dict[str, Any]) -> None:
    if not entity["rateable"]:
        raise EditError(f"{a(entity['kind_label'], capital=True)} can't be rated.")


def need_progress(entity: dict[str, Any]) -> None:
    if not entity["progress"]:
        raise EditError(f"Progress isn't kept for {a(entity['kind_label'])}.")


def plain(row: dict[str, Any] | None) -> dict[str, Any] | None:
    """A row as JSON-safe values (numbers stay numbers)."""
    if row is None:
        return None
    out = {}
    for key, value in row.items():
        if isinstance(value, Decimal):
            value = int(value) if value == value.to_integral_value() else float(value)
        out[key] = value
    return out
