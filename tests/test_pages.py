"""Pages served by address, against the seeded dev database.

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
PNG_1X1 = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAMAASsJTYQAAAAASUVORK5CYII=")


@pytest.fixture(scope="module")
def client():
    try:
        with psycopg.connect(URL, connect_timeout=3) as conn:
            seeded = conn.execute("SELECT count(*) FROM core.resolve('/04/0001/002')").fetchone()[0] == 1
    except psycopg.OperationalError:
        pytest.skip(f"dev database not reachable at {URL}: run db/dev.sh up && db/dev.sh seed")
    if not seeded:
        pytest.skip("dev database is not seeded: run db/dev.sh reset --yes && db/dev.sh up && db/dev.sh seed")
    return TestClient(create_app(Settings(root_path="/AML", database_url=URL)), follow_redirects=False)


def test_live_address_renders_the_work(client):
    r = client.get("/AML/04/0001/002")
    assert r.status_code == 200
    assert "Persona 3 Reload" in r.text


def test_lowercase_and_letter_o_redirect_to_canonical(client):
    r = client.get("/AML/o4/oo01/oo2")
    assert r.status_code == 301
    assert r.headers["location"] == "/AML/04/0001/002"


def test_trailing_slash_redirects_to_canonical(client):
    r = client.get("/AML/04/0001/002/")
    assert r.status_code == 301
    assert r.headers["location"] == "/AML/04/0001/002"


def test_redirect_keeps_the_query(client):
    r = client.get("/AML/o4/0001/002?tab=credits")
    assert r.status_code == 301
    assert r.headers["location"] == "/AML/04/0001/002?tab=credits"


def test_lowercase_root_then_canonical_address(client):
    first = client.get("/aml/o4/0001/002")
    assert first.status_code == 301 and first.headers["location"] == "/AML/o4/0001/002"
    second = client.get(first.headers["location"])
    assert second.status_code == 301 and second.headers["location"] == "/AML/04/0001/002"


def test_unknown_address_is_404(client):
    r = client.get("/AML/04/0001/0ZZ")
    assert r.status_code == 404
    assert "Nothing lives at this address" in r.text


def test_garbage_is_404(client):
    assert client.get("/AML/favicon.ico").status_code == 404
    assert client.get("/AML/04/00U1/002").status_code == 404


def test_kinds_without_a_page_yet_are_404(client):
    assert client.get("/AML/21/0001").status_code == 404          # franchise
    assert client.get("/AML/04/0001/002/14/001").status_code == 404   # DLC


# --- the desktop page -------------------------------------------------------

def test_stylesheet_url_changes_when_the_file_changes(client):
    """A browser must never draw new markup with an old cached stylesheet."""
    import re
    from pathlib import Path

    css = Path(__file__).resolve().parent.parent / "app" / "static" / "aml.css"
    before = re.search(r'href="(/AML/static/aml\.css\?v=[0-9a-f]+)"', client.get("/AML/04/0001/002").text).group(1)
    original = css.stat()
    try:
        os.utime(css, ns=(original.st_atime_ns, original.st_mtime_ns + 1_000_000_000))
        after = re.search(r'href="(/AML/static/aml\.css\?v=[0-9a-f]+)"', client.get("/AML/04/0001/002").text).group(1)
    finally:
        os.utime(css, ns=(original.st_atime_ns, original.st_mtime_ns))
    assert before != after
    assert client.get(after).status_code == 200


def test_stylesheet_is_served_under_the_root_path(client):
    r = client.get("/AML/static/aml.css")
    assert r.status_code == 200
    assert "--blue: #3A41E1" in r.text


def test_page_shows_the_parts(client):
    html = client.get("/AML/04/0001/002").text
    for expected in (
        'href="/AML/static/aml.css?v=',
        "ペルソナ3 リロード", "Perusona Surī Rirōdo",
        '<li class="rel-row"><span class="rel-tag">Original work</span><a href="/AML/04/0001/001">Persona 3</a><span class="year">2006</span></li>',
        '<a class="crumb-parent" href="/AML/21/0002">Shin Megami Tensei</a><span class="crumb-sep" aria-hidden="true">›</span><a class="crumb-current" href="/AML/21/0001">Persona</a>',
        "Role-Playing › ", "Social Simulation", "Calendar System",
        "Developer", "Atlus", "Publisher", "Sega", "Composer", "Shoji Meguro",
        "Characters", "Makoto Yuki", "結城理", "Protagonist", "Akira Ishida", "Aleks Le", "Aigis", "Dawn M. Bennett",
        "Companies", "Staff",
        "PlayStation 5", "Xbox Series X|S",
        "+6.4",
        "Aey's Take", "Tries to be Persona 5",
        "Episode Aigis -The Answer-", "2024/09/10",
        "Metacritic", '<span class="tile-value">88</span>', '<span class="tile-value">60<small>h</small></span>',
        "store.steampowered.com/app/2161700", '<span class="tile-meta">store.steampowered.com</span>',
    ):
        assert expected in html, expected


def test_stars_are_drawn_for_every_score(client):
    html = client.get("/AML/04/0001/002").text
    # General +6.4 = 3 stars; Music +7.0 = 3.5; Gameplay +8.0 = 4; Tone -3.0 = 1.5 on the negative side
    assert html.count('class="st-f"') == 3 + 3 + 4 + 1
    assert html.count('class="st-f h-l"') == 1   # Music's half star, filling from zero outward
    assert html.count('class="st-f h-r"') == 1   # Tone's half star on the negative side
    assert html.count('class="st neg"') == 5 * 4
    assert html.count('class="zero"') == 4


# --- desktop or mobile, by host ----------------------------------------------

def test_desktop_host_gets_the_desktop_page(client):
    r = client.get("/AML/04/0001/002", headers={"host": "aeyempire.com"})
    assert r.status_code == 200
    assert "aml-mobile.css" not in r.text and 'class="entry"' in r.text


def test_mobile_host_gets_the_mobile_page(client):
    r = client.get("/AML/04/0001/002", headers={"host": "m.aeyempire.com"})
    assert r.status_code == 200
    assert 'href="/AML/static/aml-mobile.css?v=' in r.text and 'class="m-work"' in r.text
    assert "Persona 3 Reload" in r.text and "Original work" in r.text


def test_mobile_host_with_a_port_and_capitals(client):
    r = client.get("/AML/04/0001/002", headers={"host": "M.AEYEMPIRE.COM:8765"})
    assert 'class="m-work"' in r.text


def test_mobile_stars_match_desktop(client):
    desktop = client.get("/AML/04/0001/002", headers={"host": "aeyempire.com"}).text
    mobile = client.get("/AML/04/0001/002", headers={"host": "m.aeyempire.com"}).text
    for marker in ('class="st-f"', 'class="st-f h-l"', 'class="st-f h-r"', 'class="zero"'):
        assert mobile.count(marker) == desktop.count(marker), marker


def test_mobile_404_and_redirects(client):
    missing = client.get("/AML/04/0001/0ZZ", headers={"host": "m.aeyempire.com"})
    assert missing.status_code == 404 and "aml-mobile.css" in missing.text
    moved = client.get("/AML/o4/0001/002", headers={"host": "m.aeyempire.com"})
    assert moved.status_code == 301 and moved.headers["location"] == "/AML/04/0001/002"


def test_mobile_stylesheet_is_served(client):
    assert client.get("/AML/static/aml-mobile.css").status_code == 200


def test_desktop_pages_send_phones_to_mobile_keeping_query_and_fragment(client):
    desktop = client.get("/AML/04/0001/002", headers={"host": "aeyempire.com"}).text
    assert 'window.location.replace("https://m.aeyempire.com" + window.location.pathname + window.location.search + window.location.hash)' in desktop
    missing = client.get("/AML/04/0001/0ZZ", headers={"host": "aeyempire.com"}).text
    assert "window.location.replace" in missing


def test_mobile_pages_do_not_redirect(client):
    mobile = client.get("/AML/04/0001/002", headers={"host": "m.aeyempire.com"}).text
    assert "window.location.replace" not in mobile


def test_mobile_origin_is_configurable(client):   # client: skip when the dev database is down
    local = TestClient(create_app(Settings(root_path="/AML", database_url=URL, mobile_origin="http://m.aeyempire.com:8765")))
    assert 'window.location.replace("http://m.aeyempire.com:8765" +' in local.get("/AML/04/0001/002").text


# --- header, footer, progress, pictures ------------------------------------------

MENU_LINKS = ['href="/AML/01">Anime', 'href="/AML/02">Manga', 'href="/AML/03">Light Novels',
              'href="/AML/04">Games', 'href="/AML/05">Series', 'href="/AML/06">Movies', 'href="/">Home']


@pytest.mark.parametrize("host", ["aeyempire.com", "m.aeyempire.com"])
def test_header_links_stay_on_the_site_plus_home(client, host):
    html = client.get("/AML/04/0001/002", headers={"host": host}).text
    header = html.split("<header", 1)[1].split("</header>", 1)[0]
    for link in MENU_LINKS:
        assert link in header, link
    hrefs = [part.split('"', 1)[0] for part in header.split('href="')[1:]]
    assert all(h == "/" or h.startswith("/AML") for h in hrefs), hrefs
    assert "blog" not in header.lower()


@pytest.mark.parametrize("host", ["aeyempire.com", "m.aeyempire.com"])
def test_no_footer(client, host):
    html = client.get("/AML/04/0001/002", headers={"host": host}).text
    assert "<footer" not in html


@pytest.mark.parametrize("host", ["aeyempire.com", "m.aeyempire.com"])
def test_progress_sits_with_the_score_not_the_facts(client, host):
    html = client.get("/AML/04/0001/002", headers={"host": host}).text
    assert "Aey&#39;s progress" not in html and "Aey's progress" not in html
    facts = html.split('class="info"' if host == "aeyempire.com" else 'class="m-info"', 1)[1].split("</dl>", 1)[0]
    assert "Completed" not in facts
    score = html.split('aria-label="Aey"', 1)[1].split("</section>", 1)[0]
    assert "Completed · 94 h" in score


def test_initials_tiles_when_there_are_no_pictures(client):
    html = client.get("/AML/04/0001/002").text
    assert html.count('class="pic pic-portrait pic-empty"') == 6        # characters
    assert "pic-avatar" not in html                                     # voice actors get no picture
    assert html.count('class="pic pic-logo pic-empty"') == 2            # companies
    assert html.count('class="pic pic-round pic-empty"') == 1           # staff
    assert 'pic-empty" aria-hidden="true">MY</span>' in html            # Makoto Yuki
    assert 'pic-empty" aria-hidden="true">A</span>' in html             # Aigis / Atlus


def _app_with_flags(tmp_path, files):
    for name in files:
        (tmp_path / name).write_bytes(PNG_1X1)
    return TestClient(create_app(Settings(root_path="/AML", database_url=URL, flags_dir=str(tmp_path))))


@pytest.mark.parametrize("host", ["aeyempire.com", "m.aeyempire.com"])
def test_cast_shows_a_language_square_when_there_is_no_flag(client, tmp_path, host):
    html = _app_with_flags(tmp_path, []).get("/AML/04/0001/002", headers={"host": host}).text
    assert html.count('<span class="lang-flag lang-flag-code" title="JA · Voice">JA</span>') == 6
    assert html.count('<span class="lang-flag lang-flag-code" title="EN · Voice">EN</span>') == 6


def test_an_uppercase_flag_file_replaces_the_language_square(client, tmp_path):
    app = _app_with_flags(tmp_path, ["JA.png"])
    html = app.get("/AML/04/0001/002").text
    assert html.count('<img class="lang-flag" src="/AML/flags/JA.png?v=') == 6
    assert 'alt="JA" title="JA · Voice">' in html
    assert html.count('title="EN · Voice">EN</span>') == 6        # no EN flag here: still the code
    served = app.get("/AML/flags/JA.png")
    assert served.status_code == 200 and served.headers["content-type"] == "image/png"


def test_a_lowercase_flag_file_works_too(client, tmp_path):
    html = _app_with_flags(tmp_path, ["en.png"]).get("/AML/04/0001/002").text
    assert html.count('<img class="lang-flag" src="/AML/flags/en.png?v=') == 6


def test_the_real_flag_pack_is_used(client):
    """EN, JA, TR and MSA from Aey's pack are in app/static/flags."""
    html = client.get("/AML/04/0001/002").text
    assert html.count('<img class="lang-flag" src="/AML/flags/JA.png?v=') == 6
    assert html.count('<img class="lang-flag" src="/AML/flags/EN.png?v=') == 6
    assert "lang-flag-code" not in html


