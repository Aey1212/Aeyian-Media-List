"""The edit operations, against the dev database. Every check is rolled back.

Needs: db/dev.sh up && db/dev.sh seed && db/dev.sh content.
"""

from __future__ import annotations

import os

import psycopg
import pytest
from psycopg.rows import dict_row

from app.config import DEV_DATABASE_URL
from app.edit.operations import EditError, recent_changes, run, tool_definitions

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
TORADORA = "/01/0003/001"    # the anime, no score yet
P3R = "/04/0001/002"         # sample score +32
MEGURO = "/23/00001"         # a person: not rateable
TAIGA = "/22/0008"           # a character: rateable, no progress


@pytest.fixture(scope="module")
def conn():
    try:
        connection = psycopg.connect(URL, row_factory=dict_row, autocommit=True, connect_timeout=3)
    except psycopg.OperationalError:
        pytest.skip(f"dev database not reachable at {URL}: run db/dev.sh up")
    with connection:
        if connection.execute("SELECT count(*) AS n FROM core.resolve(%s)", (TORADORA,)).fetchone()["n"] != 1:
            pytest.skip("Toradora content is not loaded: run db/dev.sh content")
        yield connection


@pytest.fixture()
def rollback(conn):
    with conn.transaction(force_rollback=True):
        yield conn


def log(conn, address):
    return conn.execute(
        """
        SELECT via, operation, entity_label, before, after FROM core.change_log
         WHERE entity_id = (SELECT entity_id FROM core.resolve(%s)) ORDER BY id
        """,
        (address,),
    ).fetchall()


# --- General Score ------------------------------------------------------------

def test_a_new_score_is_stored_and_logged(rollback):
    change = run(rollback, "set_score", TORADORA, {"general": 40}, via="web")
    assert (change.before, change.after, change.kept) == (None, {"general": 40, "rated_on": None}, True)
    assert change.label == "/01/0003/001 Toradora!"
    assert rollback.execute("SELECT general FROM aey.score WHERE entity_id = (SELECT entity_id FROM core.resolve(%s))",
                            (TORADORA,)).fetchone()["general"] == 40
    assert log(rollback, TORADORA) == [
        {"via": "web", "operation": "set_score", "entity_label": "/01/0003/001 Toradora!",
         "before": None, "after": {"general": 40, "rated_on": None}},
    ]


def test_changing_a_score_records_the_old_one(rollback):
    change = run(rollback, "set_score", P3R, {"general": "45", "rated_on": "2024-03"}, via="terminal")
    assert (change.before, change.after) == ({"general": 32, "rated_on": None}, {"general": 45, "rated_on": "2024-03"})
    assert log(rollback, P3R)[-1]["via"] == "terminal"


def test_setting_the_same_score_again_logs_nothing(rollback):
    run(rollback, "set_score", P3R, {"general": 32})
    assert log(rollback, P3R) == []


def test_clearing_a_score(rollback):
    change = run(rollback, "clear_score", P3R, via="chat")
    assert (change.before, change.after) == ({"general": 32, "rated_on": None}, None)
    assert log(rollback, P3R)[-1] | {"entity_label": None} == {
        "via": "chat", "operation": "clear_score", "entity_label": None, "before": {"general": 32, "rated_on": None}, "after": None,
    }


@pytest.mark.parametrize(("params", "message"), [
    ({"general": 51}, r"points go from -50 to \+50, not 51"),
    ({"general": -51}, r"points go from -50 to \+50, not -51"),
    ({"general": "3.5"}, "is not a valid points"),
    ({"general": "high"}, "is not a valid points"),
    ({}, "set_score needs general"),
    ({"general": 10, "mood": "happy"}, "set_score has no mood"),
    ({"general": 10, "rated_on": "2024-13"}, "Dates are YYYY, YYYY-MM or YYYY-MM-DD"),
])
def test_bad_scores_are_refused_in_words(rollback, params, message):
    with pytest.raises(EditError, match=message):
        run(rollback, "set_score", TORADORA, params)
    assert log(rollback, TORADORA) == []


def test_things_that_cannot_be_rated_or_do_not_exist(rollback):
    with pytest.raises(EditError, match="A Person can't be rated"):
        run(rollback, "set_score", MEGURO, {"general": 10})
    with pytest.raises(EditError, match="Nothing lives at /01/0ZZZ/001"):
        run(rollback, "set_score", "/01/0ZZZ/001", {"general": 10})
    with pytest.raises(EditError, match="no operation 'set_mood'"):
        run(rollback, "set_mood", TORADORA, {})


