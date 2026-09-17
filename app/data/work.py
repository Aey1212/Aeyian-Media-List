"""Everything a media work page shows.

Only published entities appear: the work itself, and anything it links to.
Relationship labels name the OTHER side from this page: stored "B remake_of A"
shows "A — Original work" on B's page and "B — Remake" on A's page.
"""

from __future__ import annotations

from typing import Any
from urllib.parse import urlsplit

import psycopg

from app.data.common import aey_data, all_titles, display_titles, franchise_lineage, native_titles, pictures, title_block
from app.labels import format_duration, format_number, format_partial_date, pick_label


def _media_relations(conn: psycopg.Connection, entity_id: int, lang: str) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT x.other_id, x.labels, x.type_order, x.note,
               core.address(x.other_id) AS address, k.labels AS kind_labels, w.start_date
          FROM (
            SELECT r.target_id AS other_id, rt.target_labels AS labels, rt.sort_order AS type_order, r.note
              FROM core.media_relation r JOIN core.relation_type rt ON rt.code = r.relation_type
             WHERE r.source_id = %(id)s
            UNION ALL
            SELECT r.source_id, rt.source_labels, rt.sort_order, r.note
              FROM core.media_relation r JOIN core.relation_type rt ON rt.code = r.relation_type
             WHERE r.target_id = %(id)s
          ) x
          JOIN core.entity o ON o.id = x.other_id AND o.published_at IS NOT NULL
          JOIN core.entity_kind k ON k.name = o.kind
          LEFT JOIN media.work w ON w.entity_id = o.id
         ORDER BY x.type_order, w.start_date NULLS LAST, x.other_id
        """,
        {"id": entity_id},
    ).fetchall()
    titles = display_titles(conn, (r["other_id"] for r in rows), lang)
    return [
        {
            "label": pick_label(r["labels"], lang),
            "title": titles.get(r["other_id"]),
            "address": r["address"],
            "kind": pick_label(r["kind_labels"], lang),
            "year": r["start_date"][:4] if r["start_date"] else None,
            "note": r["note"],
        }
        for r in rows
    ]


def _franchises(conn: psycopg.Connection, entity_id: int, lang: str) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT fa.franchise_id, fa.is_home, core.address(fa.franchise_id) AS address
          FROM core.entity_franchise_all fa
          JOIN core.entity f ON f.id = fa.franchise_id AND f.published_at IS NOT NULL
         WHERE fa.entity_id = %(id)s
         ORDER BY fa.is_home DESC, fa.sort_order, fa.franchise_id
        """,
        {"id": entity_id},
    ).fetchall()
    result = []
    for row in rows:
        parents = franchise_lineage(conn, row["franchise_id"])
        titles = display_titles(conn, [row["franchise_id"], *(p["id"] for p in parents)], lang)
        result.append({
            "title": titles.get(row["franchise_id"]),
            "address": row["address"],
            "is_home": row["is_home"],
            # the franchises above this one, outermost first: Shin Megami Tensei › Persona
            "parents": [{"title": titles.get(p["id"]), "address": p["address"]} for p in parents],
        })
    return result


