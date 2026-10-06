from dataclasses import dataclass
from datetime import timedelta

from fastapi import Depends, HTTPException, Request, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_db
from app.models import ApiKey, Session, User, utcnow
from app.security import (
    API_KEY_PREFIXES,
    APP_TOKEN_PREFIX,
    CSRF_COOKIE,
    CSRF_HEADER,
    LEGACY_CSRF_COOKIE,
    LEGACY_SESSION_COOKIE,
    REQUESTED_WITH_HEADER,
    REQUESTED_WITH_VALUES,
    SESSION_COOKIE,
    api_key_failures,
    constant_time_equals,
    new_app_token,
    new_token,
    token_digest,
)

SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}
# Who signed in: the browser interface, or one of the mobile apps.
WEB_CLIENT = "web"
APP_CLIENTS = ("ios", "android")
# How often last_seen_at (and an app session's expiry) is moved forward.
TOUCH_INTERVAL_SECONDS = 300


@dataclass
class AuthContext:
    """Who is calling: a signed-in browser or app (session), or another service (api_key)."""

    user: User
    session: Session | None = None
    api_key: ApiKey | None = None

    @property
    def owner_tag(self) -> str:
        """Identifies this caller's WebSocket for revocation (see Hub.disconnect)."""
        return f"session:{self.session.id}" if self.session else f"api_key:{self.api_key.id}"


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def is_https(request: Request) -> bool:
    return request.url.scheme == "https" or request.headers.get("x-forwarded-proto", "").lower() == "https"


def cookie_secure(request: Request) -> bool:
    mode = get_settings().cookie_secure
    return is_https(request) if mode == "auto" else mode == "true"


def require_requested_with(request: Request) -> None:
    if (
        request.method not in SAFE_METHODS
        and request.headers.get(REQUESTED_WITH_HEADER) not in REQUESTED_WITH_VALUES
    ):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Missing request header")


def is_app_session(sess: Session) -> bool:
    return sess.client in APP_CLIENTS


async def create_session(
    db: AsyncSession,
    request: Request,
    response: Response,
    user: User,
    client: str = WEB_CLIENT,
    device_name: str | None = None,
) -> str | None:
    """Sign in. A browser gets cookies; an app gets the token returned, to send as Bearer."""
    app = client in APP_CLIENTS
    token = new_app_token() if app else new_token()
    days = get_settings().session_days
    sess = Session(
        token_hash=token_digest(token),
        user_id=user.id,
        csrf_token=new_token(),
        expires_at=utcnow() + timedelta(days=days),
        user_agent=(request.headers.get("user-agent") or "")[:256],
        client=client,
        device_name=device_name,
    )
    db.add(sess)
    await db.flush()
    if app:
        return token
    secure = cookie_secure(request)
    max_age = days * 86400
    _delete_legacy_cookies(response)
    response.set_cookie(
        SESSION_COOKIE, token, max_age=max_age, httponly=True, secure=secure, samesite="strict", path="/"
    )
    # Readable by the page so it can echo it in the X-CSRF-Token header (double submit).
    response.set_cookie(
        CSRF_COOKIE,
        sess.csrf_token,
        max_age=max_age,
        httponly=False,
        secure=secure,
        samesite="strict",
        path="/",
    )
    return None


def clear_session_cookies(response: Response) -> None:
    response.delete_cookie(SESSION_COOKIE, path="/")
    response.delete_cookie(CSRF_COOKIE, path="/")
    _delete_legacy_cookies(response)


def _delete_legacy_cookies(response: Response) -> None:
    response.delete_cookie(LEGACY_SESSION_COOKIE, path="/")
    response.delete_cookie(LEGACY_CSRF_COOKIE, path="/")


def session_cookie(cookies) -> str | None:
    """The browser's session token: the current cookie, or the one set before the rename."""
    return cookies.get(SESSION_COOKIE) or cookies.get(LEGACY_SESSION_COOKIE)


async def load_session(db: AsyncSession, token: str | None) -> AuthContext | None:
    """A browser session, from the session cookie."""
    if not token:
        return None
    return await _load_session(db, token, app=False)


async def load_app_session(db: AsyncSession, token: str) -> AuthContext | None:
    """An app session, from "Authorization: Bearer mhd_...". Its expiry slides while in use."""
    if not token.startswith(APP_TOKEN_PREFIX):
        return None
    ctx = await _load_session(db, token, app=True)
    if ctx is not None:
        await touch_session(db, ctx.session)
    return ctx


