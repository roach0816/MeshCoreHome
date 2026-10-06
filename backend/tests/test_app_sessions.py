"""Mobile app sign-in: session tokens sent as Bearer, signed-in devices, /api/meta."""

import asyncio
import contextlib
import socket
from datetime import timedelta

import pytest
import uvicorn
import websockets
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, update

from app import db
from app.main import app
from app.models import Session, utcnow
from tests.conftest import HEADERS, PASSWORD, csrf, do_setup


def bearer(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


async def app_login(client, platform="ios", name="Test iPhone") -> str:
    r = await client.post(
        "/api/auth/login",
        headers=HEADERS,
        json={"username": "owner", "password": PASSWORD, "client": platform, "device_name": name},
    )
    assert r.status_code == 200, r.text
    assert not r.cookies, "apps get a token, not cookies"
    body = r.json()
    assert body["username"] == "owner"
    assert body["token"].startswith("mhd_")
    return body["token"]


@contextlib.asynccontextmanager
async def fresh_client():
    """A client with no cookies, like a phone."""
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


async def test_meta_before_and_after_setup(client):
    r = await client.get("/api/meta")
    assert r.status_code == 200
    meta = r.json()
    assert meta["product"] == "meshhome"
    assert meta["api_version"] == 1
    assert meta["needs_setup"] is True
    assert meta["install_kind"] == "container"
    assert "app_sessions" in meta["features"]
    assert "software_updates" not in meta["features"]  # native installs only

    await do_setup(client)
    assert (await client.get("/api/meta")).json()["needs_setup"] is False


async def test_browser_sign_in_is_unchanged(client):
    await do_setup(client)
    r = await client.post(
        "/api/auth/login", headers=HEADERS, json={"username": "owner", "password": PASSWORD}
    )
    assert r.status_code == 200
    assert r.json()["token"] is None
    assert "mh_session" in r.cookies


async def test_setup_from_an_app_returns_a_token(client):
    async with fresh_client() as phone:
        r = await phone.post(
            "/api/setup",
            headers=HEADERS,
            json={
                "setup_token": "test-setup-token",
                "username": "owner",
                "password": PASSWORD,
                "radio": {"mode": "simulated", "sim_interval_seconds": 0},
                "client": "ios",
                "device_name": "Setup phone",
            },
        )
        assert r.status_code == 200, r.text
        assert not r.cookies
        token = r.json()["token"]
        r = await phone.get("/api/auth/me", headers=bearer(token))
        assert r.status_code == 200
        assert r.json()["username"] == "owner"


async def test_app_token_has_owner_rights_without_csrf(client):
    await do_setup(client)
    token = await app_login(client)
    async with fresh_client() as phone:
        assert (await phone.get("/api/auth/me", headers=bearer(token))).status_code == 200
        # Owner-only endpoints (refused to API keys), with no CSRF token or X-Requested-With.
        r = await phone.put(
            "/api/settings/bot", headers=bearer(token), json={"enabled": True, "allow": "favorites"}
        )
        assert r.status_code == 200, r.text
        assert (await phone.get("/api/auth/sessions", headers=bearer(token))).status_code == 200

        # Garbage and look-alike tokens are refused.
        r = await phone.get("/api/auth/me", headers=bearer("mhd_" + "x" * 43))
        assert r.status_code == 401
        assert r.json()["detail"] == "Signed out; sign in again"


async def test_each_session_kind_only_works_the_way_it_was_issued(client):
    await do_setup(client)
    token = await app_login(client)
    async with fresh_client() as phone:
        # An app token sent as a cookie would need CSRF protection again: refused.
        phone.cookies.set("mh_session", token)
        assert (await phone.get("/api/auth/me")).status_code == 401
    async with fresh_client() as other:
        # A browser cookie replayed as a Bearer token: refused.
        browser_token = client.cookies.get("mh_session")
        assert (await other.get("/api/auth/me", headers=bearer(browser_token))).status_code == 401


async def test_signed_in_devices_and_sign_out(client):
    await do_setup(client)
    token = await app_login(client, name="Lost phone")
    r = await client.get("/api/auth/sessions")
    assert r.status_code == 200
    sessions = r.json()
    assert {(s["client"], s["device_name"], s["current"]) for s in sessions} == {
        ("web", None, True),
        ("ios", "Lost phone", False),
    }
    phone_id = next(s["id"] for s in sessions if s["client"] == "ios")

    # Changes from the browser still need CSRF.
    assert (await client.delete(f"/api/auth/sessions/{phone_id}")).status_code == 403
    r = await client.delete(f"/api/auth/sessions/{phone_id}", headers=csrf(client))
    assert r.status_code == 204
    async with fresh_client() as phone:
        assert (await phone.get("/api/auth/me", headers=bearer(token))).status_code == 401
    r = await client.delete(f"/api/auth/sessions/{phone_id}", headers=csrf(client))
    assert r.status_code == 404
    assert [s["client"] for s in (await client.get("/api/auth/sessions")).json()] == ["web"]


async def test_sign_out_everywhere_else(client):
    await do_setup(client)
    one = await app_login(client, "ios")
    two = await app_login(client, "android", "Tablet")
    async with fresh_client() as phone:
        # From the phone: sign out everything else, including the browser.
        r = await phone.delete("/api/auth/sessions", headers=bearer(one))
        assert r.status_code == 204
        assert (await phone.get("/api/auth/me", headers=bearer(one))).status_code == 200
        assert (await phone.get("/api/auth/me", headers=bearer(two))).status_code == 401
    assert (await client.get("/api/auth/me")).status_code == 401


async def test_password_change_signs_out_apps(client):
    await do_setup(client)
    token = await app_login(client)
    r = await client.post(
        "/api/auth/password",
        headers=csrf(client),
        json={"current_password": PASSWORD, "new_password": "another long password"},
    )
    assert r.status_code == 204
    async with fresh_client() as phone:
        assert (await phone.get("/api/auth/me", headers=bearer(token))).status_code == 401


async def test_app_logout(client):
    await do_setup(client)
    token = await app_login(client)
    async with fresh_client() as phone:
        assert (await phone.post("/api/auth/logout", headers=bearer(token))).status_code == 204
        assert (await phone.get("/api/auth/me", headers=bearer(token))).status_code == 401


async def _session(client_kind: str) -> Session:
    async with db.session_factory()() as s:
        return (await s.execute(select(Session).where(Session.client == client_kind))).scalar_one()


async def _age(client_kind: str, idle: timedelta, expires_in: timedelta) -> None:
    async with db.session_factory()() as s:
        await s.execute(
            update(Session)
            .where(Session.client == client_kind)
            .values(last_seen_at=utcnow() - idle, expires_at=utcnow() + expires_in)
        )
        await s.commit()


async def test_app_sessions_slide_and_browser_sessions_do_not(client):
    await do_setup(client)
    token = await app_login(client)
    await _age("ios", idle=timedelta(minutes=10), expires_in=timedelta(days=1))
    await _age("web", idle=timedelta(minutes=10), expires_in=timedelta(days=1))
    async with fresh_client() as phone:
        assert (await phone.get("/api/auth/me", headers=bearer(token))).status_code == 200
    assert (await client.get("/api/auth/me")).status_code == 200

    app_sess, web_sess = await _session("ios"), await _session("web")
    assert app_sess.expires_at > utcnow() + timedelta(days=29)
    assert web_sess.expires_at < utcnow() + timedelta(days=2)
    assert utcnow() - web_sess.last_seen_at < timedelta(minutes=1)

    # Unused for SESSION_DAYS: signed out.
    await _age("ios", idle=timedelta(days=30), expires_in=timedelta(seconds=-1))
    async with fresh_client() as phone:
        assert (await phone.get("/api/auth/me", headers=bearer(token))).status_code == 401


async def test_restore_upload_accepts_an_app_but_not_an_api_key(client):
    await do_setup(client)
    token = await app_login(client)
    r = await client.post("/api/api-keys", headers=csrf(client), json={"name": "script", "scope": "write"})
    key = r.json()["key"]
    async with fresh_client() as phone:
        headers = {"Content-Type": "application/octet-stream"}
        r = await phone.post(
            "/api/restore/upload", content=b"not a backup", headers={**headers, **bearer(token)}
        )
        assert r.status_code != 401, r.text  # authorised; the file itself is then checked
        r = await phone.post(
            "/api/restore/upload", content=b"not a backup", headers={**headers, **bearer(key)}
        )
        assert r.status_code == 401


# ---- WebSocket: needs a real server, since the test client can't speak WebSocket ---------------


@contextlib.asynccontextmanager
async def live_server():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, lifespan="off", log_level="warning"))
    task = asyncio.create_task(server.serve(sockets=[sock]))
    try:
        for _ in range(100):
            if server.started:
                break
            await asyncio.sleep(0.05)
        yield f"ws://127.0.0.1:{port}/ws"
    finally:
        server.should_exit = True
        await task
        sock.close()


