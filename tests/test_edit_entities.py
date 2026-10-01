"""Edit operations for entities: creating, names, facts, texts, origins, pictures.

Against the dev database; every check is rolled back. Pictures go to a temporary folder.
Needs: db/dev.sh up && db/dev.sh seed && db/dev.sh content.
"""

from __future__ import annotations

import os

import psycopg
import pytest
from PIL import Image
from psycopg.rows import dict_row

from app.config import DEV_DATABASE_URL
from app.edit.operations import EditError, run

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
TORADORA_FRANCHISE = "/21/0003"
TORADORA = "/01/0003/001"
TAIGA = "/22/0008"


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
def db(conn):
    with conn.transaction(force_rollback=True):
        yield conn


def one(db, sql, *args):
    return db.execute(sql, args).fetchone()


def entity_id(db, address):
    return one(db, "SELECT entity_id FROM core.resolve(%s)", address)["entity_id"]


# --- creating and publishing --------------------------------------------------

def test_a_new_work_gets_its_own_franchise_named_like_it(db):
    change = run(db, "create", None, {"kind": "anime", "title": "Golden Time"})
    new = entity_id(db, change.address)
    home = one(db, "SELECT franchise_id, published_at FROM core.entity WHERE id = %s", new)
    assert home["published_at"] is None                                   # a draft
    assert one(db, "SELECT text FROM core.title WHERE entity_id = %s", home["franchise_id"])["text"] == "Golden Time"
    assert change.after["franchise"].endswith("(new, a draft)")
    assert change.label == f"{change.address} Golden Time"
    assert one(db, "SELECT via, operation, entity_label FROM core.change_log ORDER BY id DESC LIMIT 1") == {
        "via": "web", "operation": "create", "entity_label": change.label,
    }


def test_a_new_work_in_an_existing_franchise(db):
    change = run(db, "create", None, {"kind": "light_novel", "title": "Toradora! Extra", "franchise": TORADORA_FRANCHISE})
    assert change.address.startswith("/03/0003/")
    assert change.after == {"kind": "light_novel", "title": "Toradora! Extra", "lang": "en", "published": False,
                            "franchise": TORADORA_FRANCHISE}


@pytest.mark.parametrize(("params", "message"), [
    ({"kind": "character", "title": "X", "franchise": TORADORA_FRANCHISE}, "Only a work belongs to a franchise."),
    ({"kind": "anime", "title": "X", "franchise": TAIGA}, "/22/0008 is a Character, not a franchise."),
    ({"kind": "episode", "title": "X"}, "kind: 'episode' is not one of anime"),
    ({"kind": "anime", "title": "  "}, "create needs title"),
    ({"kind": "anime", "title": "X", "franchise": "21/0003"}, "not a valid address"),
])
def test_creating_refusals(db, params, message):
    with pytest.raises(EditError, match=message):
        run(db, "create", None, params)


def test_every_world_kind_can_be_created(db):
    for kind in ("character", "person", "company", "franchise"):
        change = run(db, "create", None, {"kind": kind, "title": f"New {kind}"})
        assert one(db, "SELECT kind FROM core.entity WHERE id = %s", entity_id(db, change.address))["kind"] == kind


def test_publishing_and_unpublishing(db):
    address = run(db, "create", None, {"kind": "character", "title": "Kōji's Sister"}).address
    assert run(db, "publish", address).after == {"published": True}
    assert run(db, "unpublish", address).after == {"published": False}


def test_a_published_page_keeps_at_least_one_name(db):
    address = run(db, "create", None, {"kind": "person", "title": "Someone"}).address
    run(db, "publish", address)
    only = one(db, "SELECT id FROM core.title WHERE entity_id = %s", entity_id(db, address))["id"]
    with pytest.raises(EditError, match="A published page needs at least one name."):
        run(db, "remove_title", address, {"title_id": only})
    run(db, "unpublish", address)
    run(db, "remove_title", address, {"title_id": only})                    # a draft may be nameless
    with pytest.raises(EditError, match="A published page needs at least one name."):
        run(db, "publish", address)


