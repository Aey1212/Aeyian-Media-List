"""Edit operations for Aey's own data: General Score, subratings, Take, progress.

Scores are the stored points, -50..+50 (Aey: the editor works in those).
"""

from __future__ import annotations

from app.edit.base import EditError, Operation, Param, codes, need_progress, need_rateable, plain


# --- General Score ------------------------------------------------------------

def _score(conn, entity) -> dict | None:
    return plain(conn.execute(
        "SELECT general, rated_on FROM aey.score WHERE entity_id = %s", (entity["id"],)
    ).fetchone())


def set_score(conn, entity, general: int, rated_on: str | None = None):
    need_rateable(entity)
    before = _score(conn, entity)
    conn.execute(
        """
        INSERT INTO aey.score (entity_id, entity_kind, general, rated_on) VALUES (%s, %s, %s, %s)
        ON CONFLICT (entity_id) DO UPDATE SET general = EXCLUDED.general, rated_on = EXCLUDED.rated_on, updated_at = now()
        """,
        (entity["id"], entity["kind"], general, rated_on),
    )
    return before, _score(conn, entity)


def clear_score(conn, entity):
    before = _score(conn, entity)
    conn.execute("DELETE FROM aey.score WHERE entity_id = %s", (entity["id"],))
    return before, None


# --- subratings ---------------------------------------------------------------

def _subrating(conn, entity, category) -> dict | None:
    return plain(conn.execute(
        "SELECT category, value FROM aey.subrating WHERE entity_id = %s AND category = %s", (entity["id"], category)
    ).fetchone())


def set_subrating(conn, entity, category: str, value: int):
    need_rateable(entity)
    before = _subrating(conn, entity, category)
    conn.execute(
        """
        INSERT INTO aey.subrating (entity_id, entity_kind, category, value) VALUES (%s, %s, %s, %s)
        ON CONFLICT (entity_id, category) DO UPDATE SET value = EXCLUDED.value
        """,
        (entity["id"], entity["kind"], category, value),
    )
    return before, _subrating(conn, entity, category)


def clear_subrating(conn, entity, category: str):
    before = _subrating(conn, entity, category)
    conn.execute("DELETE FROM aey.subrating WHERE entity_id = %s AND category = %s", (entity["id"], category))
    return before, None


# --- Aey's Take ---------------------------------------------------------------

def _take(conn, entity, lang) -> dict | None:
    return plain(conn.execute(
        "SELECT lang, body, written_on FROM aey.take WHERE entity_id = %s AND lang = %s", (entity["id"], lang)
    ).fetchone())


def set_take(conn, entity, body: str, lang: str = "en", written_on: str | None = None):
    need_rateable(entity)
    if not body.strip():
        raise EditError("A Take can't be empty; clear it instead.")
    before = _take(conn, entity, lang)
    conn.execute(
        """
        INSERT INTO aey.take (entity_id, entity_kind, lang, body, written_on) VALUES (%s, %s, %s, %s, %s)
        ON CONFLICT (entity_id, lang) DO UPDATE SET body = EXCLUDED.body, written_on = EXCLUDED.written_on
        """,
        (entity["id"], entity["kind"], lang, body.strip(), written_on),
    )
    return before, _take(conn, entity, lang)


def clear_take(conn, entity, lang: str = "en"):
    before = _take(conn, entity, lang)
    conn.execute("DELETE FROM aey.take WHERE entity_id = %s AND lang = %s", (entity["id"], lang))
    return before, None


# --- progress -----------------------------------------------------------------

PROGRESS_FIELDS = ("status", "progress_value", "progress_unit", "started_on", "finished_on", "times_completed", "hours", "note")


def _progress(conn, entity) -> dict | None:
    row = conn.execute(
        """
        SELECT status, progress_value, progress_unit, started_on, finished_on, times_completed,
               round(time_spent_s / 3600.0, 2) AS hours, note
          FROM aey.progress WHERE entity_id = %s
        """,
        (entity["id"],),
    ).fetchone()
    return plain(row)