@pytest.mark.parametrize("host", ["aeyempire.com", "m.aeyempire.com"])
def test_backend_points_are_never_shown(client, host):
    """PLANNING.md: the page shows -10..+10; the -50..+50 range stays in the backend."""
    html = client.get("/AML/04/0001/002", headers={"host": host}).text
    for backend in ("±50", "stored", "+32", "+40", "+35", "-15", "−15"):
        assert backend not in html, backend
    assert "+6.4" in html and "+8.0" in html and "−3.0" in html


@pytest.mark.parametrize("host", ["aeyempire.com", "m.aeyempire.com"])
def test_relationships_use_tags_not_dashes(client, host):
    html = client.get("/AML/04/0001/002", headers={"host": host}).text
    block = html.split("Related" if host == "aeyempire.com" else "Connections", 1)[1].split("</ul>", 2)
    connections = "".join(block[:2])
    assert "—" not in connections and "Main work" not in connections
    assert '<span class="rel-tag">Original work</span>' in connections


@pytest.mark.parametrize("host", ["aeyempire.com", "m.aeyempire.com"])
def test_titles_sit_above_status_with_big_flags(client, host):
    html = client.get("/AML/04/0001/002", headers={"host": host}).text
    facts = html.split('class="info"' if host == "aeyempire.com" else 'class="m-info"', 1)[1].split("</dl>", 1)[0]
    assert facts.index("<dt>Titles</dt>") < facts.index("<dt>Status</dt>")
    assert facts.count('<li class="title-row">') == 2                                            # the latinized title is not its own row
    assert facts.count('<img class="lang-flag lang-flag-big" src="/AML/flags/JA.png?v=') == 1
    assert facts.count('<img class="lang-flag lang-flag-big" src="/AML/flags/EN.png?v=') == 1
    assert ('<span class="title-text" lang="ja">ペルソナ3 リロード</span>'
            '<span class="title-latinized" lang="ja-Latn">Perusona Surī Rirōdo</span>') in facts
    assert "Latinized" not in facts and "Romanized" not in facts


