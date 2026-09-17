"""Pieces every entity page shares: names, pictures, and Aey's own data."""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

import psycopg

from app.labels import format_number, format_partial_date, format_signed, pick_label


def display_titles(conn: psycopg.Connection, ids: Iterable[int], lang: str) -> dict[int, str]:
    """One display title per entity: preferred in the language, then any in it, then native."""
    ids = list(dict.fromkeys(ids))
    if not ids:
        return {}
    rows = conn.execute(
        """
        SELECT DISTINCT ON (t.entity_id) t.entity_id, t.text
          FROM core.title t
         WHERE t.entity_id = ANY(%(ids)s)
         ORDER BY t.entity_id,
                  (t.lang = %(lang)s AND t.preferred) DESC,
                  (t.lang = %(lang)s) DESC,
                  (t.title_type = 'full') DESC,
                  t.native DESC,
                  t.sort_order, t.id
        """,
        {"ids": ids, "lang": lang},
    ).fetchall()
    return {r["entity_id"]: r["text"] for r in rows}


def native_titles(conn: psycopg.Connection, ids: Iterable[int], lang: str) -> dict[int, dict[str, str]]:
    """The native title of each entity whose native language is not the page language."""
    ids = list(dict.fromkeys(ids))
    if not ids:
        return {}
    rows = conn.execute(
        """
        SELECT DISTINCT ON (t.entity_id) t.entity_id, t.text, t.lang
          FROM core.title t
         WHERE t.entity_id = ANY(%(ids)s) AND t.native AND t.lang <> %(lang)s
         ORDER BY t.entity_id, (t.title_type = 'full') DESC, t.sort_order, t.id
        """,
        {"ids": ids, "lang": lang},
    ).fetchall()
    return {r["entity_id"]: {"text": r["text"], "lang": r["lang"]} for r in rows}


def pictures(conn: psycopg.Connection, ids: Iterable[int], image_types: list[str]) -> dict[int, str]:
    """Media path (/media/<sha256>.<format>) of each entity's picture.

    The first image type in the list wins; within a type, the primary image.
    Entities without such an image are left out (the page shows initials instead).
    """
    ids = list(dict.fromkeys(ids))
    if not ids:
        return {}
    rows = conn.execute(
        """
        SELECT DISTINCT ON (i.entity_id) i.entity_id, i.sha256, i.format
          FROM core.image i
         WHERE i.entity_id = ANY(%(ids)s) AND i.image_type = ANY(%(types)s)
         ORDER BY i.entity_id, array_position(%(types)s, i.image_type), i.is_primary DESC, i.sort_order, i.id
        """,
        {"ids": ids, "types": list(image_types)},
    ).fetchall()
    return {r["entity_id"]: f"/media/{r['sha256']}.{r['format']}" for r in rows}


def title_block(conn: psycopg.Connection, entity_id: int, lang: str) -> dict[str, str | None]:
    rows = conn.execute(
        """
        SELECT id, lang, title_type, text, native, preferred, latinizes_id
          FROM core.title WHERE entity_id = %(id)s ORDER BY sort_order, id
        """,
        {"id": entity_id},
    ).fetchall()
    full = [t for t in rows if t["title_type"] == "full"] or rows
    display = (
        next((t for t in full if t["lang"] == lang and t["preferred"]), None)
        or next((t for t in full if t["lang"] == lang), None)
        or next((t for t in full if t["native"]), None)
        or (full[0] if full else None)
    )
    native = next((t for t in full if t["native"]), None)
    latinized = next((t for t in rows if native is not None and t["latinizes_id"] == native["id"]), None)
    return {
        "title": display["text"] if display else None,
        "native_title": native["text"] if native and (display is None or native["id"] != display["id"]) else None,
        "native_lang": native["lang"] if native else None,
        "latinized_title": latinized["text"] if latinized else None,
    }


def all_titles(conn: psycopg.Connection, entity_id: int, lang: str) -> list[dict[str, Any]]:
    """Every title the entity is known by: native first, then the page language, then the rest;
    full titles before short and alternative ones.

    A latinized title is not its own entry: it rides on the title it spells out in Latin
    script (ja-Latn under the Japanese title; ar-Latn under an Arabic one works the same way).
    """
    rows = conn.execute(
        """
        SELECT t.id, t.lang, t.text, t.native, t.latinizes_id, t.title_type, tt.labels AS type_labels
          FROM core.title t
          JOIN core.title_type tt ON tt.code = t.title_type
         WHERE t.entity_id = %(id)s
         ORDER BY tt.sort_order, t.native DESC, (t.lang = %(lang)s) DESC, t.preferred DESC,
                  t.lang, t.sort_order, t.text
        """,
        {"id": entity_id, "lang": lang},
    ).fetchall()
    latinized: dict[int, dict[str, Any]] = {}
    for r in rows:
        if r["latinizes_id"] is not None:
            latinized.setdefault(r["latinizes_id"], r)
    return [
        {
            "lang": r["lang"],
            "text": r["text"],
            "native": r["native"],
            "latinized": latinized[r["id"]]["text"] if r["id"] in latinized else None,
            "latinized_lang": latinized[r["id"]]["lang"] if r["id"] in latinized else None,
            "type_code": r["title_type"],
            "type": pick_label(r["type_labels"], lang),
        }
        for r in rows
        if r["latinizes_id"] is None
    ]


