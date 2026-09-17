"""Everything a person page shows.

A person is linked to works in two ways (PLANNING.md): performances (Person +
Character + Target + type + language) and staff credits (Person + Staff Role +
Target). People are not rateable, so the page has no score. Only published
entities appear.
"""

from __future__ import annotations

from typing import Any

import psycopg

from app.data.common import all_titles, display_titles, entity_text, native_titles, oldest_first, pictures, targets, title_block
from app.labels import pick_label


def _characters(conn: psycopg.Connection, person_id: int, lang: str) -> list[dict[str, Any]]:
    """One card per character this person played, with every work they played them in, oldest
    first. Characters in the order the person first played them."""
    rows = conn.execute(
        """
        SELECT p.character_id, p.target_id, p.lang, p.note, p.performance_type, t.labels AS type_labels,
               core.address(p.character_id) AS character_address
          FROM core.performance p
          JOIN core.performance_type t ON t.code = p.performance_type
          JOIN core.entity c  ON c.id = p.character_id AND c.published_at IS NOT NULL
          JOIN core.entity tg ON tg.id = p.target_id AND tg.published_at IS NOT NULL
         WHERE p.person_id = %(id)s
         ORDER BY t.sort_order, p.sort_order, p.id
        """,
        {"id": person_id},
    ).fetchall()
    works = targets(conn, (r["target_id"] for r in rows), lang)
    character_ids = list(dict.fromkeys(r["character_id"] for r in rows))
    names = display_titles(conn, character_ids, lang)
    natives = native_titles(conn, character_ids, lang)
    portraits = pictures(conn, character_ids, ["portrait"])

    cards: dict[int, dict[str, Any]] = {}
    for r in sorted(rows, key=lambda r: oldest_first(works[r["target_id"]])):
        work = works[r["target_id"]]
        card = cards.setdefault(r["character_id"], {
            "title": names.get(r["character_id"]),
            "native_title": natives.get(r["character_id"], {}).get("text"),
            "native_lang": natives.get(r["character_id"], {}).get("lang"),
            "address": r["character_address"],
            "picture": portraits.get(r["character_id"]),
            "works": [],
        })
        card["works"].append({
            "title": work["title"],
            "address": work["address"],
            "kind": work["kind"],
            "year": work["year"],
            "type": pick_label(r["type_labels"], lang),
            "type_code": r["performance_type"],
            "lang": r["lang"],
            "note": r["note"],
        })
    return list(cards.values())


def _staff_credits(conn: psycopg.Connection, person_id: int, lang: str) -> list[dict[str, Any]]:
    """One entry per work with this person's roles on it (Composer, Director ...), oldest first."""
    rows = conn.execute(
        """
        SELECT sc.target_id, r.labels AS role_labels, sc.note
          FROM core.staff_credit sc
          JOIN core.staff_role r ON r.code = sc.role
          JOIN core.entity tg ON tg.id = sc.target_id AND tg.published_at IS NOT NULL
         WHERE sc.person_id = %(id)s
         ORDER BY r.sort_order, sc.sort_order, sc.id
        """,
        {"id": person_id},
    ).fetchall()
    works = targets(conn, (r["target_id"] for r in rows), lang)
    entries: dict[int, dict[str, Any]] = {}
    for r in rows:
        work = works[r["target_id"]]
        entry = entries.setdefault(r["target_id"], {
            "title": work["title"],
            "address": work["address"],
            "kind": work["kind"],
            "year": work["year"],
            "picture": work["picture"],
            "roles": [],
            "note": None,
        })
        role = pick_label(r["role_labels"], lang)
        if role not in entry["roles"]:
            entry["roles"].append(role)
        entry["note"] = entry["note"] or r["note"]
    return [entries[t["id"]] for t in sorted((works[i] for i in entries), key=oldest_first)]


def load_person(conn: psycopg.Connection, entity_id: int, lang: str = "en") -> dict[str, Any] | None:
    """The whole page for a published person, or None if there is no such page."""
    head = conn.execute(
        """
        SELECT e.id, core.address(e.id) AS address, k.labels AS kind_labels
          FROM core.entity e
          JOIN core.entity_kind k ON k.name = e.kind
         WHERE e.id = %(id)s AND e.kind = 'person' AND e.published_at IS NOT NULL
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
        "picture": pictures(conn, [entity_id], ["portrait"]).get(entity_id),
        "characters": _characters(conn, entity_id, lang),
        "staff_credits": _staff_credits(conn, entity_id, lang),
    }
