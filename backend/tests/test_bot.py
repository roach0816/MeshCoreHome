"""The command bot, driven through the simulated radio's receive path."""

import asyncio
import time

from sqlalchemy import select

from app import db
from app.models import Message
from app.radio.base import IncomingMessage
from app.radio.supervisor import supervisor
from app.services import bot
from tests.conftest import csrf, do_setup, wait_for
from tests.test_api import _connected_conversations


def _send_to_node(name_key: str, text: str, age: int = 0, meta: dict | None = None) -> None:
    from app.radio import simulated

    supervisor.adapter.inject(
        IncomingMessage(
            kind="dm",
            text=text,
            pubkey_prefix=simulated._key(name_key)[:12],
            sender_timestamp=int(time.time()) - age,
            meta=meta or {},
        )
    )


async def _settle() -> None:
    """Give the bot task time to act before checking that it did nothing."""
    await asyncio.sleep(0.5)


async def _bot_replies() -> list[Message]:
    async with db.session_factory()() as s:
        rows = (await s.execute(select(Message).where(Message.direction == "out"))).scalars().all()
    return [m for m in rows if (m.meta or {}).get("bot")]


async def _received(text: str) -> bool:
    async with db.session_factory()() as s:
        return (await s.execute(select(Message).where(Message.body == text))).first() is not None


async def test_bot_answers_commands_from_allowed_contacts(client):
    from app.radio import simulated

    simulated._SIM_STATE = None
    bot._last_reply.clear()
    bot._recent.clear()
    await do_setup(client)
    await _connected_conversations(client)
    assert (await client.get("/api/settings/bot")).json() == {"enabled": False, "allow": "favorites"}

    # Off by default: the command is archived, nothing is sent.
    _send_to_node("tracker", "/info")
    await wait_for(lambda: _received("/info"))
    await _settle()
    assert await _bot_replies() == []

    r = await client.put(
        "/api/settings/bot", headers=csrf(client), json={"enabled": True, "allow": "favorites"}
    )
    assert r.status_code == 200
    # Not a favourite: ignored.
    _send_to_node("neighbor", "/ping")
    await wait_for(lambda: _received("/ping"))
    await _settle()
    assert await _bot_replies() == []

    items = (await client.get("/api/contacts", params={"q": "Tracker"})).json()["items"]
    await client.post(
        f"/api/contacts/{items[0]['id']}/favorite", headers=csrf(client), json={"favorite": True}
    )

    _send_to_node("tracker", "/INFO please")
    replies = await wait_for(_bot_replies)
    info = replies[0]
    assert info.body.startswith("Home (simulated) · MeshCore Home ") and "contacts" in info.body
    assert len(info.body.encode()) <= 150 and info.meta == {"bot": "info"}

    # Rate limited per contact: an immediate second command is not answered.
    _send_to_node("tracker", "/help")
    await wait_for(lambda: _received("/help"))
    await _settle()
    assert len(await _bot_replies()) == 1

    bot._last_reply.clear()
    _send_to_node("tracker", "/ping", meta={"SNR": 7.25, "RSSI": -80, "path_len": 2})

    async def two():
        r = await _bot_replies()
        return r if len(r) == 2 else None

    replies = await wait_for(two)
    assert any(m.body == "pong · SNR 7.25 dB, RSSI -80 dBm, 2 hops" for m in replies)

    # Old commands (e.g. collected after an outage) are not answered.
    bot._last_reply.clear()
    _send_to_node("tracker", "/ping", age=3600)
    await wait_for(lambda: _received("/ping"))
    await _settle()
    assert len(await _bot_replies()) == 2

    # Everyone: unknown commands get a hint.
    await client.put("/api/settings/bot", headers=csrf(client), json={"enabled": True, "allow": "everyone"})
    _send_to_node("neighbor", "/weather")

    async def three():
        r = await _bot_replies()
        return r if len(r) == 3 else None

    replies = await wait_for(three)
    assert any(m.body == "Unknown command /weather. Try /help" for m in replies)

    # Replies go out through the normal queue.
    async def sent():
        return all(m.state != "queued" for m in await _bot_replies())

    await wait_for(sent)


def test_parse_and_fit():
    assert bot.parse("/info") == "info"
    assert bot.parse("  /Ping@Home extra") == "ping"
    assert bot.parse("hello /info") is None and bot.parse("/") is None and bot.parse("") is None
    long = bot._fit("é" * 200)
    assert len(long.encode()) <= 150 and long.endswith("...")
    assert bot._route({"path_len": 255, "SNR": -3.5}) == "SNR -3.5 dB, direct route"
    assert bot._route({"path_len": 0}) == "0 hops (heard directly)"
