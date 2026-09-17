"""The franchise page data, read from the seeded dev database.

Needs: db/dev.sh up && db/dev.sh seed. Skips when the dev database is not reachable.
Checks that add rows do it inside a transaction that is rolled back.
"""

from __future__ import annotations

import os

import psycopg
import pytest
from psycopg.rows import dict_row

from app.config import DEV_DATABASE_URL
from app.data.address import resolve
from app.data.franchise import load_franchise

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
PERSONA = "/21/0001"
SMT = "/21/0002"


@pytest.fixture(scope="module")
def conn():
    try:
        connection = psycopg.connect(URL, row_factory=dict_row, autocommit=True, connect_timeout=3)
    except psycopg.OperationalError:
        pytest.skip(f"dev database not reachable at {URL}: run db/dev.sh up && db/dev.sh seed")
    with connection:
        if resolve(connection, "/04/0001/003") is None:
            pytest.skip("dev database is not seeded: run db/dev.sh up && db/dev.sh seed")
        yield connection


def entity(conn, address):
    return resolve(conn, address)["entity_id"]


def new_franchise(conn, name):
    f = conn.execute("SELECT core.create_entity('franchise') AS id").fetchone()["id"]
    conn.execute("INSERT INTO core.title (entity_id, lang, title_type, text) VALUES (%s, 'en', 'full', %s)", (f, name))
    conn.execute("UPDATE core.entity SET published_at = now() WHERE id = %s", (f,))
    return f


def test_names_and_lineage_without_a_relationship_label(conn):
    page = load_franchise(conn, entity(conn, PERSONA), "en")
    assert (page["address"], page["kind"], page["title"], page["native_title"], page["picture"]) == (
        PERSONA, "Franchise", "Persona", "ペルソナ", None,
    )
    assert page["parents"] == [{"title": "Shin Megami Tensei", "address": SMT}]
    assert page["related"] == []   # the parent is the lineage, not a "Main work" row


def test_the_parent_franchise_lists_its_spin_off_as_a_tag(conn):
    page = load_franchise(conn, entity(conn, SMT), "en")
    assert page["parents"] == []
    assert page["related"] == [{"label": "Spin-off", "title": "Persona", "address": PERSONA, "note": None}]
    # intended: a spin-off franchise's works do not roll up into the franchise above it
    assert (page["works"], page["characters"]) == ([], [])


def test_works_oldest_first(conn):
    works = load_franchise(conn, entity(conn, PERSONA), "en")["works"]
    assert [(w["title"], w["address"], w["kind"], w["year"], w["roles"]) for w in works] == [
        ("Persona 3", "/04/0001/001", "Game", "2006", []),
        ("Persona 5 Royal", "/04/0001/003", "Game", "2019", []),
        ("Persona 3 Reload", "/04/0001/002", "Game", "2024", []),
    ]


def test_characters_in_first_appearance_order_then_name(conn):
    characters = load_franchise(conn, entity(conn, PERSONA), "en")["characters"]
    # all six first appear in Persona 3 (2006), so they sort by name
    assert [(c["title"], c["native_title"], c["address"][:4]) for c in characters] == [
        ("Aigis", "アイギス", "/22/"),
        ("Akihiko Sanada", "真田明彦", "/22/"),
        ("Junpei Iori", "伊織順平", "/22/"),
        ("Makoto Yuki", "結城理", "/22/"),
        ("Mitsuru Kirijo", "桐条美鶴", "/22/"),
        ("Yukari Takeba", "岳羽ゆかり", "/22/"),
    ]


def test_characters_under_child_entities_and_extra_members_count(conn):
    persona, smt = entity(conn, PERSONA), entity(conn, SMT)
    dlc = entity(conn, "/04/0001/002/14/001")
    with conn.transaction(force_rollback=True):
        guest = conn.execute("SELECT core.create_entity('character') AS id").fetchone()["id"]
        conn.execute("INSERT INTO core.title (entity_id, lang, title_type, text) VALUES (%s, 'en', 'full', 'Zz DLC Guest')", (guest,))
        conn.execute("UPDATE core.entity SET published_at = now() WHERE id = %s", (guest,))
        conn.execute("INSERT INTO core.appearance (character_id, target_id, target_kind) VALUES (%s, %s, 'dlc')", (guest, dlc))
        assert load_franchise(conn, persona, "en")["characters"][-1]["title"] == "Zz DLC Guest"   # first seen 2024
        # a Persona game that also belongs to Shin Megami Tensei shows there too
        p3 = entity(conn, "/04/0001/001")
        conn.execute("INSERT INTO core.entity_franchise (entity_id, entity_kind, franchise_id) VALUES (%s, 'game', %s)", (p3, smt))
        page = load_franchise(conn, smt, "en")
        assert [w["title"] for w in page["works"]] == ["Persona 3"]
        assert len(page["characters"]) == 6


def test_two_sided_and_other_relationships(conn):
    persona = entity(conn, PERSONA)
    with conn.transaction(force_rollback=True):
        other = new_franchise(conn, "Catherine")
        low, high = sorted([persona, other])
        conn.execute("INSERT INTO core.franchise_relation (source_id, relation_type, target_id) VALUES (%s, 'crossover', %s)", (low, high))
        side = new_franchise(conn, "Persona Q")
        conn.execute("INSERT INTO core.franchise_relation (source_id, relation_type, target_id, note) VALUES (%s, 'spin_off_of', %s, 'Dungeon crawler')", (side, persona))
        page = load_franchise(conn, persona, "en")
        assert page["parents"] == [{"title": "Shin Megami Tensei", "address": SMT}]
        assert [(r["label"], r["title"], r["note"]) for r in page["related"]] == [
            ("Spin-off", "Persona Q", "Dungeon crawler"),
            ("Crossover", "Catherine", None),
        ]


def test_no_page_for_other_kinds_unknown_or_drafts(conn):
    assert load_franchise(conn, entity(conn, "/24/0001"), "en") is None
    assert load_franchise(conn, 999_999_999, "en") is None
    with conn.transaction(force_rollback=True):
        draft = conn.execute("SELECT core.create_entity('franchise') AS id").fetchone()["id"]
        assert load_franchise(conn, draft, "en") is None
