"""Push notifications to the MeshHome app, through the relay (push-relay/, docs/push-notifications.md).

Apple delivers a push only when it is signed with the app's push key, which can't be handed to
every self-hosted server. A relay holds the key instead: this server gives it an encrypted
notification for a phone, and the relay forwards it to Apple.

- Off until the owner turns it on (Settings → Notifications).
- Each phone signs up from the app (PushDevice): its push token, a ticket from the relay (the relay
  forwards only to tokens it issued a ticket for), and a key the phone generated.
- Sender, text, conversation and unread count are encrypted with that key (AES-256-GCM), so the
  relay and Apple see only ciphertext, the push token and the time. The app decrypts it.
"""

import asyncio
import base64
import hashlib
import hmac
import json
import logging
import os
import uuid
from typing import Any

import httpx
from Crypto.Cipher import AES
from sqlalchemy import and_, delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import db
from app.models import Conversation, Message, PushDevice, ReadPosition, Session, utcnow
from app.services import app_settings

log = logging.getLogger(__name__)

QUEUE_SIZE = 500
RELAY_TIMEOUT = 10.0
BODY_LIMIT = 1000  # characters of message text; MeshCore messages are far shorter
PAYLOAD_VERSION = 1

_queue: asyncio.Queue[uuid.UUID] | None = None
_task: asyncio.Task | None = None


class RelayResult:
    def __init__(self, ok: bool, gone: bool = False, error: str | None = None) -> None:
        self.ok, self.gone, self.error = ok, gone, error


# ---- lifecycle -------------------------------------------------------------------------------


def start(transport: httpx.AsyncBaseTransport | None = None) -> None:
    """Start the sender (tests pass a fake relay as `transport`)."""
    global _queue, _task
    _queue = asyncio.Queue(maxsize=QUEUE_SIZE)
    _task = asyncio.create_task(_worker(transport), name="push")


async def stop() -> None:
    global _task
    if _task:
        _task.cancel()
        try:
            await _task
        except (asyncio.CancelledError, Exception):  # noqa: BLE001
            pass
        _task = None


def enqueue(message_id: uuid.UUID) -> None:
    """A new incoming message was committed: notify the phones that want it (never blocks)."""
    if _queue is None:
        return
    try:
        _queue.put_nowait(message_id)
    except asyncio.QueueFull:
        log.warning("push queue full; a notification was dropped")


async def _worker(transport: httpx.AsyncBaseTransport | None) -> None:
    assert _queue is not None
    async with httpx.AsyncClient(timeout=RELAY_TIMEOUT, transport=transport) as client:
        while True:
            message_id = await _queue.get()
            try:
                await notify_message(client, message_id)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 - push must never disturb collection
                log.warning("push notification failed: %s", type(exc).__name__)


# ---- encryption --------------------------------------------------------------------------------


def encrypt(key_b64: str, content: dict[str, Any]) -> str:
    """AES-256-GCM: base64(nonce(12) || ciphertext || tag(16)), as CryptoKit's `combined`."""
    key = base64.b64decode(key_b64)
    nonce = os.urandom(12)
    cipher = AES.new(key, AES.MODE_GCM, nonce=nonce)
    ct, tag = cipher.encrypt_and_digest(json.dumps(content, separators=(",", ":")).encode())
    return base64.b64encode(nonce + ct + tag).decode()


def collapse_id(key_b64: str, conversation_id: uuid.UUID) -> str:
    """Groups notifications per conversation (a newer one replaces the older) without revealing which."""
    return hmac.new(base64.b64decode(key_b64), str(conversation_id).encode(), hashlib.sha256).hexdigest()[:32]


# ---- deciding and sending --------------------------------------------------------------------


def wants(device: PushDevice, conv: Conversation) -> bool:
    # The conversation's own setting (alerts on/off) wins; otherwise the phone's choice by kind.
    if conv.sound == "off":
        return False
    if conv.sound == "on":
        return True
    return device.channels if conv.kind == "channel" else device.dms


