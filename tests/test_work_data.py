"""The work page data, read from the seeded dev database.

Needs: db/dev.sh up && db/dev.sh seed. Skips when the dev database is not reachable.
Nothing here writes to it: the one check that creates a row rolls it back.
"""

from __future__ import annotations

import os
from decimal import Decimal

import psycopg
import pytest
from psycopg.rows import dict_row

from app.config import DEV_DATABASE_URL
from app.data.address import resolve
from app.data.work import load_work
from app.labels import format_number, format_partial_date, format_signed, pick_label

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
P3R = "/04/0001/002"


@pytest.fixture(scope="module")
def conn():
    try:
        connection = psycopg.connect(URL, row_factory=dict_row, autocommit=True, connect_timeout=3)
    except psycopg.OperationalError:
        pytest.skip(f"dev database not reachable at {URL}: run db/dev.sh up && db/dev.sh seed")
    with connection:
        if resolve(connection, P3R) is None:
            pytest.skip("dev database is not seeded: run db/dev.sh reset --yes && db/dev.sh up && db/dev.sh seed")
        yield connection


@pytest.fixture(scope="module")
def page(conn):
    return load_work(conn, resolve(conn, P3R)["entity_id"], "en")


# --- display helpers --------------------------------------------------------

def test_pick_label_prefers_language_then_native_then_first():
    labels = {"en": {"text": "Anime", "native": False}, "ja": {"text": "アニメ", "native": True}}
    assert pick_label(labels, "en") == "Anime"
    assert pick_label(labels, "tr") == "アニメ"
    assert pick_label({"tr": {"text": "Dizi", "native": False}}, "en") == "Dizi"
    assert pick_label(None, "en") is None


def test_dates_numbers_and_signs():
    assert format_partial_date("2024-02-02") == "2024/02/02"
    assert format_partial_date("2006") == "2006"
    assert format_number(Decimal("88.000")) == "88"
    assert format_number(Decimal("8.450")) == "8.45"
    assert format_number(Decimal("100")) == "100"
    assert format_signed(Decimal("6.4")) == "+6.4"
    assert format_signed(Decimal("-3.0")) == "−3.0"
    assert format_signed(0) == "0.0"


# --- the page ---------------------------------------------------------------

def test_address_resolves(conn):
    assert resolve(conn, P3R) | {"entity_id": None} == {"entity_id": None, "canonical": P3R, "redirected": False}


def test_title_block(page):
    assert page["title"] == "Persona 3 Reload"
    assert page["native_title"] == "ペルソナ3 リロード"
    assert page["native_lang"] == "ja"
    assert page["latinized_title"] == "Perusona Surī Rirōdo"


def test_kind_status_and_dates(page):
    assert page["address"] == P3R
    assert page["kind"] == "Game"
    assert page["status"] == "Released"
    assert page["start_date"] == "2024/02/02"
    assert page["end_date"] is None
    assert page["source_type"] == "Game"


def test_franchise_with_the_franchise_above_it(page):
    assert page["franchises"] == [{
        "title": "Persona",
        "address": "/21/0001",
        "is_home": True,
        "parents": [{"title": "Shin Megami Tensei", "address": "/21/0002"}],
    }]


def test_franchise_lineage_skips_crossovers_and_stops_on_loops(conn):
    from app.data.common import franchise_lineage

    persona = resolve(conn, "/21/0001")["entity_id"]
    smt = resolve(conn, "/21/0002")["entity_id"]
    with conn.transaction(force_rollback=True):
        top = conn.execute("SELECT core.create_entity('franchise') AS id").fetchone()["id"]
        conn.execute("UPDATE core.entity SET published_at = now() WHERE id = %s", (top,))
        conn.execute("INSERT INTO core.title (entity_id, lang, title_type, text) VALUES (%s, 'en', 'full', 'Megami Tensei')", (top,))
        conn.execute("INSERT INTO core.franchise_relation (source_id, relation_type, target_id) VALUES (%s, 'spin_off_of', %s)", (smt, top))
        assert [p["id"] for p in franchise_lineage(conn, persona)] == [top, smt]
        # a loop back down to Persona must not repeat forever
        conn.execute("INSERT INTO core.franchise_relation (source_id, relation_type, target_id) VALUES (%s, 'sequel_of', %s)", (top, persona))
        assert [p["id"] for p in franchise_lineage(conn, persona)] == [top, smt]