def aey_data(conn: psycopg.Connection, entity_id: int, lang: str) -> dict[str, Any]:
    params = {"id": entity_id, "lang": lang}
    score = conn.execute(
        """
        SELECT general, aey.score_shown(general) AS shown, aey.half_stars(general) AS half_stars
          FROM aey.score WHERE entity_id = %(id)s
        """,
        params,
    ).fetchone()
    subratings = conn.execute(
        """
        SELECT c.labels, s.value, aey.score_shown(s.value) AS shown, aey.half_stars(s.value) AS half_stars
          FROM aey.subrating s JOIN aey.subrating_category c ON c.code = s.category
         WHERE s.entity_id = %(id)s
         ORDER BY c.sort_order, c.code
        """,
        params,
    ).fetchall()
    take = conn.execute(
        "SELECT lang, body FROM aey.take WHERE entity_id = %(id)s ORDER BY (lang = %(lang)s) DESC, lang LIMIT 1",
        params,
    ).fetchone()
    progress = conn.execute(
        """
        SELECT st.labels AS status_labels, p.progress_value, u.labels AS unit_labels,
               p.times_completed, p.time_spent_s, p.started_on, p.finished_on
          FROM aey.progress p
          LEFT JOIN aey.status st ON st.code = p.status
          LEFT JOIN media.cadence_item u ON u.code = p.progress_unit
         WHERE p.entity_id = %(id)s
        """,
        params,
    ).fetchone()
    return {
        "score": None if score is None else {
            "general": score["general"],
            "shown": format_signed(score["shown"]),
            "half_stars": score["half_stars"],
        },
        "subratings": [
            {
                "label": pick_label(s["labels"], lang),
                "value": s["value"],
                "shown": format_signed(s["shown"]),
                "half_stars": s["half_stars"],
            }
            for s in subratings
        ],
        "take": None if take is None else {"lang": take["lang"], "body": take["body"]},
        "progress": None if progress is None else {
            "status": pick_label(progress["status_labels"], lang),
            "value": format_number(progress["progress_value"]),
            "unit": pick_label(progress["unit_labels"], lang),
            "times_completed": progress["times_completed"],
            "hours": format_number(round(progress["time_spent_s"] / 3600, 1)) if progress["time_spent_s"] else None,
            "started_on": format_partial_date(progress["started_on"]),
            "finished_on": format_partial_date(progress["finished_on"]),
        },
    }


def entity_text(conn: psycopg.Connection, entity_id: int, text_type: str, lang: str) -> dict[str, str] | None:
    """One text of a type (synopsis, description): in the page language if there is one, else any."""
    row = conn.execute(
        """
        SELECT lang, body FROM core.entity_text
         WHERE entity_id = %(id)s AND text_type = %(type)s
         ORDER BY (lang = %(lang)s) DESC, lang
         LIMIT 1
        """,
        {"id": entity_id, "type": text_type, "lang": lang},
    ).fetchone()
    return None if row is None else {"lang": row["lang"], "body": row["body"]}


# The picture shown for a work or child entity in a list: the first of these types it has.
TARGET_PICTURES = ["cover", "box_art", "poster", "season_poster", "volume_cover", "thumbnail"]


def targets(conn: psycopg.Connection, ids: Iterable[int], lang: str) -> dict[int, dict[str, Any]]:
    """Works and child entities as list entries (appearances, performances, credits):
    title, address, kind, date (the work's start, or the child's own date), year and picture.
    Callers pass published ids only."""
    ids = list(dict.fromkeys(ids))
    if not ids:
        return {}
    rows = conn.execute(
        """
        SELECT e.id, core.address(e.id) AS address, k.labels AS kind_labels,
               COALESCE(w.start_date, s.started_on, ep.aired_on, v.released_on, d.released_on,
                        rel.released_on, st.released_on) AS date
          FROM core.entity e
          JOIN core.entity_kind k ON k.name = e.kind
          LEFT JOIN media.work w         ON w.entity_id = e.id
          LEFT JOIN child.season s       ON s.entity_id = e.id
          LEFT JOIN child.episode ep     ON ep.entity_id = e.id
          LEFT JOIN child.volume v       ON v.entity_id = e.id
          LEFT JOIN child.dlc d          ON d.entity_id = e.id
          LEFT JOIN child.release rel    ON rel.entity_id = e.id
          LEFT JOIN child.soundtrack st  ON st.entity_id = e.id
         WHERE e.id = ANY(%(ids)s)
        """,
        {"ids": ids},
    ).fetchall()
    titles = display_titles(conn, ids, lang)
    covers = pictures(conn, ids, TARGET_PICTURES)
    return {
        r["id"]: {
            "id": r["id"],
            "title": titles.get(r["id"]),
            "address": r["address"],
            "kind": pick_label(r["kind_labels"], lang),
            "date": r["date"],
            "year": r["date"][:4] if r["date"] else None,
            "picture": covers.get(r["id"]),
        }
        for r in rows
    }


def oldest_first(target: dict[str, Any]) -> tuple:
    """Sort key for targets: dated ones oldest first, undated ones last."""
    return (target["date"] is None, target["date"] or "", target["id"])
