"""The picture import tool, against the seeded dev database.

Every check runs inside a transaction that is rolled back, with a temporary media folder.
"""

from __future__ import annotations

import hashlib
import io
import os
import stat

import psycopg
import pytest
from PIL import Image
from psycopg.rows import dict_row

from app.config import DEV_DATABASE_URL
from app.tools.add_image import add_image, main
from app.tools.pictures import web_copy, web_size

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
SVG = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 5"><rect width="4" height="5"/></svg>'


def picture(path, width, height, mode="RGB"):
    """A test picture of a given size, saved as PNG. RGBA ones are half transparent."""
    image = Image.new(mode, (width, height), (200, 120, 60) if mode == "RGB" else (200, 120, 60, 0))
    if mode == "RGBA":
        image.paste((10, 200, 90, 255), (0, 0, width // 2, height))
    image.save(path, format="PNG")
    return path


@pytest.fixture(scope="module")
def conn():
    try:
        connection = psycopg.connect(URL, row_factory=dict_row, autocommit=True, connect_timeout=3)
    except psycopg.OperationalError:
        pytest.skip(f"dev database not reachable at {URL}: run db/dev.sh up && db/dev.sh seed")
    with connection:
        if connection.execute("SELECT count(*) AS n FROM core.resolve('/24/0001')").fetchone()["n"] != 1:
            pytest.skip("dev database is not seeded: run db/dev.sh up && db/dev.sh seed")
        yield connection


@pytest.fixture()
def sega(conn):
    return conn.execute("SELECT entity_id FROM core.resolve('/24/0002')").fetchone()["entity_id"]


@pytest.fixture()
def character(conn):
    return conn.execute("SELECT entity_id FROM core.resolve('/22/0001')").fetchone()["entity_id"]


@pytest.fixture()
def person(conn):
    return conn.execute("SELECT entity_id FROM core.resolve('/23/00001')").fetchone()["entity_id"]


def images(conn, entity_id):
    return conn.execute(
        """
        SELECT image_type, sha256, format, byte_size, width, height, is_primary, sort_order
          FROM core.image WHERE entity_id = %s ORDER BY sort_order
        """,
        (entity_id,),
    ).fetchall()


# --- what gets stored --------------------------------------------------------

def test_the_site_serves_a_web_copy_at_the_site_size(conn, character, tmp_path):
    """Aey's 960x1280 portraits are stored as 480x640 WebP; his file is left alone."""
    source = picture(tmp_path / "Taiga portrait.png", 960, 1280)
    original = source.read_bytes()
    media = tmp_path / "media"
    with conn.transaction(force_rollback=True):
        result = add_image(conn, character, "portrait", source, media)
        assert (result["format"], result["width"], result["height"]) == ("webp", 480, 640)
        stored = media / f"{result['sha256']}.webp"
        assert stored.is_file() and stat.S_IMODE(stored.stat().st_mode) == 0o644
        assert len(stored.read_bytes()) < len(original) / 5      # much lighter than the original
        with Image.open(io.BytesIO(stored.read_bytes())) as copy:
            assert (copy.format, copy.size) == ("WEBP", (480, 640))
        assert source.read_bytes() == original                   # the original is untouched
        assert images(conn, character)[0] | {"sha256": None} == {
            "image_type": "portrait", "sha256": None, "format": "webp", "byte_size": len(stored.read_bytes()),
            "width": 480, "height": 640, "is_primary": True, "sort_order": 0,
        }


def test_a_person_portrait_is_square(conn, person, tmp_path):
    source = picture(tmp_path / "meguro.png", 1440, 1440)
    with conn.transaction(force_rollback=True):
        result = add_image(conn, person, "portrait", source, tmp_path / "media")
        assert (result["format"], result["width"], result["height"]) == ("webp", 720, 720)


def test_a_small_picture_is_never_made_bigger(conn, character, tmp_path):
    source = picture(tmp_path / "tiny.png", 60, 80)
    with conn.transaction(force_rollback=True):
        result = add_image(conn, character, "portrait", source, tmp_path / "media")
        assert (result["width"], result["height"]) == (60, 80)


def test_transparency_is_kept(conn, sega, tmp_path):
    source = picture(tmp_path / "logo.png", 900, 900, mode="RGBA")
    with conn.transaction(force_rollback=True):
        result = add_image(conn, sega, "logo", source, tmp_path / "media")
        with Image.open(tmp_path / "media" / f"{result['sha256']}.webp") as copy:
            assert copy.mode in ("RGBA", "LA", "P")
        assert (result["width"], result["height"]) == (512, 512)


def test_svg_is_stored_exactly_as_it_is(conn, sega, tmp_path):
    source = tmp_path / "Sega Logo.svg"
    source.write_bytes(SVG)
    media = tmp_path / "media"
    with conn.transaction(force_rollback=True):
        result = add_image(conn, sega, "logo", source, media)
        sha = hashlib.sha256(SVG).hexdigest()
        assert (result["sha256"], result["format"], result["width"]) == (sha, "svg", None)
        assert (media / f"{sha}.svg").read_bytes() == SVG
        assert [f.name for f in media.iterdir()] == [f"{sha}.svg"]   # no temporary file left behind


def test_as_is_stores_the_file_untouched(conn, character, tmp_path):
    source = picture(tmp_path / "portrait.png", 960, 1280)
    with conn.transaction(force_rollback=True):
        result = add_image(conn, character, "portrait", source, tmp_path / "media", as_is=True)
        assert (result["format"], result["width"]) == ("png", None)
        assert (tmp_path / "media" / f"{result['sha256']}.png").read_bytes() == source.read_bytes()


def test_the_site_sizes_come_from_the_schema_document():
    assert web_size("portrait", "character") == (480, 640)
    assert web_size("portrait", "person") == (720, 720)
    assert web_size("cover", "soundtrack") == (600, 600)
    assert web_size("cover", "anime") == (600, 800)
    assert web_size("thumbnail", "episode") == (640, 360)
    assert web_size("sticker", "anime") is None


def test_a_picture_with_no_size_rule_is_stored_as_it_is(tmp_path):
    source = picture(tmp_path / "odd.png", 100, 100)
    assert web_copy(source, "sticker", "anime") == (source.read_bytes(), "png", None, None)


# --- rows -------------------------------------------------------------------

def test_the_first_of_a_type_is_primary_and_the_next_one_is_not(conn, sega, tmp_path):
    (tmp_path / "a.svg").write_bytes(SVG)
    picture(tmp_path / "b.PNG", 40, 40)
    with conn.transaction(force_rollback=True):
        first = add_image(conn, sega, "logo", tmp_path / "a.svg", tmp_path / "media")
        second = add_image(conn, sega, "logo", tmp_path / "b.PNG", tmp_path / "media")
        banner = add_image(conn, sega, "banner", tmp_path / "b.PNG", tmp_path / "media")
        assert (first["primary"], second["primary"], banner["primary"]) == (True, False, True)
        assert second["format"] == "webp"
        assert [(i["image_type"], i["format"], i["is_primary"], i["sort_order"]) for i in images(conn, sega)] == [
            ("logo", "svg", True, 0), ("banner", "webp", True, 0), ("logo", "webp", False, 1),
        ]


def test_adding_the_same_picture_again_changes_nothing(conn, sega, tmp_path):
    (tmp_path / "logo.svg").write_bytes(SVG)
    with conn.transaction(force_rollback=True):
        add_image(conn, sega, "logo", tmp_path / "logo.svg", tmp_path / "media")
        again = add_image(conn, sega, "logo", tmp_path / "logo.svg", tmp_path / "media")
        assert (again["added"], again["primary"]) == (False, True)
        assert len(images(conn, sega)) == 1


def test_a_damaged_stored_file_is_replaced(conn, sega, tmp_path):
    (tmp_path / "logo.svg").write_bytes(SVG)
    media = tmp_path / "media"
    media.mkdir()
    damaged = media / f"{hashlib.sha256(SVG).hexdigest()}.svg"
    damaged.write_bytes(b"<svg")
    with conn.transaction(force_rollback=True):
        add_image(conn, sega, "logo", tmp_path / "logo.svg", media)
        assert damaged.read_bytes() == SVG


def test_jpeg_is_stored_as_jpg(conn, sega, tmp_path):
    (tmp_path / "photo.jpeg").write_bytes(b"\xff\xd8\xff\xe0 not really a photo")
    with conn.transaction(force_rollback=True):
        assert add_image(conn, sega, "logo", tmp_path / "photo.jpeg", tmp_path / "media", as_is=True)["format"] == "jpg"


@pytest.mark.parametrize(("name", "image_type", "constraint"), [
    ("logo.bmp", "logo", "image_format_fk"),
    ("logo.svg", "sticker", "image_type_fk"),
])
def test_unknown_formats_and_types_are_refused_before_any_file_is_written(conn, sega, tmp_path, name, image_type, constraint):
    (tmp_path / name).write_bytes(SVG)
    media = tmp_path / "media"
    with pytest.raises(psycopg.errors.ForeignKeyViolation) as refused:
        with conn.transaction():
            add_image(conn, sega, image_type, tmp_path / name, media, as_is=True)
    assert refused.value.diag.constraint_name == constraint
    assert not media.exists()


# --- the command line --------------------------------------------------------

def test_command_line_refuses_unknown_addresses_and_missing_files(conn, tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("AML_DATABASE_URL", URL)
    monkeypatch.setenv("AML_MEDIA_DIR", str(tmp_path / "media"))
    (tmp_path / "logo.svg").write_bytes(SVG)
    assert main(["/24/0ZZZ", "logo", str(tmp_path / "logo.svg")]) == 1
    assert "nothing lives at /24/0ZZZ" in capsys.readouterr().err
    assert main(["/24/0002", "logo", str(tmp_path / "missing.svg")]) == 1
    assert "no such file" in capsys.readouterr().err


def test_command_line_reports_a_refusal_and_keeps_nothing(conn, sega, tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("AML_DATABASE_URL", URL)
    monkeypatch.setenv("AML_MEDIA_DIR", str(tmp_path / "media"))
    (tmp_path / "logo.bmp").write_bytes(SVG)
    assert main(["/24/0002", "logo", str(tmp_path / "logo.bmp"), "--as-is"]) == 1
    assert "refused: image_format_fk" in capsys.readouterr().err
    assert images(conn, sega) == []
