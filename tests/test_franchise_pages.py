"""Franchise pages served by address, against the seeded dev database.

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
PERSONA = "/AML/21/0001"
SMT = "/AML/21/0002"
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
def test_franchise_page_shows_the_parts(client, host):
    r = client.get(PERSONA, headers={"host": host})
    assert r.status_code == 200
    html = r.text
    for expected in (
        "<title>Persona · ",
        '<p class="eyebrow">Franchise</p>',
        '<span lang="ja">ペルソナ</span>',
        "<dt>Names</dt>",
        'class="pic pic-logo pic-empty" aria-hidden="true">P</span>',
        # lineage: the parent links, this franchise does not
        '<span class="crumbs"><a class="crumb-parent" href="/AML/21/0002">Shin Megami Tensei</a><span class="crumb-sep" aria-hidden="true">›</span><span class="crumb-current">Persona</span></span>',
        ">Works</h2>",
        ">Characters</h2>",
        '<a class="character-name" href="/AML/22/0001">Makoto Yuki</a>',
    ):
        assert expected in html, expected
    assert "Main work" not in html and "—" not in html.split("<main", 1)[1]
    works = html.split(">Works</h2>", 1)[1].split("</ul>", 1)[0]
    assert re.findall(r'<a class="character-name" href="/AML/04/0001/(\d+)">', works) == ["001", "003", "002"]
    characters = html.split(">Characters</h2>", 1)[1]
    assert len(re.findall(r'<a class="character-name" href="/AML/22/', characters)) == 6
    assert "General Score" not in html   # franchises are not rateable
    header = html.split("<header", 1)[1].split("</header>", 1)[0]
    assert all(h == "/" or h.startswith("/AML") for h in re.findall(r'href="([^"]*)"', header))
    assert "<footer" not in html


@pytest.mark.parametrize("host", HOSTS)
def test_parent_franchise_page_tags_its_spin_off(client, host):
    html = client.get(SMT, headers={"host": host}).text
    assert '<li class="rel-row"><span class="rel-tag">Spin-off</span><a href="/AML/21/0001">Persona</a></li>' in html
    assert ">Works</h2>" not in html and ">Characters</h2>" not in html


def test_every_franchise_linked_from_work_pages_has_a_page(client):
    links = set()
    for page in ("/AML/04/0001/001", "/AML/04/0001/002", "/AML/04/0001/003"):
        links |= set(re.findall(r'href="(/AML/21/[0-9A-Z]+)"', client.get(page).text))
    assert links == {PERSONA, SMT}
    for link in sorted(links):
        assert client.get(link).status_code == 200, link
