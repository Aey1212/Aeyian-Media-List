"""Toradora! pictures, from Aey's folder of originals.

Each file becomes a web copy in the media folder (AML_MEDIA_DIR); his originals
are not touched. Paths are relative to AML_PICTURES (default /mnt/hdd/Backups),
or absolute. Files are matched to entities by kind and English name, so this
works whatever addresses a database hands out.

A picture can carry a crop box (left, top, width, height) in the coordinates of
the original file: the anime cover is a 3:4 crop of Aey's 1355 × 762 wallpaper,
so the wallpaper stays untouched and the cover can be made again exactly.

Pictures follow the ratios in Documents/SCHEMA.md: portraits of characters 3:4,
people 1:1, covers 3:4, logos any shape. Run by db/dev.sh content.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import psycopg
from PIL import Image

from app.config import load_settings
from app.tools.add_image import add_image

PICTURES = Path(os.environ.get("AML_PICTURES", "/mnt/hdd/Backups"))

# (kind, English name, image type, file, crop box or None)
FILES = [
    ("character", "Taiga Aisaka", "portrait", "portraits/Taiga portrait.png", None),
    ("character", "Ryuji Takasu", "portrait", "portraits/Ryuuji portrait.png", None),
    ("character", "Minori Kushieda", "portrait", "portraits/Minori portrait.png", None),
    # Aey's wallpaper, cropped to 3:4 around Ryuji and Taiga
    ("anime", "Toradora!", "cover", "/home/aey/Pictures/Background/Toradora.jpeg", (429, 0, 576, 762)),
]


def source(file: str) -> Path:
    """Where the original lives: absolute as given, otherwise inside the pictures folder."""
    path = Path(file)
    return path if path.is_absolute() else PICTURES / path


def main() -> int:
    missing = [f for _, _, _, f, _ in FILES if not source(f).is_file()]
    if missing:
        print(f"not found: {', '.join(missing)} (set AML_PICTURES to the folder of originals)", file=sys.stderr)
        return 1
    settings = load_settings()
    with psycopg.connect(settings.database_url) as conn:
        for kind, name, image_type, file, crop in FILES:
            rows = conn.execute(
                """
                SELECT e.id, core.address(e.id)
                  FROM core.entity e
                 WHERE e.kind = %s
                   AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = e.id AND t.lang = 'en' AND t.text = %s)
                """,
                (kind, name),
            ).fetchall()
            if len(rows) != 1:
                # an exception, not a return: leaving by exception rolls back what was added
                raise SystemExit(f"expected one {kind} named {name}, found {len(rows)}")
            entity_id, address = rows[0]
            shape = "person" if kind == "person" else "portrait"
            if crop is None:
                result = add_image(conn, entity_id, image_type, source(file), settings.media_dir, shape=shape)
            else:
                left, top, width, height = crop
                with Image.open(source(file)) as picture, tempfile.TemporaryDirectory() as folder:
                    cut = Path(folder) / "crop.png"
                    picture.crop((left, top, left + width, top + height)).save(cut, format="PNG")
                    result = add_image(conn, entity_id, image_type, cut, settings.media_dir, shape=shape)
            where = f"{file} cropped {crop}" if crop else file
            print(f"  {address}  {name} {image_type}: {where}{'' if result['added'] else ' (already there)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
