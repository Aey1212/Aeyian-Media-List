"""The web editor, against the dev database.

The editor commits for real, so every test that edits cleans up afterwards: the
Toradora! anime has none of Aey's data in the content files, so its rows can be wiped.
Needs: db/dev.sh up && db/dev.sh seed && db/dev.sh content.
"""

from __future__ import annotations

import os

import psycopg
import pytest
from fastapi.testclient import TestClient

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
    assert r.status_code == 303 and r.headers["location"] == "/aml/e/01/0003/001?done=set_score"
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
    assert "A Person can't be rated." in page
    assert 'name="general"' not in page and 'id="progress"' not in page


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