def set_progress(conn, entity, **fields):
    """Changes the given fields and keeps the others. An empty value clears that field."""
    need_progress(entity)
    before = _progress(conn, entity)
    merged = {name: (before or {}).get(name) for name in PROGRESS_FIELDS}
    merged.update(fields)   # a field given as None was left empty: it is cleared
    seconds = None if merged["hours"] in (None, "") else round(float(merged["hours"]) * 3600)
    conn.execute(
        """
        INSERT INTO aey.progress (entity_id, entity_kind, status, progress_value, progress_unit, started_on,
                                  finished_on, times_completed, time_spent_s, note)
        VALUES (%(id)s, %(kind)s, %(status)s, %(progress_value)s, %(progress_unit)s, %(started_on)s,
                %(finished_on)s, %(times_completed)s, %(seconds)s, %(note)s)
        ON CONFLICT (entity_id) DO UPDATE SET
          status = EXCLUDED.status, progress_value = EXCLUDED.progress_value, progress_unit = EXCLUDED.progress_unit,
          started_on = EXCLUDED.started_on, finished_on = EXCLUDED.finished_on,
          times_completed = EXCLUDED.times_completed, time_spent_s = EXCLUDED.time_spent_s,
          note = EXCLUDED.note, updated_at = now()
        """,
        {**merged, "id": entity["id"], "kind": entity["kind"], "seconds": seconds},
    )
    return before, _progress(conn, entity)


def clear_progress(conn, entity):
    before = _progress(conn, entity)
    conn.execute("DELETE FROM aey.progress WHERE entity_id = %s", (entity["id"],))
    return before, None


CATEGORIES = codes("SELECT code FROM aey.subrating_category ORDER BY sort_order, code")
STATUSES = codes("SELECT code FROM aey.status ORDER BY sort_order, code")
UNITS = codes("SELECT code FROM media.cadence_item ORDER BY sort_order, code")

AEY_OPERATIONS: dict[str, Operation] = {
    "set_score": Operation(set_score, "Set the General Score (stored points, -50..+50).", {
        "general": Param("points", "The score, -50..+50.", required=True),
        "rated_on": Param("date", "When it was rated: YYYY, YYYY-MM or YYYY-MM-DD."),
    }),
    "clear_score": Operation(clear_score, "Remove the General Score."),
    "set_subrating": Operation(set_subrating, "Set one subrating (stored points, -50..+50).", {
        "category": Param("choice", "The subrating category.", required=True, choices=CATEGORIES),
        "value": Param("points", "The subrating, -50..+50.", required=True),
    }),
    "clear_subrating": Operation(clear_subrating, "Remove one subrating.", {
        "category": Param("choice", "The subrating category.", required=True, choices=CATEGORIES),
    }),
    "set_take": Operation(set_take, "Write Aey's Take in one language.", {
        "body": Param("text", "The Take.", required=True),
        "lang": Param("text", "Language tag, e.g. en."),
        "written_on": Param("date", "When it was written: YYYY, YYYY-MM or YYYY-MM-DD."),
    }),
    "clear_take": Operation(clear_take, "Remove the Take in one language.", {
        "lang": Param("text", "Language tag, e.g. en."),
    }),
    "set_progress": Operation(set_progress, "Change Aey's progress; fields left out stay, empty ones are cleared.", {
        "status": Param("choice", "Status.", choices=STATUSES),
        "progress_value": Param("number", "How far: episodes, chapters or volumes."),
        "progress_unit": Param("choice", "What the value counts.", choices=UNITS),
        "started_on": Param("date", "Started: YYYY, YYYY-MM or YYYY-MM-DD."),
        "finished_on": Param("date", "Finished: YYYY, YYYY-MM or YYYY-MM-DD."),
        "times_completed": Param("count", "How many times completed."),
        "hours": Param("number", "Time spent, in hours."),
        "note": Param("text", "A note."),
    }),
    "clear_progress": Operation(clear_progress, "Remove Aey's progress."),
}
