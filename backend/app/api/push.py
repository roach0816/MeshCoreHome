"""Push notifications to the MeshHome app: the owner's setting, and each phone's sign-up."""

from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import AuthContext, require_auth, require_session
from app.db import get_db
from app.models import PushDevice
from app.realtime import hub
from app.services import app_settings, push

router = APIRouter(prefix="/api", tags=["push"])


class PushSettingsOut(app_settings.PushConfig):
    devices: int  # phones signed up for push


@router.get("/settings/push", response_model=PushSettingsOut)
async def get_push_settings(ctx: AuthContext = Depends(require_auth), db: AsyncSession = Depends(get_db)):
    cfg = await app_settings.get_push_config(db)
    n = (await db.execute(select(func.count()).select_from(PushDevice))).scalar_one()
    return PushSettingsOut(**cfg.model_dump(), devices=n)


@router.put("/settings/push", response_model=PushSettingsOut)
async def put_push_settings(
    body: app_settings.PushConfig,
    ctx: AuthContext = Depends(require_session),
    db: AsyncSession = Depends(get_db),
):
    await app_settings.put_push_config(db, body)
    await db.commit()
    hub.publish("settings-updated", key="push")
    n = (await db.execute(select(func.count()).select_from(PushDevice))).scalar_one()
    return PushSettingsOut(**body.model_dump(), devices=n)


class PushDeviceIn(BaseModel):
    platform: Literal["ios"]
    # "development" for builds from Xcode, "production" for TestFlight and the App Store.
    environment: Literal["production", "development"]
    token: str = Field(pattern=r"^[0-9a-f]{32,200}$")
    ticket: str = Field(pattern=r"^[A-Za-z0-9_\-]{20,128}$")
    key: str = Field(pattern=r"^[A-Za-z0-9+/]{43}=$")  # base64 of 32 bytes
    dms: bool = True
    channels: bool = False


class PushDeviceOut(BaseModel):
    registered: bool
    dms: bool = True
    channels: bool = False
    last_sent_at: datetime | None = None
    last_error: str | None = None


def _app_session(ctx: AuthContext):
    if ctx.session is None or ctx.session.client not in ("ios", "android"):
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Only a phone signed in with the MeshHome app can do this"
        )
    return ctx.session


async def _device(db: AsyncSession, ctx: AuthContext) -> PushDevice | None:
    sess = _app_session(ctx)
    return (await db.execute(select(PushDevice).where(PushDevice.session_id == sess.id))).scalar_one_or_none()


def _out(d: PushDevice | None) -> PushDeviceOut:
    if d is None:
        return PushDeviceOut(registered=False)
    return PushDeviceOut(
        registered=True, dms=d.dms, channels=d.channels, last_sent_at=d.last_sent_at, last_error=d.last_error
    )


@router.get("/push/device", response_model=PushDeviceOut)
async def get_push_device(ctx: AuthContext = Depends(require_session), db: AsyncSession = Depends(get_db)):
    return _out(await _device(db, ctx))


@router.put("/push/device", response_model=PushDeviceOut)
async def put_push_device(
    body: PushDeviceIn, ctx: AuthContext = Depends(require_session), db: AsyncSession = Depends(get_db)
):
    """This phone signs up for push (or updates its token, key or choices)."""
    d = await _device(db, ctx)
    if d is None:
        d = PushDevice(session_id=ctx.session.id)
        db.add(d)
    d.platform, d.environment, d.token, d.ticket, d.key = (
        body.platform,
        body.environment,
        body.token,
        body.ticket,
        body.key,
    )
    d.dms, d.channels = body.dms, body.channels
    await db.commit()
    return _out(d)


@router.delete("/push/device", status_code=204)
async def delete_push_device(ctx: AuthContext = Depends(require_session), db: AsyncSession = Depends(get_db)):
    sess = _app_session(ctx)
    await db.execute(delete(PushDevice).where(PushDevice.session_id == sess.id))
    await db.commit()


class PushTestOut(BaseModel):
    ok: bool
    error: str | None = None


@router.post("/push/device/test", response_model=PushTestOut)
async def test_push_device(ctx: AuthContext = Depends(require_session), db: AsyncSession = Depends(get_db)):
    d = await _device(db, ctx)
    if d is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "This phone isn't signed up for push notifications")
    if not (await app_settings.get_push_config(db)).enabled:
        raise HTTPException(status.HTTP_409_CONFLICT, "Push notifications are turned off on this server")
    result = await push.send_test(db, d)
    await db.commit()
    return PushTestOut(ok=result.ok, error=result.error)
