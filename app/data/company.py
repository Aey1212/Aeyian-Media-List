"""Everything a company page shows.

A company is linked to works by company credits (PLANNING.md: Company + Company Role +
Target + notes). Companies are not rateable, so the page has no score. Only published
entities appear.
"""

from __future__ import annotations

from typing import Any

import psycopg

from app.data.common import all_titles, credited_works, entity_text, pictures, title_block
from app.labels import pick_label


def load_company(conn: psycopg.Connection, entity_id: int, lang: str = "en") -> dict[str, Any] | None:
    """The whole page for a published company, or None if there is no such page."""
    head = conn.execute(
        """
        SELECT e.id, core.address(e.id) AS address, k.labels AS kind_labels
          FROM core.entity e
          JOIN core.entity_kind k ON k.name = e.kind
         WHERE e.id = %(id)s AND e.kind = 'company' AND e.published_at IS NOT NULL
        """,
        {"id": entity_id},
    ).fetchone()
    if head is None:
        return None
    return {
        "id": head["id"],
        "address": head["address"],
        "kind": pick_label(head["kind_labels"], lang),
        **title_block(conn, entity_id, lang),
        "titles": all_titles(conn, entity_id, lang),
        "description": entity_text(conn, entity_id, "description", lang),
        "picture": pictures(conn, [entity_id], ["logo"]).get(entity_id),
        "works": credited_works(conn, entity_id, "company", lang),
    }
