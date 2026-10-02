import uuid

from sqlalchemy import select

from app import db
from app.models import Message
from app.radio.supervisor import supervisor
from app.services.messaging import States, mark_interrupted_sends_uncertain
from tests.conftest import HEADERS, PASSWORD, csrf, do_setup, wait_for


async def test_setup_requires_token_and_runs_once(client):
    assert (await client.get("/api/setup/status")).json()["needs_setup"] is True
    bad = await client.post(
        "/api/setup",
        headers=HEADERS,
        json={"setup_token": "wrong", "username": "owner", "password": PASSWORD, "radio": {"mode": "none"}},
    )
    assert bad.status_code == 403
    await do_setup(client, mode="none")
    assert (await client.get("/api/setup/status")).json()["needs_setup"] is False
    again = await client.post(
        "/api/setup",
        headers=HEADERS,
        json={
            "setup_token": "test-setup-token",
            "username": "x",
            "password": PASSWORD,
            "radio": {"mode": "none"},
        },
    )
    assert again.status_code == 409


async def test_unauthenticated_and_csrf_rejected(client):
    await do_setup(client, mode="none")
    anon = client.__class__(transport=client._transport, base_url="http://test")
    assert (await anon.get("/api/conversations")).status_code == 401
    assert (await anon.get("/api/status")).status_code == 401
    # Signed in, but mutation without CSRF token / custom header.
    assert (await client.post("/api/radio/pause", headers=HEADERS)).status_code == 403
    assert (await client.post("/api/radio/pause", headers=csrf(client))).status_code == 200


async def test_login_logout(client):
    await do_setup(client, mode="none")
    client.cookies.clear()
    bad = await client.post(
        "/api/auth/login", headers=HEADERS, json={"username": "owner", "password": "nope"}
    )
    assert bad.status_code == 401
    ok = await client.post(
        "/api/auth/login", headers=HEADERS, json={"username": "owner", "password": PASSWORD}
    )
    assert ok.status_code == 200
    assert (await client.get("/api/auth/me")).json()["username"] == "owner"
    assert (await client.post("/api/auth/logout", headers=csrf(client))).status_code == 204
    client.cookies.clear()
    assert (await client.get("/api/auth/me")).status_code == 401


async def _connected_conversations(client):
    async def ready():
        if supervisor.status.state != "connected":
            return None
        convs = (await client.get("/api/conversations")).json()
        return convs if len(convs) >= 2 else None

    return await wait_for(ready)


async def test_simulated_receive_send_ack_and_idempotency(client):
    await do_setup(client)
    convs = await _connected_conversations(client)
    public = next(c for c in convs if c["title"] == "Public")

    # Receive
    assert (await client.post("/api/radio/simulate-incoming", headers=csrf(client))).status_code == 200
    await wait_for(lambda: _total_messages(client))

    # Send to channel, idempotently
    body = {"client_message_id": "abc12345", "body": "Hi 👋\nthere"}
    r1 = await client.post(f"/api/conversations/{public['id']}/messages", headers=csrf(client), json=body)
    r2 = await client.post(f"/api/conversations/{public['id']}/messages", headers=csrf(client), json=body)
    assert r1.status_code == r2.status_code == 200
    assert r1.json()["id"] == r2.json()["id"]
    conflict = await client.post(
        f"/api/conversations/{public['id']}/messages",
        headers=csrf(client),
        json={"client_message_id": "abc12345", "body": "different"},
    )
    assert conflict.status_code == 409

    async def accepted():
        page = (await client.get(f"/api/conversations/{public['id']}/messages")).json()
        mine = [m for m in page["messages"] if m["id"] == r1.json()["id"]]
        return mine and mine[0]["state"] == States.ACCEPTED

    await wait_for(accepted)

    # DM to a known contact gets an ACK from the simulator (force it).
    supervisor.adapter.ack_probability = 1.0
    contacts = (await client.get("/api/contacts")).json()
    tracker = next(c for c in contacts if c["name"] == "Tracker (sim)")
    conv_id = (await client.post(f"/api/contacts/{tracker['id']}/conversation", headers=csrf(client))).json()[
        "conversation_id"
    ]
    sent = await client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=csrf(client),
        json={"client_message_id": uuid.uuid4().hex, "body": "ping"},
    )

    async def acked():
        page = (await client.get(f"/api/conversations/{conv_id}/messages")).json()
        return any(
            m["id"] == sent.json()["id"] and m["state"] == States.ACKNOWLEDGED for m in page["messages"]
        )

    await wait_for(acked)


async def _total_messages(client):
    return (await client.get("/api/status")).json()["database"]["messages"] > 0


