"""The web editor, against the dev database.

The editor commits for real, so every test that edits cleans up afterwards: the
Toradora! anime has none of Aey's data in the content files, so its rows can be wiped.
Needs: db/dev.sh up && db/dev.sh seed && db/dev.sh content.
"""

from __future__ import annotations

import io
import os

import psycopg
import pytest
from fastapi.testclient import TestClient

from PIL import Image

from app.config import DEV_DATABASE_URL, Settings
from app.editor.config import EditorSettings
from app.editor.main import create_editor
from app.main import create_app

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
TORADORA = "/01/0003/001"
SAME_SITE = {"origin": "http://testserver"}


@pytest.fixture(scope="module")
def db():
    try:
        conn = psycopg.connect(URL, autocommit=True, connect_timeout=3)
    except psycopg.OperationalError:
        pytest.skip(f"dev database not reachable at {URL}: run db/dev.sh up")
    with conn:
        if conn.execute("SELECT count(*) FROM core.resolve(%s)", (TORADORA,)).fetchone()[0] != 1:
            pytest.skip("Toradora content is not loaded: run db/dev.sh content")
        yield conn


@pytest.fixture()
def clean(db):
    """Leaves the Toradora anime without Aey's data, and the change log as it was."""
    start = db.execute("SELECT coalesce(max(id), 0) FROM core.change_log").fetchone()[0]
    yield db
    toradora = db.execute("SELECT entity_id FROM core.resolve(%s)", (TORADORA,)).fetchone()[0]
    for table in ("aey.score", "aey.subrating", "aey.take", "aey.progress"):
        db.execute(f"DELETE FROM {table} WHERE entity_id = %s", (toradora,))
    db.execute("DELETE FROM core.change_log WHERE id > %s", (start,))


@pytest.fixture()
def editor(db):
    return TestClient(create_editor(EditorSettings(database_url=URL, dev=True)), follow_redirects=False)


def test_search_by_name_and_by_address(editor):
    page = editor.get("/aml/", params={"q": "tora"}).text
    assert '<a href="/aml/e/01/0003/001"><span class="ed-kind">Anime</span><span class="ed-title">Toradora!</span></a>' in page
    assert "Toradora Spin-off!" in page and "Toradora Portable!" in page
    exact = editor.get("/aml/", params={"q": TORADORA}).text
    first = exact.split('<ul class="ed-results">', 1)[1].split("</li>", 1)[0]
    assert 'href="/aml/e/01/0003/001"' in first
    assert "Nothing matches" in editor.get("/aml/", params={"q": "zzqq"}).text


def test_the_entity_page_works_in_stored_points(editor):
    page = editor.get("/aml/e" + TORADORA).text
    assert '<input type="number" name="general" min="-50" max="50" step="1" value="" required>' in page
    assert "Points from −50 to +50." in page and "Not rated yet." in page
    assert '<a class="ed-more" href="https://aeyempire.com/AML/01/0003/001">View on the site ↗</a>' in page
    for section in ('id="subratings"', 'id="take"', 'id="progress"'):
        assert section in page


def test_saving_a_score(editor, clean):
    r = editor.post("/aml/e" + TORADORA, data={"op": "set_score", "general": "40", "rated_on": ""}, headers=SAME_SITE)
    assert r.status_code == 303 and r.headers["location"] == "/aml/e/01/0003/001?done=set_score#score"
    page = editor.get(r.headers["location"]).text
    assert 'name="general" min="-50" max="50" step="1" value="40"' in page
    assert "Now +40, shown on the site as +8.0." in page
    assert "Saved: set_score" in page
    changes = page.split('id="changes"', 1)[1]
    assert '<span class="ed-via">web</span>' in changes and '<span class="ed-op">set_score</span>' in changes
    # the public page shows the same score divided by five, never the points
    public = TestClient(create_app(Settings(root_path="/AML", database_url=URL))).get("/AML" + TORADORA).text
    assert "+8.0" in public and "+40" not in public


def test_a_bad_value_is_refused_on_the_page(editor, clean):
    r = editor.post("/aml/e" + TORADORA, data={"op": "set_score", "general": "99"}, headers=SAME_SITE)
    assert r.status_code == 400
    assert "general: points go from -50 to +50, not 99." in r.text
    assert clean.execute("SELECT count(*) FROM aey.score WHERE entity_id = (SELECT entity_id FROM core.resolve(%s))",
                         (TORADORA,)).fetchone()[0] == 0


