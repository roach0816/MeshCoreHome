"""Software version, update availability and (native installs) in-place upgrades."""

import time

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import AuthContext, require_auth
from app.config import APP_VERSION, get_settings
from app.db import get_db
from app.models import AuditEvent
from app.security import RateLimiter
from app.services import updates

router = APIRouter(prefix="/api/system", tags=["system"])

_manual_checks = RateLimiter(limit=3, window_seconds=60)
ACTIVE_STATES = {"queued", "downloading", "installing", "migrating", "restarting"}
STALE_AFTER = 30 * 60  # an "active" status older than this is assumed dead


class UpdateRequest(BaseModel):
    version: str = Field(pattern=r"^\d+\.\d+\.\d+$")


def _in_progress(st: dict | None) -> bool:
    return bool(
        st
        and st.get("state") in ACTIVE_STATES
        and time.time() - float(st.get("updated_at") or 0) < STALE_AFTER
    )


@router.get("/update")
async def update_info(refresh: bool = Query(default=False), ctx: AuthContext = Depends(require_auth)):
    force = False
    if refresh:
        key = str(ctx.user.id)
        if _manual_checks.blocked(key):
            raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Checked recently; try again in a minute")
        _manual_checks.hit(key)
        force = True
    await updates.checker.check(force=force)
    return {**updates.checker.summary(), "status": updates.read_status()}


@router.get("/update/status")
async def update_status(ctx: AuthContext = Depends(require_auth)):
    return {"current_version": APP_VERSION, "status": updates.read_status()}


@router.post("/update", status_code=202)
async def request_update(
    body: UpdateRequest, ctx: AuthContext = Depends(require_auth), db: AsyncSession = Depends(get_db)
):
    s = get_settings()
    if s.install_kind != "native" or not s.state_dir:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            "In-place upgrades are only available on a native install. Container installs are updated by redeploying.",
        )
    await updates.checker.check()
    info = updates.checker.summary()
    latest = info["latest"]
    if not latest or latest["version"] != body.version or not info["update_available"]:
        raise HTTPException(status.HTTP_409_CONFLICT, "That version is not the latest available release")
    if not latest["has_native_package"]:
        raise HTTPException(status.HTTP_409_CONFLICT, "That release has no installable package yet")
    if _in_progress(updates.read_status()):
        raise HTTPException(status.HTTP_409_CONFLICT, "An update is already in progress")
    try:
        updates.write_request(body.version, ctx.user.username)
    except OSError as exc:
        raise HTTPException(
            status.HTTP_500_INTERNAL_SERVER_ERROR, f"Could not queue the update: {exc}"
        ) from exc
    db.add(AuditEvent(kind="system.update_requested", detail={"from": APP_VERSION, "to": body.version}))
    await db.commit()
    return {"queued": True, "version": body.version}
