"""Company pages served by address, against the seeded dev database.

Needs: db/dev.sh up && db/dev.sh seed. Skips when the dev database is not reachable.
"""

from __future__ import annotations

import base64
import hashlib
import os
import re

import psycopg
import pytest
from fastapi.testclient import TestClient

from app.config import DEV_DATABASE_URL, Settings
from app.main import create_app

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
ATLUS = "/AML/24/0001"
HOSTS = ["aeyempire.com", "m.aeyempire.com"]
PNG_1X1 = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAMAASsJTYQAAAAASUVORK5CYII=")


@pytest.fixture(scope="module")
def client():
    try:
        with psycopg.connect(URL, connect_timeout=3) as conn:
            seeded = conn.execute("SELECT count(*) FROM core.resolve('/04/0001/003')").fetchone()[0] == 1
    except psycopg.OperationalError:
        pytest.skip(f"dev database not reachable at {URL}: run db/dev.sh up && db/dev.sh seed")
    if not seeded:
        pytest.skip("dev database is not seeded: run db/dev.sh up && db/dev.sh seed")
    return TestClient(create_app(Settings(root_path="/AML", database_url=URL)), follow_redirects=False)


@pytest.mark.parametrize("host", HOSTS)
def test_company_page_shows_the_parts(client, host):
    r = client.get(ATLUS, headers={"host": host})
    assert r.status_code == 200
    html = r.text
    for expected in (
        "<title>Atlus · ",
        '<p class="eyebrow">Company</p>',
        '<span lang="ja">アトラス</span>',
        "<dt>Names</dt>",
        'class="pic pic-logo pic-empty" aria-hidden="true">A</span>',
        ">Works</h2>",
        '<span class="role-chips"><span class="role-chip">Developer · Publisher</span></span>',
    ):
        assert expected in html, expected
    works = html.split(">Works</h2>", 1)[1]
    assert re.findall(r'<a class="character-name" href="/AML/04/0001/(\d+)">', works) == ["001", "003", "002"]
    assert "General Score" not in html   # companies are not rateable
    header = html.split("<header", 1)[1].split("</header>", 1)[0]
    assert all(h == "/" or h.startswith("/AML") for h in re.findall(r'href="([^"]*)"', header))
    assert "<footer" not in html


def test_a_real_logo_fills_the_big_tile(client, tmp_path):
    sha = hashlib.sha256(PNG_1X1).hexdigest()
    (tmp_path / f"{sha}.png").write_bytes(PNG_1X1)
    app = TestClient(create_app(Settings(root_path="/AML", database_url=URL, media_dir=str(tmp_path))))
    with psycopg.connect(URL, autocommit=True) as conn:
        atlus = conn.execute("SELECT entity_id FROM core.resolve('/24/0001')").fetchone()[0]
        conn.execute("INSERT INTO core.image (entity_id, image_type, sha256, format, is_primary) VALUES (%s, 'logo', %s, 'png', true)", (atlus, sha))
        try:
            html = app.get(ATLUS).text
        finally:
            conn.execute("DELETE FROM core.image WHERE entity_id = %s AND sha256 = %s", (atlus, sha))
    cover = html.split('<div class="cover">', 1)[1].split("</div>", 1)[0]
    assert f'<img class="pic pic-logo" src="/AML/media/{sha}.png" alt="">' in cover   # the page's own picture loads right away
    css = app.get("/AML/static/aml.css").text
    assert ".cover .pic-logo { width: 100%; height: auto; aspect-ratio: 1 / 1;" in css


def test_every_company_linked_from_work_pages_has_a_page(client):
    links = set()
    for page in ("/AML/04/0001/001", "/AML/04/0001/002", "/AML/04/0001/003"):
        links |= set(re.findall(r'href="(/AML/24/[0-9A-Z]+)"', client.get(page).text))
    assert links == {"/AML/24/0001", "/AML/24/0002"}
    for link in sorted(links):
        assert client.get(link).status_code == 200, link