def test_subratings_takes_and_progress_from_their_forms(editor, clean):
    post = lambda data: editor.post("/aml/e" + TORADORA, data=data, headers=SAME_SITE)   # noqa: E731
    assert post({"op": "set_subrating", "category": "characters", "value": "44"}).status_code == 303
    assert post({"op": "set_take", "lang": "en", "body": "The best romcom ending.", "written_on": "2026-10"}).status_code == 303
    assert post({"op": "set_progress", "status": "completed", "progress_value": "25", "progress_unit": "episode",
                 "started_on": "", "finished_on": "", "times_completed": "1", "hours": "", "note": ""}).status_code == 303
    page = editor.get("/aml/e" + TORADORA).text
    assert '<input type="hidden" name="category" value="characters">' in page and 'value="44"' in page
    assert ">The best romcom ending.</textarea>" in page
    assert '<option value="completed" selected>' in page and '<option value="episode" selected>' in page
    assert post({"op": "clear_subrating", "category": "characters", "value": ""}).status_code == 303
    assert '<input type="hidden" name="category" value="characters">' not in editor.get("/aml/e" + TORADORA).text


def test_forms_from_other_sites_are_refused(editor, clean):
    assert editor.post("/aml/e" + TORADORA, data={"op": "set_score", "general": "10"}).status_code == 403
    r = editor.post("/aml/e" + TORADORA, data={"op": "set_score", "general": "10"}, headers={"origin": "https://evil.example"})
    assert r.status_code == 403
    assert clean.execute("SELECT count(*) FROM aey.score WHERE entity_id = (SELECT entity_id FROM core.resolve(%s))",
                         (TORADORA,)).fetchone()[0] == 0


def test_only_signed_in_requests_get_in(db):
    """On the server nginx sets the header after the admin login; without it, nothing opens."""
    locked = TestClient(create_editor(EditorSettings(database_url=URL)), follow_redirects=False)
    assert locked.get("/aml/").status_code == 403
    assert locked.get("/aml/e" + TORADORA).status_code == 403
    assert locked.post("/aml/e" + TORADORA, data={"op": "set_score", "general": "1"}, headers=SAME_SITE).status_code == 403
    signed = locked.get("/aml/", headers={"X-Auth-User": "aey"})
    assert signed.status_code == 200 and '<span class="ed-user">aey</span>' in signed.text


def test_things_that_cannot_be_rated(editor):
    page = editor.get("/aml/e/23/00001").text   # a person
    assert 'id="names"' in page and 'id="pictures"' in page
    assert 'name="general"' not in page and 'id="progress"' not in page and 'id="facts"' not in page


def test_unknown_addresses_and_operations(editor):
    assert editor.get("/aml/e/01/0ZZZ/001").status_code == 404
    assert editor.post("/aml/e" + TORADORA, data={"op": "drop_table"}, headers=SAME_SITE).status_code == 400


def test_the_public_site_has_no_editor(db):
    public = TestClient(create_app(Settings(root_path="/AML", database_url=URL)))
    assert public.get("/AML/e" + TORADORA).status_code == 404
    assert public.post("/AML" + TORADORA, data={"op": "set_score", "general": "1"}).status_code == 405


def test_editor_styles_are_served(editor):
    r = editor.get("/aml/static/editor.css")
    assert r.status_code == 200 and ".ed-form" in r.text


@pytest.fixture()
def fresh(db, tmp_path, monkeypatch):
    """For tests that create entities: removes them afterwards, with their log, and keeps
    pictures in a temporary folder."""
    monkeypatch.setenv("AML_MEDIA_DIR", str(tmp_path))
    last = db.execute("SELECT max(id) FROM core.entity").fetchone()[0]
    start = db.execute("SELECT coalesce(max(id), 0) FROM core.change_log").fetchone()[0]
    client = TestClient(create_editor(EditorSettings(database_url=URL, dev=True, media_dir=str(tmp_path))),
                        follow_redirects=False)
    yield client
    db.execute("DELETE FROM core.entity WHERE id > %s AND kind <> 'franchise'", (last,))
    db.execute("DELETE FROM core.entity WHERE id > %s", (last,))
    db.execute("DELETE FROM core.change_log WHERE id > %s", (start,))


def test_creating_from_the_search_page(fresh):
    assert '<form method="post" action="/aml/new"' in fresh.get("/aml/").text
    r = fresh.post("/aml/new", data={"kind": "anime", "title": "Golden Time", "lang": "en", "franchise": ""}, headers=SAME_SITE)
    assert r.status_code == 303 and r.headers["location"].endswith("?done=create#top")
    page = fresh.get(r.headers["location"]).text
    assert "Created. It is a draft until you publish it." in page
    assert '<h1 class="title">Golden Time</h1>' in page and '<button name="op" value="publish">Publish</button>' in page
    assert 'id="facts"' in page and 'id="origin"' in page
    # a refusal keeps what was typed
    bad = fresh.post("/aml/new", data={"kind": "character", "title": "Kōko", "lang": "en", "franchise": "/21/0003"}, headers=SAME_SITE)
    assert bad.status_code == 400 and "Only a work belongs to a franchise." in bad.text
    assert 'value="Kōko"' in bad.text and '<option value="character" selected>' in bad.text