@pytest.mark.parametrize("host", ["aeyempire.com", "m.aeyempire.com"])
def test_age_rating_icons_in_the_facts_after_platforms(client, host):
    html = client.get("/AML/04/0001/002", headers={"host": host}).text
    facts = html.split('class="info"' if host == "aeyempire.com" else 'class="m-info"', 1)[1].split("</dl>", 1)[0]
    assert facts.index("<dt>Platforms</dt>") < facts.index("<dt>Age Ratings</dt>")
    ratings = facts.split("<dt>Age Ratings</dt>", 1)[1].split("</ul>", 1)[0]
    shown = re.findall(r'<a class="age-rating" href="(/AML/29/[0-9/]+)" title="([^"]+)"><img class="age-icon" src="/AML/media/[0-9a-f]{64}\.svg" alt="([^"]+)"></a>', ratings)
    assert shown == [
        ("/AML/29/03/19/03", "CERO C", "CERO C"),
        ("/AML/29/01/19/04", "PEGI 16", "PEGI 16"),
        ("/AML/29/02/19/05", "ESRB Mature 17+", "ESRB Mature 17+"),
    ]


def test_age_rating_icons_are_served_as_svg(client):
    html = client.get("/AML/04/0001/002").text
    for src in re.findall(r'<img class="age-icon" src="(/AML/media/[0-9a-f]{64}\.svg)"', html):
        served = client.get(src)
        assert served.status_code == 200 and served.headers["content-type"] == "image/svg+xml"
        assert served.content.lstrip().startswith((b"<?xml", b"<svg", b"<!DOCTYPE"))