def test_relationship_is_labelled_from_this_page(page):
    assert page["relations"] == [{
        "label": "Original work",
        "title": "Persona 3",
        "address": "/04/0001/001",
        "kind": "Game",
        "year": "2006",
        "note": None,
    }]


def test_the_other_side_reads_the_other_way(conn):
    p3 = load_work(conn, resolve(conn, "/04/0001/001")["entity_id"], "en")
    assert [(r["label"], r["title"]) for r in p3["relations"]] == [("Remake", "Persona 3 Reload")]


def test_children_skip_releases(page):
    assert page["children"] == [{
        "kind": "DLC",
        "title": "Episode Aigis -The Answer-",
        "address": "/04/0001/002/14/001",
        "date": "2024/09/10",
    }]


def test_genres_with_parents_and_tags(page):
    assert [(g["title"], g["parents"]) for g in page["genres"]] == [("JRPG", ["Role-Playing"]), ("Social Simulation", [])]
    assert [t["title"] for t in page["tags"]] == ["Calendar System", "Turn-Based Combat"]


def test_companies_and_staff_one_card_each(page):
    assert [(c["title"], c["roles"], c["picture"]) for c in page["companies"]] == [
        ("Atlus", ["Developer"], None),
        ("Sega", ["Publisher"], None),
    ]
    assert [(s["title"], s["roles"], s["address"]) for s in page["staff"]] == [
        ("Shoji Meguro", ["Composer"], "/23/00001"),
    ]


def test_characters_with_roles_and_cast(page):
    characters = page["characters"]
    assert [(c["title"], c["roles"]) for c in characters] == [
        ("Makoto Yuki", ["Protagonist"]),
        ("Yukari Takeba", ["Main"]),
        ("Junpei Iori", ["Main"]),
        ("Akihiko Sanada", ["Main"]),
        ("Mitsuru Kirijo", ["Main"]),
        ("Aigis", ["Main"]),
    ]
    makoto = characters[0]
    assert (makoto["native_title"], makoto["native_lang"], makoto["address"], makoto["picture"]) == ("結城理", "ja", "/22/0001", None)
    # the work's original language (Japanese) first
    assert [(x["type"], x["lang"], x["title"]) for x in makoto["cast"]] == [
        ("Voice", "ja", "Akira Ishida"),
        ("Voice", "en", "Aleks Le"),
    ]


def test_character_with_a_performance_but_no_appearance_still_shows(conn):
    work_id = resolve(conn, P3R)["entity_id"]
    with conn.transaction(force_rollback=True):
        extra = conn.execute("SELECT core.create_entity('character') AS id").fetchone()["id"]
        actor = conn.execute("SELECT id FROM core.entity WHERE kind = 'person' ORDER BY id LIMIT 1").fetchone()["id"]
        conn.execute("INSERT INTO core.title (entity_id, lang, title_type, text) VALUES (%s, 'en', 'full', 'Zzz Extra')", (extra,))
        conn.execute("UPDATE core.entity SET published_at = now() WHERE id = %s", (extra,))
        conn.execute(
            "INSERT INTO core.performance (person_id, character_id, target_id, target_kind, performance_type) VALUES (%s, %s, %s, 'game', 'voice')",
            (actor, extra, work_id),
        )
        page = load_work(conn, work_id, "en")
        assert page["characters"][-1]["title"] == "Zzz Extra"
        assert page["characters"][-1]["roles"] == []


def test_pictures_pick_the_primary_image_of_the_first_listed_type(conn):
    from app.data.work import pictures

    atlus = resolve(conn, "/24/0001")["entity_id"]
    with conn.transaction(force_rollback=True):
        conn.execute(
            """
            INSERT INTO core.image (entity_id, image_type, sha256, format, is_primary, sort_order) VALUES
              (%(e)s, 'logo',   repeat('a', 64), 'png', false, 0),
              (%(e)s, 'logo',   repeat('b', 64), 'svg', true,  1),
              (%(e)s, 'banner', repeat('c', 64), 'jpg', true,  0)
            """,
            {"e": atlus},
        )
        assert pictures(conn, [atlus], ["logo"]) == {atlus: "/media/" + "b" * 64 + ".svg"}
        assert pictures(conn, [atlus], ["banner", "logo"]) == {atlus: "/media/" + "c" * 64 + ".jpg"}
        assert pictures(conn, [atlus], ["portrait"]) == {}


