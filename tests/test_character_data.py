"""The character page data, read from the seeded dev database.

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
from app.data.character import load_character

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
MAKOTO = "/22/0001"


@pytest.fixture(scope="module")
def conn():
    try:
        connection = psycopg.connect(URL, row_factory=dict_row, autocommit=True, connect_timeout=3)
    except psycopg.OperationalError:
        pytest.skip(f"dev database not reachable at {URL}: run db/dev.sh up && db/dev.sh seed")
    with connection:
        if resolve(connection, MAKOTO) is None:
            pytest.skip("dev database is not seeded: run db/dev.sh up && db/dev.sh seed")
        yield connection


def entity(conn, address):
    return resolve(conn, address)["entity_id"]


def test_names_and_titles(conn):
    page = load_character(conn, entity(conn, MAKOTO), "en")
    assert (page["address"], page["kind"], page["title"], page["native_title"], page["native_lang"]) == (
        MAKOTO, "Character", "Makoto Yuki", "結城理", "ja",
    )
    assert [(t["lang"], t["text"], t["native"]) for t in page["titles"]] == [("ja", "結城理", True), ("en", "Makoto Yuki", False)]
    assert (page["description"], page["picture"]) == (None, None)


def work(title, address, year, **extra):
    return {"title": title, "address": address, "kind": "Game", "year": year, **extra}


P3 = ("Persona 3", "/04/0001/001", "2006")
P5R = ("Persona 5 Royal", "/04/0001/003", "2019")
P3R = ("Persona 3 Reload", "/04/0001/002", "2024")


def test_appearances_in_several_games_oldest_first_with_their_own_roles(conn):
    page = load_character(conn, entity(conn, MAKOTO), "en")
    assert page["appearances"] == [
        work(*P3, picture=None, roles=["Protagonist"], note=None),
        work(*P5R, picture=None, roles=["Boss"], note="Optional"),
        work(*P3R, picture=None, roles=["Protagonist"], note=None),
    ]


def test_one_voice_actor_card_per_person_listing_every_game(conn):
    cast = load_character(conn, entity(conn, MAKOTO), "en")["cast"]
    voice = {"type": "Voice", "type_code": "voice", "note": None}
    assert [(c["title"], c["native_title"], c["lang"], c["types"], c["works"], c["picture"]) for c in cast] == [
        # the oldest game's cast first, its original language (Japanese) first
        ("Akira Ishida", "石田彰", "ja", ["Voice"], [work(*P3, **voice), work(*P5R, **voice), work(*P3R, **voice)], None),
        ("Yuri Lowenthal", None, "en", ["Voice"], [work(*P3, **voice)], None),
        ("Aleks Le", None, "en", ["Voice"], [work(*P5R, **voice), work(*P3R, **voice)], None),
    ]
    assert all(c["address"].startswith("/23/") for c in cast)


def test_a_performance_without_an_appearance_still_shows(conn):
    yukari, p5r = entity(conn, "/22/0002"), entity(conn, "/04/0001/003")
    with conn.transaction(force_rollback=True):
        actor = conn.execute(
            "SELECT person_id FROM core.performance WHERE character_id = %s AND lang = 'ja' LIMIT 1", (yukari,)
        ).fetchone()["person_id"]
        conn.execute(
            "INSERT INTO core.performance (person_id, character_id, target_id, target_kind, performance_type, lang) VALUES (%s, %s, %s, 'game', 'voice', 'ja')",
            (actor, yukari, p5r),
        )
        page = load_character(conn, yukari, "en")
        assert [(a["title"], a["roles"]) for a in page["appearances"]] == [
            ("Persona 3", ["Main"]), ("Persona 5 Royal", []), ("Persona 3 Reload", ["Main"]),
        ]
        assert [w["title"] for w in page["cast"][0]["works"]] == ["Persona 3", "Persona 5 Royal", "Persona 3 Reload"]


def test_unpublished_targets_are_left_out(conn):
    makoto, p5r = entity(conn, MAKOTO), entity(conn, "/04/0001/003")
    with conn.transaction(force_rollback=True):
        conn.execute("UPDATE core.entity SET published_at = NULL WHERE id = %s", (p5r,))
        page = load_character(conn, makoto, "en")
        assert [a["title"] for a in page["appearances"]] == ["Persona 3", "Persona 3 Reload"]
        assert [(c["title"], [w["title"] for w in c["works"]]) for c in page["cast"]] == [
            ("Akira Ishida", ["Persona 3", "Persona 3 Reload"]),
            ("Yuri Lowenthal", ["Persona 3"]),
            ("Aleks Le", ["Persona 3 Reload"]),
        ]


def test_description_in_the_page_language_first(conn):
    makoto = entity(conn, MAKOTO)
    with conn.transaction(force_rollback=True):
        conn.execute(
            "INSERT INTO core.entity_text (entity_id, text_type, lang, body) VALUES (%s, 'description', 'ja', '月光館学園の転校生。'), (%s, 'description', 'en', 'A transfer student at Gekkoukan High.')",
            (makoto, makoto),
        )
        assert load_character(conn, makoto, "en")["description"] == {"lang": "en", "body": "A transfer student at Gekkoukan High."}
        assert load_character(conn, makoto, "ja")["description"]["lang"] == "ja"


def test_portrait_and_aey_data(conn):
    makoto = entity(conn, MAKOTO)
    with conn.transaction(force_rollback=True):
        conn.execute("INSERT INTO core.image (entity_id, image_type, sha256, format, is_primary) VALUES (%s, 'portrait', repeat('d', 64), 'png', true)", (makoto,))
        ishida = conn.execute("SELECT person_id FROM core.performance WHERE character_id = %s AND lang = 'ja'", (makoto,)).fetchone()["person_id"]
        conn.execute("INSERT INTO core.image (entity_id, image_type, sha256, format, is_primary) VALUES (%s, 'portrait', repeat('e', 64), 'jpg', true)", (ishida,))
        conn.execute("INSERT INTO aey.score (entity_id, entity_kind, general) VALUES (%s, 'character', 45)", (makoto,))
        page = load_character(conn, makoto, "en")
        assert page["picture"] == "/media/" + "d" * 64 + ".png"
        assert [c["picture"] for c in page["cast"]] == ["/media/" + "e" * 64 + ".jpg", None, None]
        assert page["aey"]["score"] == {"general": 45, "shown": "+9.0", "half_stars": 9}
        assert page["aey"]["progress"] is None


def test_no_page_for_other_kinds_unknown_or_drafts(conn):
    assert load_character(conn, entity(conn, "/04/0001/002"), "en") is None
    assert load_character(conn, 999_999_999, "en") is None
    with conn.transaction(force_rollback=True):
        draft = conn.execute("SELECT core.create_entity('character') AS id").fetchone()["id"]
        assert load_character(conn, draft, "en") is None
