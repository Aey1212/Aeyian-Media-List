"""The edit operations: the only way AML's data is changed by hand.

Every door (the web editor, the admin chat, terminal commands) calls `run()` with an
operation name and its parameters. `run()` checks the parameters, makes the change in
one transaction, records it in core.change_log (what changed, from what to what, when,
through which door) and returns the change. With `dry_run=True` nothing is kept: the
chat uses that to show a change before Aey confirms it.

Scores are the stored points, -50..+50 (Aey: the editor works in those). Public pages
show them divided by 5; that stays the pages' business.

This first round covers Aey's own data: General Score, subratings, Take and progress.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from decimal import Decimal
from typing import Any

import psycopg
from psycopg.rows import dict_row

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
    kind: str                 # "points", "text", "date", "number", "count", "choice"
    description: str
    required: bool = False
    choices: Callable[[psycopg.Connection], list[str]] | None = None


@dataclass
class Operation:
    run: Callable[..., tuple[dict | None, dict | None]]
    description: str
    params: dict[str, Param] = field(default_factory=dict)


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


def _need_rateable(entity: dict[str, Any]) -> None:
    if not entity["rateable"]:
        raise EditError(f"A {entity['kind_label']} can't be rated.")


def _need_progress(entity: dict[str, Any]) -> None:
    if not entity["progress"]:
        raise EditError(f"Progress isn't kept for a {entity['kind_label']}.")


def _plain(row: dict[str, Any] | None) -> dict[str, Any] | None:
    """A row as JSON-safe values (numbers stay numbers)."""
    if row is None:
        return None
    out = {}
    for key, value in row.items():
        if isinstance(value, Decimal):
            value = int(value) if value == value.to_integral_value() else float(value)
        out[key] = value
    return out


# --- General Score ------------------------------------------------------------

def _score(conn, entity) -> dict | None:
    return _plain(conn.execute(
        "SELECT general, rated_on FROM aey.score WHERE entity_id = %s", (entity["id"],)
    ).fetchone())


def set_score(conn, entity, general: int, rated_on: str | None = None):
    _need_rateable(entity)
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
    return _plain(conn.execute(
        "SELECT category, value FROM aey.subrating WHERE entity_id = %s AND category = %s", (entity["id"], category)
    ).fetchone())


def set_subrating(conn, entity, category: str, value: int):
    _need_rateable(entity)
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
    return _plain(conn.execute(
        "SELECT lang, body, written_on FROM aey.take WHERE entity_id = %s AND lang = %s", (entity["id"], lang)
    ).fetchone())


def set_take(conn, entity, body: str, lang: str = "en", written_on: str | None = None):
    _need_rateable(entity)
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
    return _plain(row)


def set_progress(conn, entity, **fields):
    """Changes the given fields and keeps the others. An empty value clears that field."""
    _need_progress(entity)
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


# --- the list every door uses ---------------------------------------------------

def _codes(sql: str) -> Callable[[psycopg.Connection], list[str]]:
    return lambda conn: [r["code"] for r in conn.execute(sql).fetchall()]


CATEGORIES = _codes("SELECT code FROM aey.subrating_category ORDER BY sort_order, code")
STATUSES = _codes("SELECT code FROM aey.status ORDER BY sort_order, code")
UNITS = _codes("SELECT code FROM media.cadence_item ORDER BY sort_order, code")

OPERATIONS: dict[str, Operation] = {
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

# what the database's own refusals mean, in words
REFUSALS = {
    "score_50_ck": "Points go from -50 to +50.",
    "partial_date_ck": "Dates are YYYY, YYYY-MM or YYYY-MM-DD, and must be real dates.",
    "progress_dates_order_ck": "It can't be finished before it was started.",
    "progress_value_needs_unit_ck": "Say what the progress counts: episodes, chapters or volumes.",
    "lang_tag_ck": "That isn't a language tag (en, ja, tr, pt-BR ...).",
}


def _check(conn: psycopg.Connection, name: str, params: dict[str, Any]) -> dict[str, Any]:
    """The parameters as the operation needs them, or EditError naming what is wrong."""
    operation = OPERATIONS[name]
    unknown = set(params) - set(operation.params)
    if unknown:
        raise EditError(f"{name} has no {', '.join(sorted(unknown))}.")
    clean: dict[str, Any] = {}
    for key, param in operation.params.items():
        if key not in params:
            if param.required:
                raise EditError(f"{name} needs {key}.")
            continue
        value = params[key]
        if isinstance(value, str):
            value = value.strip()
        if value in ("", None):
            if param.required:
                raise EditError(f"{name} needs {key}.")
            clean[key] = None
            continue
        try:
            if param.kind == "points":
                number = float(value)
                if number != int(number):
                    raise ValueError
                value = int(number)
                if not -50 <= value <= 50:
                    raise EditError(f"{key}: points go from -50 to +50, not {value}.")
            elif param.kind == "count":
                value = int(value)
                if value < 0:
                    raise ValueError
            elif param.kind == "number":
                value = float(value)
                if value < 0:
                    raise ValueError
            elif param.kind in ("text", "date", "choice"):
                value = str(value)
        except (TypeError, ValueError):
            raise EditError(f"{key}: {value!r} is not a valid {param.kind}.") from None
        if param.kind == "choice" and param.choices and value not in param.choices(conn):
            raise EditError(f"{key}: {value!r} is not one of {', '.join(param.choices(conn))}.")
        clean[key] = value
    return clean


def run(conn: psycopg.Connection, name: str, address: str, params: dict[str, Any] | None = None,
        via: str = "web", dry_run: bool = False) -> Change:
    """Make one change and record it. With dry_run the change is shown, not kept."""
    if name not in OPERATIONS:
        raise EditError(f"There is no operation {name!r}.")
    if via not in DOORS:
        raise ValueError(f"unknown door {via!r}")
    conn.row_factory = dict_row
    try:
        with conn.transaction(force_rollback=dry_run):
            entity = target(conn, address)
            clean = _check(conn, name, params or {})
            before, after = OPERATIONS[name].run(conn, entity, **clean)
            label = f"{entity['address']} {entity['title'] or ''}".strip()
            if before != after:
                conn.execute(
                    """
                    INSERT INTO core.change_log (via, operation, entity_id, entity_label, before, after)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    """,
                    (via, name, entity["id"], label,
                     None if before is None else json.dumps(before), None if after is None else json.dumps(after)),
                )
    except psycopg.errors.IntegrityError as error:
        constraint = error.diag.constraint_name or ""
        raise EditError(REFUSALS.get(constraint, f"The database refused it ({constraint or error.diag.message_primary}).")) from None
    except psycopg.errors.RaiseException as error:
        # the database's own validators already say what is wrong ("partial_date: month out of range ...")
        message = error.diag.message_primary or ""
        if message.startswith("partial_date:"):
            raise EditError(f"{REFUSALS['partial_date_ck']} ({message.split(':', 1)[1].strip()})") from None
        raise EditError(message) from None
    except psycopg.errors.DataError as error:
        raise EditError(f"The database refused a value: {error.diag.message_primary}.") from None
    return Change(name, entity["address"], label, before, after, kept=not dry_run)


def recent_changes(conn: psycopg.Connection, limit: int = 50, address: str | None = None) -> list[dict[str, Any]]:
    """The latest changes, newest first; for one entity when an address is given."""
    conn.row_factory = dict_row
    entity_id = target(conn, address)["id"] if address else None
    return conn.execute(
        """
        SELECT id, changed_at, via, operation, entity_label, before, after
          FROM core.change_log
         WHERE %(entity)s::bigint IS NULL OR entity_id = %(entity)s
         ORDER BY changed_at DESC, id DESC
         LIMIT %(limit)s
        """,
        {"entity": entity_id, "limit": limit},
    ).fetchall()


def tool_definitions(conn: psycopg.Connection) -> list[dict[str, Any]]:
    """The operations as tool definitions (JSON Schema), for a chat that edits through them."""
    types = {"points": "integer", "count": "integer", "number": "number", "text": "string", "date": "string", "choice": "string"}
    tools = []
    for name, operation in OPERATIONS.items():
        properties: dict[str, Any] = {"address": {"type": "string", "description": "The entity's address, e.g. /01/0001/001."}}
        for key, param in operation.params.items():
            prop: dict[str, Any] = {"type": types[param.kind], "description": param.description}
            if param.kind == "points":
                prop.update(minimum=-50, maximum=50)
            if param.choices:
                prop["enum"] = param.choices(conn)
            properties[key] = prop
        required = ["address", *[k for k, p in operation.params.items() if p.required]]
        tools.append({"name": name, "description": operation.description,
                      "parameters": {"type": "object", "properties": properties, "required": required}})
    return tools