def test_a_dry_run_creates_nothing(db):
    before = one(db, "SELECT count(*) AS n FROM core.entity")["n"]
    change = run(db, "create", None, {"kind": "anime", "title": "Not Kept"}, dry_run=True)
    assert change.kept is False
    assert one(db, "SELECT count(*) AS n FROM core.entity")["n"] == before


# --- names ----------------------------------------------------------------------

def test_names_native_latinized_and_preferred(db):
    address = run(db, "create", None, {"kind": "anime", "title": "Golden Time"}).address
    native = run(db, "add_title", address, {"text": "ゴールデンタイム", "lang": "ja", "native": "1", "preferred": "0"})
    assert native.after | {"id": None} == {"id": None, "lang": "ja", "type": "full", "text": "ゴールデンタイム",
                                           "native": True, "preferred": False, "latinizes": None}
    latin = run(db, "add_title", address, {"text": "Gōruden Taimu", "lang": "ja-Latn", "latinizes": native.after["id"]})
    assert latin.after["latinizes"] == native.after["id"]
    # a second preferred English name takes the mark over, and the log says so
    second = run(db, "add_title", address, {"text": "Golden Time (TV)", "preferred": "yes"})
    assert second.after["took"] == ["preferred from Golden Time"]
    names = db.execute("SELECT text, preferred FROM core.title WHERE entity_id = %s AND lang = 'en' ORDER BY id",
                       (entity_id(db, address),)).fetchall()
    assert names == [{"text": "Golden Time", "preferred": False}, {"text": "Golden Time (TV)", "preferred": True}]


@pytest.mark.parametrize(("params", "message"), [
    ({"text": "Golden Time"}, "That name is already there"),
    ({"text": "Gōruden", "lang": "ja", "latinizes": "ORIGINAL"}, "Latin-script language tag, like ja-Latn"),
    ({"text": "X", "latinizes": "99999999"}, r"This page has no name #99999999."),
    ({"text": "X", "native": "maybe"}, "is not yes or no"),
])
def test_name_refusals(db, params, message):
    address = run(db, "create", None, {"kind": "anime", "title": "Golden Time"}).address
    if params.get("latinizes") == "ORIGINAL":
        params["latinizes"] = one(db, "SELECT id FROM core.title WHERE entity_id = %s", entity_id(db, address))["id"]
    with pytest.raises(EditError, match=message):
        run(db, "add_title", address, params)


def test_editing_and_removing_names(db):
    address = run(db, "create", None, {"kind": "anime", "title": "Goldn Time"}).address
    title_id = one(db, "SELECT id FROM core.title WHERE entity_id = %s", entity_id(db, address))["id"]
    change = run(db, "edit_title", address, {"title_id": title_id, "text": "Golden Time"})
    assert (change.before["text"], change.after["text"], change.after["preferred"]) == ("Goldn Time", "Golden Time", True)
    assert change.label.endswith("Golden Time")                             # the log names it by its new name
    native = run(db, "add_title", address, {"text": "ゴールデンタイム", "lang": "ja", "native": "1"})
    run(db, "add_title", address, {"text": "Gōruden Taimu", "lang": "ja-Latn", "latinizes": native.after["id"]})
    with pytest.raises(EditError, match="remove the latinized one first"):
        run(db, "remove_title", address, {"title_id": native.after["id"]})
    with pytest.raises(EditError, match="This page has no name"):
        run(db, "edit_title", TORADORA, {"title_id": title_id, "text": "x"})   # a name of another page


# --- facts, origins, texts ----------------------------------------------------------

def test_work_facts(db):
    change = run(db, "set_work", TORADORA, {"status": "airing", "end_date": ""})
    assert change.before == {"status": "finished", "start_date": "2008-10-02", "end_date": "2009-03-26", "source_type": "light_novel"}
    assert change.after == {"status": "airing", "start_date": "2008-10-02", "end_date": None, "source_type": "light_novel"}
    with pytest.raises(EditError, match="That status doesn't apply to this medium."):
        run(db, "set_work", TORADORA, {"status": "released"})
    with pytest.raises(EditError, match="It can't end before it started."):
        run(db, "set_work", TORADORA, {"end_date": "2007"})
    with pytest.raises(EditError, match="A Character is not a work."):
        run(db, "set_work", TAIGA, {"status": "airing"})


