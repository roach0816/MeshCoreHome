"""First-run setup wizard and owner sign-in."""

import logging
import secrets
from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import (
    AuthContext,
    clear_session_cookies,
    client_ip,
    create_session,
    require_auth,
    require_requested_with,
)
from app.config import get_settings
from app.db import get_db
from app.models import AuditEvent, Session, User, utcnow
from app.radio.supervisor import supervisor
from app.security import (
    MIN_PASSWORD_LENGTH,
    constant_time_equals,
    hash_password,
    login_failures,
    setup_failures,
    verify_password,
)
from app.services import app_settings

log = logging.getLogger(__name__)
router = APIRouter(prefix="/api", tags=["auth"])


class SetupToken:
    """One-time token that proves the person running the wizard can read the server logs."""

    value: str | None = None

    @classmethod
    def ensure(cls) -> str:
        if cls.value is None:
            cls.value = get_settings().setup_token or secrets.token_urlsafe(12)
        return cls.value

    @classmethod
    def clear(cls) -> None:
        cls.value = None


def _check_password(v: str) -> str:
    if len(v) < MIN_PASSWORD_LENGTH:
        raise ValueError(f"Password must be at least {MIN_PASSWORD_LENGTH} characters")
    if len(v) > 256:
        raise ValueError("Password is too long")
    return v


class SetupStatus(BaseModel):
    needs_setup: bool
    version: str


class SetupRequest(BaseModel):
    setup_token: str = Field(min_length=1, max_length=128)
    username: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9_.@-]+$")
    password: str
    home_name: str = Field(default="Home", min_length=1, max_length=64)
    radio: app_settings.RadioConfig

    @field_validator("password")
    @classmethod
    def _password_ok(cls, v: str) -> str:
        return _check_password(v)


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)


class ChangePasswordRequest(BaseModel):
    current_password: str = Field(min_length=1, max_length=256)
    new_password: str

    @field_validator("new_password")
    @classmethod
    def _password_ok(cls, v: str) -> str:
        return _check_password(v)


class Me(BaseModel):
    username: str
    home_name: str


@router.get("/setup/status", response_model=SetupStatus)
async def setup_status(db: AsyncSession = Depends(get_db)) -> SetupStatus:
    from app.config import APP_VERSION

    return SetupStatus(needs_setup=not await app_settings.setup_complete(db), version=APP_VERSION)


@router.post("/setup", response_model=Me, dependencies=[Depends(require_requested_with)])
async def run_setup(
    body: SetupRequest, request: Request, response: Response, db: AsyncSession = Depends(get_db)
) -> Me:
    ip = client_ip(request)
    if setup_failures.blocked(ip):
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many attempts; wait a minute")
    if await app_settings.setup_complete(db):
        raise HTTPException(status.HTTP_409_CONFLICT, "Setup has already been completed")
    expected = SetupToken.value
    if expected is None or not constant_time_equals(body.setup_token.strip(), expected):
        setup_failures.hit(ip)
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, "Setup token is incorrect — copy it from the server log"
        )
    if body.radio.mode == "tcp" and not body.radio.host:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Enter the radio's IP address or hostname")

    user = User(username=body.username, password_hash=hash_password(body.password))
    db.add(user)
    await app_settings.put_installation(
        db,
        app_settings.InstallationConfig(
            home_name=body.home_name.strip(), setup_completed_at=datetime.now(UTC).isoformat()
        ),
    )
    await app_settings.put_radio_config(db, body.radio)
    await app_settings.get_fingerprint_key(db)
    db.add(AuditEvent(kind="setup.completed", detail={"radio_mode": body.radio.mode}))
    await db.flush()
    await create_session(db, request, response, user)
    await db.commit()
    SetupToken.clear()
    log.info("first-run setup completed; owner account created")
    supervisor.reload()
    return Me(username=user.username, home_name=body.home_name.strip())


@router.post("/auth/login", response_model=Me, dependencies=[Depends(require_requested_with)])
async def login(
    body: LoginRequest, request: Request, response: Response, db: AsyncSession = Depends(get_db)
) -> Me:
    ip = client_ip(request)
    if login_failures.blocked(ip):
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many failed sign-ins; wait a minute")
    user = (await db.execute(select(User).where(User.username == body.username))).scalar_one_or_none()
    # Always run a hash verification so timing does not reveal whether the username exists.
    ok = verify_password(user.password_hash if user else _DUMMY_HASH, body.password) and user is not None
    if not ok:
        login_failures.hit(ip)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Incorrect username or password")
    login_failures.reset(ip)
    await create_session(db, request, response, user)
    await db.commit()
    inst = await app_settings.get_installation(db)
    return Me(username=user.username, home_name=inst.home_name)


@router.post("/auth/logout", status_code=204)
async def logout(
    response: Response, ctx: AuthContext = Depends(require_auth), db: AsyncSession = Depends(get_db)
):
    await db.execute(delete(Session).where(Session.id == ctx.session.id))
    await db.commit()
    clear_session_cookies(response)
    response.status_code = 204
    return response


@router.get("/auth/me", response_model=Me)
async def me(ctx: AuthContext = Depends(require_auth), db: AsyncSession = Depends(get_db)) -> Me:
    inst = await app_settings.get_installation(db)
    return Me(username=ctx.user.username, home_name=inst.home_name)


@router.post("/auth/password", status_code=204)
async def change_password(
    body: ChangePasswordRequest,
    request: Request,
    response: Response,
    ctx: AuthContext = Depends(require_auth),
    db: AsyncSession = Depends(get_db),
):
    if not verify_password(ctx.user.password_hash, body.current_password):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Current password is incorrect")
    user = await db.get(User, ctx.user.id)
    user.password_hash = hash_password(body.new_password)
    user.password_changed_at = utcnow()
    # Sign out every other browser.
    await db.execute(delete(Session).where(Session.user_id == user.id, Session.id != ctx.session.id))
    db.add(AuditEvent(kind="auth.password_changed", detail={}))
    await db.commit()
    response.status_code = 204
    return response


_DUMMY_HASH = hash_password(secrets.token_urlsafe(16))