def _children(conn: psycopg.Connection, entity_id: int, lang: str) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT c.id, k.labels AS kind_labels, core.address(c.id) AS address,
               COALESCE(d.released_on, v.released_on, s.started_on, st.released_on) AS date
          FROM core.entity c
          JOIN core.entity_kind k ON k.name = c.kind
          LEFT JOIN child.dlc d         ON d.entity_id = c.id
          LEFT JOIN child.volume v      ON v.entity_id = c.id
          LEFT JOIN child.season s      ON s.entity_id = c.id
          LEFT JOIN child.soundtrack st ON st.entity_id = c.id
         WHERE c.parent_id = %(id)s AND c.published_at IS NOT NULL AND c.kind <> 'release'
         ORDER BY k.code, c.seq
        """,
        {"id": entity_id},
    ).fetchall()
    titles = display_titles(conn, (r["id"] for r in rows), lang)
    return [
        {
            "kind": pick_label(r["kind_labels"], lang),
            "title": titles.get(r["id"]),
            "address": r["address"],
            "date": format_partial_date(r["date"]),
        }
        for r in rows
    ]


def _genres_and_tags(conn: psycopg.Connection, entity_id: int, lang: str) -> tuple[list, list]:
    genre_rows = conn.execute(
        """
        SELECT eg.genre_id AS id, core.address(eg.genre_id) AS address,
               COALESCE((SELECT array_agg(gp.parent_id ORDER BY gp.parent_id)
                           FROM core.genre_parent gp
                           JOIN core.entity pe ON pe.id = gp.parent_id AND pe.published_at IS NOT NULL
                          WHERE gp.genre_id = eg.genre_id), '{}') AS parent_ids
          FROM core.entity_genre eg
          JOIN core.entity g ON g.id = eg.genre_id AND g.published_at IS NOT NULL
         WHERE eg.entity_id = %(id)s
        """,
        {"id": entity_id},
    ).fetchall()
    tag_rows = conn.execute(
        """
        SELECT et.tag_id AS id, core.address(et.tag_id) AS address
          FROM core.entity_tag et
          JOIN core.entity t ON t.id = et.tag_id AND t.published_at IS NOT NULL
         WHERE et.entity_id = %(id)s
        """,
        {"id": entity_id},
    ).fetchall()
    ids = [r["id"] for r in genre_rows] + [p for r in genre_rows for p in r["parent_ids"]] + [r["id"] for r in tag_rows]
    titles = display_titles(conn, ids, lang)
    genres = sorted(
        (
            {"title": titles.get(r["id"]), "address": r["address"], "parents": [titles.get(p) for p in r["parent_ids"]]}
            for r in genre_rows
        ),
        key=lambda g: (g["title"] or "").casefold(),
    )
    tags = sorted(
        ({"title": titles.get(r["id"]), "address": r["address"]} for r in tag_rows),
        key=lambda t: (t["title"] or "").casefold(),
    )
    return genres, tags


def _characters(conn: psycopg.Connection, entity_id: int, lang: str) -> list[dict[str, Any]]:
    """Characters in this work with their roles and cast.

    Appearances and performances are separate systems (PLANNING.md), so a character
    with a performance but no appearance row still shows. Order: best role
    (Protagonist first), then the appearance order, then name. Cast in the work's
    original language comes first.
    """
    params = {"id": entity_id}
    appearances = conn.execute(
        """
        SELECT a.id, a.character_id, a.sort_order, a.note, core.address(a.character_id) AS address
          FROM core.appearance a
          JOIN core.entity c ON c.id = a.character_id AND c.published_at IS NOT NULL
         WHERE a.target_id = %(id)s
        """,
        params,
    ).fetchall()
    roles = conn.execute(
        """
        SELECT l.appearance_id, r.labels, r.sort_order
          FROM core.appearance_role_link l
          JOIN core.appearance_role r ON r.code = l.role
          JOIN core.appearance a ON a.id = l.appearance_id
         WHERE a.target_id = %(id)s
         ORDER BY r.sort_order, r.code
        """,
        params,
    ).fetchall()
    cast = conn.execute(
        """
        SELECT p.character_id, p.person_id, p.lang, p.note, t.labels AS type_labels,
               core.address(p.character_id) AS character_address, core.address(p.person_id) AS person_address
          FROM core.performance p
          JOIN core.performance_type t ON t.code = p.performance_type
          JOIN core.entity c  ON c.id = p.character_id AND c.published_at IS NOT NULL
          JOIN core.entity pe ON pe.id = p.person_id AND pe.published_at IS NOT NULL
         WHERE p.target_id = %(id)s
         ORDER BY t.sort_order,
                  (p.lang IN (SELECT ol.lang FROM core.entity_original_language ol WHERE ol.entity_id = %(id)s)) DESC,
                  p.lang NULLS LAST, p.sort_order, p.person_id
        """,
        params,
    ).fetchall()

    roles_by_appearance: dict[int, list[dict[str, Any]]] = {}
    for r in roles:
        roles_by_appearance.setdefault(r["appearance_id"], []).append(r)

    last = 32767
    entries: dict[int, dict[str, Any]] = {}
    for a in appearances:
        own = roles_by_appearance.get(a["id"], [])
        entries[a["character_id"]] = {
            "id": a["character_id"],
            "address": a["address"],
            "note": a["note"],
            "roles": [pick_label(r["labels"], lang) for r in own],
            "order": (min((r["sort_order"] for r in own), default=last), a["sort_order"]),
            "cast": [],
        }
    for c in cast:
        entry = entries.setdefault(c["character_id"], {
            "id": c["character_id"], "address": c["character_address"], "note": None,
            "roles": [], "order": (last, last), "cast": [],
        })
        entry["cast"].append({
            "person_id": c["person_id"], "address": c["person_address"],
            "type": pick_label(c["type_labels"], lang), "lang": c["lang"], "note": c["note"],
        })

    person_ids = [x["person_id"] for e in entries.values() for x in e["cast"]]
    titles = display_titles(conn, [*entries, *person_ids], lang)
    natives = native_titles(conn, entries, lang)
    portraits = pictures(conn, [*entries, *person_ids], ["portrait"])
    ordered = sorted(entries.values(), key=lambda e: (e["order"], (titles.get(e["id"]) or "").casefold()))
    return [
        {
            "title": titles.get(e["id"]),
            "native_title": natives.get(e["id"], {}).get("text"),
            "native_lang": natives.get(e["id"], {}).get("lang"),
            "address": e["address"],
            "picture": portraits.get(e["id"]),
            "roles": e["roles"],
            "note": e["note"],
            "cast": [
                {
                    "title": titles.get(x["person_id"]),
                    "address": x["address"],
                    "picture": portraits.get(x["person_id"]),
                    "type": x["type"],
                    "lang": x["lang"],
                    "note": x["note"],
                }
                for x in e["cast"]
            ],
        }
        for e in ordered
    ]


def _companies_and_staff(conn: psycopg.Connection, entity_id: int, lang: str) -> tuple[list, list]:
    """One card per company and per person, each listing its roles in role order."""
    rows = conn.execute(
        """
        SELECT 1 AS side, r.sort_order AS role_order, cc.role, r.labels AS role_labels,
               cc.company_id AS who_id, cc.note, cc.sort_order AS item_order, core.address(cc.company_id) AS address
          FROM core.company_credit cc
          JOIN core.company_role r ON r.code = cc.role
          JOIN core.entity w ON w.id = cc.company_id AND w.published_at IS NOT NULL
         WHERE cc.target_id = %(id)s
        UNION ALL
        SELECT 2, r.sort_order, sc.role, r.labels, sc.person_id, sc.note, sc.sort_order, core.address(sc.person_id)
          FROM core.staff_credit sc
          JOIN core.staff_role r ON r.code = sc.role
          JOIN core.entity w ON w.id = sc.person_id AND w.published_at IS NOT NULL
         WHERE sc.target_id = %(id)s
         ORDER BY side, role_order, item_order, who_id
        """,
        {"id": entity_id},
    ).fetchall()
    titles = display_titles(conn, (r["who_id"] for r in rows), lang)
    logos = pictures(conn, (r["who_id"] for r in rows if r["side"] == 1), ["logo"])
    portraits = pictures(conn, (r["who_id"] for r in rows if r["side"] == 2), ["portrait"])
    cards: dict[tuple[int, int], dict[str, Any]] = {}
    for r in rows:
        card = cards.setdefault((r["side"], r["who_id"]), {
            "title": titles.get(r["who_id"]),
            "address": r["address"],
            "picture": (logos if r["side"] == 1 else portraits).get(r["who_id"]),
            "roles": [],
        })
        role = pick_label(r["role_labels"], lang)
        if role not in card["roles"]:
            card["roles"].append(role)
    companies = [c for (side, _), c in cards.items() if side == 1]
    staff = [c for (side, _), c in cards.items() if side == 2]
    return companies, staff


def _platforms(conn: psycopg.Connection, entity_id: int, lang: str) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT DISTINCT r.platform_id AS id, fam.seq AS family_seq, p.seq AS seq,
               core.address(r.platform_id) AS address
          FROM core.entity rel
          JOIN child.release r ON r.entity_id = rel.id
          JOIN core.entity p   ON p.id = r.platform_id AND p.published_at IS NOT NULL
          JOIN core.entity fam ON fam.id = p.parent_id
         WHERE rel.parent_id = %(id)s AND rel.published_at IS NOT NULL
         ORDER BY family_seq, seq
        """,
        {"id": entity_id},
    ).fetchall()
    titles = display_titles(conn, (r["id"] for r in rows), lang)
    return [{"title": titles.get(r["id"]), "address": r["address"]} for r in rows]


