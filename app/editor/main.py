"""The AML editor app (admin.aeyempire.com/aml/).

    AML_EDITOR_DEV=1 .venv/bin/uvicorn app.editor.main:app --port 8766

Pages: search (by name or address), one page per entity with Aey's own data in stored
points (-50..+50), and the change log. Every form posts to the entity's page with the
operation's name; the edit operations do the checking, the change and the log.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit

import psycopg
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from psycopg.rows import dict_row

from app.edit.operations import OPERATIONS, EditError, recent_changes, run, target
from app.editor.config import EditorSettings, load_editor_settings

HERE = Path(__file__).resolve().parent.parent
TEMPLATES = Jinja2Templates(directory=str(HERE / "templates"))


def _labels(conn: psycopg.Connection, table: str) -> dict[str, str]:
    """code -> English label for an option list (fixed table names only)."""
    rows = conn.execute(f"SELECT code, labels -> 'en' ->> 'text' AS label FROM {table} ORDER BY sort_order, code").fetchall()
    return {r["code"]: r["label"] for r in rows}


def search(conn: psycopg.Connection, query: str) -> list[dict[str, Any]]:
    """Entities whose address is the query, or with a name containing it; drafts included."""
    query = query.strip()
    if not query:
        return []
    exact = conn.execute("SELECT entity_id FROM core.resolve(%s)", (query,)).fetchone() if query.startswith("/") else None
    return conn.execute(
        """
        SELECT e.id, core.address(e.id) AS address, k.labels -> 'en' ->> 'text' AS kind, e.published_at IS NOT NULL AS published,
               (SELECT t.text FROM core.title t WHERE t.entity_id = e.id
                 ORDER BY (t.lang = 'en' AND t.preferred) DESC, (t.lang = 'en') DESC, t.native DESC, t.id LIMIT 1) AS title,
               p.address AS parent_address,
               (SELECT t.text FROM core.title t WHERE t.entity_id = e.parent_id
                 ORDER BY (t.lang = 'en' AND t.preferred) DESC, (t.lang = 'en') DESC, t.id LIMIT 1) AS parent_title
          FROM core.entity e
          JOIN core.entity_kind k ON k.name = e.kind
          LEFT JOIN LATERAL (SELECT core.address(e.parent_id) AS address) p ON e.parent_id IS NOT NULL
         WHERE e.id = %(exact)s
            OR EXISTS (SELECT 1 FROM core.title t WHERE t.entity_id = e.id AND t.text ILIKE '%%' || %(q)s || '%%')
         ORDER BY (e.id = %(exact)s) DESC NULLS LAST, k.code, title
         LIMIT 60
        """,
        {"q": query, "exact": exact["entity_id"] if exact else None},
    ).fetchall()


def entity_page(conn: psycopg.Connection, address: str) -> dict[str, Any]:
    """Everything the entity page shows: who it is, and Aey's own data in stored points."""
    entity = target(conn, address)
    row = conn.execute("SELECT published_at IS NOT NULL AS published FROM core.entity WHERE id = %s", (entity["id"],)).fetchone()
    data: dict[str, Any] = {"entity": entity, "published": row["published"]}
    if entity["rateable"]:
        data["score"] = conn.execute(
            "SELECT general, rated_on, aey.score_shown(general) AS shown, aey.half_stars(general) AS half_stars "
            "FROM aey.score WHERE entity_id = %s", (entity["id"],)
        ).fetchone()
        data["subratings"] = conn.execute(
            """
            SELECT s.category, c.labels -> 'en' ->> 'text' AS label, s.value, aey.score_shown(s.value) AS shown
              FROM aey.subrating s JOIN aey.subrating_category c ON c.code = s.category
             WHERE s.entity_id = %s ORDER BY c.sort_order, c.code
            """,
            (entity["id"],),
        ).fetchall()
        data["categories"] = _labels(conn, "aey.subrating_category")
        data["takes"] = conn.execute(
            "SELECT lang, body, written_on FROM aey.take WHERE entity_id = %s ORDER BY (lang = 'en') DESC, lang", (entity["id"],)
        ).fetchall()
    if entity["progress"]:
        data["progress"] = conn.execute(
            """
            SELECT status, progress_value, progress_unit, started_on, finished_on, times_completed,
                   round(time_spent_s / 3600.0, 2) AS hours, note
              FROM aey.progress WHERE entity_id = %s
            """,
            (entity["id"],),
        ).fetchone()
        data["statuses"] = _labels(conn, "aey.status")
        data["units"] = _labels(conn, "media.cadence_item")
    data["changes"] = recent_changes(conn, limit=20, address=entity["address"])
    return data


