"""Everything a franchise page shows.

PLANNING.md: franchises are proper entities; media belong to franchises; franchises
have directed relationships (Persona is a spin-off of Shin Megami Tensei).

The franchises above this one are its lineage, a breadcrumb with no label (Aey: a
franchise does not get a work term like "Main work"). Every other relationship is a
tag naming the other side from this page, as on work pages ([SPIN-OFF] Persona on the
Shin Megami Tensei page). Franchises are not rateable. Only published entities appear.
"""

from __future__ import annotations

from typing import Any

import psycopg

from app.data.common import (
    all_titles, display_titles, entity_text, franchise_lineage, native_titles, oldest_first, pictures, targets, title_block,
)
from app.labels import pick_label


def _related(conn: psycopg.Connection, franchise_id: int, lineage_parent: int | None, lang: str) -> list[dict[str, Any]]:
    """Relationships to other franchises, labelled from this page, except the parent already
    shown in the lineage."""
    rows = conn.execute(
        """
        SELECT x.other_id, x.labels, x.type_order, x.note, core.address(x.other_id) AS address
          FROM (
            -- this franchise is the source: the other side is named by the target label
            SELECT r.target_id AS other_id, rt.target_labels AS labels, rt.sort_order AS type_order, r.note,
                   NOT rt.two_sided AS upward
              FROM core.franchise_relation r JOIN core.relation_type rt ON rt.code = r.relation_type
             WHERE r.source_id = %(id)s
            UNION ALL
            SELECT r.source_id, rt.source_labels, rt.sort_order, r.note, false
              FROM core.franchise_relation r JOIN core.relation_type rt ON rt.code = r.relation_type
             WHERE r.target_id = %(id)s
          ) x
          JOIN core.entity o ON o.id = x.other_id AND o.published_at IS NOT NULL
         WHERE NOT (x.upward AND x.other_id IS NOT DISTINCT FROM %(parent)s)
         ORDER BY x.type_order, x.other_id
        """,
        {"id": franchise_id, "parent": lineage_parent},
    ).fetchall()
    titles = display_titles(conn, (r["other_id"] for r in rows), lang)
    return [
        {"label": pick_label(r["labels"], lang), "title": titles.get(r["other_id"]), "address": r["address"], "note": r["note"]}
        for r in rows
    ]


def _works(conn: psycopg.Connection, franchise_id: int, lang: str) -> list[dict[str, Any]]:
    """Every published work in the franchise (home or member), oldest first.

    Only the franchise's own works: works of a spin-off franchise do not roll up into the
    franchise above it (Aey: Persona games do not show on the Shin Megami Tensei page).
    A work that belongs to both is added to both as a member."""
    rows = conn.execute(
        """
        SELECT DISTINCT fa.entity_id
          FROM core.entity_franchise_all fa
          JOIN core.entity e ON e.id = fa.entity_id AND e.published_at IS NOT NULL
         WHERE fa.franchise_id = %(id)s
        """,
        {"id": franchise_id},
    ).fetchall()
    works = targets(conn, (r["entity_id"] for r in rows), lang)
    return [
        {"id": w["id"], "title": w["title"], "address": w["address"], "kind": w["kind"], "year": w["year"],
         "date": w["date"], "picture": w["picture"], "roles": [], "note": None}
        for w in sorted(works.values(), key=oldest_first)
    ]


def _characters(conn: psycopg.Connection, work_ids: list[int], lang: str) -> list[dict[str, Any]]:
    """Characters appearing in (or played in) the franchise's works and anything under them
    (episodes, DLC ...), in the order they first appeared, then by name."""
    if not work_ids:
        return []
    rows = conn.execute(
        """
        WITH RECURSIVE tree AS (
          SELECT e.id FROM core.entity e WHERE e.id = ANY(%(works)s)
          UNION
          SELECT c.id FROM core.entity c JOIN tree t ON c.parent_id = t.id WHERE c.published_at IS NOT NULL
        )
        SELECT DISTINCT x.character_id, x.target_id, core.address(x.character_id) AS address
          FROM (
            SELECT a.character_id, a.target_id FROM core.appearance a WHERE a.target_id IN (SELECT id FROM tree)
            UNION
            SELECT p.character_id, p.target_id FROM core.performance p WHERE p.target_id IN (SELECT id FROM tree)
          ) x
          JOIN core.entity c ON c.id = x.character_id AND c.published_at IS NOT NULL
        """,
        {"works": work_ids},
    ).fetchall()
    places = targets(conn, (r["target_id"] for r in rows), lang)
    first: dict[int, tuple] = {}
    addresses: dict[int, str] = {}
    for r in rows:
        key = oldest_first(places[r["target_id"]])
        first[r["character_id"]] = min(first.get(r["character_id"], key), key)
        addresses[r["character_id"]] = r["address"]
    ids = list(first)
    names = display_titles(conn, ids, lang)
    natives = native_titles(conn, ids, lang)
    portraits = pictures(conn, ids, ["portrait"])
    ordered = sorted(ids, key=lambda i: (first[i][:2], (names.get(i) or "").casefold()))
    return [
        {
            "title": names.get(i),
            "native_title": natives.get(i, {}).get("text"),
            "native_lang": natives.get(i, {}).get("lang"),
            "address": addresses[i],
            "picture": portraits.get(i),
        }
        for i in ordered
    ]


def load_franchise(conn: psycopg.Connection, entity_id: int, lang: str = "en") -> dict[str, Any] | None:
    """The whole page for a published franchise, or None if there is no such page."""
    head = conn.execute(
        """
        SELECT e.id, core.address(e.id) AS address, k.labels AS kind_labels
          FROM core.entity e
          JOIN core.entity_kind k ON k.name = e.kind
         WHERE e.id = %(id)s AND e.kind = 'franchise' AND e.published_at IS NOT NULL
        """,
        {"id": entity_id},
    ).fetchone()
    if head is None:
        return None
    lineage = franchise_lineage(conn, entity_id)
    lineage_titles = display_titles(conn, (p["id"] for p in lineage), lang)
    works = _works(conn, entity_id, lang)
    return {
        "id": head["id"],
        "address": head["address"],
        "kind": pick_label(head["kind_labels"], lang),
        **title_block(conn, entity_id, lang),
        "titles": all_titles(conn, entity_id, lang),
        "description": entity_text(conn, entity_id, "description", lang),
        "picture": pictures(conn, [entity_id], ["logo"]).get(entity_id),
        # the franchises above this one, outermost first: Shin Megami Tensei › (Persona)
        "parents": [{"title": lineage_titles.get(p["id"]), "address": p["address"]} for p in lineage],
        "related": _related(conn, entity_id, lineage[-1]["id"] if lineage else None, lang),
        "works": works,
        "characters": _characters(conn, [w["id"] for w in works], lang),
    }
