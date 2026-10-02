"""MeshCore Ethernet/TCP companion adapter, built on the upstream ``meshcore`` client.

Written against the source of ``meshcore`` 2.3.14 (pinned in requirements.txt).
NOT YET VERIFIED AGAINST REAL HARDWARE: response shapes are read defensively and any
unexpected shape degrades to a RadioError with redacted detail instead of crashing.
Capture redacted real responses as test fixtures once the RAK companion is commissioned.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from app.radio.base import (
    DeviceSnapshot,
    IncomingMessage,
    RadioAdapter,
    RadioChannel,
    RadioContact,
    RadioError,
    SendResult,
    split_channel_text,
)

log = logging.getLogger(__name__)

COMMAND_TIMEOUT = 8.0
CONNECT_TIMEOUT = 10.0
MAX_CHANNEL_SLOTS_FALLBACK = 8  # only used if the device does not report max_channels


def _payload(event: Any) -> dict[str, Any]:
    p = getattr(event, "payload", None)
    return p if isinstance(p, dict) else {}


def _describe(event: Any) -> str:
    """Error description safe for logs/UI: event type and a reason field only, never payload data."""
    if event is None:
        return "no response"
    p = _payload(event)
    reason = p.get("reason") or p.get("error") or p.get("error_code")
    etype = getattr(getattr(event, "type", None), "value", "unknown")
    return f"{etype}: {reason}" if reason else str(etype)


class MeshCoreTcpRadio(RadioAdapter):
    is_simulated = False

    def __init__(self, host: str, port: int):
        super().__init__()
        self.host = host
        self.port = port
        self._mc = None
        self._subs: list[Any] = []
        self._self_info: dict[str, Any] = {}
        self._device_info: dict[str, Any] = {}

    async def connect(self) -> None:
        from meshcore import EventType, MeshCore

        try:
            # auto_reconnect=False: our supervisor is the single reconnect mechanism.
            mc = await asyncio.wait_for(
                MeshCore.create_tcp(
                    self.host, self.port, default_timeout=COMMAND_TIMEOUT, auto_reconnect=False
                ),
                timeout=CONNECT_TIMEOUT,
            )
        except (TimeoutError, OSError, ConnectionError) as exc:
            raise RadioError(
                f"cannot reach companion at {self.host}:{self.port}: {type(exc).__name__}"
            ) from exc
        if mc is None:
            raise RadioError("companion did not answer the handshake")
        self._mc = mc
        self._self_info = dict(mc.self_info or {})

        # Subscribe to pushes before any message retrieval starts.
        async def _on_waiting(_event):
            if self.on_messages_waiting:
                await self.on_messages_waiting()

        async def _on_ack(event):
            code = _payload(event).get("code")
            if code and self.on_ack:
                await self.on_ack(code)

        async def _on_disconnected(event):
            if self.on_disconnect:
                await self.on_disconnect(str(_payload(event).get("reason", "disconnected")))

        self._subs = [
            mc.subscribe(EventType.MESSAGES_WAITING, _on_waiting),
            mc.subscribe(EventType.ACK, _on_ack),
            mc.subscribe(EventType.DISCONNECTED, _on_disconnected),
        ]

        res = await mc.commands.send_device_query()
        if res is not None and not res.is_error():
            self._device_info = _payload(res)

    async def disconnect(self) -> None:
        mc, self._mc = self._mc, None
        if mc is None:
            return
        for s in self._subs:
            mc.unsubscribe(s)
        self._subs = []
        try:
            await asyncio.wait_for(mc.disconnect(), timeout=5)
        except Exception as exc:  # noqa: BLE001 - best effort close
            log.warning("error while closing companion connection: %s", type(exc).__name__)

    def _require(self):
        if self._mc is None or not self._mc.is_connected:
            raise RadioError("not connected")
        return self._mc

    async def get_device_snapshot(self) -> DeviceSnapshot:
        self._require()
        si, di = self._self_info, self._device_info
        key = si.get("public_key")
        if not isinstance(key, str) or len(key) != 64:
            raise RadioError("device did not report a full public key")
        return DeviceSnapshot(
            public_key=key,
            name=str(si.get("name") or ""),
            is_simulated=False,
            model=di.get("model"),
            firmware=" ".join(str(x) for x in (di.get("ver"), di.get("fw_build")) if x) or None,
            radio={
                "freq_mhz": si.get("radio_freq"),
                "bw_khz": si.get("radio_bw"),
                "sf": si.get("radio_sf"),
                "cr": si.get("radio_cr"),
                "tx_power_dbm": si.get("tx_power"),
            },
            # Explicit allow-list: never forward unknown fields (e.g. BLE PIN) to the UI.
            raw_device_info={
                k: di[k]
                for k in ("fw ver", "max_contacts", "max_channels", "model", "ver", "fw_build")
                if k in di
            },
        )

    async def get_contacts(self) -> list[RadioContact]:
        mc = self._require()
        res = await mc.commands.get_contacts(timeout=COMMAND_TIMEOUT)
        if res is None or res.is_error():
            raise RadioError(f"contact refresh failed ({_describe(res)})")
        out = []
        for c in _payload(res).values():
            key = c.get("public_key") if isinstance(c, dict) else None
            if not isinstance(key, str) or len(key) != 64:
                continue
            out.append(
                RadioContact(
                    public_key=key,
                    name=str(c.get("adv_name") or ""),
                    kind=int(c.get("type") or 0),
                    last_advert=c.get("last_advert") or None,
                    meta={"out_path_len": c.get("out_path_len")},
                )
            )
        return out

    async def get_channels(self) -> list[RadioChannel]:
        mc = self._require()
        max_channels = self._device_info.get("max_channels") or MAX_CHANNEL_SLOTS_FALLBACK
        out = []
        for idx in range(int(max_channels)):
            res = await mc.commands.get_channel(idx)
            if res is None or res.is_error():
                continue
            p = _payload(res)
            name = str(p.get("channel_name") or "").strip()
            secret = p.get("channel_secret") or b""
            if not name and not any(secret):
                continue  # empty slot
            out.append(RadioChannel(slot=idx, name=name or f"Channel {idx}", secret=bytes(secret)))
        return out

    async def fetch_next_message(self) -> IncomingMessage | None:
        from meshcore import EventType

        mc = self._require()
        res = await mc.commands.get_msg(timeout=COMMAND_TIMEOUT)
        if res is None:
            raise RadioError("no response to message fetch")
        if res.type == EventType.NO_MORE_MSGS:
            return None
        if res.is_error():
            raise RadioError(f"message fetch failed ({_describe(res)})")
        p = _payload(res)
        meta = {k: p[k] for k in ("SNR", "path_len", "path_hash_mode", "RSSI") if k in p}
        text = str(p.get("text") or "")
        if res.type == EventType.CONTACT_MSG_RECV:
            return IncomingMessage(
                kind="dm",
                text=text,
                txt_type=int(p.get("txt_type") or 0),
                sender_timestamp=p.get("sender_timestamp"),
                pubkey_prefix=p.get("pubkey_prefix"),
                meta=meta,
            )
        if res.type == EventType.CHANNEL_MSG_RECV:
            label, body = split_channel_text(text)
            return IncomingMessage(
                kind="channel",
                text=body,
                txt_type=int(p.get("txt_type") or 0),
                sender_timestamp=p.get("sender_timestamp"),
                channel_slot=p.get("channel_idx"),
                sender_label=label,
                meta=meta,
            )
        raise RadioError(f"unexpected response to message fetch ({_describe(res)})")

    async def send_channel(self, slot: int, text: str, timestamp: int) -> SendResult:
        mc = self._require()
        res = await mc.commands.send_chan_msg(slot, text, timestamp)
        if res is None or res.is_error():
            return SendResult(ok=False, error=_describe(res))
        return SendResult(ok=True)

    async def send_dm(self, public_key: str, text: str, timestamp: int) -> SendResult:
        mc = self._require()
        # Single attempt; the library's send_msg_with_retry is deliberately not used
        # (no hidden automatic resend — retries are explicit and user-initiated).
        res = await mc.commands.send_msg(public_key, text, timestamp)
        if res is None or res.is_error():
            return SendResult(ok=False, error=_describe(res))
        p = _payload(res)
        ack = p.get("expected_ack")
        ack_hex = ack.hex() if isinstance(ack, bytes | bytearray) else (str(ack) if ack else None)
        return SendResult(ok=True, expected_ack=ack_hex, suggested_timeout_ms=p.get("suggested_timeout"))

    async def sync_clock(self, epoch_seconds: int) -> None:
        mc = self._require()
        res = await mc.commands.set_time(epoch_seconds)
        if res is None or res.is_error():
            log.info("radio clock sync not accepted (%s)", _describe(res))
