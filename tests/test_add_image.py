"""The picture import tool, against the seeded dev database.

Every check runs inside a transaction that is rolled back, with a temporary media folder.
"""

from __future__ import annotations

import base64
import hashlib
import os
import stat

import psycopg
import pytest
from psycopg.rows import dict_row

from app.config import DEV_DATABASE_URL
from app.tools.add_image import add_image, main

URL = os.environ.get("AML_DATABASE_URL", DEV_DATABASE_URL)
PNG_1X1 = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAMAASsJTYQAAAAASUVORK5CYII=")
SVG = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 5"><rect width="4" height="5"/></svg>'


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


def images(conn, entity_id):
    return conn.execute(
        "SELECT image_type, sha256, format, byte_size, is_primary, sort_order FROM core.image WHERE entity_id = %s ORDER BY sort_order",
        (entity_id,),
    ).fetchall()


def test_the_file_is_copied_unchanged_and_named_by_its_hash(conn, sega, tmp_path):
    source = tmp_path / "Sega Logo.svg"
    source.write_bytes(SVG)
    media = tmp_path / "media"
    with conn.transaction(force_rollback=True):
        result = add_image(conn, sega, "logo", source, media)
        sha = hashlib.sha256(SVG).hexdigest()
        stored = media / f"{sha}.svg"
        assert result == {"sha256": sha, "format": "svg", "path": str(stored), "added": True, "primary": True}
        assert stored.read_bytes() == SVG
        assert stat.S_IMODE(stored.stat().st_mode) == 0o644
        assert source.read_bytes() == SVG                          # the original is left alone
        assert [f.name for f in media.iterdir()] == [stored.name]  # no temporary file left behind
        assert images(conn, sega) == [
            {"image_type": "logo", "sha256": sha, "format": "svg", "byte_size": len(SVG), "is_primary": True, "sort_order": 0},
        ]


def test_the_first_of_a_type_is_primary_and_the_next_one_is_not(conn, sega, tmp_path):
    (tmp_path / "a.svg").write_bytes(SVG)
    (tmp_path / "b.PNG").write_bytes(PNG_1X1)
    with conn.transaction(force_rollback=True):
        first = add_image(conn, sega, "logo", tmp_path / "a.svg", tmp_path / "media")
        second = add_image(conn, sega, "logo", tmp_path / "b.PNG", tmp_path / "media")
        banner = add_image(conn, sega, "banner", tmp_path / "b.PNG", tmp_path / "media")
        assert (first["primary"], second["primary"], banner["primary"]) == (True, False, True)
        assert second["format"] == "png"
        assert [(i["image_type"], i["format"], i["is_primary"], i["sort_order"]) for i in images(conn, sega)] == [
            ("logo", "svg", True, 0), ("banner", "png", True, 0), ("logo", "png", False, 1),
        ]


def test_adding_the_same_file_again_changes_nothing(conn, sega, tmp_path):
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
        assert add_image(conn, sega, "logo", tmp_path / "photo.jpeg", tmp_path / "media")["format"] == "jpg"


@pytest.mark.parametrize(("name", "image_type", "constraint"), [
    ("logo.bmp", "logo", "image_format_fk"),
    ("logo.svg", "sticker", "image_type_fk"),
])
def test_unknown_formats_and_types_are_refused_before_any_file_is_written(conn, sega, tmp_path, name, image_type, constraint):
    (tmp_path / name).write_bytes(SVG)
    media = tmp_path / "media"
    with pytest.raises(psycopg.errors.ForeignKeyViolation) as refused:
        with conn.transaction():
            add_image(conn, sega, image_type, tmp_path / name, media)
    assert refused.value.diag.constraint_name == constraint
    assert not media.exists()


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
    assert main(["/24/0002", "logo", str(tmp_path / "logo.bmp")]) == 1
    assert "refused: image_format_fk" in capsys.readouterr().err
    assert images(conn, sega) == []
