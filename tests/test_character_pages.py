"""Character pages served by address, against the seeded dev database.

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
MAKOTO = "/AML/22/0001"
HOSTS = ["aeyempire.com", "m.aeyempire.com"]


@pytest.fixture(scope="module")
def client():
    try:
        with psycopg.connect(URL, connect_timeout=3) as conn:
            seeded = conn.execute("SELECT count(*) FROM core.resolve('/22/0001')").fetchone()[0] == 1
    except psycopg.OperationalError:
        pytest.skip(f"dev database not reachable at {URL}: run db/dev.sh up && db/dev.sh seed")
    if not seeded:
        pytest.skip("dev database is not seeded: run db/dev.sh up && db/dev.sh seed")
    return TestClient(create_app(Settings(root_path="/AML", database_url=URL)), follow_redirects=False)


@pytest.mark.parametrize("host", HOSTS)
def test_character_page_shows_the_parts(client, host):
    r = client.get(MAKOTO, headers={"host": host})
    assert r.status_code == 200
    html = r.text
    assert ("m-work" in html) == (host == "m.aeyempire.com")
    for expected in (
        "<title>Makoto Yuki · ",
        '<p class="eyebrow">Character</p>',
        '<span lang="ja">結城理</span>',
        "<dt>Names</dt>",
        '<dt>First Appearance</dt><dd><a href="/AML/04/0001/001">Persona 3</a> <span class="year">2006</span></dd>',
        '<a class="character-name" href="/AML/04/0001/003">Persona 5 Royal</a>',
        '<span class="appearance-meta">Game · 2019</span>',
        '<span class="role-chips"><span class="role-chip">Boss</span><span class="role-chip">Optional</span></span>',   # the note looks like the role
        ">Yuri Lowenthal</a>",
        'class="pic pic-person pic-empty" aria-hidden="true">YL</span>',
        "Not rated yet",
        ">Appearances</h2>",
        '<a class="character-name" href="/AML/04/0001/002">Persona 3 Reload</a>',
        '<span class="appearance-meta">Game · 2024</span>',
        '<span class="role-chip">Protagonist</span>',
        ">Voice Actors</h2>",
        ">Aleks Le</a>",
        '>Akira Ishida</a><span class="voice-native" lang="ja">石田彰</span>',   # native name right beside the name
        'class="pic pic-portrait pic-empty" aria-hidden="true">MY</span>',   # the character
        'class="pic pic-portrait pic-empty" aria-hidden="true">P3</span>',   # the game's cover frame
        'class="pic pic-person pic-empty" aria-hidden="true">AI</span>',     # Akira Ishida's big picture frame
        'class="pic pic-person pic-empty" aria-hidden="true">AL</span>',      # Aleks Le's
    ):
        assert expected in html, expected
    assert ">Cast</h2>" not in html
    # the language flag sits inside the picture frame, not as small cast lines under the appearances
    assert re.search(r'<div class="voice-frame"><span class="pic pic-person pic-empty" aria-hidden="true">AI</span><img class="lang-flag lang-flag-big" src="/AML/flags/JA\.png\?v=[0-9a-f]+" alt="JA" title="JA · Voice"></div>', html)
    assert re.search(r'<div class="voice-frame"><span class="pic pic-person pic-empty" aria-hidden="true">AL</span><img class="lang-flag lang-flag-big" src="/AML/flags/EN\.png\?v=[0-9a-f]+" alt="EN" title="EN · Voice"></div>', html)
    assert '<ul class="cast">' not in html
    # one card per actor, every game they voiced Makoto in
    assert html.count('class="pic pic-person') == 3
    def games(name):
        card = html.split(f">{name}</a>", 1)[1].split("</ul>", 1)[0]
        return re.findall(r'<span class="voice-work"><a href="/AML/04/0001/(\d+)">', card)
    assert games("Akira Ishida") == ["001", "003", "002"]
    assert games("Yuri Lowenthal") == ["001"]
    assert games("Aleks Le") == ["003", "002"]
    # the section says Voice Actors, so voice lines carry no tag of their own
    assert '<span class="voice-type">' not in html
    assert '<li><span class="voice-work"><a href="/AML/04/0001/003">Persona 5 Royal</a><span class="year">2019</span></span></li>' in html
    # appearances oldest first, each with its own role
    appearances = html.split(">Appearances</h2>", 1)[1]
    assert re.findall(r'<a class="character-name" href="/AML/04/0001/(\d+)">', appearances) == ["001", "003", "002"]


def test_a_voice_actor_picture_is_a_big_rounded_square(client, tmp_path):
    import base64
    import hashlib

    png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAMAASsJTYQAAAAASUVORK5CYII=")
    sha = hashlib.sha256(png).hexdigest()
    (tmp_path / f"{sha}.png").write_bytes(png)
    app = TestClient(create_app(Settings(root_path="/AML", database_url=URL, media_dir=str(tmp_path))))
    with psycopg.connect(URL, autocommit=True) as conn:
        ishida = conn.execute(
            "SELECT person_id FROM core.performance WHERE character_id = (SELECT entity_id FROM core.resolve('/22/0001')) AND lang = 'ja'"
        ).fetchone()[0]
        conn.execute("INSERT INTO core.image (entity_id, image_type, sha256, format, is_primary) VALUES (%s, 'portrait', %s, 'png', true)", (ishida, sha))
        try:
            html = app.get(MAKOTO).text
        finally:
            conn.execute("DELETE FROM core.image WHERE entity_id = %s AND sha256 = %s", (ishida, sha))
    assert f'<img class="pic pic-person" src="/AML/media/{sha}.png" alt="" loading="lazy">' in html
    css = app.get("/AML/static/aml.css").text
    rule = css.split("\n.pic-person {", 1)[1].split("}", 1)[0]
    assert "aspect-ratio: 1 / 1" in rule and "border-radius: 14px" in rule
    assert "repeat(auto-fill, 200px)" in css.split(".voice-grid {", 1)[1].split("}", 1)[0]   # about 60% of the first version


@pytest.mark.parametrize("host", HOSTS)
def test_header_menus_and_no_footer_on_character_pages(client, host):
    html = client.get(MAKOTO, headers={"host": host}).text
    header = html.split("<header", 1)[1].split("</header>", 1)[0]
    hrefs = [part.split('"', 1)[0] for part in header.split('href="')[1:]]
    assert all(h == "/" or h.startswith("/AML") for h in hrefs), hrefs
    assert "<footer" not in html


def test_every_character_linked_from_the_work_page_has_a_page(client):
    work = client.get("/AML/04/0001/002").text
    links = re.findall(r'<a class="character-name" href="(/AML/22/[0-9A-Z]+)">', work)
    assert len(links) == 6
    for link in links:
        assert client.get(link).status_code == 200, link


def test_character_addresses_redirect_to_canonical(client):
    r = client.get("/aml/22/ooo1")
    assert r.status_code == 301 and r.headers["location"] == "/AML/22/ooo1"
    r = client.get(r.headers["location"])
    assert r.status_code == 301 and r.headers["location"] == MAKOTO


@pytest.mark.parametrize("host", HOSTS)
def test_a_rated_character_shows_the_frontend_score_only(client, host):
    with psycopg.connect(URL, autocommit=True) as conn:
        makoto = conn.execute("SELECT entity_id FROM core.resolve('/22/0001')").fetchone()[0]
        conn.execute("INSERT INTO aey.score (entity_id, entity_kind, general) VALUES (%s, 'character', 45)", (makoto,))
        try:
            html = client.get(MAKOTO, headers={"host": host}).text
        finally:
            conn.execute("DELETE FROM aey.score WHERE entity_id = %s", (makoto,))
    assert "+9.0" in html and "Not rated yet" not in html
    for backend in ("+45", "±50", "stored"):   # never the stored points
        assert backend not in html, backend
    assert html.count('class="st-f"') == 4 and html.count('class="st-f h-l"') == 1


def test_other_kinds_of_performance_get_a_tag(client):
    with psycopg.connect(URL, autocommit=True) as conn:
        makoto = conn.execute("SELECT entity_id FROM core.resolve('/22/0001')").fetchone()[0]
        ishida = conn.execute("SELECT person_id FROM core.performance WHERE character_id = %s AND lang = 'ja' LIMIT 1", (makoto,)).fetchone()[0]
        p3r = conn.execute("SELECT entity_id FROM core.resolve('/04/0001/002')").fetchone()[0]
        conn.execute(
            "INSERT INTO core.performance (person_id, character_id, target_id, target_kind, performance_type, lang) VALUES (%s, %s, %s, 'game', 'motion_capture', 'ja')",
            (ishida, makoto, p3r),
        )
        try:
            html = client.get(MAKOTO).text
        finally:
            conn.execute("DELETE FROM core.performance WHERE person_id = %s AND character_id = %s AND performance_type = 'motion_capture'", (ishida, makoto))
    card = html.split(">Akira Ishida</a>", 1)[1].split("</ul>", 1)[0]
    assert card.count('<span class="voice-type">Motion Capture</span>') == 1
    assert card.count('<span class="voice-type">') == 1


@pytest.mark.parametrize("host", HOSTS)
def test_the_work_page_shows_an_appearance_note(client, host):
    html = client.get("/AML/04/0001/003", headers={"host": host}).text
    assert '<span class="role-chips"><span class="role-chip">Boss</span><span class="role-chip">Optional</span></span>' in html
    assert '<span class="note">Optional</span>' not in html
