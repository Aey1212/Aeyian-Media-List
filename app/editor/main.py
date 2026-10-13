"""The AML editor app (admin.aeyempire.com/aml/).

    AML_EDITOR_DEV=1 .venv/bin/uvicorn app.editor.main:app --port 8766

Pages: search (by name or address) and a form for new entities, one page per entity with
its names, facts, texts and pictures and Aey's own data in stored points (-50..+50), and the
change log. Every form posts to the entity's page with the operation's name; the edit
operations do the checking, the change and the log.
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit

import psycopg
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from psycopg.rows import dict_row
from starlette.datastructures import UploadFile

from app.edit.entities import CREATABLE, MEDIA_KINDS, medium_facts
from app.edit.operations import OPERATIONS, EditError, recent_changes, run, target
from app.editor.config import EditorSettings, load_editor_settings
from app.main import MediaFiles
from app.tools.pictures import SLOT_WIDTHS, shape_for

HERE = Path(__file__).resolve().parent.parent
TEMPLATES = Jinja2Templates(directory=str(HERE / "templates"))


# The part of the entity page each operation changes: a save lands back there.
SECTIONS = {
    "create": "top", "publish": "top", "unpublish": "top", "delete_draft": "top",
    "add_title": "names", "edit_title": "names", "remove_title": "names",
    "set_work": "facts", "set_medium": "facts",
    "add_original_language": "origin", "remove_original_language": "origin",
    "add_origin_country": "origin", "remove_origin_country": "origin",
    "set_text": "texts", "clear_text": "texts",
    "add_picture": "pictures", "remove_picture": "pictures", "make_primary": "pictures",
    "set_score": "score", "clear_score": "score",
    "set_subrating": "subratings", "clear_subrating": "subratings",
    "set_take": "take", "clear_take": "take",
    "set_progress": "progress", "clear_progress": "progress",
}

# How the medium facts are asked for: form field -> label.
MEDIUM_LABELS = {
    "format": "Format", "episode_count": "Episodes", "episode_minutes": "Minutes per episode",
    "volume_count": "Volumes", "chapter_count": "Chapters",
    "local_players_min": "Local players, fewest", "local_players_max": "Local players, most",
    "online_players_min": "Online players, fewest", "online_players_max": "Online players, most",
    "runtime_minutes": "Runtime in minutes",
}

# The picture type a new upload starts on, by kind.
FIRST_PICTURE = {"character": "portrait", "person": "portrait", "company": "logo", "franchise": "cover"}

# Picture files the editor takes; anything else is refused before it is read.
UPLOAD_SUFFIXES = (".png", ".jpg", ".jpeg", ".webp", ".gif", ".avif", ".bmp", ".tif", ".tiff", ".svg")


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


def entity_page(conn: psycopg.Connection, address: str, media_dir: str) -> dict[str, Any]:
    """Everything the entity page shows: who it is, its names, facts, texts and pictures,
    and Aey's own data in stored points."""
    entity = target(conn, address)
    eid = entity["id"]
    row = conn.execute(
        """
        SELECT e.published_at IS NOT NULL AS published, core.address(e.franchise_id) AS franchise,
               (SELECT t.text FROM core.title t WHERE t.entity_id = e.franchise_id
                 ORDER BY (t.lang = 'en' AND t.preferred) DESC, (t.lang = 'en') DESC, t.id LIMIT 1) AS franchise_title,
               f.published_at IS NOT NULL AS franchise_published
          FROM core.entity e LEFT JOIN core.entity f ON f.id = e.franchise_id
         WHERE e.id = %s
        """,
        (eid,),
    ).fetchone()
    data: dict[str, Any] = {"entity": entity, "published": row["published"], "is_work": entity["kind"] in MEDIA_KINDS}
    if data["is_work"]:
        data["franchise"] = row
    data["titles"] = conn.execute(
        """
        SELECT t.id, t.lang, t.title_type, t.text, t.native, t.preferred, t.latinizes_id, l.text AS latinizes_text
          FROM core.title t LEFT JOIN core.title l ON l.id = t.latinizes_id
         WHERE t.entity_id = %s
         ORDER BY t.title_type = 'full' DESC, t.title_type, (t.lang = 'en') DESC, t.native DESC, t.lang, t.id
        """,
        (eid,),
    ).fetchall()
    data["title_types"] = _labels(conn, "core.title_type")
    if data["is_work"]:
        data["work"] = conn.execute(
            "SELECT status, start_date, end_date, source_type FROM media.work WHERE entity_id = %s", (eid,)
        ).fetchone()
        data["work_statuses"] = {
            r["code"]: r["label"] for r in conn.execute(
                """
                SELECT s.code, s.labels -> 'en' ->> 'text' AS label
                  FROM media.work_status s JOIN media.work_status_kind k ON k.status = s.code AND k.kind = %s
                 ORDER BY s.sort_order, s.code
                """,
                (entity["kind"],),
            ).fetchall()
        }
        data["source_types"] = _labels(conn, "media.source_type")
        data["medium"] = [{"name": name, "label": MEDIUM_LABELS[name], "value": value}
                          for name, value in medium_facts(conn, entity).items()]
        data["anime_formats"] = _labels(conn, "media.anime_format")
        data["languages"] = [r["lang"] for r in conn.execute(
            "SELECT lang FROM core.entity_original_language WHERE entity_id = %s ORDER BY sort_order, lang", (eid,))]
        data["countries"] = [r["country"] for r in conn.execute(
            "SELECT country FROM core.entity_origin_country WHERE entity_id = %s ORDER BY sort_order, country", (eid,))]
    data["texts"] = conn.execute(
        """
        SELECT x.text_type, x.lang, x.body, y.labels -> 'en' ->> 'text' AS label
          FROM core.entity_text x JOIN core.text_type y ON y.code = x.text_type
         WHERE x.entity_id = %s ORDER BY y.sort_order, (x.lang = 'en') DESC, x.lang
        """,
        (eid,),
    ).fetchall()
    data["text_types"] = _labels(conn, "core.text_type")
    data["first_text"] = "synopsis" if data["is_work"] else "description"
    pictures = conn.execute(
        """
        SELECT i.id, i.image_type, i.sha256, i.format, i.is_primary, i.width, i.height, t.labels -> 'en' ->> 'text' AS label
          FROM core.image i JOIN core.image_type t ON t.code = i.image_type
         WHERE i.entity_id = %s ORDER BY t.sort_order, i.image_type, i.sort_order, i.id
        """,
        (eid,),
    ).fetchall()
    for p in pictures:
        # the smallest copy stored for how it is drawn, else the web copy itself
        widths = SLOT_WIDTHS.get(shape_for(p["image_type"], entity["kind"]), [])
        small = next((w for w in widths if w >= 150 and (Path(media_dir) / f"{p['sha256']}@{w}.webp").is_file()), None)
        p["file"] = f"{p['sha256']}@{small}.webp" if small else f"{p['sha256']}.{p['format']}"
    data["pictures"] = pictures
    data["image_types"] = _labels(conn, "core.image_type")
    data["first_picture"] = FIRST_PICTURE.get(entity["kind"], "cover")
    if entity["rateable"]:
        data["score"] = conn.execute(
            "SELECT general, rated_on, aey.score_shown(general) AS shown, aey.half_stars(general) AS half_stars "
            "FROM aey.score WHERE entity_id = %s", (eid,)
        ).fetchone()
        data["subratings"] = conn.execute(
            """
            SELECT s.category, c.labels -> 'en' ->> 'text' AS label, s.value, aey.score_shown(s.value) AS shown
              FROM aey.subrating s JOIN aey.subrating_category c ON c.code = s.category
             WHERE s.entity_id = %s ORDER BY c.sort_order, c.code
            """,
            (eid,),
        ).fetchall()
        data["categories"] = _labels(conn, "aey.subrating_category")
        data["takes"] = conn.execute(
            "SELECT lang, body, written_on FROM aey.take WHERE entity_id = %s ORDER BY (lang = 'en') DESC, lang", (eid,)
        ).fetchall()
    if entity["progress"]:
        data["progress"] = conn.execute(
            """
            SELECT status, progress_value, progress_unit, started_on, finished_on, times_completed,
                   round(time_spent_s / 3600.0, 2) AS hours, note
              FROM aey.progress WHERE entity_id = %s
            """,
            (eid,),
        ).fetchone()
        data["statuses"] = _labels(conn, "aey.status")
        data["units"] = _labels(conn, "media.cadence_item")
    data["changes"] = recent_changes(conn, limit=20, address=entity["address"])
    return data