async def test_byte_budget_enforced(client):
    await do_setup(client)
    convs = await _connected_conversations(client)
    public = next(c for c in convs if c["title"] == "Public")
    too_long = "é" * (public["max_bytes"] // 2 + 1)  # 2 bytes each
    r = await client.post(
        f"/api/conversations/{public['id']}/messages",
        headers=csrf(client),
        json={"client_message_id": "budget01", "body": too_long},
    )
    assert r.status_code == 422
    assert "bytes" in r.json()["detail"]


async def test_send_rejected_while_offline(client):
    await do_setup(client)
    convs = await _connected_conversations(client)
    await client.post("/api/radio/pause", headers=csrf(client))
    await wait_for(lambda: _state_is("paused"))
    r = await client.post(
        f"/api/conversations/{convs[0]['id']}/messages",
        headers=csrf(client),
        json={"client_message_id": "offline01", "body": "hi"},
    )
    assert r.status_code == 409
    status = (await client.get("/api/status")).json()
    assert any(g["open"] for g in status["gaps"])  # pausing records a collection gap


async def _state_is(state):
    return supervisor.status.state == state


async def test_read_position_is_monotonic(client):
    await do_setup(client)
    await _connected_conversations(client)
    supervisor.simulate_incoming()
    supervisor.simulate_incoming()

    async def unread_conv():
        convs = (await client.get("/api/conversations")).json()
        return next((c for c in convs if c["unread"] > 0), None)

    conv = await wait_for(unread_conv)
    url = f"/api/conversations/{conv['id']}/read-position"
    assert (
        await client.put(url, headers=csrf(client), json={"position": conv["last_position"]})
    ).status_code == 204
    assert (await client.put(url, headers=csrf(client), json={"position": 0})).status_code == 204
    after = (await client.get(f"/api/conversations/{conv['id']}")).json()
    assert after["read_position"] == conv["last_position"]
    assert after["unread"] == 0


async def test_interrupted_send_becomes_uncertain(client):
    await do_setup(client)
    convs = await _connected_conversations(client)
    public = next(c for c in convs if c["title"] == "Public")
    await client.post("/api/radio/pause", headers=csrf(client))
    async with db.session_factory()() as s:
        s.add(
            Message(
                position=10_000,
                conversation_id=uuid.UUID(public["id"]),
                direction="out",
                body="half sent",
                state=States.SENDING,
            )
        )
        await s.commit()
        assert await mark_interrupted_sends_uncertain(s) == 1
        await s.commit()
        m = (await s.execute(select(Message).where(Message.position == 10_000))).scalar_one()
        assert m.state == States.UNCERTAIN
    # Retrying an uncertain message requires explicit confirmation.
    await client.post("/api/radio/resume", headers=csrf(client))
    await wait_for(lambda: _state_is("connected"))
    r = await client.post(f"/api/messages/{m.id}/retry", headers=csrf(client), json={})
    assert r.status_code == 409
    r = await client.post(
        f"/api/messages/{m.id}/retry", headers=csrf(client), json={"confirm_possible_duplicate": True}
    )
    assert r.status_code == 200 and r.json()["state"] == States.QUEUED


async def test_device_endpoint_never_returns_channel_secrets(client):
    await do_setup(client)
    await _connected_conversations(client)
    text = (await client.get("/api/device")).text
    assert "secret" not in text.lower()
    assert "sim-public-secret" not in text


async def test_conversation_info_and_delete_semantics(client):
    await do_setup(client)
    convs = await _connected_conversations(client)
    public = next(c for c in convs if c["title"] == "Public")

    # Active channel: info reports "clear"; deleting clears history but keeps the conversation.
    await client.post(
        f"/api/conversations/{public['id']}/messages",
        headers=csrf(client),
        json={"client_message_id": "info0001", "body": "hello"},
    )
    info = (await client.get(f"/api/conversations/{public['id']}/info")).json()
    assert info["delete_action"] == "clear"
    assert info["channel"]["slot"] == 0 and info["stats"]["outgoing"] == 1
    r = await client.delete(f"/api/conversations/{public['id']}", headers=csrf(client))
    assert r.json() == {"action": "cleared", "messages_removed": 1}
    page = (await client.get(f"/api/conversations/{public['id']}/messages")).json()
    assert page["messages"] == []
    assert any(c["id"] == public["id"] for c in (await client.get("/api/conversations")).json())

    # DM: info includes the contact's full key; deleting removes the conversation entirely.
    contacts = (await client.get("/api/contacts")).json()
    tracker = next(c for c in contacts if c["name"] == "Tracker (sim)")
    conv_id = (await client.post(f"/api/contacts/{tracker['id']}/conversation", headers=csrf(client))).json()[
        "conversation_id"
    ]
    info = (await client.get(f"/api/conversations/{conv_id}/info")).json()
    assert info["delete_action"] == "delete"
    assert info["contact"]["public_key"] == tracker["public_key"]
    assert (await client.delete(f"/api/conversations/{conv_id}", headers=HEADERS)).status_code == 403  # CSRF
    r = await client.delete(f"/api/conversations/{conv_id}", headers=csrf(client))
    assert r.json()["action"] == "deleted"
    assert (await client.get(f"/api/conversations/{conv_id}")).status_code == 404
    # The contact itself is untouched and a DM can be reopened.
    assert any(c["id"] == tracker["id"] for c in (await client.get("/api/contacts")).json())
