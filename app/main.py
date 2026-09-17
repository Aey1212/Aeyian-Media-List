"""The AML app.

The site itself is mounted under the root path (/AML). Everything outside it
belongs to the rest of aeyempire.com, except case variants of the root path
(/aml, /Aml ...), which redirect to it with the rest of the URL kept.
"""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from app.config import Settings, load_settings
from app.data.address import resolve
from app.data.character import load_character
from app.data.company import load_company
from app.data.franchise import load_franchise
from app.data.person import load_person
from app.data.work import load_work
from app.db import connect

HERE = Path(__file__).parent
TEMPLATES = Jinja2Templates(directory=str(HERE / "templates"))

# AML's own menus in the header: the six primary media, by kind code (/AML/01 ...).
# Header links never leave the site except Home, which is aeyempire.com itself.
MENU = [
    ("Anime", "01"),
    ("Manga", "02"),
    ("Light Novels", "03"),
    ("Games", "04"),
    ("Series", "05"),
    ("Movies", "06"),
]

# Which loader and template draw a page, by entity kind. Every media work uses "work".
PAGES = {
    "character": (load_character, "character"),
    "person": (load_person, "person"),
    "company": (load_company, "company"),
    "franchise": (load_franchise, "franchise"),
}
MEDIA_PAGE = (load_work, "work")

# Square language flags, looked up in this order of file types.
FLAG_EXTENSIONS = ("svg", "png", "webp")
# Language codes whose flag file in Aey's pack has another name (Arabic is tagged ar, drawn as MSA).
FLAG_ALIASES = {"ar": "MSA"}


class MediaFiles(StaticFiles):
    """Pictures from the media folder.

    An SVG opened on its own (not through an <img>) is a document that could run script
    on the site. This policy keeps every media file an inert picture; pictures shown in
    pages are not affected.
    """

    POLICY = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox"

    async def get_response(self, path: str, scope) -> Response:
        response = await super().get_response(path, scope)
        response.headers["Content-Security-Policy"] = self.POLICY
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response


def create_site(settings: Settings) -> FastAPI:
    site = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    # Both mounted before the address route, which would otherwise catch them.
    # StaticFiles errors on the first request if its folder is missing, so make sure it exists.
    Path(settings.media_dir).mkdir(parents=True, exist_ok=True)
    Path(settings.flags_dir).mkdir(parents=True, exist_ok=True)
    site.mount("/static", StaticFiles(directory=str(HERE / "static")), name="static")
    site.mount("/media", MediaFiles(directory=settings.media_dir), name="media")
    site.mount("/flags", StaticFiles(directory=settings.flags_dir), name="flags")

    def asset(name: str) -> str:
        """URL of a static file with its modification time as a version.

        Without it, a browser can keep using an old stylesheet after the file changes,
        drawing new markup with old rules (it happened: Firefox kept a pre-change aml.css).
        """
        try:
            version = format((HERE / "static" / name).stat().st_mtime_ns, "x")
        except FileNotFoundError:
            version = "0"
        return f"{settings.root_path}/static/{name}?v={version}"

    def flag(lang: str | None) -> str | None:
        """URL of the square flag for a language tag, or None.

        Files in the flags folder are named by language code, in either case:
        JA.png or ja.png ('ja-Latn' falls back to JA). Tags are validated by the
        database (core.lang_tag), so they are safe to use as file names.
        """
        if not lang:
            return None
        folder = Path(settings.flags_dir)
        tag = lang.lower()
        base = tag.split("-")[0]
        for name in dict.fromkeys(n for n in (tag, base, FLAG_ALIASES.get(base)) if n):
            for spelled in dict.fromkeys([name.upper(), name]):
                for ext in FLAG_EXTENSIONS:
                    path = folder / f"{spelled}.{ext}"
                    if path.is_file():
                        return f"{settings.root_path}/flags/{path.name}?v={path.stat().st_mtime_ns:x}"
        return None

    def page_context(**values):
        return {
            "base": settings.root_path,
            "sample_notice": settings.sample_notice,
            "mobile_origin": settings.mobile_origin,
            "menu": MENU,
            "asset": asset,
            "flag": flag,
            **values,
        }

    def variant(request: Request) -> str:
        """'mobile' for m.aeyempire.com (port ignored), 'desktop' otherwise."""
        host = request.headers.get("host", "").rsplit(":", 1)[0].lower()
        return "mobile" if host in settings.mobile_hosts else "desktop"

    def not_found(request: Request) -> Response:
        return TEMPLATES.TemplateResponse(
            request, f"{variant(request)}/not_found.html", page_context(), status_code=404
        )

    @site.get("/", response_class=HTMLResponse)
    def home() -> str:
        return "<!doctype html><title>AML</title><p>Aeyian Media List</p>"

    @site.get("/{address:path}")
    def entity_page(address: str, request: Request) -> Response:
        requested = "/" + address
        with connect(settings.database_url) as conn:
            found = resolve(conn, requested)
            if found is None:
                return not_found(request)
            # Retired addresses, and live ones typed differently (lowercase, O for 0,
            # a trailing slash), go to the canonical address with the query kept.
            if found["redirected"] or found["canonical"] != requested:
                target = settings.root_path + found["canonical"]
                if request.url.query:
                    target += "?" + request.url.query
                return RedirectResponse(target, status_code=301)
            kind = conn.execute("SELECT kind FROM core.entity WHERE id = %s", (found["entity_id"],)).fetchone()["kind"]
            loader, name = PAGES.get(kind, MEDIA_PAGE)
            page = loader(conn, found["entity_id"], settings.lang)
        if page is None:   # a draft, or a kind whose page is not built yet
            return not_found(request)
        return TEMPLATES.TemplateResponse(request, f"{variant(request)}/{name}.html", page_context(**{name: page}))

    return site


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or load_settings()
    prefix_segment = settings.root_path.strip("/")

    outer = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

    @outer.middleware("http")
    async def canonical_root_case(request: Request, call_next):
        path = request.url.path
        first = path.split("/", 2)[1] if path.startswith("/") else ""
        if first != prefix_segment and first.lower() == prefix_segment.lower():
            target = "/" + prefix_segment + path[len(first) + 1:]
            if request.url.query:
                target += "?" + request.url.query
            return RedirectResponse(target, status_code=301)
        return await call_next(request)

    outer.mount(settings.root_path, create_site(settings))
    return outer


app = create_app()