def creatable_kinds(conn: psycopg.Connection) -> dict[str, str]:
    """kind -> English label, for the New form, works first."""
    rows = conn.execute("SELECT name, labels -> 'en' ->> 'text' AS label FROM core.entity_kind WHERE name = ANY(%s) ORDER BY code",
                        (list(CREATABLE),)).fetchall()
    return {r["name"]: r["label"] for r in rows}


async def _upload(upload: Any, folder: Path) -> str:
    """Saves an uploaded picture into folder, keeping its file type, and returns its path."""
    if not isinstance(upload, UploadFile) or not upload.filename:
        raise EditError("Choose a picture file first.")
    suffix = Path(upload.filename).suffix.lower()
    if suffix not in UPLOAD_SUFFIXES:
        raise EditError(f"{upload.filename} is not a picture file the editor takes ({' '.join(UPLOAD_SUFFIXES)}).")
    path = folder / f"upload{suffix}"
    path.write_bytes(await upload.read())
    return str(path)


def create_editor(settings: EditorSettings | None = None) -> FastAPI:
    settings = settings or load_editor_settings()
    editor = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    site = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    site.mount("/static", StaticFiles(directory=str(HERE / "static")), name="static")
    Path(settings.media_dir).mkdir(parents=True, exist_ok=True)
    site.mount("/media", MediaFiles(directory=settings.media_dir), name="media")

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

    def landing(result, name: str) -> RedirectResponse:
        if OPERATIONS[name].deletes:
            return RedirectResponse(f"{settings.root_path}/?deleted={quote(result.label)}", status_code=303)
        section = SECTIONS.get(name)
        return RedirectResponse(f"{settings.root_path}/e{result.address}?done={quote(name)}"
                                + (f"#{section}" if section else ""), status_code=303)

    @site.get("/", response_class=HTMLResponse)
    def index(request: Request, q: str = "", deleted: str = "") -> Response:
        with connect() as conn:
            results = search(conn, q)
            changes = recent_changes(conn, limit=15)
            kinds = creatable_kinds(conn)
        return page(request, "index", q=q, results=results, changes=changes, kinds=kinds, sent={}, deleted=deleted)

    @site.post("/new", response_class=HTMLResponse)
    async def new(request: Request) -> Response:
        form = {k: v for k, v in (await request.form()).items() if isinstance(v, str)}
        params = {k: v for k, v in form.items() if k in OPERATIONS["create"].params}
        with connect() as conn:
            try:
                result = run(conn, "create", None, params, via="web")
            except EditError as error:
                return page(request, "index", status=400, q="", results=[], changes=recent_changes(conn, limit=15),
                            kinds=creatable_kinds(conn), sent=form, error=str(error))
        return landing(result, "create")

    @site.get("/changes", response_class=HTMLResponse)
    def changes(request: Request) -> Response:
        with connect() as conn:
            return page(request, "changes", changes=recent_changes(conn, limit=300))

    @site.get("/e/{address:path}", response_class=HTMLResponse)
    def show(address: str, request: Request, done: str = "") -> Response:
        with connect() as conn:
            try:
                data = entity_page(conn, "/" + address, settings.media_dir)
            except EditError as error:
                return page(request, "index", status=404, q="", results=[], changes=[],
                            kinds=creatable_kinds(conn), sent={}, error=str(error))
        return page(request, "entity", done=done, sections=SECTIONS, sent={}, **data)

    @site.post("/e/{address:path}", response_class=HTMLResponse)
    async def change(address: str, request: Request) -> Response:
        form = await request.form()
        name = form.get("op", "")
        if name not in OPERATIONS or OPERATIONS[name].creates:
            return HTMLResponse("Unknown operation.", status_code=400)
        sent = {k: v for k, v in form.items() if isinstance(v, str) and k != "op"}
        # only the fields the operation takes; the rest of the form is ignored. A picture
        # comes only as an upload: the web never names a file on the server.
        params = {k: v for k, v in sent.items() if k in OPERATIONS[name].params and k != "file"}
        with tempfile.TemporaryDirectory(prefix="aml-upload-") as folder, connect() as conn:
            try:
                if name == "add_picture":
                    params["file"] = await _upload(form.get("upload"), Path(folder))
                result = run(conn, name, "/" + address, params, via="web")
            except EditError as error:
                try:
                    data = entity_page(conn, "/" + address, settings.media_dir)
                except EditError:
                    return page(request, "index", status=404, q="", results=[], changes=[],
                                kinds=creatable_kinds(conn), sent={}, error=str(error))
                return page(request, "entity", status=400, error=str(error), failed=name, sections=SECTIONS,
                            sent=sent, **data)
        return landing(result, name)

    editor.mount(settings.root_path, site)
    return editor


app = create_editor()
