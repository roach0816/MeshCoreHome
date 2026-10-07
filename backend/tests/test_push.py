"""Push notifications through the relay: phone sign-up, what is sent, encryption, and clean-up."""

import base64
import json
import os
import time

import httpx
from Crypto.Cipher import AES
from sqlalchemy import delete, select, update

from app import db
from app.models import Conversation, PushDevice, Session
from app.radio.base import IncomingMessage
from app.services import backup, push
from tests.conftest import HEADERS, csrf, do_setup, radio_adapter, wait_for
from tests.test_app_sessions import app_login, bearer, fresh_client

RELAY = "https://relay.test"


class FakeRelay:
    """Stands in for the relay: records each push; answers with `status`."""

    def __init__(self) -> None:
        self.pushes: list[dict] = []
        self.status = 200

    def handler(self, request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/v1/push"
        self.pushes.append(json.loads(request.content))
        return httpx.Response(self.status, json={} if self.status == 200 else {"error": "nope"})

    @property
    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handler)


def new_key() -> str:
    return base64.b64encode(os.urandom(32)).decode()


def decrypt(key_b64: str, payload: str) -> dict:
    raw = base64.b64decode(payload)
    nonce, ct, tag = raw[:12], raw[12:-16], raw[-16:]
    cipher = AES.new(base64.b64decode(key_b64), AES.MODE_GCM, nonce=nonce)
    return json.loads(cipher.decrypt_and_verify(ct, tag))


def device_body(key: str, **kw) -> dict:
    return {
        "platform": "ios",
        "environment": "development",
        "token": "ab" * 32,
        "ticket": "t" * 43,
        "key": key,
        **kw,
    }


async def setup_push(client, relay: FakeRelay, enabled=True, **device) -> tuple[str, str]:
    """Owner turns push on; a phone signs in and signs up. Returns (app token, key)."""
    await do_setup(client)
    await push.stop()
    push.start(relay.transport)
    push.test_transport = relay.transport
    r = await client.put(
        "/api/settings/push", headers=csrf(client), json={"enabled": enabled, "relay_url": RELAY}
    )
    assert r.status_code == 200, r.text
    token = await app_login(client)
    key = new_key()
    async with fresh_client() as phone:
        r = await phone.put("/api/push/device", headers=bearer(token), json=device_body(key, **device))
        assert r.status_code == 200, r.text
        assert r.json()["registered"] is True
    return token, key


async def send_dm(text: str) -> None:
    from app.radio import simulated

    (await radio_adapter()).inject(
        IncomingMessage(
            kind="dm",
            text=text,
            pubkey_prefix=simulated._key("tracker")[:12],
            sender_timestamp=int(time.time()),
        )
    )


async def send_channel(text: str) -> None:
    (await radio_adapter()).inject(
        IncomingMessage(
            kind="channel", text=text, channel_slot=0, sender_label="Bob", sender_timestamp=int(time.time())
        )
    )


async def test_settings_default_off_and_validation(client):
    await do_setup(client)
    r = await client.get("/api/settings/push", headers=HEADERS)
    assert r.json() == {"enabled": False, "relay_url": "https://push.meshhome.app", "devices": 0}
    r = await client.put(
        "/api/settings/push", headers=csrf(client), json={"enabled": True, "relay_url": "http://x"}
    )
    assert r.status_code == 422
    assert "push_notifications" in (await client.get("/api/meta")).json()["features"]


async def test_only_app_sessions_sign_up_and_input_is_checked(client):
    await do_setup(client)
    key = new_key()
    r = await client.put("/api/push/device", headers=csrf(client), json=device_body(key))
    assert r.status_code == 409  # a browser can't receive app pushes
    token = await app_login(client)
    async with fresh_client() as phone:
        r = await phone.put("/api/push/device", headers=bearer(token), json=device_body("short"))
        assert r.status_code == 422
        r = await phone.put("/api/push/device", headers=bearer(token), json=device_body(key, token="not-hex"))
        assert r.status_code == 422
        assert (await phone.get("/api/push/device", headers=bearer(token))).json()["registered"] is False
        r = await phone.put("/api/push/device", headers=bearer(token), json=device_body(key, channels=True))
        assert r.json()["channels"] is True
        # Updating keeps one row per phone.
        r = await phone.put("/api/push/device", headers=bearer(token), json=device_body(key, dms=False))
        assert r.json() == {
            "registered": True,
            "dms": False,
            "channels": False,
            "last_sent_at": None,
            "last_error": None,
        }
        assert (await phone.delete("/api/push/device", headers=bearer(token))).status_code == 204
        assert (await phone.get("/api/push/device", headers=bearer(token))).json()["registered"] is False


