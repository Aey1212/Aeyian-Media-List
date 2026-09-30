"""Edit AML from the terminal: the same operations as the web editor and the admin chat.

    python -m app.tools.edit set_score /01/0003/001 general=40
    python -m app.tools.edit set_take /01/0003/001 body="The best romcom ending." written_on=2026-10
    python -m app.tools.edit set_progress /01/0003/001 status=completed hours=10.5
    python -m app.tools.edit set_progress /01/0003/001 times_completed=     (empty clears a field)
    python -m app.tools.edit clear_score /01/0003/001 --dry-run            (show, keep nothing)
    python -m app.tools.edit ops                                           (the operations and their fields)
    python -m app.tools.edit log [/01/0003/001] [-n 20]                    (the change log)
    python -m app.tools.edit tools                                         (definitions for a chat, as JSON)

Scores are the stored points, -50..+50. Every change lands in the change log as "terminal".
Uses AML_EDIT_DATABASE_URL, else AML_DATABASE_URL.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import psycopg
from psycopg.rows import dict_row

from app.config import DEV_DATABASE_URL
from app.edit.operations import OPERATIONS, EditError, recent_changes, run, tool_definitions


def _url() -> str:
    return os.environ.get("AML_EDIT_DATABASE_URL", os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL))


def _show(value) -> str:
    if value is None:
        return "nothing"
    return ", ".join(f"{k} {v}" for k, v in value.items() if v is not None) or "nothing"


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 1
    command, rest = argv[0], argv[1:]

    with psycopg.connect(_url(), row_factory=dict_row, autocommit=True) as conn:
        if command == "ops":
            for name, operation in OPERATIONS.items():
                fields = " ".join(f"{k}{'' if p.required else '?'}" for k, p in operation.params.items())
                print(f"{name:16} ADDRESS {fields}".rstrip() + f"\n{'':16} {operation.description}")
            return 0
        if command == "tools":
            print(json.dumps(tool_definitions(conn), ensure_ascii=False, indent=2))
            return 0
        if command == "log":
            parser = argparse.ArgumentParser(prog="python -m app.tools.edit log")
            parser.add_argument("address", nargs="?")
            parser.add_argument("-n", type=int, default=20)
            args = parser.parse_args(rest)
            try:
                changes = recent_changes(conn, limit=args.n, address=args.address)
            except EditError as error:
                print(error, file=sys.stderr)
                return 1
            for c in reversed(changes):
                print(f"{c['changed_at']:%Y/%m/%d %H:%M}  {c['via']:8} {c['operation']:16} {c['entity_label']}\n"
                      f"{'':17}{_show(c['before'])}  ->  {_show(c['after'])}")
            return 0

        if command not in OPERATIONS:
            print(f"There is no operation {command!r}. See: python -m app.tools.edit ops", file=sys.stderr)
            return 1
        dry_run = "--dry-run" in rest
        rest = [a for a in rest if a != "--dry-run"]
        if not rest:
            print(f"{command} needs an address, e.g. /01/0003/001", file=sys.stderr)
            return 1
        address, pairs = rest[0], rest[1:]
        params = {}
        for pair in pairs:
            if "=" not in pair:
                print(f"{pair!r}: write fields as name=value", file=sys.stderr)
                return 1
            key, value = pair.split("=", 1)
            params[key] = value
        try:
            change = run(conn, command, address, params, via="terminal", dry_run=dry_run)
        except EditError as error:
            print(error, file=sys.stderr)
            return 1
    print(f"{change.operation} {change.label}\n  {_show(change.before)}  ->  {_show(change.after)}"
          + ("" if change.kept else "\n  (dry run: nothing kept)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
