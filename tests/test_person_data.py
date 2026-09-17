"""The person page data, read from the seeded dev database.

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
from app.data.person import load_person

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
MEGURO = "/23/00001"
ISHIDA = "/23/00002"


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


def voice(title, address, year):
    return {"title": title, "address": address, "kind": "Game", "year": year, "type": "Voice", "type_code": "voice", "lang": "ja", "note": None}


def test_names_with_the_latinized_name(conn):
    page = load_person(conn, entity(conn, MEGURO), "en")
    assert (page["address"], page["kind"], page["title"], page["native_title"], page["native_lang"], page["latinized_title"]) == (
        MEGURO, "Person", "Shoji Meguro", "目黒将司", "ja", "Meguro Shōji",
    )
    assert [(t["lang"], t["text"], t["latinized"]) for t in page["titles"]] == [
        ("ja", "目黒将司", "Meguro Shōji"), ("en", "Shoji Meguro", None),
    ]
    assert (page["description"], page["picture"], page["characters"]) == (None, None, [])


def test_staff_credits_one_entry_per_work_oldest_first(conn):
    page = load_person(conn, entity(conn, MEGURO), "en")
    assert page["staff_credits"] == [
        {"title": "Persona 3", "address": "/04/0001/001", "kind": "Game", "year": "2006", "picture": None, "roles": ["Composer"], "note": None},
        {"title": "Persona 3 Reload", "address": "/04/0001/002", "kind": "Game", "year": "2024", "picture": None, "roles": ["Composer"], "note": None},
    ]


def test_several_roles_on_one_work_share_an_entry(conn):
    meguro, p3r = entity(conn, MEGURO), entity(conn, "/04/0001/002")
    with conn.transaction(force_rollback=True):
        conn.execute("INSERT INTO core.staff_credit (person_id, role, target_id, target_kind, note) VALUES (%s, 'director', %s, 'game', 'Sound')", (meguro, p3r))
        credits = load_person(conn, meguro, "en")["staff_credits"]
        assert [(c["title"], c["roles"], c["note"]) for c in credits] == [
            ("Persona 3", ["Composer"], None),
            ("Persona 3 Reload", ["Director", "Composer"], "Sound"),
        ]


def test_a_voice_actor_character_card_lists_every_work(conn):
    page = load_person(conn, entity(conn, ISHIDA), "en")
    assert page["staff_credits"] == []
    assert [(c["title"], c["native_title"], c["address"], c["picture"], c["works"]) for c in page["characters"]] == [
        ("Makoto Yuki", "結城理", "/22/0001", None, [
            voice("Persona 3", "/04/0001/001", "2006"),
            voice("Persona 5 Royal", "/04/0001/003", "2019"),
            voice("Persona 3 Reload", "/04/0001/002", "2024"),
        ]),
    ]


def test_several_characters_in_the_order_first_played(conn):
    ishida, yukari, p3r = entity(conn, ISHIDA), entity(conn, "/22/0002"), entity(conn, "/04/0001/002")
    with conn.transaction(force_rollback=True):
        conn.execute(
            "INSERT INTO core.performance (person_id, character_id, target_id, target_kind, performance_type, lang) VALUES (%s, %s, %s, 'game', 'voice', 'ja')",
            (ishida, yukari, p3r),
        )
        conn.execute("INSERT INTO core.image (entity_id, image_type, sha256, format, is_primary) VALUES (%s, 'portrait', repeat('f', 64), 'png', true)", (yukari,))
        cards = load_person(conn, ishida, "en")["characters"]
        assert [(c["title"], c["picture"], [w["title"] for w in c["works"]]) for c in cards] == [
            ("Makoto Yuki", None, ["Persona 3", "Persona 5 Royal", "Persona 3 Reload"]),
            ("Yukari Takeba", "/media/" + "f" * 64 + ".png", ["Persona 3 Reload"]),
        ]


def test_unpublished_works_and_characters_are_left_out(conn):
    ishida, p5r, makoto = entity(conn, ISHIDA), entity(conn, "/04/0001/003"), entity(conn, "/22/0001")
    with conn.transaction(force_rollback=True):
        conn.execute("UPDATE core.entity SET published_at = NULL WHERE id = %s", (p5r,))
        assert [w["title"] for w in load_person(conn, ishida, "en")["characters"][0]["works"]] == ["Persona 3", "Persona 3 Reload"]
        conn.execute("UPDATE core.entity SET published_at = NULL WHERE id = %s", (makoto,))
        assert load_person(conn, ishida, "en")["characters"] == []


def test_no_page_for_other_kinds_unknown_or_drafts(conn):
    assert load_person(conn, entity(conn, "/22/0001"), "en") is None
    assert load_person(conn, 999_999_999, "en") is None
    with conn.transaction(force_rollback=True):
        draft = conn.execute("SELECT core.create_entity('person') AS id").fetchone()["id"]
        assert load_person(conn, draft, "en") is None