async def test_dm_is_pushed_encrypted(client):
    relay = FakeRelay()
    _, key = await setup_push(client, relay)
    await send_dm("Weather turning, bring a jacket")

    async def pushed():
        return relay.pushes

    [p] = await wait_for(pushed)
    assert set(p) == {"platform", "environment", "token", "ticket", "payload", "collapse_id"}
    assert p["token"] == "ab" * 32 and p["environment"] == "development"
    assert "jacket" not in json.dumps(p)  # the relay sees only ciphertext
    content = decrypt(key, p["payload"])
    assert content["v"] == 1 and content["k"] == "dm"
    assert content["b"] == "Weather turning, bring a jacket"
    assert content["t"]  # the conversation's title (the sender, for a DM)
    assert content["n"] >= 1  # unread count for the badge
    assert len(p["collapse_id"]) == 32 and content["c"] not in p["collapse_id"]

    async with db.session_factory()() as s:
        d = (await s.execute(select(PushDevice))).scalar_one()
        assert d.last_sent_at is not None and d.last_error is None


async def test_channels_follow_the_phone_and_conversation_settings(client):
    relay = FakeRelay()
    await setup_push(client, relay)  # DMs only (the default)
    await send_channel("channel chatter")
    await send_dm("a dm")

    async def got_dm():
        return relay.pushes

    await wait_for(got_dm)
    assert len(relay.pushes) == 1  # the channel message was not pushed

    # A conversation set to alert ("on") is pushed even though channels are off; "off" mutes a DM.
    async with db.session_factory()() as s:
        await s.execute(update(Conversation).where(Conversation.kind == "channel").values(sound="on"))
        await s.execute(update(Conversation).where(Conversation.kind == "dm").values(sound="off"))
        await s.commit()
    await send_channel("important channel news")
    await send_dm("muted dm")

    async def two():
        return len(relay.pushes) >= 2

    await wait_for(two)
    await push_settle()
    assert len(relay.pushes) == 2


async def push_settle() -> None:
    import asyncio

    await asyncio.sleep(0.5)


async def test_disabled_sends_nothing(client):
    relay = FakeRelay()
    await setup_push(client, relay, enabled=False)
    await send_dm("hello?")

    async def stored():
        async with db.session_factory()() as s:
            return (await s.execute(select(Conversation).where(Conversation.kind == "dm"))).first()

    await wait_for(stored)
    await push_settle()
    assert relay.pushes == []


async def test_gone_device_is_removed_and_errors_are_recorded(client):
    relay = FakeRelay()
    token, _ = await setup_push(client, relay)
    relay.status = 403
    await send_dm("one")

    async def error_recorded():
        async with db.session_factory()() as s:
            d = (await s.execute(select(PushDevice))).scalar_one_or_none()
            return d is not None and d.last_error

    await wait_for(error_recorded)
    async with fresh_client() as phone:
        assert "403" in (await phone.get("/api/push/device", headers=bearer(token))).json()["last_error"]

    relay.status = 410  # Apple says the phone is gone: forget it
    await send_dm("two")

    async def removed():
        async with db.session_factory()() as s:
            return (await s.execute(select(PushDevice))).first() is None

    await wait_for(removed)


async def test_test_notification(client):
    relay = FakeRelay()
    token, key = await setup_push(client, relay)
    async with fresh_client() as phone:
        r = await phone.post("/api/push/device/test", headers=bearer(token))
    assert r.json() == {"ok": True, "error": None}
    assert decrypt(key, relay.pushes[-1]["payload"])["k"] == "test"


async def test_signing_out_removes_the_device_and_backups_skip_it(client):
    relay = FakeRelay()
    await setup_push(client, relay)
    async with db.session_factory()() as s:
        await s.execute(delete(Session).where(Session.client == "ios"))
        await s.commit()
        assert (await s.execute(select(PushDevice))).first() is None
    assert "push_devices" not in {t.name for t in backup.tables()}
