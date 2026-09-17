"""Icons for the age ratings from 0002_age_ratings.sql, from Aey's pack.

Each SVG is copied unchanged into the media folder (AML_MEDIA_DIR) as
<sha256>.svg by app.tools.add_image; the pack itself is not touched. The pack
folder is AML_AGE_ICONS (default /mnt/hdd/Backups/Age).

Ratings are found by their system and English name, not by address.
Run by db/dev.sh seed.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import psycopg

from app.config import load_settings
from app.tools.add_image import add_image

PACK = Path(os.environ.get("AML_AGE_ICONS", "/mnt/hdd/Backups/Age"))

ICONS = {
    ("PEGI", "3"): "PEGI_3.svg",
    ("PEGI", "7"): "PEGI_7.svg",
    ("PEGI", "12"): "PEGI_12.svg",
    ("PEGI", "16"): "PEGI_16.svg",
    ("PEGI", "18"): "PEGI_18.svg",
    ("PEGI", "Rating Pending"): "PEGI_Pending.svg",
    ("ESRB", "Early Childhood"): "ESRB_Early_Childhood.svg",
    ("ESRB", "Everyone"): "ESRB_Everyone.svg",
    ("ESRB", "Everyone 10+"): "ESRB_Everyone_10Plus.svg",
    ("ESRB", "Teen"): "ESRB_Teen.svg",
    ("ESRB", "Mature 17+"): "ESRB_Mature.svg",
    ("ESRB", "Adults Only 18+"): "ESRB_Adults_Only_18+.svg",
    ("ESRB", "Rating Pending"): "ESRB_Pending.svg",
    ("CERO", "A"): "CERO_A.svg",
    ("CERO", "B"): "CERO_B.svg",
    ("CERO", "C"): "CERO_C.svg",
    ("CERO", "D"): "CERO_D.svg",
    ("CERO", "Z"): "CERO_Z.svg",
    ("CERO", "Rating Pending"): "CERO_Pending.svg",
}


def main() -> int:
    missing = [name for name in ICONS.values() if not (PACK / name).is_file()]
    if missing:
        print(f"not in {PACK}: {', '.join(missing)} (set AML_AGE_ICONS to the pack folder)", file=sys.stderr)
        return 1
    settings = load_settings()
    with psycopg.connect(settings.database_url) as conn:
        for (system, rating), name in ICONS.items():
            rows = conn.execute(
                """
                SELECT r.id, core.address(r.id)
                  FROM core.entity r
                  JOIN core.entity s ON s.id = r.parent_id AND s.kind = 'age_rating_system'
                 WHERE r.kind = 'age_rating'
                   AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = s.id AND t.lang = 'en' AND t.text = %s)
                   AND EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = r.id AND t.lang = 'en' AND t.text = %s)
                """,
                (system, rating),
            ).fetchall()
            if len(rows) != 1:
                # an exception, not a return: leaving the block by exception rolls back the icons added so far
                raise SystemExit(f"expected one {system} {rating} rating, found {len(rows)}")
            rating_id, address = rows[0]
            result = add_image(conn, rating_id, "icon", PACK / name, settings.media_dir)
            print(f"  {address}  {system} {rating}: {name}{'' if result['added'] else ' (already there)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
