"""Person pages served by address, against the seeded dev database.

Needs: db/dev.sh up && db/dev.sh seed. Skips when the dev database is not reachable.
"""

from __future__ import annotations

import os
import re

import psycopg
import pytest
from fastapi.testclient import TestClient

from app.config import DEV_DATABASE_URL, Settings
from app.main import create_app

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
MEGURO = "/AML/23/00001"
ISHIDA = "/AML/23/00002"
HOSTS = ["aeyempire.com", "m.aeyempire.com"]


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
def test_voice_actor_page_shows_their_characters_big(client, host):
    r = client.get(ISHIDA, headers={"host": host})
    assert r.status_code == 200
    html = r.text
    for expected in (
        "<title>Akira Ishida · ",
        '<p class="eyebrow">Person</p>',
        '<span lang="ja">石田彰</span>',
        "<dt>Names</dt>",
        'class="pic pic-person pic-empty" aria-hidden="true">AI</span>',     # the person's own picture frame
        ">Characters</h2>",
        '<div class="voice-frame"><span class="pic pic-portrait pic-empty" aria-hidden="true">MY</span></div>',
        '<a class="voice-name" href="/AML/22/0001">Makoto Yuki</a><span class="voice-native" lang="ja">結城理</span>',
    ):
        assert expected in html, expected
    card = html.split(">Makoto Yuki</a>", 1)[1].split("</ul>", 1)[0]
    assert re.findall(r'<span class="voice-work"><a href="/AML/04/0001/(\d+)">', card) == ["001", "003", "002"]
    assert '<span class="voice-type">' not in html
    assert "Staff Credits" not in html
    assert "General Score" not in html and "Not rated yet" not in html   # people are not rateable


@pytest.mark.parametrize("host", HOSTS)
def test_staff_page_shows_credits_with_roles(client, host):
    html = client.get(MEGURO, headers={"host": host}).text
    for expected in (
        "<title>Shoji Meguro · ",
        '<span lang="ja">目黒将司</span>',
        "<span>Meguro Shōji</span>",
        '<span class="title-latinized" lang="ja-Latn">Meguro Shōji</span>',
        ">Staff Credits</h2>",
        '<a class="character-name" href="/AML/04/0001/001">Persona 3</a>',
        '<span class="appearance-meta">Game · 2006</span>',
        '<span class="role-chips"><span class="role-chip">Composer</span></span>',
    ):
        assert expected in html, expected
    credits = html.split(">Staff Credits</h2>", 1)[1]
    assert re.findall(r'<a class="character-name" href="/AML/04/0001/(\d+)">', credits) == ["001", "002"]
    assert ">Characters</h2>" not in html
    assert "General Score" not in html


@pytest.mark.parametrize("host", HOSTS)
def test_header_menus_and_no_footer_on_person_pages(client, host):
    html = client.get(ISHIDA, headers={"host": host}).text
    header = html.split("<header", 1)[1].split("</header>", 1)[0]
    hrefs = [part.split('"', 1)[0] for part in header.split('href="')[1:]]
    assert all(h == "/" or h.startswith("/AML") for h in hrefs), hrefs
    assert "<footer" not in html


def test_every_person_linked_from_work_and_character_pages_has_a_page(client):
    links = set()
    for page in ("/AML/04/0001/001", "/AML/04/0001/002", "/AML/04/0001/003", "/AML/22/0001"):
        links |= set(re.findall(r'href="(/AML/23/[0-9A-Z]+)"', client.get(page).text))
    assert len(links) >= 15
    for link in sorted(links):
        assert client.get(link).status_code == 200, link


def test_person_addresses_redirect_to_canonical(client):
    r = client.get("/AML/23/ooooi")
    assert r.status_code == 301 and r.headers["location"] == MEGURO