def test_a_rating_without_an_icon_shows_its_name(client):   # client: skip when the dev database is down
    from psycopg.rows import dict_row

    from app.data.work import load_work
    from app.main import TEMPLATES

    # The icon is removed inside a transaction that is rolled back, so the page is
    # rendered from that transaction's data rather than through the app's own connection.
    with psycopg.connect(URL, row_factory=dict_row, autocommit=True) as conn:
        with conn.transaction(force_rollback=True):
            conn.execute("DELETE FROM core.image WHERE entity_id = (SELECT entity_id FROM core.resolve('/29/03/19/03'))")
            work = load_work(conn, conn.execute("SELECT entity_id FROM core.resolve('/04/0001/002')").fetchone()["entity_id"])
    html = str(TEMPLATES.env.get_template("macros.html").module.age_ratings("/AML", work["age_ratings"]))
    assert '<a class="age-rating" href="/AML/29/03/19/03" title="CERO C"><span class="age-text">CERO C</span></a>' in html
    assert html.count('<img class="age-icon"') == 2


def test_arabic_uses_the_msa_flag(client, tmp_path):
    (tmp_path / "MSA.png").write_bytes(PNG_1X1)
    app = TestClient(create_app(Settings(root_path="/AML", database_url=URL, flags_dir=str(tmp_path))))
    with psycopg.connect(URL, autocommit=True) as conn:
        work = conn.execute("SELECT entity_id FROM core.resolve('/04/0001/002')").fetchone()[0]
        conn.execute("INSERT INTO core.title (entity_id, lang, title_type, text) VALUES (%s, 'ar', 'full', 'بيرسونا 3 ريلود')", (work,))
        try:
            html = app.get("/AML/04/0001/002").text
            assert '<img class="lang-flag lang-flag-big" src="/AML/flags/MSA.png?v=' in html
            assert '<span class="title-text" lang="ar">بيرسونا 3 ريلود</span>' in html
        finally:
            conn.execute("DELETE FROM core.title WHERE entity_id = %s AND lang = 'ar'", (work,))


