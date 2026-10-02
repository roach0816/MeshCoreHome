from dataclasses import dataclass
from datetime import timedelta

from fastapi import Depends, HTTPException, Request, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_db
from app.models import Session, User, utcnow
from app.security import (
    CSRF_COOKIE,
    CSRF_HEADER,
    REQUESTED_WITH_HEADER,
    REQUESTED_WITH_VALUE,
    SESSION_COOKIE,
    constant_time_equals,
    new_token,
    token_digest,
)

SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}


@dataclass
class AuthContext:
    user: User
    session: Session


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
        and request.headers.get(REQUESTED_WITH_HEADER) != REQUESTED_WITH_VALUE
    ):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Missing request header")


async def create_session(db: AsyncSession, request: Request, response: Response, user: User) -> Session:
    token = new_token()
    days = get_settings().session_days
    sess = Session(
        token_hash=token_digest(token),
        user_id=user.id,
        csrf_token=new_token(),
        expires_at=utcnow() + timedelta(days=days),
        user_agent=(request.headers.get("user-agent") or "")[:256],
    )
    db.add(sess)
    await db.flush()
    secure = cookie_secure(request)
    max_age = days * 86400
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
    return sess


def clear_session_cookies(response: Response) -> None:
    response.delete_cookie(SESSION_COOKIE, path="/")
    response.delete_cookie(CSRF_COOKIE, path="/")


async def load_session(db: AsyncSession, token: str | None) -> AuthContext | None:
    if not token:
        return None
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
    return AuthContext(user=user, session=sess)


async def require_auth(request: Request, db: AsyncSession = Depends(get_db)) -> AuthContext:
    ctx = await load_session(db, request.cookies.get(SESSION_COOKIE))
    if ctx is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Not signed in")
    if request.method not in SAFE_METHODS:
        require_requested_with(request)
        header = request.headers.get(CSRF_HEADER, "")
        if not header or not constant_time_equals(header, ctx.session.csrf_token):
            raise HTTPException(status.HTTP_403_FORBIDDEN, "CSRF check failed")
    now = utcnow()
    if (now - ctx.session.last_seen_at).total_seconds() > 300:
        ctx.session.last_seen_at = now
        await db.commit()
    return ctx