async def unread_total(s: AsyncSession, user_id: uuid.UUID) -> int:
    q = (
        select(func.count())
        .select_from(Message)
        .outerjoin(
            ReadPosition,
            and_(ReadPosition.conversation_id == Message.conversation_id, ReadPosition.user_id == user_id),
        )
        .where(
            Message.direction == "in",
            Message.position > func.coalesce(ReadPosition.position, 0),
            Message.suppressed.is_(False),
        )
    )
    return int((await s.execute(q)).scalar_one())


async def relay_send(
    client: httpx.AsyncClient,
    relay_url: str,
    device: PushDevice,
    content: dict[str, Any],
    collapse: str | None,
) -> RelayResult:
    body = {
        "platform": device.platform,
        "environment": device.environment,
        "token": device.token,
        "ticket": device.ticket,
        "payload": encrypt(device.key, {"v": PAYLOAD_VERSION, **content}),
    }
    if collapse:
        body["collapse_id"] = collapse
    try:
        r = await client.post(f"{relay_url}/v1/push", json=body)
    except httpx.HTTPError as exc:
        return RelayResult(False, error=f"Couldn't reach the relay ({type(exc).__name__})")
    if r.status_code == 200:
        return RelayResult(True)
    if r.status_code == 410:
        return RelayResult(False, gone=True, error="The phone is no longer registered with Apple")
    try:
        detail = str(r.json().get("error", ""))[:120]
    except ValueError:
        detail = ""
    return RelayResult(False, error=f"Relay answered {r.status_code}{': ' + detail if detail else ''}")


async def _record(s: AsyncSession, device: PushDevice, result: RelayResult) -> None:
    if result.gone:
        await s.execute(delete(PushDevice).where(PushDevice.id == device.id))
        return
    if result.ok:
        device.last_sent_at = utcnow()
        device.last_error = None
    else:
        device.last_error = (result.error or "failed")[:200]


async def notify_message(client: httpx.AsyncClient, message_id: uuid.UUID) -> int:
    """Send one message's notification to every phone that wants it. Returns how many were sent."""
    async with db.session_factory()() as s:
        cfg = await app_settings.get_push_config(s)
        if not cfg.enabled:
            return 0
        m = await s.get(Message, message_id)
        if m is None or m.direction != "in" or m.suppressed:
            return 0
        conv = await s.get(Conversation, m.conversation_id)
        if conv is None:
            return 0
        rows = (
            await s.execute(
                select(PushDevice, Session)
                .join(Session, Session.id == PushDevice.session_id)
                .where(Session.expires_at > utcnow())
            )
        ).all()
        badges: dict[uuid.UUID, int] = {}
        sent = 0
        for device, sess in rows:
            if not wants(device, conv):
                continue
            if sess.user_id not in badges:
                badges[sess.user_id] = await unread_total(s, sess.user_id)
            content = {
                "c": str(conv.id),
                "m": str(m.id),
                "k": conv.kind,
                "t": conv.title,
                "s": m.sender_label or "",
                "b": m.body[:BODY_LIMIT],
                "n": badges[sess.user_id],
            }
            result = await relay_send(
                client, cfg.relay_url, device, content, collapse_id(device.key, conv.id)
            )
            await _record(s, device, result)
            sent += result.ok
        await s.commit()
        return sent


test_transport: httpx.AsyncBaseTransport | None = None  # tests: a fake relay for send_test


async def send_test(s: AsyncSession, device: PushDevice) -> RelayResult:
    """A test notification to one phone (Settings → Notifications → Send a test)."""
    cfg = await app_settings.get_push_config(s)
    async with httpx.AsyncClient(timeout=RELAY_TIMEOUT, transport=test_transport) as client:
        result = await relay_send(
            client,
            cfg.relay_url,
            device,
            {"k": "test", "t": "MeshHome", "s": "", "b": "Push notifications work."},
            None,
        )
    await _record(s, device, result)
    return result