def test_names_facts_origin_and_texts_from_their_forms(fresh):
    address = fresh.post("/aml/new", data={"kind": "anime", "title": "Golden Time", "lang": "en"},
                         headers=SAME_SITE).headers["location"].split("?")[0].removeprefix("/aml/e")
    post = lambda data: fresh.post("/aml/e" + address, data=data, headers=SAME_SITE)   # noqa: E731
    r = post({"op": "add_title", "text": "ゴールデンタイム", "lang": "ja", "title_type": "full", "native": ["0", "1"],
              "preferred": "0", "latinizes": ""})
    assert r.status_code == 303 and r.headers["location"].endswith("?done=add_title#names")
    assert post({"op": "set_work", "status": "finished", "start_date": "2013-10-04", "end_date": "2014-03-28",
                 "source_type": "light_novel"}).status_code == 303
    assert post({"op": "set_medium", "format": "tv", "episode_count": "24", "episode_minutes": "24"}).status_code == 303
    assert post({"op": "add_original_language", "lang": "ja"}).status_code == 303
    assert post({"op": "add_origin_country", "country": "jp"}).status_code == 303
    assert post({"op": "set_text", "text_type": "synopsis", "lang": "en", "body": "Banri loses his memory."}).status_code == 303
    page = fresh.get("/aml/e" + address).text
    assert 'value="ゴールデンタイム" lang="ja"' in page
    assert page.count('<input type="checkbox" name="native" value="1" checked>') == 1
    assert '<option value="finished" selected>' in page and 'value="2013-10-04"' in page
    assert '<option value="light_novel" selected>' in page and '<option value="tv" selected>' in page
    assert 'name="episode_count" min="0" step="1" value="24"' in page
    assert "<span>ja</span>" in page and "<span>JP</span>" in page
    assert ">Banri loses his memory.</textarea>" in page
    # unticking a box sends only the hidden "0": the mark goes
    title_id = page.split('name="title_id" value="', 2)[2].split('"', 1)[0]
    assert post({"op": "edit_title", "title_id": title_id, "text": "ゴールデンタイム", "lang": "ja", "title_type": "full",
                 "native": "0", "preferred": "0"}).status_code == 303
    assert '<input type="checkbox" name="native" value="1" checked>' not in fresh.get("/aml/e" + address).text
    # a refusal shows in its section and keeps the typed name
    bad = post({"op": "add_title", "text": "Gōruden", "lang": "ja", "title_type": "full", "latinizes": title_id})
    assert bad.status_code == 400
    names = bad.text.split('id="names"', 1)[1].split("</section>", 1)[0]
    assert 'class="ed-message ed-error"' in names and 'value="Gōruden"' in names
    assert post({"op": "publish"}).status_code == 303
    assert '<button name="op" value="unpublish" class="ed-danger">Unpublish</button>' in fresh.get("/aml/e" + address).text


def test_pictures_are_uploaded_not_named(fresh, tmp_path):
    address = fresh.post("/aml/new", data={"kind": "character", "title": "Pictured", "lang": "en"},
                         headers=SAME_SITE).headers["location"].split("?")[0].removeprefix("/aml/e")
    png = io.BytesIO()
    Image.new("RGB", (960, 1280), (200, 100, 50)).save(png, format="PNG")
    r = fresh.post("/aml/e" + address, data={"op": "add_picture", "image_type": "portrait", "file": "/etc/hostname"},
                   files={"upload": ("taiga.PNG", png.getvalue(), "image/png")}, headers=SAME_SITE)
    assert r.status_code == 303 and r.headers["location"].endswith("#pictures")
    page = fresh.get("/aml/e" + address).text
    thumb = page.split('<li class="ed-picture">', 1)[1].split('src="', 1)[1].split('"', 1)[0]
    assert thumb.endswith("@180.webp") and "Portrait · primary" in page
    assert fresh.get(thumb).status_code == 200
    # no upload: refused, even with a server path in the form
    none = fresh.post("/aml/e" + address, data={"op": "add_picture", "image_type": "portrait", "file": "/etc/hostname"},
                      headers=SAME_SITE)
    assert none.status_code == 400 and "Choose a picture file first." in none.text
    text = fresh.post("/aml/e" + address, data={"op": "add_picture", "image_type": "portrait"},
                      files={"upload": ("notes.txt", b"hello", "text/plain")}, headers=SAME_SITE)
    assert text.status_code == 400 and "is not a picture file the editor takes" in text.text
    fake = fresh.post("/aml/e" + address, data={"op": "add_picture", "image_type": "portrait"},
                      files={"upload": ("fake.png", b"not a picture", "image/png")}, headers=SAME_SITE)
    assert fake.status_code == 400 and "can&#39;t be read as a picture" in fake.text
