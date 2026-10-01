"""Terminal edits, against the dev database; each test cleans up the Toradora! anime.

Needs: db/dev.sh up && db/dev.sh seed && db/dev.sh content.
"""

from __future__ import annotations

import json
import os

import psycopg
import pytest

from app.config import DEV_DATABASE_URL
from app.tools.edit import main

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
TORADORA = "/01/0003/001"


@pytest.fixture()
def clean(monkeypatch):
    monkeypatch.setenv("AML_EDIT_DATABASE_URL", URL)
    try:
        db = psycopg.connect(URL, autocommit=True, connect_timeout=3)
    except psycopg.OperationalError:
        pytest.skip(f"dev database not reachable at {URL}: run db/dev.sh up")
    with db:
        if db.execute("SELECT count(*) FROM core.resolve(%s)", (TORADORA,)).fetchone()[0] != 1:
            pytest.skip("Toradora content is not loaded: run db/dev.sh content")
        start = db.execute("SELECT coalesce(max(id), 0) FROM core.change_log").fetchone()[0]
        yield db
        toradora = db.execute("SELECT entity_id FROM core.resolve(%s)", (TORADORA,)).fetchone()[0]
        for table in ("aey.score", "aey.subrating", "aey.take", "aey.progress"):
            db.execute(f"DELETE FROM {table} WHERE entity_id = %s", (toradora,))
        db.execute("DELETE FROM core.change_log WHERE id > %s", (start,))


def score(db):
    row = db.execute("SELECT general FROM aey.score WHERE entity_id = (SELECT entity_id FROM core.resolve(%s))", (TORADORA,)).fetchone()
    return row[0] if row else None


def test_set_a_score_from_the_terminal(clean, capsys):
    assert main(["set_score", TORADORA, "general=40"]) == 0
    assert capsys.readouterr().out == "set_score /01/0003/001 Toradora!\n  nothing  ->  general 40\n"
    assert score(clean) == 40
    assert clean.execute("SELECT via FROM core.change_log ORDER BY id DESC LIMIT 1").fetchone()[0] == "terminal"


def test_a_dry_run_keeps_nothing(clean, capsys):
    assert main(["set_score", TORADORA, "general=12", "--dry-run"]) == 0
    assert "(dry run: nothing kept)" in capsys.readouterr().out
    assert score(clean) is None


def test_text_with_spaces_and_clearing_a_field(clean, capsys):
    assert main(["set_take", TORADORA, "body=The best romcom ending.", "written_on=2026-10"]) == 0
    assert main(["set_progress", TORADORA, "status=completed", "times_completed=2"]) == 0
    assert main(["set_progress", TORADORA, "times_completed="]) == 0
    out = capsys.readouterr().out
    assert "body The best romcom ending., written_on 2026-10" in out
    assert out.rstrip().endswith("->  status completed")


def test_refusals_are_plain_and_exit_1(clean, capsys):
    assert main(["set_score", TORADORA, "general=99"]) == 1
    assert "general: points go from -50 to +50, not 99." in capsys.readouterr().err
    assert main(["set_score", "/23/00001", "general=1"]) == 1
    assert "A Person can't be rated." in capsys.readouterr().err
    assert main(["set_mood", TORADORA]) == 1
    assert "There is no operation 'set_mood'" in capsys.readouterr().err
    assert main(["set_score", TORADORA, "40"]) == 1
    assert "write fields as name=value" in capsys.readouterr().err
    assert score(clean) is None


def test_the_log_ops_and_chat_tools(clean, capsys):
    main(["set_score", TORADORA, "general=10"])
    main(["set_score", TORADORA, "general=20"])
    capsys.readouterr()
    assert main(["log", TORADORA, "-n", "2"]) == 0
    log = capsys.readouterr().out
    assert log.index("general 10") < log.index("general 20")   # oldest first, like reading a history
    assert main(["ops"]) == 0
    assert "set_score        ADDRESS general rated_on?" in capsys.readouterr().out
    assert main(["tools"]) == 0
    tools = json.loads(capsys.readouterr().out)
    assert {t["name"] for t in tools} >= {"set_score", "set_take", "set_progress"}


def test_creating_needs_no_address(clean, capsys):
    last = clean.execute("SELECT max(id) FROM core.entity").fetchone()[0]
    try:
        assert main(["create", "kind=character", "title=Terminal Person"]) == 0
        out = capsys.readouterr().out
        assert out.startswith("create /22/") and "kind character, title Terminal Person" in out
        assert main(["ops"]) == 0
        assert "create           kind title lang? franchise?" in capsys.readouterr().out
    finally:
        clean.execute("DELETE FROM core.entity WHERE id > %s", (last,))