async def _closed_with(ws) -> int:
    async def drain():
        with contextlib.suppress(websockets.ConnectionClosed):
            while True:
                await ws.recv()

    await asyncio.wait_for(drain(), timeout=5)
    return ws.close_code


async def test_websocket_with_app_token_closes_when_signed_out(client):
    await do_setup(client)
    token = await app_login(client)
    async with live_server() as url:
        # No Origin header, as from a phone: accepted because of the token.
        async with websockets.connect(url, additional_headers=bearer(token)) as ws:
            hello = await asyncio.wait_for(ws.recv(), timeout=5)
            assert '"hello"' in hello
            phone_id = next(
                s["id"] for s in (await client.get("/api/auth/sessions")).json() if s["client"] == "ios"
            )
            r = await client.delete(f"/api/auth/sessions/{phone_id}", headers=csrf(client))
            assert r.status_code == 204
            assert await _closed_with(ws) == 4401

        with pytest.raises(websockets.InvalidStatus):
            async with websockets.connect(url, additional_headers=bearer(token)):
                pass


async def test_websocket_closes_when_api_key_revoked(client):
    await do_setup(client)
    r = await client.post("/api/api-keys", headers=csrf(client), json={"name": "listener", "scope": "read"})
    created = r.json()
    async with live_server() as url:
        async with websockets.connect(url, additional_headers=bearer(created["key"])) as ws:
            await asyncio.wait_for(ws.recv(), timeout=5)
            r = await client.delete(f"/api/api-keys/{created['api_key']['id']}", headers=csrf(client))
            assert r.status_code == 204
            assert await _closed_with(ws) == 4401