def test_platforms_from_releases_in_family_order(page):
    assert [p["title"] for p in page["platforms"]] == [
        "PlayStation 4", "PlayStation 5", "Xbox One", "Xbox Series X|S", "Windows",
    ]


def test_age_ratings_with_icons_origin_country_system_first(conn, page):
    icons = {
        r["address"]: r["path"]
        for r in conn.execute(
            """
            SELECT core.address(entity_id) AS address, '/media/' || sha256 || '.' || format AS path
              FROM core.image WHERE image_type = 'icon' AND is_primary
            """
        ).fetchall()
    }
    assert [(a["label"], a["system"], a["rating"], a["address"], a["min_age"]) for a in page["age_ratings"]] == [
        ("CERO C", "CERO", "C", "/29/03/19/03", 15),      # Japan: the game's country of origin
        ("PEGI 16", "PEGI", "16", "/29/01/19/04", 16),
        ("ESRB Mature 17+", "ESRB", "Mature 17+", "/29/02/19/05", 17),
    ]
    assert [a["icon"] for a in page["age_ratings"]] == [icons["/29/03/19/03"], icons["/29/01/19/04"], icons["/29/02/19/05"]]
    assert all(a["icon"].endswith(".svg") for a in page["age_ratings"])


def test_age_ratings_skip_unpublished_and_show_text_without_an_icon(conn):
    p3 = resolve(conn, "/04/0001/001")["entity_id"]
    assert load_work(conn, p3, "en")["age_ratings"] == []
    with conn.transaction(force_rollback=True):
        cero_b = resolve(conn, "/29/03/19/02")["entity_id"]
        pegi_12 = resolve(conn, "/29/01/19/03")["entity_id"]
        conn.execute("INSERT INTO core.entity_age_rating (entity_id, entity_kind, rating_id) VALUES (%s, 'game', %s), (%s, 'game', %s)",
                     (p3, cero_b, p3, pegi_12))
        conn.execute("DELETE FROM core.image WHERE entity_id = %s", (cero_b,))
        conn.execute("UPDATE core.entity SET published_at = NULL WHERE id = %s", (pegi_12,))
        assert [(a["label"], a["icon"]) for a in load_work(conn, p3, "en")["age_ratings"]] == [("CERO B", None)]


def test_aey_placeholders(page):
    aey = page["aey"]
    assert aey["score"] == {"general": 32, "shown": "+6.4", "half_stars": 6}
    assert [(s["label"], s["shown"], s["half_stars"]) for s in aey["subratings"]] == [
        ("Music", "+7.0", 7), ("Gameplay", "+8.0", 8), ("Tone", "−3.0", -3),
    ]
    assert aey["take"]["body"].startswith("Tries to be Persona 5")
    assert aey["progress"]["status"] == "Completed"
    assert aey["progress"]["hours"] == "94"


def test_external_ratings_and_links(page):
    assert [(r["source"], r["metric"], r["value"], r["number"], r["suffix"]) for r in page["external"]["ratings"]] == [
        ("Metacritic", "Metascore", "88 / 100", "88", ""),
        ("HowLongToBeat", "Main Story", "60 h", "60", "h"),
    ]
    assert page["external"]["links"] == [
        {"url": "https://store.steampowered.com/app/2161700/", "label": "Steam", "host": "store.steampowered.com"},
    ]


def test_all_titles_with_the_latinized_title_under_the_japanese_title(page):
    assert [(t["lang"], t["text"], t["native"], t["latinized"], t["latinized_lang"], t["type"]) for t in page["titles"]] == [
        ("ja", "ペルソナ3 リロード", True, "Perusona Surī Rirōdo", "ja-Latn", "Full"),
        ("en", "Persona 3 Reload", False, None, None, "Full"),
    ]


def test_no_page_for_non_media_unknown_or_draft(conn):
    assert load_work(conn, resolve(conn, "/21/0001")["entity_id"], "en") is None   # a franchise
    assert load_work(conn, 999_999_999, "en") is None
    with conn.transaction(force_rollback=True):
        draft = conn.execute("SELECT core.create_entity('game') AS id").fetchone()["id"]
        assert load_work(conn, draft, "en") is None
