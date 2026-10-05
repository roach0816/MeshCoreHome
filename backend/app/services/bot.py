"""A small command bot: answers direct messages that start with "/" (e.g. /info, /ping).

Off until the owner turns it on (Settings → Bot). Only direct messages from known contacts are
considered, never channels; by default only favourite contacts may use it. Replies go through the
normal outgoing queue, so they are archived and delivered like any message the owner sends.

Airtime is precious, so replies are rate limited (per contact and overall), unknown commands get
one short hint, and commands that arrive late (e.g. collected after the radio was offline) are
ignored rather than answered out of context.
"""

from __future__ import annotations

import logging
import time
import uuid
from collections import deque
from typing import Any

from sqlalchemy import func, select

from app import db
from app.config import APP_VERSION, get_settings
from app.models import Contact, Conversation, Message, Radio
from app.realtime import hub
from app.services import app_settings, messaging

log = logging.getLogger(__name__)

DM_MAX_BYTES = 150
MAX_AGE_SECONDS = 15 * 60  # ignore commands older than this (sender's clock)
PER_CONTACT_SECONDS = 10.0
GLOBAL_PER_MINUTE = 6
DIRECT_ROUTE = 255  # path_len for a message that came along a known (direct) route
COMMANDS = {
    "help": "list the commands",
    "info": "about this node",
    "ping": "how your message arrived",
}

_last_reply: dict[uuid.UUID, float] = {}
_recent: deque[float] = deque()


def _fit(text: str, limit: int = DM_MAX_BYTES) -> str:
    """Trim to the DM size limit in UTF-8 bytes without splitting a character."""
    raw = text.encode()
    if len(raw) <= limit:
        return text
    return raw[: limit - 3].decode(errors="ignore").rstrip() + "..."


def _duration(seconds: float) -> str:
    s = int(max(0, seconds))
    d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
    return f"{d}d {h}h" if d else f"{h}h {m}m" if h else f"{m}m"


def _route(meta: dict[str, Any] | None) -> str:
    meta = meta or {}
    parts = []
    snr = meta.get("SNR")
    if isinstance(snr, int | float):
        parts.append(f"SNR {snr:g} dB")
    rssi = meta.get("RSSI")
    if isinstance(rssi, int | float):
        parts.append(f"RSSI {rssi:g} dBm")
    hops = meta.get("path_len")
    if hops == DIRECT_ROUTE:
        parts.append("direct route")
    elif isinstance(hops, int) and hops >= 0:
        parts.append("0 hops (heard directly)" if hops == 0 else f"{hops} hop{'s' if hops != 1 else ''}")
    return ", ".join(parts)


async def _info(s, radio: Radio, connected_since: float | None) -> str:
    rf = (radio.self_info or {}).get("radio") or {}
    contacts = (
        await s.execute(
            select(func.count())
            .select_from(Contact)
            .where(Contact.radio_id == radio.id, Contact.on_radio.is_(True))
        )
    ).scalar_one()
    parts = [radio.name or "MeshCore Home", f"MeshCore Home {APP_VERSION}"]
    if connected_since:
        parts.append(f"up {_duration(time.time() - connected_since)}")
    if rf.get("freq_mhz"):
        parts.append(f"{rf['freq_mhz']:g} MHz SF{rf.get('sf')} BW{rf.get('bw_khz'):g}")
    parts.append(f"{contacts} contacts")
    return " · ".join(parts)


def _limited(contact_id: uuid.UUID) -> bool:
    now = time.monotonic()
    while _recent and now - _recent[0] > 60:
        _recent.popleft()
    if len(_recent) >= GLOBAL_PER_MINUTE or now - _last_reply.get(contact_id, -1e9) < PER_CONTACT_SECONDS:
        return True
    _recent.append(now)
    _last_reply[contact_id] = now
    return False


def parse(body: str) -> str | None:
    """The command word of "/info", "/INFO please", "/ping@node" → "info"; None if not a command."""
    text = (body or "").strip()
    if not text.startswith("/") or len(text) < 2:
        return None
    word = text[1:].split(None, 1)[0].split("@", 1)[0].lower()
    return word or None


async def handle(message_id: uuid.UUID, *, connected_since: float | None = None) -> str | None:
    """Answer one received message if it is a bot command. Returns the reply text, if any."""
    async with db.session_factory()() as s:
        cfg = await app_settings.get_bot_config(s)
        if not cfg.enabled:
            return None
        msg = await s.get(Message, message_id)
        if msg is None or msg.direction != "in" or msg.suppressed or (msg.txt_type or 0) != 0:
            return None
        command = parse(msg.body)
        if command is None:
            return None
        conv = await s.get(Conversation, msg.conversation_id)
        if conv is None or conv.kind != "dm" or conv.contact_id is None:
            return None
        contact = await s.get(Contact, conv.contact_id)
        if contact is None or contact.blocked:
            return None
        if cfg.allow == "favorites" and not contact.favorite:
            log.info("bot: ignoring /%s from a contact that is not a favourite", command)
            return None
        if msg.sender_timestamp and time.time() - msg.sender_timestamp > MAX_AGE_SECONDS:
            log.info("bot: ignoring a /%s sent %d s ago", command, time.time() - msg.sender_timestamp)
            return None
        if _limited(contact.id):
            log.info("bot: rate limited, not answering /%s", command)
            return None
        radio = await s.get(Radio, conv.radio_id)

        if command == "help":
            reply = "Commands: " + ", ".join(f"/{k} ({v})" for k, v in COMMANDS.items())
        elif command == "info":
            reply = await _info(s, radio, connected_since)
        elif command == "ping":
            route = _route(msg.meta)
            reply = f"pong · {route}" if route else "pong"
        else:
            reply = f"Unknown command /{command[:20]}. Try /help"
        reply = _fit(reply)

        # Derived from the command's id: handling the same message twice cannot send twice.
        out, created = await messaging.create_outgoing(
            s,
            conv,
            reply,
            f"bot-{message_id.hex}",
            get_settings().send_expiry_seconds,
            radio.is_simulated,
        )
        if created:
            out.meta = {"bot": command}
        await s.commit()
    if created:
        hub.publish("message-created", conversation_id=str(conv.id), message_id=str(out.id))
    return reply