def _medium_facts(conn: psycopg.Connection, entity_id: int, lang: str) -> list[dict[str, str]]:
    """Facts only some media have, in the order the page lists them: format, episodes and
    their length (anime, series), volumes and chapters (manga, light novels), runtime (movies).
    Unknown values are left out."""
    row = conn.execute(
        """
        SELECT f.labels AS format_labels,
               COALESCE(a.episode_count, s.episode_count) AS episodes,
               COALESCE(a.typical_runtime_s, s.typical_runtime_s) AS episode_length,
               COALESCE(m.volume_count, ln.volume_count) AS volumes,
               m.chapter_count AS chapters,
               mv.runtime_s AS runtime
          FROM core.entity e
          LEFT JOIN media.anime a        ON a.entity_id = e.id
          LEFT JOIN media.anime_format f ON f.code = a.format
          LEFT JOIN media.series s       ON s.entity_id = e.id
          LEFT JOIN media.manga m        ON m.entity_id = e.id
          LEFT JOIN media.light_novel ln ON ln.entity_id = e.id
          LEFT JOIN media.movie mv       ON mv.entity_id = e.id
         WHERE e.id = %(id)s
        """,
        {"id": entity_id},
    ).fetchone()
    facts = [
        ("Format", pick_label(row["format_labels"], lang)),
        ("Episodes", row["episodes"]),
        ("Episode Length", format_duration(row["episode_length"])),
        ("Volumes", row["volumes"]),
        ("Chapters", row["chapters"]),
        ("Runtime", format_duration(row["runtime"])),
    ]
    return [{"label": label, "value": str(value)} for label, value in facts if value is not None]