def test_a_dry_run_shows_the_change_and_keeps_nothing(rollback):
    change = run(rollback, "set_score", TORADORA, {"general": 12}, via="chat", dry_run=True)
    assert (change.before, change.after, change.kept) == (None, {"general": 12, "rated_on": None}, False)
    assert rollback.execute("SELECT count(*) AS n FROM aey.score WHERE entity_id = (SELECT entity_id FROM core.resolve(%s))",
                            (TORADORA,)).fetchone()["n"] == 0
    assert log(rollback, TORADORA) == []


# --- subratings, Take ---------------------------------------------------------

def test_subratings(rollback):
    change = run(rollback, "set_subrating", TORADORA, {"category": "characters", "value": 44})
    assert change.after == {"category": "characters", "value": 44}
    with pytest.raises(EditError, match="'vibes' is not one of story, characters"):
        run(rollback, "set_subrating", TORADORA, {"category": "vibes", "value": 1})
    assert run(rollback, "clear_subrating", TORADORA, {"category": "characters"}).after is None


def test_takes_per_language(rollback):
    run(rollback, "set_take", TORADORA, {"body": "  The best romcom ending.  ", "written_on": "2026-10"})
    run(rollback, "set_take", TORADORA, {"body": "En iyi romantik komedi sonu.", "lang": "tr"})
    rows = rollback.execute(
        "SELECT lang, body, written_on FROM aey.take WHERE entity_id = (SELECT entity_id FROM core.resolve(%s)) ORDER BY lang",
        (TORADORA,),
    ).fetchall()
    assert rows == [
        {"lang": "en", "body": "The best romcom ending.", "written_on": "2026-10"},
        {"lang": "tr", "body": "En iyi romantik komedi sonu.", "written_on": None},
    ]
    with pytest.raises(EditError, match="needs body"):
        run(rollback, "set_take", TORADORA, {"body": "   "})
    with pytest.raises(EditError, match="language tag"):
        run(rollback, "set_take", TORADORA, {"body": "x", "lang": "English"})
    assert run(rollback, "clear_take", TORADORA, {"lang": "tr"}).before["lang"] == "tr"


def test_a_character_can_be_rated(rollback):
    assert run(rollback, "set_score", TAIGA, {"general": 50}).after["general"] == 50


# --- progress -------------------------------------------------------------------

def test_progress_changes_only_what_is_given(rollback):
    run(rollback, "set_progress", TORADORA, {"status": "completed", "progress_value": 25, "progress_unit": "episode"})
    change = run(rollback, "set_progress", TORADORA, {"hours": "10.5", "times_completed": 2})
    assert change.after == {
        "status": "completed", "progress_value": 25, "progress_unit": "episode", "started_on": None,
        "finished_on": None, "times_completed": 2, "hours": 10.5, "note": None,
    }
    cleared = run(rollback, "set_progress", TORADORA, {"times_completed": ""})   # an empty field clears it
    assert cleared.after["times_completed"] is None and cleared.after["status"] == "completed"


def test_progress_refusals(rollback):
    with pytest.raises(EditError, match="Progress isn't kept for a Character"):
        run(rollback, "set_progress", TAIGA, {"status": "completed"})
    with pytest.raises(EditError, match="finished before it was started"):
        run(rollback, "set_progress", TORADORA, {"started_on": "2009-03", "finished_on": "2008-10"})
    with pytest.raises(EditError, match="Say what the progress counts"):
        run(rollback, "set_progress", TORADORA, {"progress_value": 3})
    with pytest.raises(EditError, match="'binged' is not one of planning"):
        run(rollback, "set_progress", TORADORA, {"status": "binged"})


# --- history and the chat's view ------------------------------------------------

def test_recent_changes_newest_first(rollback):
    run(rollback, "set_score", TORADORA, {"general": 10})
    run(rollback, "set_score", TORADORA, {"general": 20})
    changes = recent_changes(rollback, address=TORADORA)
    assert [c["after"]["general"] for c in changes] == [20, 10]
    assert changes[0]["before"] == {"general": 10, "rated_on": None}


def test_tool_definitions_for_a_chat(conn):
    tools = {t["name"]: t for t in tool_definitions(conn)}
    assert set(tools) >= {"set_score", "clear_score", "set_subrating", "clear_subrating",
                          "set_take", "clear_take", "set_progress", "clear_progress"}
    assert tools["create"]["parameters"]["required"] == ["kind", "title"]   # creating needs no address
    score = tools["set_score"]["parameters"]
    assert score["required"] == ["address", "general"]
    assert score["properties"]["general"] | {"description": None} == {"type": "integer", "minimum": -50, "maximum": 50, "description": None}
    assert "characters" in tools["set_subrating"]["parameters"]["properties"]["category"]["enum"]
