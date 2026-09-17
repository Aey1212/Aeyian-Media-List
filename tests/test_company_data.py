"""The company page data, read from the seeded dev database.

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
from app.data.company import load_company

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
ATLUS = "/24/0001"
SEGA = "/24/0002"


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


def game(title, address, year, roles):
    return {"title": title, "address": address, "kind": "Game", "year": year, "picture": None, "roles": roles, "note": None}


def test_names(conn):
    page = load_company(conn, entity(conn, ATLUS), "en")
    assert (page["address"], page["kind"], page["title"], page["native_title"], page["native_lang"]) == (
        ATLUS, "Company", "Atlus", "アトラス", "ja",
    )
    assert [(t["lang"], t["text"]) for t in page["titles"]] == [("ja", "アトラス"), ("en", "Atlus")]
    assert (page["description"], page["picture"]) == (None, None)


def test_works_oldest_first_with_every_role_on_one_card(conn):
    assert load_company(conn, entity(conn, ATLUS), "en")["works"] == [
        game("Persona 3", "/04/0001/001", "2006", ["Developer", "Publisher"]),
        game("Persona 5 Royal", "/04/0001/003", "2019", ["Developer"]),
        game("Persona 3 Reload", "/04/0001/002", "2024", ["Developer"]),
    ]
    assert load_company(conn, entity(conn, SEGA), "en")["works"] == [
        game("Persona 3 Reload", "/04/0001/002", "2024", ["Publisher"]),
    ]


def test_logo_note_and_unpublished_works(conn):
    sega, p3r = entity(conn, SEGA), entity(conn, "/04/0001/002")
    with conn.transaction(force_rollback=True):
        conn.execute("INSERT INTO core.image (entity_id, image_type, sha256, format, is_primary) VALUES (%s, 'logo', repeat('a', 64), 'svg', true)", (sega,))
        conn.execute("UPDATE core.company_credit SET note = 'Worldwide' WHERE company_id = %s AND target_id = %s", (sega, p3r))
        page = load_company(conn, sega, "en")
        assert page["picture"] == "/media/" + "a" * 64 + ".svg"
        assert page["works"][0]["note"] == "Worldwide"
        conn.execute("UPDATE core.entity SET published_at = NULL WHERE id = %s", (p3r,))
        assert load_company(conn, sega, "en")["works"] == []


def test_no_page_for_other_kinds_unknown_or_drafts(conn):
    assert load_company(conn, entity(conn, "/23/00001"), "en") is None
    assert load_company(conn, 999_999_999, "en") is None
    with conn.transaction(force_rollback=True):
        draft = conn.execute("SELECT core.create_entity('company') AS id").fetchone()["id"]
        assert load_company(conn, draft, "en") is None
