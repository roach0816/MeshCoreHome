import asyncio
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse
from sqlalchemy import text
from starlette.middleware.base import BaseHTTPMiddleware

from app import db
from app.api import auth, inbox, node_map, radio, radio_config
from app.api.deps import load_session
from app.config import APP_VERSION, get_settings
from app.radio.supervisor import supervisor
from app.realtime import hub
from app.security import SESSION_COOKIE
from app.services import app_settings

log = logging.getLogger("meshcore_home")

WS_HEARTBEAT_SECONDS = 25


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    logging.basicConfig(
        level=settings.log_level.upper(), format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    db.init_engine()
    async with db.session_factory()() as s:
        needs_setup = not await app_settings.setup_complete(s)
    if needs_setup:
        token = auth.SetupToken.ensure()
        banner = "=" * 64
        log.warning(
            "\n%s\n  MeshCore Home first-run setup\n  Open the web UI and enter this setup token:\n\n      %s\n%s",
            banner,
            token,
            banner,
        )
    supervisor.start()
    try:
        yield
    finally:
        await supervisor.stop()
        hub.close_all()
        await db.dispose_engine()


app = FastAPI(
    title="MeshCore Home",
    version=APP_VERSION,
    lifespan=lifespan,
    docs_url="/api/docs",
    openapi_url="/api/openapi.json",
)


class SecurityHeaders(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        response = await call_next(request)
        h = response.headers
        h.setdefault("X-Content-Type-Options", "nosniff")
        h.setdefault("Referrer-Policy", "same-origin")
        h.setdefault("X-Frame-Options", "DENY")
        if not request.url.path.startswith("/api/docs"):
            h.setdefault(
                "Content-Security-Policy",
                "default-src 'self'; img-src 'self' data: https:; style-src 'self' 'unsafe-inline'; "
                "connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
            )
        if request.url.path.startswith("/api/"):
            h.setdefault("Cache-Control", "no-store")
        return response


app.add_middleware(SecurityHeaders)
app.include_router(auth.router)
app.include_router(inbox.router)
app.include_router(radio.router)
app.include_router(node_map.router)
app.include_router(radio_config.router)


# ---- health ------------------------------------------------------------------------------


@app.get("/health/live", include_in_schema=False)
async def live():
    return {"ok": True}


@app.get("/health/ready", include_in_schema=False)
async def ready():
    try:
        async with db.engine().connect() as conn:
            await asyncio.wait_for(conn.execute(text("SELECT 1")), timeout=3)
    except Exception:  # noqa: BLE001
        return JSONResponse({"ok": False}, status_code=503)
    return {"ok": True}


# ---- websocket ---------------------------------------------------------------------------


def _same_origin(ws: WebSocket) -> bool:
    origin = ws.headers.get("origin")
    if not origin:
        return False
    host = ws.headers.get("x-forwarded-host") or ws.headers.get("host", "")
    return origin.split("://", 1)[-1] == host


@app.websocket("/ws")
async def websocket(ws: WebSocket):
    if not _same_origin(ws):
        await ws.close(code=4403)
        return
    async with db.session_factory()() as s:
        ctx = await load_session(s, ws.cookies.get(SESSION_COOKIE))
    if ctx is None:
        await ws.close(code=4401)
        return
    await ws.accept()
    queue = hub.register()
    await ws.send_json({"v": 1, "type": "hello", "radio_state": supervisor.status.state})

    async def pump():
        while True:
            try:
                event = await asyncio.wait_for(queue.get(), WS_HEARTBEAT_SECONDS)
            except TimeoutError:
                event = {"v": 1, "type": "ping"}
            if event is None:  # dropped as a slow client, or shutting down
                await ws.close(code=4408)
                return
            await ws.send_json(event)

    async def drain():
        while True:
            await ws.receive_text()  # client pings / keepalives; content ignored

    tasks = [asyncio.create_task(pump()), asyncio.create_task(drain())]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    except WebSocketDisconnect:
        pass
    finally:
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        hub.unregister(queue)


# ---- static frontend (production build) --------------------------------------------------

_static = Path(get_settings().static_dir)
if get_settings().static_dir and _static.is_dir():
    _index = _static / "index.html"

    @app.api_route("/{path:path}", methods=["GET", "HEAD"], include_in_schema=False)
    async def spa(path: str):
        if path.startswith(("api/", "health/", "ws")):
            return JSONResponse({"detail": "Not Found"}, status_code=404)
        candidate = (_static / path).resolve()
        if path and candidate.is_file() and _static.resolve() in candidate.parents:
            headers = (
                {"Cache-Control": "public, max-age=31536000, immutable"} if path.startswith("assets/") else {}
            )
            return FileResponse(candidate, headers=headers)
        return FileResponse(_index, headers={"Cache-Control": "no-cache"})
elif os.environ.get("STATIC_DIR"):
    log.warning("STATIC_DIR=%s does not exist; frontend will not be served", _static)
