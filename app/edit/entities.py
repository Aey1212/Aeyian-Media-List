"""Edit operations for the entities themselves: creating them, their names, facts, texts,
origins and pictures.

New entities start as drafts, hidden from the public site; `publish` shows them. A work
created without a franchise gets its own new one (the database makes it), named like
the work so it can be published too.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from app.config import load_settings
from app.edit.base import EditError, Operation, Param, a, codes, plain, target
from app.tools.add_image import add_image
from app.tools.pictures import shape_for

MEDIA_KINDS = ("anime", "manga", "light_novel", "game", "series", "movie")
WORLD_KINDS = ("character", "person", "company", "franchise")
CREATABLE = MEDIA_KINDS + WORLD_KINDS


def _need_work(entity: dict[str, Any]) -> None:
    if entity["kind"] not in MEDIA_KINDS:
        raise EditError(f"{a(entity['kind_label'], capital=True)} is not a work.")


# --- creating and publishing --------------------------------------------------

def create(conn, kind: str, title: str, lang: str = "en", franchise: str | None = None):
    franchise_id = None
    if franchise:
        if kind not in MEDIA_KINDS:
            raise EditError("Only a work belongs to a franchise.")
        home = target(conn, franchise)
        if home["kind"] != "franchise":
            raise EditError(f"{home['address']} is {a(home['kind_label'])}, not a franchise.")
        franchise_id = home["id"]
    new_id = conn.execute("SELECT core.create_entity(%s, %s) AS id", (kind, franchise_id)).fetchone()["id"]
    conn.execute(
        "INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (%s, %s, 'full', %s, true)",
        (new_id, lang, title),
    )
    if kind in MEDIA_KINDS and franchise_id is None:
        own = conn.execute("SELECT franchise_id FROM core.entity WHERE id = %s", (new_id,)).fetchone()["franchise_id"]
        conn.execute(
            "INSERT INTO core.title (entity_id, lang, title_type, text, preferred) VALUES (%s, %s, 'full', %s, true)",
            (own, lang, title),
        )
        franchise = conn.execute("SELECT core.address(%s) AS a", (own,)).fetchone()["a"] + " (new, a draft)"
    entity = target(conn, conn.execute("SELECT core.address(%s) AS a", (new_id,)).fetchone()["a"])
    after = {"kind": kind, "title": title, "lang": lang, "published": False}
    if franchise:
        after["franchise"] = franchise
    return None, after, entity


def _published(conn, entity) -> dict:
    row = conn.execute("SELECT published_at IS NOT NULL AS published FROM core.entity WHERE id = %s", (entity["id"],)).fetchone()
    return {"published": row["published"]}


def publish(conn, entity):
    before = _published(conn, entity)
    conn.execute("UPDATE core.entity SET published_at = now() WHERE id = %s AND published_at IS NULL", (entity["id"],))
    return before, _published(conn, entity)


def unpublish(conn, entity):
    before = _published(conn, entity)
    conn.execute("UPDATE core.entity SET published_at = NULL WHERE id = %s", (entity["id"],))
    return before, _published(conn, entity)


# Rows that tie a page to another page: (table, columns the page can be in, one, many).
# The database would delete these with the page, silently changing the other page, so a draft
# that is still tied to another page is not deleted.
LINKS = (
    ("core.media_relation", ("source_id", "target_id"), "relation", "relations"),
    ("core.franchise_relation", ("source_id", "target_id"), "franchise relation", "franchise relations"),
    ("core.entity_franchise", ("entity_id", "franchise_id"), "franchise membership", "franchise memberships"),
    ("core.appearance", ("character_id", "target_id"), "appearance", "appearances"),
    ("core.performance", ("person_id", "character_id", "target_id"), "cast entry", "cast entries"),
    ("core.staff_credit", ("person_id", "target_id"), "staff credit", "staff credits"),
    ("core.company_credit", ("company_id", "target_id"), "company credit", "company credits"),
    ("core.entity", ("parent_id",), "page under it", "pages under it"),
    ("core.entity", ("franchise_id",), "work in it", "works in it"),
)


def _ties(conn, entity_id: int) -> list[str]:
    """What still ties a page to other pages, in words ("2 cast entries")."""
    ties = []
    for table, columns, one, many in LINKS:
        where = " OR ".join(f"{column} = %(id)s" for column in columns)
        n = conn.execute(f"SELECT count(*) AS n FROM {table} WHERE {where}", {"id": entity_id}).fetchone()["n"]
        if n:
            ties.append(f"{n} {one if n == 1 else many}")
    return ties


def delete_draft(conn, entity):
    """Deletes a draft and everything that is only its own (names, texts, pictures' records,
    facts, Aey's data). Refused for a published page, or while other pages are tied to it.
    A work's own franchise goes with it when that is a draft with nothing else in it."""
    row = conn.execute("SELECT published_at IS NOT NULL AS published, franchise_id FROM core.entity WHERE id = %s",
                       (entity["id"],)).fetchone()
    if row["published"]:
        raise EditError("Only a draft can be deleted. Unpublish it first.")
    ties = _ties(conn, entity["id"])
    if ties:
        raise EditError(f"It is still tied to other pages ({', '.join(ties)}). Those go first.")
    before = {"kind": entity["kind"], "names": [r["text"] for r in conn.execute(
        "SELECT text FROM core.title WHERE entity_id = %s ORDER BY id", (entity["id"],))], "published": False}
    conn.execute("DELETE FROM core.entity WHERE id = %s", (entity["id"],))
    home = row["franchise_id"]
    if home is not None:
        franchise = conn.execute(
            """
            SELECT core.address(id) AS address, published_at IS NOT NULL AS published,
                   (SELECT text FROM core.title WHERE entity_id = e.id ORDER BY preferred DESC, id LIMIT 1) AS title
              FROM core.entity e WHERE id = %s
            """,
            (home,),
        ).fetchone()
        if not franchise["published"] and not _ties(conn, home):
            conn.execute("DELETE FROM core.entity WHERE id = %s", (home,))
            before["franchise"] = f"{franchise['address']} {franchise['title'] or ''}".strip() + " (deleted with it)"
    return before, None


# --- names --------------------------------------------------------------------

def _title(conn, entity, title_id: int) -> dict[str, Any]:
    row = conn.execute(
        """
        SELECT id, lang, title_type, text, native, preferred, latinizes_id
          FROM core.title WHERE id = %s AND entity_id = %s
        """,
        (title_id, entity["id"]),
    ).fetchone()
    if row is None:
        raise EditError(f"This page has no name #{title_id}.")
    return row


def _snapshot(row: dict[str, Any] | None) -> dict[str, Any] | None:
    if row is None:
        return None
    return {"id": row["id"], "lang": row["lang"], "type": row["title_type"], "text": row["text"],
            "native": row["native"], "preferred": row["preferred"], "latinizes": row["latinizes_id"]}


def _take_over(conn, entity, title_id: int | None, lang: str, title_type: str, native: bool, preferred: bool) -> list[str]:
    """Marking a name native (one per type) or preferred (one per language and type) takes the
    mark from the name that had it. Returns what was taken over, for the change log."""
    taken = []
    if native:
        for row in conn.execute(
            "UPDATE core.title SET native = false WHERE entity_id = %s AND title_type = %s AND native AND id IS DISTINCT FROM %s RETURNING text",
            (entity["id"], title_type, title_id),
        ).fetchall():
            taken.append(f"native from {row['text']}")
    if preferred:
        for row in conn.execute(
            "UPDATE core.title SET preferred = false WHERE entity_id = %s AND lang = %s AND title_type = %s AND preferred AND id IS DISTINCT FROM %s RETURNING text",
            (entity["id"], lang, title_type, title_id),
        ).fetchall():
            taken.append(f"preferred from {row['text']}")
    return taken


def add_title(conn, entity, text: str, lang: str = "en", title_type: str = "full", native: bool = False,
              preferred: bool = False, latinizes: int | None = None):
    if latinizes is not None:
        _title(conn, entity, latinizes)   # must be a name of this page
    taken = _take_over(conn, entity, None, lang, title_type, native, preferred)
    row = conn.execute(
        """
        INSERT INTO core.title (entity_id, lang, title_type, text, native, preferred, latinizes_id)
        VALUES (%s, %s, %s, %s, %s, %s, %s)
        RETURNING id, lang, title_type, text, native, preferred, latinizes_id
        """,
        (entity["id"], lang, title_type, text.strip(), native, preferred, latinizes),
    ).fetchone()
    after = _snapshot(row)
    if taken:
        after["took"] = taken
    return None, after


def edit_title(conn, entity, title_id: int, **fields):
    """Changes the given fields of one name and keeps the others."""
    row = _title(conn, entity, title_id)
    before = _snapshot(row)
    merged = {"lang": row["lang"], "title_type": row["title_type"], "text": row["text"],
              "native": row["native"], "preferred": row["preferred"]}
    merged.update({k: v for k, v in fields.items() if v is not None})
    taken = _take_over(conn, entity, title_id, merged["lang"], merged["title_type"], merged["native"], merged["preferred"])
    updated = conn.execute(
        """
        UPDATE core.title SET lang = %(lang)s, title_type = %(title_type)s, text = %(text)s,
               native = %(native)s, preferred = %(preferred)s
         WHERE id = %(id)s
        RETURNING id, lang, title_type, text, native, preferred, latinizes_id
        """,
        {**merged, "text": merged["text"].strip(), "id": title_id},
    ).fetchone()
    after = _snapshot(updated)
    if taken:
        after["took"] = taken
    return before, after


def remove_title(conn, entity, title_id: int):
    before = _snapshot(_title(conn, entity, title_id))
    conn.execute("DELETE FROM core.title WHERE id = %s", (title_id,))
    return before, None


# --- facts of a work ------------------------------------------------------------

WORK_FIELDS = ("status", "start_date", "end_date", "source_type")


def _work(conn, entity) -> dict:
    return plain(conn.execute(
        "SELECT status, start_date, end_date, source_type FROM media.work WHERE entity_id = %s", (entity["id"],)
    ).fetchone())


def set_work(conn, entity, **fields):
    """Status, dates and source of a work; fields left out stay, empty ones are cleared."""
    _need_work(entity)
    before = _work(conn, entity)
    merged = {**before, **fields}
    conn.execute(
        """
        UPDATE media.work SET status = %(status)s, start_date = %(start_date)s, end_date = %(end_date)s,
               source_type = %(source_type)s WHERE entity_id = %(id)s
        """,
        {**merged, "id": entity["id"]},
    )
    return before, _work(conn, entity)


# the facts each medium has: form field -> (column, seconds per unit or None)
MEDIUM_FIELDS: dict[str, dict[str, tuple[str, int | None]]] = {
    "anime": {"format": ("format", None), "episode_count": ("episode_count", None), "episode_minutes": ("typical_runtime_s", 60)},
    "series": {"episode_count": ("episode_count", None), "episode_minutes": ("typical_runtime_s", 60)},
    "manga": {"volume_count": ("volume_count", None), "chapter_count": ("chapter_count", None)},
    "light_novel": {"volume_count": ("volume_count", None)},
    "game": {"local_players_min": ("local_players_min", None), "local_players_max": ("local_players_max", None),
             "online_players_min": ("online_players_min", None), "online_players_max": ("online_players_max", None)},
    "movie": {"runtime_minutes": ("runtime_s", 60)},
}


def medium_facts(conn, entity) -> dict:
    """The medium's facts by form field, minutes as minutes (24, or 23.5 when not whole)."""
    fields = MEDIUM_FIELDS[entity["kind"]]
    columns = ", ".join(column for column, _ in fields.values())
    row = conn.execute(f"SELECT {columns} FROM media.{entity['kind']} WHERE entity_id = %s", (entity["id"],)).fetchone()
    out = {}
    for name, (column, unit) in fields.items():
        value = row[column]
        if unit is not None and value is not None:
            value = round(value / unit, 2)
            value = int(value) if value == int(value) else value
        out[name] = value
    return plain(out)


def set_medium(conn, entity, **fields):
    """The facts only some media have (episodes, volumes, players ...); left out stays, empty clears."""
    _need_work(entity)
    allowed = MEDIUM_FIELDS[entity["kind"]]
    wrong = [name for name in fields if name not in allowed]
    if wrong:
        raise EditError(f"{a(entity['kind_label'], capital=True)} has no {', '.join(wrong)}.")
    before = medium_facts(conn, entity)
    for name, value in fields.items():
        column, unit = allowed[name]
        stored = value if unit is None or value is None else round(float(value) * unit)
        # table and column names come from MEDIUM_FIELDS, never from input
        conn.execute(f"UPDATE media.{entity['kind']} SET {column} = %s WHERE entity_id = %s", (stored, entity["id"]))
    return before, medium_facts(conn, entity)


# --- original languages and countries of origin ---------------------------------

def _list(conn, entity, table: str, column: str) -> dict:
    rows = conn.execute(f"SELECT {column} FROM {table} WHERE entity_id = %s ORDER BY sort_order, {column}", (entity["id"],)).fetchall()
    return {column + "s": [r[column] for r in rows]}


def _add_to(conn, entity, table: str, column: str, value: str):
    _need_work(entity)
    before = _list(conn, entity, table, column)
    conn.execute(
        f"""
        INSERT INTO {table} (entity_id, entity_kind, {column}, sort_order)
        SELECT %(id)s, %(kind)s, %(value)s,
               COALESCE((SELECT max(sort_order) + 1 FROM {table} WHERE entity_id = %(id)s), 0)
        ON CONFLICT DO NOTHING
        """,
        {"id": entity["id"], "kind": entity["kind"], "value": value},
    )
    return before, _list(conn, entity, table, column)


def _remove_from(conn, entity, table: str, column: str, value: str):
    before = _list(conn, entity, table, column)
    conn.execute(f"DELETE FROM {table} WHERE entity_id = %s AND {column} = %s", (entity["id"], value))
    return before, _list(conn, entity, table, column)


def add_original_language(conn, entity, lang: str):
    return _add_to(conn, entity, "core.entity_original_language", "lang", lang)


def remove_original_language(conn, entity, lang: str):
    return _remove_from(conn, entity, "core.entity_original_language", "lang", lang)


def add_origin_country(conn, entity, country: str):
    return _add_to(conn, entity, "core.entity_origin_country", "country", country.upper())


def remove_origin_country(conn, entity, country: str):
    return _remove_from(conn, entity, "core.entity_origin_country", "country", country.upper())


# --- synopsis and description ---------------------------------------------------

def _text(conn, entity, text_type, lang) -> dict | None:
    return conn.execute(
        "SELECT text_type, lang, body FROM core.entity_text WHERE entity_id = %s AND text_type = %s AND lang = %s",
        (entity["id"], text_type, lang),
    ).fetchone()


def set_text(conn, entity, text_type: str, body: str, lang: str = "en"):
    before = _text(conn, entity, text_type, lang)
    conn.execute(
        """
        INSERT INTO core.entity_text (entity_id, text_type, lang, body) VALUES (%s, %s, %s, %s)
        ON CONFLICT (entity_id, text_type, lang) DO UPDATE SET body = EXCLUDED.body
        """,
        (entity["id"], text_type, lang, body.strip()),
    )
    return before, _text(conn, entity, text_type, lang)


def clear_text(conn, entity, text_type: str, lang: str = "en"):
    before = _text(conn, entity, text_type, lang)
    conn.execute("DELETE FROM core.entity_text WHERE entity_id = %s AND text_type = %s AND lang = %s", (entity["id"], text_type, lang))
    return before, None


# --- pictures -----------------------------------------------------------------------

def _picture(conn, entity, image_id: int) -> dict:
    row = conn.execute(
        "SELECT id, image_type, sha256, format, is_primary, sort_order FROM core.image WHERE id = %s AND entity_id = %s",
        (image_id, entity["id"]),
    ).fetchone()
    if row is None:
        raise EditError(f"This page has no picture #{image_id}.")
    return row


def _picture_snapshot(row: dict | None) -> dict | None:
    if row is None:
        return None
    return {"id": row["id"], "type": row["image_type"], "file": f"{row['sha256']}.{row['format']}", "primary": row["is_primary"]}


def add_picture(conn, entity, file: str, image_type: str):
    """Stores a web copy of the file (app/tools/add_image.py). The file is read from the
    machine the operation runs on; the first picture of a type becomes the primary one."""
    path = Path(file)
    if not path.is_file():
        raise EditError(f"No file at {file}.")
    try:
        result = add_image(conn, entity["id"], image_type, path, load_settings().media_dir,
                           shape=shape_for(image_type, entity["kind"]))
    except OSError as error:
        raise EditError(f"That file can't be read as a picture ({error}).") from None
    row = conn.execute(
        "SELECT id, image_type, sha256, format, is_primary, sort_order FROM core.image "
        "WHERE entity_id = %s AND image_type = %s AND sha256 = %s AND format = %s",
        (entity["id"], image_type, result["sha256"], result["format"]),
    ).fetchone()
    return (None if result["added"] else _picture_snapshot(row)), _picture_snapshot(row)


def remove_picture(conn, entity, image_id: int):
    """Removes one picture from the page. If it was the primary one, the next of its type
    becomes primary. The stored file stays (other pages may use the same file)."""
    row = _picture(conn, entity, image_id)
    conn.execute("DELETE FROM core.image WHERE id = %s", (image_id,))
    if row["is_primary"]:
        conn.execute(
            """
            UPDATE core.image SET is_primary = true
             WHERE id = (SELECT id FROM core.image WHERE entity_id = %s AND image_type = %s ORDER BY sort_order, id LIMIT 1)
            """,
            (entity["id"], row["image_type"]),
        )
    return _picture_snapshot(row), None


def make_primary(conn, entity, image_id: int):
    row = _picture(conn, entity, image_id)
    conn.execute("UPDATE core.image SET is_primary = false WHERE entity_id = %s AND image_type = %s AND is_primary",
                 (entity["id"], row["image_type"]))
    conn.execute("UPDATE core.image SET is_primary = true WHERE id = %s", (image_id,))
    return _picture_snapshot(row), _picture_snapshot(_picture(conn, entity, image_id))


# --- the list -------------------------------------------------------------------------

KINDS = lambda conn: list(CREATABLE)   # noqa: E731
TITLE_TYPES = codes("SELECT code FROM core.title_type ORDER BY sort_order, code")
WORK_STATUSES = codes("SELECT code FROM media.work_status ORDER BY sort_order, code")
SOURCE_TYPES = codes("SELECT code FROM media.source_type ORDER BY sort_order, code")
ANIME_FORMATS = codes("SELECT code FROM media.anime_format ORDER BY sort_order, code")
TEXT_TYPES = codes("SELECT code FROM core.text_type ORDER BY sort_order, code")
IMAGE_TYPES = codes("SELECT code FROM core.image_type ORDER BY sort_order, code")

LANG = Param("text", "Language tag, e.g. en, ja, ja-Latn.")

ENTITY_OPERATIONS: dict[str, Operation] = {
    "create": Operation(create, "Create a work, character, person, company or franchise, as a draft.", {
        "kind": Param("choice", "What to create.", required=True, choices=KINDS),
        "title": Param("text", "Its name.", required=True),
        "lang": LANG,
        "franchise": Param("address", "For a work: the franchise it belongs to. Left out, it gets its own new one."),
    }, creates=True),
    "publish": Operation(publish, "Show the page on the public site."),
    "unpublish": Operation(unpublish, "Hide the page from the public site (a draft again)."),
    "delete_draft": Operation(delete_draft, "Delete a draft for good, if no other page is tied to it.", deletes=True),
    "add_title": Operation(add_title, "Add a name.", {
        "text": Param("text", "The name.", required=True),
        "lang": LANG,
        "title_type": Param("choice", "Full, short or alternative.", choices=TITLE_TYPES),
        "native": Param("bool", "The name in the original language (one per type)."),
        "preferred": Param("bool", "The one shown for its language and type."),
        "latinizes": Param("id", "For a latinized name (ja-Latn ...): the name it spells out."),
    }),
    "edit_title": Operation(edit_title, "Change a name; fields left out stay.", {
        "title_id": Param("id", "Which name.", required=True),
        "text": Param("text", "The name."),
        "lang": LANG,
        "title_type": Param("choice", "Full, short or alternative.", choices=TITLE_TYPES),
        "native": Param("bool", "The name in the original language (one per type)."),
        "preferred": Param("bool", "The one shown for its language and type."),
    }),
    "remove_title": Operation(remove_title, "Remove a name.", {
        "title_id": Param("id", "Which name.", required=True),
    }),
    "set_work": Operation(set_work, "Status, dates and source of a work; fields left out stay, empty ones are cleared.", {
        "status": Param("choice", "Status.", choices=WORK_STATUSES),
        "start_date": Param("date", "Started: YYYY, YYYY-MM or YYYY-MM-DD."),
        "end_date": Param("date", "Ended: YYYY, YYYY-MM or YYYY-MM-DD."),
        "source_type": Param("choice", "What it is based on.", choices=SOURCE_TYPES),
    }),
    "set_medium": Operation(set_medium, "The facts only some media have; fields left out stay, empty ones are cleared.", {
        "format": Param("choice", "Anime format.", choices=ANIME_FORMATS),
        "episode_count": Param("count", "Episodes (anime, series)."),
        "episode_minutes": Param("number", "Typical episode length in minutes (anime, series)."),
        "volume_count": Param("count", "Volumes (manga, light novel)."),
        "chapter_count": Param("count", "Chapters (manga)."),
        "local_players_min": Param("count", "Fewest local players (game; 0 = no local play)."),
        "local_players_max": Param("count", "Most local players (game)."),
        "online_players_min": Param("count", "Fewest online players (game; 0 = no online play)."),
        "online_players_max": Param("count", "Most online players (game)."),
        "runtime_minutes": Param("number", "Runtime in minutes (movie)."),
    }),
    "add_original_language": Operation(add_original_language, "Add an original language of a work.", {
        "lang": Param("text", "Language tag, e.g. ja.", required=True),
    }),
    "remove_original_language": Operation(remove_original_language, "Remove an original language.", {
        "lang": Param("text", "Language tag, e.g. ja.", required=True),
    }),
    "add_origin_country": Operation(add_origin_country, "Add a country of origin of a work.", {
        "country": Param("text", "Country code, e.g. JP.", required=True),
    }),
    "remove_origin_country": Operation(remove_origin_country, "Remove a country of origin.", {
        "country": Param("text", "Country code, e.g. JP.", required=True),
    }),
    "set_text": Operation(set_text, "Write a synopsis or description in one language.", {
        "text_type": Param("choice", "Synopsis or description.", required=True, choices=TEXT_TYPES),
        "body": Param("text", "The text.", required=True),
        "lang": LANG,
    }),
    "clear_text": Operation(clear_text, "Remove a synopsis or description in one language.", {
        "text_type": Param("choice", "Synopsis or description.", required=True, choices=TEXT_TYPES),
        "lang": LANG,
    }),
    "add_picture": Operation(add_picture, "Add a picture from a file (a web copy is stored).", {
        "file": Param("file", "Path of the picture file.", required=True),
        "image_type": Param("choice", "Cover, portrait, logo ...", required=True, choices=IMAGE_TYPES),
    }),
    "remove_picture": Operation(remove_picture, "Remove a picture from the page.", {
        "image_id": Param("id", "Which picture.", required=True),
    }),
    "make_primary": Operation(make_primary, "Make a picture the one shown for its type.", {
        "image_id": Param("id", "Which picture.", required=True),
    }),
}