def _age_ratings(conn: psycopg.Connection, entity_id: int, lang: str) -> list[dict[str, Any]]:
    """The work's age ratings, one per system, with icons.

    Systems covering the work's countries of origin come first (CERO for a Japanese
    game), then systems in the order they were added.
    """
    rows = conn.execute(
        """
        SELECT a.rating_id, a.system_id, core.address(a.rating_id) AS address, ar.min_age
          FROM core.entity_age_rating a
          JOIN core.entity r ON r.id = a.rating_id AND r.published_at IS NOT NULL
          JOIN core.entity s ON s.id = a.system_id AND s.published_at IS NOT NULL
          JOIN child.age_rating ar ON ar.entity_id = a.rating_id
          JOIN world.age_rating_system sys ON sys.entity_id = a.system_id
         WHERE a.entity_id = %(id)s
         ORDER BY sys.regions::text[] && ARRAY(SELECT oc.country::text FROM core.entity_origin_country oc
                                               WHERE oc.entity_id = %(id)s) DESC,
                  s.seq, s.id
        """,
        {"id": entity_id},
    ).fetchall()
    titles = display_titles(conn, [*(r["system_id"] for r in rows), *(r["rating_id"] for r in rows)], lang)
    icons = pictures(conn, (r["rating_id"] for r in rows), ["icon"])
    return [
        {
            "system": titles.get(r["system_id"]),
            "rating": titles.get(r["rating_id"]),
            # a rating's name does not repeat its system's: "PEGI" + "16"
            "label": " ".join(t for t in (titles.get(r["system_id"]), titles.get(r["rating_id"])) if t),
            "address": r["address"],
            "icon": icons.get(r["rating_id"]),
            "min_age": r["min_age"],
        }
        for r in rows
    ]