def create_editor(settings: EditorSettings | None = None) -> FastAPI:
    settings = settings or load_editor_settings()
    editor = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    site = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    site.mount("/static", StaticFiles(directory=str(HERE / "static")), name="static")

    def asset(name: str) -> str:
        try:
            version = format((HERE / "static" / name).stat().st_mtime_ns, "x")
        except FileNotFoundError:
            version = "0"
        return f"{settings.root_path}/static/{name}?v={version}"

    def connect() -> psycopg.Connection:
        return psycopg.connect(settings.database_url, row_factory=dict_row, autocommit=True)

    def page(request: Request, name: str, status: int = 200, **values) -> Response:
        return TEMPLATES.TemplateResponse(request, f"editor/{name}.html", {
            "base": settings.root_path, "asset": asset, "public_url": settings.public_url,
            "user": request.headers.get(settings.auth_header), "dev": settings.dev, **values,
        }, status_code=status)

    @editor.middleware("http")
    async def signed_in_only(request: Request, call_next):
        """Only requests that came through the admin login (nginx sets the header) get in."""
        if not settings.dev and not request.headers.get(settings.auth_header):
            return HTMLResponse("<!doctype html><title>AML editor</title><p>Sign in through admin.aeyempire.com.</p>",
                                status_code=403)
        if request.method == "POST":
            # a form posted from another site must not change anything
            source = request.headers.get("origin") or request.headers.get("referer") or ""
            if urlsplit(source).netloc != request.headers.get("host", ""):
                return HTMLResponse("<!doctype html><title>AML editor</title><p>Refused: not sent from the editor.</p>",
                                    status_code=403)
        return await call_next(request)

    @site.get("/", response_class=HTMLResponse)
    def index(request: Request, q: str = "") -> Response:
        with connect() as conn:
            results = search(conn, q)
            changes = recent_changes(conn, limit=15)
        return page(request, "index", q=q, results=results, changes=changes)

    @site.get("/changes", response_class=HTMLResponse)
    def changes(request: Request) -> Response:
        with connect() as conn:
            return page(request, "changes", changes=recent_changes(conn, limit=300))

    @site.get("/e/{address:path}", response_class=HTMLResponse)
    def show(address: str, request: Request, done: str = "") -> Response:
        with connect() as conn:
            try:
                data = entity_page(conn, "/" + address)
            except EditError as error:
                return page(request, "index", status=404, q="", results=[], changes=[], error=str(error))
        return page(request, "entity", done=done, **data)

    @site.post("/e/{address:path}", response_class=HTMLResponse)
    async def change(address: str, request: Request) -> Response:
        form = dict(await request.form())
        name = form.pop("op", "")
        if name not in OPERATIONS:
            return HTMLResponse("Unknown operation.", status_code=400)
        # only the fields the operation takes; the rest of the form is ignored
        params = {k: v for k, v in form.items() if k in OPERATIONS[name].params}
        with connect() as conn:
            try:
                result = run(conn, name, "/" + address, params, via="web")
            except EditError as error:
                data = entity_page(conn, "/" + address)
                return page(request, "entity", status=400, error=str(error), failed=name, **data)
        return RedirectResponse(f"{settings.root_path}/e{result.address}?done={quote(name)}", status_code=303)

    editor.mount(settings.root_path, site)
    return editor


app = create_editor()
