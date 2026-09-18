"""Turning a picture into the copy the site serves.

Aey keeps the originals; the site stores a web copy: the site size from
Documents/SCHEMA.md, as WebP (about twenty times smaller than his PNGs, with
transparency kept). Vector pictures (SVG) are stored exactly as they are.

A picture is only ever scaled down, never up, and never cropped: its own ratio
is kept, and pages crop to their frames.
"""

from __future__ import annotations

import io
from pathlib import Path

from PIL import Image

# Longest size the site serves, per image type and the kind of entity it belongs to
# (Documents/SCHEMA.md, "Image ratios"). None as the kind means every other kind.
WEB_SIZES: dict[tuple[str, str | None], tuple[int, int]] = {
    ("portrait", "person"): (720, 720),      # square, rounded corners
    ("portrait", None): (480, 640),          # characters, 3:4
    ("cover", "soundtrack"): (600, 600),     # album art, 1:1
    ("cover", None): (600, 800),
    ("poster", None): (600, 800),
    ("box_art", None): (600, 800),
    ("season_poster", None): (600, 800),
    ("volume_cover", None): (600, 800),
    ("logo", None): (512, 512),
    ("icon", None): (256, 256),
    ("banner", None): (1600, 400),
    ("backdrop", None): (1920, 1080),
    ("thumbnail", None): (640, 360),
}

# Pictures that are drawings, not photographs: stored as they are.
VECTOR_FORMATS = {"svg"}

# How wide each kind of picture is actually drawn on the pages, per CSS:
#   portrait/cover 180px, person cards 200px, credit logos 56px, company page logo 180px.
# A picture is stored at the master size AND at the size a page draws it, so the browser
# does not have to resample: <sha256>@<width>.webp next to <sha256>.<format>.
SLOT_WIDTHS: dict[str, list[int]] = {
    "portrait": [180, 360],
    "person": [200, 400],
    "logo": [56, 112, 180, 360],
    "round": [56, 112],
}


def renditions(data: bytes, fmt: str, shape: str) -> list[tuple[int, bytes]]:
    """(width, bytes) for each size the pages draw this kind of picture in, smaller than
    the picture itself. Vector pictures get none."""
    if fmt in VECTOR_FORMATS:
        return []
    try:
        picture = Image.open(io.BytesIO(data))
        picture.load()
    except OSError:
        return []   # stored as it is (--as-is): not something we can read
    out = []
    with picture:
        for width in SLOT_WIDTHS.get(shape, []):
            if width >= picture.width:
                continue
            small = picture.resize((width, max(1, round(picture.height * width / picture.width))), Image.LANCZOS)
            buffer = io.BytesIO()
            small.save(buffer, format="WEBP", quality=90, method=6)
            out.append((width, buffer.getvalue()))
    return out


def web_size(image_type: str, kind: str | None) -> tuple[int, int] | None:
    """The box this kind of picture is scaled into, or None when there is no rule."""
    return WEB_SIZES.get((image_type, kind)) or WEB_SIZES.get((image_type, None))


def web_copy(file: str | Path, image_type: str, kind: str | None) -> tuple[bytes, str, int | None, int | None]:
    """(bytes, format, width, height) of the copy to store.

    Rasters become WebP, scaled down into the site's box for their type; SVG and
    anything without a size rule is returned unchanged.
    """
    path = Path(file)
    data = path.read_bytes()
    extension = path.suffix.lower().lstrip(".")
    box = web_size(image_type, kind)
    if extension in VECTOR_FORMATS or box is None:
        return data, extension, None, None

    with Image.open(io.BytesIO(data)) as picture:
        picture.load()
        if picture.mode not in ("RGB", "RGBA"):
            picture = picture.convert("RGBA" if "transparency" in picture.info or picture.mode in ("LA", "PA") else "RGB")
        picture.thumbnail(box, Image.LANCZOS)   # only ever smaller; the ratio is kept
        out = io.BytesIO()
        picture.save(out, format="WEBP", quality=90, method=6)
        return out.getvalue(), "webp", picture.width, picture.height