def _external(conn: psycopg.Connection, entity_id: int, lang: str) -> dict[str, list[dict[str, Any]]]:
    ratings = conn.execute(
        """
        SELECT s.labels AS source_labels, m.labels AS metric_labels, m.unit,
               l.score, l.scale_max, l.vote_count, l.source_url, l.recorded_on
          FROM ext.rating_latest l
          JOIN ext.metric m ON m.source = l.source AND m.code = l.metric
          JOIN ext.source s ON s.code = l.source
         WHERE l.entity_id = %(id)s
         ORDER BY s.sort_order, m.sort_order
        """,
        {"id": entity_id},
    ).fetchall()
    links = conn.execute(
        """
        SELECT l.url, l.caption, s.labels AS source_labels
          FROM ext.link l LEFT JOIN ext.source s ON s.code = l.source
         WHERE l.entity_id = %(id)s
         ORDER BY l.sort_order, l.id
        """,
        {"id": entity_id},
    ).fetchall()

    def value_parts(r: dict[str, Any]) -> tuple[str, str, str]:
        """(number, suffix shown on the page, full text):
        ('88', '', '88 / 100'), ('60', 'h', '60 h'), ('93', '%', '93%').
        A scaled score shows only its number on the page (Aey: no "/ 100")."""
        number = format_number(r["score"])
        if r["unit"] == "hours":
            return number, "h", f"{number} h"
        if r["unit"] == "percent":
            return number, "%", f"{number}%"
        if r["scale_max"] is not None:
            return number, "", f"{number} / {format_number(r['scale_max'])}"
        return number, "", number

    def host(url: str) -> str:
        name = urlsplit(url).hostname or url
        return name[4:] if name.startswith("www.") else name

    result_ratings = []
    for r in ratings:
        number, suffix, text = value_parts(r)
        result_ratings.append({
            "source": pick_label(r["source_labels"], lang),
            "metric": pick_label(r["metric_labels"], lang),
            "value": text,
            "number": number,
            "suffix": suffix,
            "votes": r["vote_count"],
            "url": r["source_url"],
            "recorded_on": r["recorded_on"].strftime("%Y/%m/%d"),
        })
    return {
        "ratings": result_ratings,
        "links": [
            {
                "url": l["url"],
                "label": pick_label(l["caption"], lang) or pick_label(l["source_labels"], lang) or l["url"],
                "host": host(l["url"]),
            }
            for l in links
        ],
    }


def load_work(conn: psycopg.Connection, entity_id: int, lang: str = "en") -> dict[str, Any] | None:
    """The whole page for a published media work, or None if there is no such page."""
    head = conn.execute(
        """
        SELECT e.id, core.address(e.id) AS address, k.labels AS kind_labels,
               ws.labels AS status_labels, w.start_date, w.end_date, st.labels AS source_labels
          FROM core.entity e
          JOIN core.entity_kind k ON k.name = e.kind
          JOIN media.work w ON w.entity_id = e.id
          LEFT JOIN media.work_status ws ON ws.code = w.status
          LEFT JOIN media.source_type st ON st.code = w.source_type
         WHERE e.id = %(id)s AND e.family = 'media' AND e.published_at IS NOT NULL
        """,
        {"id": entity_id},
    ).fetchone()
    if head is None:
        return None
    genres, tags = _genres_and_tags(conn, entity_id, lang)
    companies, staff = _companies_and_staff(conn, entity_id, lang)
    return {
        "id": head["id"],
        "address": head["address"],
        "kind": pick_label(head["kind_labels"], lang),
        **title_block(conn, entity_id, lang),
        "titles": all_titles(conn, entity_id, lang),
        "status": pick_label(head["status_labels"], lang),
        "facts": _medium_facts(conn, entity_id, lang),
        "start_date": format_partial_date(head["start_date"]),
        "end_date": format_partial_date(head["end_date"]),
        "source_type": pick_label(head["source_labels"], lang),
        "franchises": _franchises(conn, entity_id, lang),
        "relations": _media_relations(conn, entity_id, lang),
        "children": _children(conn, entity_id, lang),
        "genres": genres,
        "tags": tags,
        "characters": _characters(conn, entity_id, lang),
        "companies": companies,
        "staff": staff,
        "platforms": _platforms(conn, entity_id, lang),
        "age_ratings": _age_ratings(conn, entity_id, lang),
        "aey": aey_data(conn, entity_id, lang),
        "external": _external(conn, entity_id, lang),
    }