def test_medium_facts_in_minutes(db):
    change = run(db, "set_medium", TORADORA, {"episode_count": "26", "episode_minutes": "23.5"})
    assert change.before == {"format": "tv", "episode_count": 25, "episode_minutes": 24}
    assert change.after == {"format": "tv", "episode_count": 26, "episode_minutes": 23.5}
    assert one(db, "SELECT typical_runtime_s FROM media.anime WHERE entity_id = %s", entity_id(db, TORADORA))["typical_runtime_s"] == 1410
    with pytest.raises(EditError, match="An Anime has no volume_count."):
        run(db, "set_medium", TORADORA, {"volume_count": "3"})


def test_players_range(db):
    game = run(db, "create", None, {"kind": "game", "title": "Test Game"}).address
    with pytest.raises(EditError, match="fewest local players can't be more than the most"):
        run(db, "set_medium", game, {"local_players_min": "4", "local_players_max": "2"})


def test_origins(db):
    address = run(db, "create", None, {"kind": "anime", "title": "Golden Time"}).address
    run(db, "add_original_language", address, {"lang": "ja"})
    assert run(db, "add_original_language", address, {"lang": "ja"}).after == {"langs": ["ja"]}   # no double
    assert run(db, "add_origin_country", address, {"country": "jp"}).after == {"countrys": ["JP"]}
    with pytest.raises(EditError, match="Countries are two capital letters"):
        run(db, "add_origin_country", address, {"country": "JPN"})
    with pytest.raises(EditError, match="A Character is not a work."):
        run(db, "add_original_language", TAIGA, {"lang": "ja"})
    assert run(db, "remove_original_language", address, {"lang": "ja"}).after == {"langs": []}


def test_texts(db):
    change = run(db, "set_text", TAIGA, {"text_type": "description", "body": " The palmtop tiger. "})
    assert change.after == {"text_type": "description", "lang": "en", "body": "The palmtop tiger."}
    assert run(db, "clear_text", TAIGA, {"text_type": "description"}).after is None
    with pytest.raises(EditError, match="set_text needs body"):
        run(db, "set_text", TAIGA, {"text_type": "synopsis", "body": ""})


# --- pictures -----------------------------------------------------------------------

def test_pictures(db, tmp_path, monkeypatch):
    monkeypatch.setenv("AML_MEDIA_DIR", str(tmp_path / "media"))
    address = run(db, "create", None, {"kind": "character", "title": "Pictured"}).address
    first, second = tmp_path / "a.png", tmp_path / "b.png"
    Image.new("RGB", (960, 1280), (200, 100, 50)).save(first)
    Image.new("RGB", (960, 1280), (50, 100, 200)).save(second)
    a = run(db, "add_picture", address, {"file": str(first), "image_type": "portrait"}).after
    b = run(db, "add_picture", address, {"file": str(second), "image_type": "portrait"}).after
    assert (a["primary"], b["primary"], a["file"].endswith(".webp")) == (True, False, True)
    assert (tmp_path / "media" / a["file"].replace(".webp", "@180.webp")).is_file()   # the drawn sizes too
    run(db, "make_primary", address, {"image_id": b["id"]})
    rows = db.execute("SELECT id, is_primary FROM core.image WHERE entity_id = %s ORDER BY id", (entity_id(db, address),)).fetchall()
    assert rows == [{"id": a["id"], "is_primary": False}, {"id": b["id"], "is_primary": True}]
    run(db, "remove_picture", address, {"image_id": b["id"]})             # the other one becomes primary
    assert db.execute("SELECT id, is_primary FROM core.image WHERE entity_id = %s", (entity_id(db, address),)).fetchall() == [
        {"id": a["id"], "is_primary": True}]
    with pytest.raises(EditError, match="No file at"):
        run(db, "add_picture", address, {"file": str(tmp_path / "missing.png"), "image_type": "portrait"})
    with pytest.raises(EditError, match="image_type: 'sticker' is not one of"):
        run(db, "add_picture", address, {"file": str(first), "image_type": "sticker"})