async def _load_session(db: AsyncSession, token: str, app: bool) -> AuthContext | None:
    row = (
        await db.execute(
            select(Session, User)
            .join(User, User.id == Session.user_id)
            .where(Session.token_hash == token_digest(token), Session.expires_at > utcnow())
        )
    ).first()
    if row is None:
        return None
    sess, user = row
    # Each kind of session only works the way it was issued: app tokens never as cookies
    # (which would bring back CSRF), browser cookies never as Bearer tokens.
    if is_app_session(sess) != app:
        return None
    return AuthContext(user=user, session=sess)


async def touch_session(db: AsyncSession, sess: Session) -> None:
    """Record activity. An app session's expiry moves forward with it, so a phone in use
    stays signed in; one left unused for SESSION_DAYS is signed out."""
    now = utcnow()
    if (now - sess.last_seen_at).total_seconds() <= TOUCH_INTERVAL_SECONDS:
        return
    sess.last_seen_at = now
    if is_app_session(sess):
        sess.expires_at = now + timedelta(days=get_settings().session_days)
    await db.commit()


def bearer_token(headers) -> str | None:
    """The token from "Authorization: Bearer ...": an API key (mh_, or mch_ from before the rename)
    or an app session (mhd_)."""
    scheme, _, value = headers.get("authorization", "").partition(" ")
    value = value.strip()
    return value if scheme.lower() == "bearer" and value else None


async def load_api_key(db: AsyncSession, raw: str) -> AuthContext | None:
    if not raw.startswith(API_KEY_PREFIXES):
        return None
    row = (
        await db.execute(
            select(ApiKey, User)
            .join(User, User.id == ApiKey.user_id)
            .where(ApiKey.key_hash == token_digest(raw))
        )
    ).first()
    if row is None:
        return None
    key, user = row
    now = utcnow()
    if key.expires_at is not None and key.expires_at <= now:
        return None
    if key.last_used_at is None or (now - key.last_used_at).total_seconds() > 60:
        key.last_used_at = now
        await db.commit()
    return AuthContext(user=user, api_key=key)


async def load_bearer(db: AsyncSession, raw: str) -> AuthContext | None:
    """An app session or an API key, whichever the Bearer token is."""
    if raw.startswith(APP_TOKEN_PREFIX):
        return await load_app_session(db, raw)
    return await load_api_key(db, raw)


async def _bearer_auth(request: Request, db: AsyncSession, raw: str) -> AuthContext:
    ip = client_ip(request)
    app = raw.startswith(APP_TOKEN_PREFIX)
    if api_key_failures.blocked(ip):
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many invalid API keys; wait a minute")
    ctx = await load_bearer(db, raw)
    if ctx is None:
        api_key_failures.hit(ip)
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            "Signed out; sign in again" if app else "Invalid or expired API key",
            headers={"WWW-Authenticate": "Bearer"},
        )
    # No CSRF checks: a Bearer token is never sent automatically by a browser.
    if ctx.api_key is not None and request.method not in SAFE_METHODS and ctx.api_key.scope != "write":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "This API key is read-only")
    return ctx


async def require_auth(request: Request, db: AsyncSession = Depends(get_db)) -> AuthContext:
    """A signed-in browser (cookie), a signed-in app or an API key (Authorization: Bearer)."""
    raw = bearer_token(request.headers)
    if raw is not None:
        return await _bearer_auth(request, db, raw)
    ctx = await load_session(db, session_cookie(request.cookies))
    if ctx is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Not signed in")
    if request.method not in SAFE_METHODS:
        require_csrf(request, ctx.session)
    await touch_session(db, ctx.session)
    return ctx


def require_csrf(request: Request, sess: Session) -> None:
    """Browser sessions: changes must echo the CSRF cookie in the X-CSRF-Token header."""
    require_requested_with(request)
    header = request.headers.get(CSRF_HEADER, "")
    if not header or not constant_time_equals(header, sess.csrf_token):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "CSRF check failed")


async def require_session(ctx: AuthContext = Depends(require_auth)) -> AuthContext:
    """Owner administration (account, API keys, updates, network, radio and node settings):
    a signed-in browser or app only, never an API key."""
    if ctx.session is None:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, "API keys cannot use this endpoint; use the web interface"
        )
    return ctx
