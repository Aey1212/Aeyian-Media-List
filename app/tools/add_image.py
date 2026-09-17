"""Add a picture to an entity.

    python -m app.tools.add_image ADDRESS IMAGE_TYPE FILE
    python -m app.tools.add_image /29/01/19/01 icon PEGI_3.svg

The file is copied unchanged into the media folder (AML_MEDIA_DIR) as
<sha256>.<format>, and gets a core.image row. The first picture of a type on an
entity becomes its primary picture, the one pages show. Adding the same file
again for the same entity and type changes nothing.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

import psycopg
from psycopg.rows import dict_row, tuple_row

from app.config import load_settings
from app.data.address import resolve

# File extensions spelled differently from the format codes in core.image_format.
FORMAT_ALIASES = {"jpeg": "jpg"}


def add_image(conn: psycopg.Connection, entity_id: int, image_type: str, file: str | Path, media_dir: str | Path) -> dict[str, Any]:
    """Store the file and record it. Does not commit.

    Returns {sha256, format, path, added, primary}; added is False when the entity
    already had this file as this image type. An unknown image type or format is
    refused by the database (image_type_fk, image_format_fk) before any file is written.
    """
    data = Path(file).read_bytes()
    extension = Path(file).suffix.lower().lstrip(".")
    fmt = FORMAT_ALIASES.get(extension, extension)
    sha = hashlib.sha256(data).hexdigest()

    cur = conn.cursor(row_factory=tuple_row)   # whatever rows the caller's connection makes
    row = cur.execute(
        """
        INSERT INTO core.image (entity_id, image_type, sha256, format, byte_size, is_primary, sort_order)
        SELECT %(entity)s, %(type)s, %(sha)s, %(format)s, %(size)s,
               NOT EXISTS (SELECT 1 FROM core.image
                            WHERE entity_id = %(entity)s AND image_type = %(type)s AND is_primary),
               COALESCE((SELECT max(sort_order) + 1 FROM core.image
                          WHERE entity_id = %(entity)s AND image_type = %(type)s), 0)
        ON CONFLICT ON CONSTRAINT image_file_once_uq DO NOTHING
        RETURNING is_primary
        """,
        {"entity": entity_id, "type": image_type, "sha": sha, "format": fmt, "size": len(data)},
    ).fetchone()
    if row is None:
        row = cur.execute(
            "SELECT is_primary FROM core.image WHERE entity_id = %s AND image_type = %s AND sha256 = %s AND format = %s",
            (entity_id, image_type, sha, fmt),
        ).fetchone()
        added = False
    else:
        added = True

    folder = Path(media_dir)
    target = folder / f"{sha}.{fmt}"
    if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != sha:
        folder.mkdir(parents=True, exist_ok=True)
        # Written under a temporary name first, so a page never sees half a file.
        with tempfile.NamedTemporaryFile(dir=folder, prefix=".adding-", delete=False) as tmp:
            tmp.write(data)
        os.chmod(tmp.name, 0o644)   # the web server may run as another user
        os.replace(tmp.name, target)

    return {"sha256": sha, "format": fmt, "path": str(target), "added": added, "primary": row[0]}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.tools.add_image", description="Add a picture to an entity.")
    parser.add_argument("address", help="the entity's address, e.g. /29/01/19/01")
    parser.add_argument("image_type", help="cover, poster, logo, portrait, icon ... (core.image_type)")
    parser.add_argument("file", help="the picture; copied unchanged")
    args = parser.parse_args(argv)

    settings = load_settings()
    if not Path(args.file).is_file():
        print(f"no such file: {args.file}", file=sys.stderr)
        return 1
    with psycopg.connect(settings.database_url, row_factory=dict_row) as conn:
        found = resolve(conn, args.address)
        if found is None:
            print(f"nothing lives at {args.address}", file=sys.stderr)
            return 1
        try:
            result = add_image(conn, found["entity_id"], args.image_type, args.file, settings.media_dir)
        except psycopg.errors.ForeignKeyViolation as error:
            conn.rollback()
            print(f"refused: {error.diag.constraint_name} ({error.diag.message_detail})", file=sys.stderr)
            return 1
    state = "added" if result["added"] else "already there"
    primary = ", primary" if result["primary"] else ""
    print(f"{found['canonical']} {args.image_type}: {state}{primary} -> {result['path']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