def test_dlc_elsewhere_and_links_are_framed(client):
    html = client.get("/AML/04/0001/002").text
    more = html.split('class="more"', 1)[1]
    assert more.count('class="tile"') == 1                # the DLC
    assert more.count('class="tile tile-rating"') == 2    # Metacritic, HowLongToBeat
    assert more.count('class="tile tile-link"') == 1      # Steam
    assert '<a class="tile" href="/AML/04/0001/002/14/001"><span class="tile-title">Episode Aigis -The Answer-</span><span class="tile-meta">2024/09/10</span></a>' in more


def test_links_are_not_underlined_and_brighten_on_hover(client):
    css = client.get("/AML/static/aml.css").text
    assert "border-bottom: 1px solid rgba(154, 160, 255" not in css
    assert "border-bottom-color" not in css
    assert "a:hover { filter: brightness(1.35); }" in css


def test_a_real_logo_is_shown_and_served(client, tmp_path):
    sha = hashlib.sha256(PNG_1X1).hexdigest()
    (tmp_path / f"{sha}.png").write_bytes(PNG_1X1)
    app = TestClient(create_app(Settings(root_path="/AML", database_url=URL, media_dir=str(tmp_path))))
    with psycopg.connect(URL, autocommit=True) as conn:
        atlus = conn.execute("SELECT entity_id FROM core.resolve('/24/0001')").fetchone()[0]
        conn.execute(
            "INSERT INTO core.image (entity_id, image_type, sha256, format, is_primary) VALUES (%s, 'logo', %s, 'png', true)",
            (atlus, sha),
        )
        try:
            html = app.get("/AML/04/0001/002").text
            assert f'<img class="pic pic-logo" src="/AML/media/{sha}.png" alt="" loading="lazy">' in html
            assert html.count('class="pic pic-logo pic-empty"') == 1     # Sega still has none
            served = app.get(f"/AML/media/{sha}.png")
            assert served.status_code == 200 and served.headers["content-type"] == "image/png"
            assert served.content == PNG_1X1
        finally:
            conn.execute("DELETE FROM core.image WHERE entity_id = %s AND sha256 = %s", (atlus, sha))


def test_media_files_cannot_run_script_when_opened_directly(client, tmp_path):
    svg = b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
    name = hashlib.sha256(svg).hexdigest() + ".svg"
    (tmp_path / name).write_bytes(svg)
    app = TestClient(create_app(Settings(root_path="/AML", database_url=URL, media_dir=str(tmp_path))))
    served = app.get(f"/AML/media/{name}")
    assert served.status_code == 200 and served.headers["content-type"] == "image/svg+xml"
    policy = served.headers["content-security-policy"]
    assert "default-src 'none'" in policy and "sandbox" in policy and "script" not in policy
    assert served.headers["x-content-type-options"] == "nosniff"


def test_missing_media_file_is_404(client, tmp_path):
    app = TestClient(create_app(Settings(root_path="/AML", database_url=URL, media_dir=str(tmp_path))))
    assert app.get("/AML/media/" + "0" * 64 + ".png").status_code == 404


def test_sample_notice_only_when_switched_on(client):   # client: skip when the dev database is down
    quiet = TestClient(create_app(Settings(root_path="/AML", database_url=URL)))
    loud = TestClient(create_app(Settings(root_path="/AML", database_url=URL, sample_notice=True)))
    assert "Sample data" not in quiet.get("/AML/04/0001/002").text
    assert "Sample data" in loud.get("/AML/04/0001/002").text
