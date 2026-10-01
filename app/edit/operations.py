"""The edit operations: the only way AML's data is changed by hand.

Every door (the web editor, the admin chat, terminal commands) calls `run()` with an
operation name, the address of the entity it is about and its parameters. `run()` checks
the parameters, makes the change in one transaction, records it in core.change_log (what
changed, from what to what, when, through which door) and returns the change. With
`dry_run=True` nothing is kept: the chat uses that to show a change before Aey confirms it.

The operations themselves live in app/edit/aey.py (Aey's own data: scores in stored
points, -50..+50, Take, progress) and app/edit/entities.py (creating entities, names,
facts, texts, origins, pictures).
"""

from __future__ import annotations

import json
from typing import Any

import psycopg
from psycopg.rows import dict_row

from app.edit.aey import AEY_OPERATIONS, CATEGORIES, STATUSES, UNITS  # noqa: F401 (the editor uses these)
from app.edit.base import DOORS, Change, EditError, Operation, Param, plain, target  # noqa: F401
from app.edit.entities import ENTITY_OPERATIONS

OPERATIONS: dict[str, Operation] = {**AEY_OPERATIONS, **ENTITY_OPERATIONS}

# what the database's own refusals mean, in words
REFUSALS = {
    "score_50_ck": "Points go from -50 to +50.",
    "partial_date_ck": "Dates are YYYY, YYYY-MM or YYYY-MM-DD, and must be real dates.",
    "progress_dates_order_ck": "It can't be finished before it was started.",
    "progress_value_needs_unit_ck": "Say what the progress counts: episodes, chapters or volumes.",
    "lang_tag_ck": "That isn't a language tag (en, ja, tr, pt-BR ...).",
    "country_code_ck": "Countries are two capital letters, like JP or TR.",
    "title_text_ck": "A name can't be empty.",
    "title_text_uq": "That name is already there, in that language and type.",
    "title_latinizes_fk": "A latinized name and the name it spells out stay together (same page, same type): "
                          "remove the latinized one first, or pick a name of this page.",
    "title_latinized_latin_ck": "A latinized name needs a Latin-script language tag, like ja-Latn.",
    "title_latinized_not_native_ck": "A latinized name can't be the native one.",
    "title_latinizes_self_ck": "A name can't spell out itself.",
    "work_status_allowed_fk": "That status doesn't apply to this medium.",
    "work_dates_order_ck": "It can't end before it started.",
    "game_local_players_range_ck": "The fewest local players can't be more than the most.",
    "game_online_players_range_ck": "The fewest online players can't be more than the most.",
    "entity_original_language_allowed_fk": "Original languages are kept for works only.",
    "entity_origin_country_allowed_fk": "Countries of origin are kept for works only.",
    "entity_text_body_ck": "A text can't be empty; clear it instead.",
}

# refusals raised by the database's own checks, recognised by how their message starts
MESSAGES = {
    "publish:": "A published page needs at least one name.",
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
        if param.kind == "bool":
            if isinstance(value, bool):
                clean[key] = value
            elif str(value).lower() in ("1", "true", "on", "yes"):
                clean[key] = True
            elif str(value).lower() in ("", "0", "false", "off", "no"):
                clean[key] = False
            else:
                raise EditError(f"{key}: {value!r} is not yes or no.")
            continue
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
            elif param.kind == "id":
                value = int(value)
                if value <= 0:
                    raise ValueError
            elif param.kind == "address":
                value = str(value)
                if not value.startswith("/"):
                    raise ValueError
            elif param.kind in ("text", "date", "choice", "file"):
                value = str(value)
        except (TypeError, ValueError):
            raise EditError(f"{key}: {value!r} is not a valid {param.kind}.") from None
        if param.kind == "choice" and param.choices and value not in param.choices(conn):
            raise EditError(f"{key}: {value!r} is not one of {', '.join(param.choices(conn))}.")
        clean[key] = value
    return clean


def run(conn: psycopg.Connection, name: str, address: str | None, params: dict[str, Any] | None = None,
        via: str = "web", dry_run: bool = False) -> Change:
    """Make one change and record it. With dry_run the change is shown, not kept.

    `address` is the entity the change is about; an operation that creates an entity
    takes none, and the change carries the new entity's address."""
    if name not in OPERATIONS:
        raise EditError(f"There is no operation {name!r}.")
    if via not in DOORS:
        raise ValueError(f"unknown door {via!r}")
    operation = OPERATIONS[name]
    conn.row_factory = dict_row
    try:
        with conn.transaction(force_rollback=dry_run):
            clean = _check(conn, name, params or {})
            if operation.creates:
                before, after, entity = operation.run(conn, **clean)
            else:
                if not address:
                    raise EditError(f"{name} needs the address of what it changes.")
                entity = target(conn, address)
                before, after = operation.run(conn, entity, **clean)
            # rules the database checks at commit (a published page needs a name) are checked
            # now, so a refusal reaches the door as words, and a dry run is refused the same way
            conn.execute("SET CONSTRAINTS ALL IMMEDIATE")
            entity = target(conn, entity["address"])   # its name may have just changed
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
    except (psycopg.errors.IntegrityError, psycopg.errors.RaiseException) as error:
        raise EditError(_refusal(error)) from None
    except psycopg.errors.DataError as error:
        raise EditError(f"The database refused a value: {error.diag.message_primary}.") from None
    return Change(name, entity["address"], label, before, after, kept=not dry_run)


def _refusal(error: psycopg.Error) -> str:
    """The database's refusal in words."""
    constraint = error.diag.constraint_name or ""
    message = error.diag.message_primary or ""
    if constraint in REFUSALS:
        return REFUSALS[constraint]
    if message.startswith("partial_date:"):
        # the date validator already says what is wrong ("month out of range in ...")
        return f"{REFUSALS['partial_date_ck']} ({message.split(':', 1)[1].strip()})"
    for start, words in MESSAGES.items():
        if message.startswith(start):
            return words
    if isinstance(error, psycopg.errors.RaiseException):
        return message
    return f"The database refused it ({constraint or message})."


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
    types = {"points": "integer", "count": "integer", "number": "number", "text": "string", "date": "string",
             "choice": "string", "bool": "boolean", "id": "integer", "address": "string", "file": "string"}
    tools = []
    for name, operation in OPERATIONS.items():
        properties: dict[str, Any] = {} if operation.creates else {
            "address": {"type": "string", "description": "The entity's address, e.g. /01/0001/001."}}
        for key, param in operation.params.items():
            prop: dict[str, Any] = {"type": types[param.kind], "description": param.description}
            if param.kind == "points":
                prop.update(minimum=-50, maximum=50)
            if param.choices:
                prop["enum"] = param.choices(conn)
            properties[key] = prop
        required = ([] if operation.creates else ["address"]) + [k for k, p in operation.params.items() if p.required]
        tools.append({"name": name, "description": operation.description,
                      "parameters": {"type": "object", "properties": properties, "required": required}})
    return tools
