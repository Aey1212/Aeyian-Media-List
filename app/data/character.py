"""Everything a character page shows.

Characters are global (one character can appear in several franchises), so the page
lists every work, or episode, DLC ..., they appear in with their roles there, and
everyone who played them, with big pictures. Only published entities appear.
"""

from __future__ import annotations

from typing import Any

import psycopg

from app.data.common import aey_data, all_titles, display_titles, entity_text, native_titles, pictures, targets, title_block
from app.labels import pick_label

def _appearances_and_cast(conn: psycopg.Connection, character_id: int, lang: str) -> tuple[list, list]:
    """(appearances, cast) for this character.

    appearances: every target with this character's roles, oldest first. Appearances and
    performances are separate systems (PLANNING.md): a target with a performance but no
    appearance row still shows.

    cast: one card per person (and language) who played the character, with the works they
    played them in. Order: the oldest work's cast first, its original language first.
    """
    params = {"id": character_id}
    appearances = conn.execute(
        """
        SELECT a.id, a.target_id, a.note, a.sort_order
          FROM core.appearance a
          JOIN core.entity t ON t.id = a.target_id AND t.published_at IS NOT NULL
         WHERE a.character_id = %(id)s
        """,
        params,
    ).fetchall()
    roles = conn.execute(
        """
        SELECT l.appearance_id, r.labels
          FROM core.appearance_role_link l
          JOIN core.appearance_role r ON r.code = l.role
          JOIN core.appearance a ON a.id = l.appearance_id
         WHERE a.character_id = %(id)s
         ORDER BY r.sort_order, r.code
        """,
        params,
    ).fetchall()
    cast = conn.execute(
        """
        SELECT p.target_id, p.person_id, p.lang, p.note, p.performance_type, t.labels AS type_labels,
               core.address(p.person_id) AS person_address
          FROM core.performance p
          JOIN core.performance_type t ON t.code = p.performance_type
          JOIN core.entity tg ON tg.id = p.target_id AND tg.published_at IS NOT NULL
          JOIN core.entity pe ON pe.id = p.person_id AND pe.published_at IS NOT NULL
         WHERE p.character_id = %(id)s
         ORDER BY t.sort_order,
                  (p.lang IN (SELECT ol.lang FROM core.entity_original_language ol WHERE ol.entity_id = p.target_id)) DESC,
                  p.lang NULLS LAST, p.sort_order, p.person_id
        """,
        params,
    ).fetchall()

    target_ids = list(dict.fromkeys([*(a["target_id"] for a in appearances), *(c["target_id"] for c in cast)]))
    if not target_ids:
        return [], []
    works = targets(conn, target_ids, lang)

    roles_by_appearance: dict[int, list[str]] = {}
    for r in roles:
        roles_by_appearance.setdefault(r["appearance_id"], []).append(pick_label(r["labels"], lang))
    appearance_by_target = {a["target_id"]: a for a in appearances}
    cast_by_target: dict[int, list[dict[str, Any]]] = {}
    for c in cast:
        cast_by_target.setdefault(c["target_id"], []).append(c)

    person_ids = list(dict.fromkeys(c["person_id"] for c in cast))
    names = display_titles(conn, person_ids, lang)
    natives = native_titles(conn, person_ids, lang)
    portraits = pictures(conn, person_ids, ["portrait"])
    last = 32767

    def order(t: dict[str, Any]) -> tuple:
        appearance = appearance_by_target.get(t["id"])
        return (t["date"] is None, t["date"] or "", appearance["sort_order"] if appearance else last, t["id"])

    appearances_out = []
    cards: dict[tuple[int, str | None], dict[str, Any]] = {}
    for t in sorted(works.values(), key=order):
        appearance = appearance_by_target.get(t["id"])
        work = {"title": t["title"], "address": t["address"], "kind": t["kind"], "year": t["year"]}
        appearances_out.append({
            **work,
            "picture": t["picture"],
            "roles": roles_by_appearance.get(appearance["id"], []) if appearance else [],
            "note": appearance["note"] if appearance else None,
        })
        for c in cast_by_target.get(t["id"], []):
            card = cards.setdefault((c["person_id"], c["lang"]), {
                "title": names.get(c["person_id"]),
                "native_title": natives.get(c["person_id"], {}).get("text"),
                "native_lang": natives.get(c["person_id"], {}).get("lang"),
                "address": c["person_address"],
                "picture": portraits.get(c["person_id"]),
                "lang": c["lang"],
                "types": [],
                "works": [],
            })
            performance_type = pick_label(c["type_labels"], lang)
            if performance_type not in card["types"]:
                card["types"].append(performance_type)
            card["works"].append({**work, "type": performance_type, "type_code": c["performance_type"], "note": c["note"]})
    return appearances_out, list(cards.values())


def load_character(conn: psycopg.Connection, entity_id: int, lang: str = "en") -> dict[str, Any] | None:
    """The whole page for a published character, or None if there is no such page."""
    head = conn.execute(
        """
        SELECT e.id, core.address(e.id) AS address, k.labels AS kind_labels
          FROM core.entity e
          JOIN core.entity_kind k ON k.name = e.kind
         WHERE e.id = %(id)s AND e.kind = 'character' AND e.published_at IS NOT NULL
        """,
        {"id": entity_id},
    ).fetchone()
    if head is None:
        return None
    appearances, cast = _appearances_and_cast(conn, entity_id, lang)
    return {
        "id": head["id"],
        "address": head["address"],
        "kind": pick_label(head["kind_labels"], lang),
        **title_block(conn, entity_id, lang),
        "titles": all_titles(conn, entity_id, lang),
        "description": entity_text(conn, entity_id, "description", lang),
        "picture": pictures(conn, [entity_id], ["portrait"]).get(entity_id),
        "cast": cast,
        "appearances": appearances,
        "aey": aey_data(conn, entity_id, lang),
    }
