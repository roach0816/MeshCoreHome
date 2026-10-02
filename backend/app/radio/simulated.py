"""Deterministic-ish simulated radio for development and for running before hardware exists.

Everything it produces is stored with ``is_simulated = true`` and labelled in the UI.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import random
import time
from collections import deque

from app.radio.base import (
    DeviceSnapshot,
    IncomingMessage,
    NotSupported,
    RadioAdapter,
    RadioChannel,
    RadioContact,
    RadioError,
    SendResult,
    channel_key_kind,
    hashtag_key,
)

log = logging.getLogger(__name__)


def _key(seed: str) -> str:
    return hashlib.sha256(f"meshcore-home-sim:{seed}".encode()).hexdigest()


SIM_SELF_KEY = _key("home")
# Fictional positions around a public landmark (Boulder, Colorado), not any real installation.
SIM_HOME_POSITION = (40.0150, -105.2705)
SIM_CONTACTS = [
    RadioContact(public_key=_key("tracker"), name="Tracker (sim)", kind=1, lat=40.0274, lon=-105.2519),
    RadioContact(public_key=_key("neighbor"), name="Neighbor (sim)", kind=1, lat=40.0108, lon=-105.2790),
    RadioContact(public_key=_key("roof"), name="Roof Repeater (sim)", kind=2, lat=40.0163, lon=-105.2662),
    RadioContact(
        public_key=_key("hilltop"), name="Hilltop Repeater (sim)", kind=2, lat=39.9990, lon=-105.2930
    ),
    RadioContact(public_key=_key("room"), name="Club Room (sim)", kind=3, lat=40.0201, lon=-105.2829),
    RadioContact(public_key=_key("wx"), name="Weather Station (sim)", kind=4, lat=40.0060, lon=-105.2600),
    # Shares no position, like many real nodes.
    RadioContact(public_key=_key("hiker"), name="Hiker (sim, no location)", kind=1),
]
SIM_CHANNELS = [
    RadioChannel(slot=0, name="Public", secret=b"sim-public-secret"),
    RadioChannel(slot=1, name="#home-sim", secret=b"sim-home-secret!"),
]
CHANNEL_SENDERS = ["Tracker (sim)", "Neighbor (sim)", "Hilltop", "Kayak 🚣", "BaseCamp"]
PHRASES = [
    "Testing, anyone copy?",
    "Heading out for a walk, back in an hour.",
    "Signal looks good from the ridge today.",
    "Can you hear me through the roof repeater?",
    "Weather turning, bring a jacket 🌧️",
    "All good here.",
    "Ping 👋",
    "Line one\nLine two — newlines survive the trip.",
    "<b>not bold</b> — remote text is always rendered as plain text",
]


SIM_MAX_CHANNELS = 8


def _initial_state() -> dict:
    return {
        "name": "Home (simulated)",
        "lat": SIM_HOME_POSITION[0],
        "lon": SIM_HOME_POSITION[1],
        "share_location": True,
        "radio": {"freq_mhz": 910.525, "bw_khz": 62.5, "sf": 7, "cr": 5, "tx_power_dbm": 22, "repeat": False},
        "auto_add_contacts": True,
        "multi_acks": 0,
        "path_hash_mode": 0,
        "default_flood_scope": "",
        "telemetry": {"base": 0, "location": 0, "environment": 0},
        "tuning": {"rx_delay": 0.0, "airtime_factor": 1.0},
        "channels": {c.slot: (c.name, c.secret) for c in SIM_CHANNELS},
        "custom_vars": {"gps": "0", "gps_interval": "900"},
    }


# Simulated node settings live for the process lifetime, so they survive reconnects like a real
# node's flash would (but reset when the app restarts).
_SIM_STATE: dict | None = None


def sim_state() -> dict:
    global _SIM_STATE
    if _SIM_STATE is None:
        _SIM_STATE = _initial_state()
    return _SIM_STATE


class SimulatedRadio(RadioAdapter):
    is_simulated = True

    def __init__(self, interval_seconds: int = 60, ack_probability: float = 0.8, seed: int | None = None):
        super().__init__()
        self.interval = interval_seconds
        self.ack_probability = ack_probability
        self._rng = random.Random(seed)
        self._queue: deque[IncomingMessage] = deque()
        self._task: asyncio.Task | None = None
        self._pending: set[asyncio.Task] = set()
        self._connected = False

    async def connect(self) -> None:
        await asyncio.sleep(0.2)  # pretend handshake
        self._connected = True
        if self.interval > 0:
            self._task = asyncio.create_task(self._generator(), name="sim-radio-generator")

    async def disconnect(self) -> None:
        self._connected = False
        for t in [self._task, *self._pending]:
            if t:
                t.cancel()
        self._task = None
        self._pending.clear()

    def _require(self) -> None:
        if not self._connected:
            raise RadioError("simulated radio is not connected")

    async def get_device_snapshot(self) -> DeviceSnapshot:
        self._require()
        st = sim_state()
        return DeviceSnapshot(
            public_key=SIM_SELF_KEY,
            name=st["name"],
            is_simulated=True,
            model="Simulated companion",
            firmware="sim-0.1",
            radio={k: v for k, v in st["radio"].items() if k != "repeat"},
            lat=st["lat"],
            lon=st["lon"],
        )

    async def get_contacts(self) -> list[RadioContact]:
        self._require()
        now = int(time.time())
        return [
            RadioContact(c.public_key, c.name, c.kind, now - 600 * (i + 1), lat=c.lat, lon=c.lon)
            for i, c in enumerate(SIM_CONTACTS)
        ]

    async def get_channels(self) -> list[RadioChannel]:
        self._require()
        return [
            RadioChannel(slot=slot, name=name, secret=secret)
            for slot, (name, secret) in sorted(sim_state()["channels"].items())
        ]

    async def fetch_next_message(self) -> IncomingMessage | None:
        self._require()
        return self._queue.popleft() if self._queue else None

    async def send_channel(self, slot: int, text: str, timestamp: int) -> SendResult:
        self._require()
        if slot not in sim_state()["channels"]:
            return SendResult(ok=False, error="unknown channel slot")
        await asyncio.sleep(0.15)
        return SendResult(ok=True)

    async def send_dm(self, public_key: str, text: str, timestamp: int) -> SendResult:
        self._require()
        await asyncio.sleep(0.15)
        ack = self._rng.randbytes(4).hex()
        if self._rng.random() < self.ack_probability:
            self._spawn(self._deliver_ack(ack, self._rng.uniform(0.8, 3.0)))
        if self._rng.random() < 0.5:
            contact = next((c for c in SIM_CONTACTS if c.public_key == public_key), None)
            if contact and contact.kind == 1:
                self._spawn(self._auto_reply(contact, self._rng.uniform(3.0, 8.0)))
        return SendResult(ok=True, expected_ack=ack, suggested_timeout_ms=8000)

    # ---- node configuration (in memory) ---------------------------------------------

    async def read_config(self) -> dict:
        self._require()
        st = sim_state()
        return {
            "simulated": True,
            "firmware": {
                "version_code": 10,
                "version": "sim-0.1",
                "build": "simulated",
                "model": "Simulated companion",
            },
            "identity": {
                "name": st["name"],
                "lat": st["lat"],
                "lon": st["lon"],
                "share_location": st["share_location"],
            },
            "radio": {**st["radio"], "max_tx_power_dbm": 22},
            "behavior": {
                "auto_add_contacts": st["auto_add_contacts"],
                "multi_acks": st["multi_acks"],
                "path_hash_mode": st["path_hash_mode"],
                "default_flood_scope": st["default_flood_scope"],
            },
            "telemetry": dict(st["telemetry"]),
            "tuning": dict(st["tuning"]),
            "channels": [
                {
                    "slot": i,
                    "name": st["channels"].get(i, ("", bytes(16)))[0],
                    "key": channel_key_kind(*st["channels"].get(i, ("", bytes(16)))),
                }
                for i in range(SIM_MAX_CHANNELS)
            ],
            "max_channels": SIM_MAX_CHANNELS,
            "custom_vars": dict(st["custom_vars"]),
        }

    async def configure(self, op: str, params: dict) -> dict:
        self._require()
        await asyncio.sleep(0.1)
        st = sim_state()
        if op == "identity":
            st.update(
                name=params["name"],
                lat=params.get("lat"),
                lon=params.get("lon"),
                share_location=params["share_location"],
            )
        elif op == "radio":
            st["radio"].update({k: params[k] for k in ("freq_mhz", "bw_khz", "sf", "cr", "tx_power_dbm")})
            if params.get("repeat") is not None:
                st["radio"]["repeat"] = bool(params["repeat"])
        elif op == "behavior":
            st["auto_add_contacts"] = params["auto_add_contacts"]
            st["multi_acks"] = params["multi_acks"]
            for k in ("path_hash_mode", "default_flood_scope"):
                if params.get(k) is not None:
                    st[k] = params[k]
        elif op == "telemetry":
            st["telemetry"] = {k: params[k] for k in ("base", "location", "environment")}
        elif op == "tuning":
            st["tuning"] = {k: params[k] for k in ("rx_delay", "airtime_factor")}
        elif op == "channel":
            name = params["name"]
            secret = (
                hashtag_key(name)
                if name.startswith("#") or params.get("secret") is None
                else params["secret"]
            )
            st["channels"][params["slot"]] = (name, secret)
        elif op == "channel_clear":
            st["channels"].pop(params["slot"], None)
        elif op == "custom_var":
            st["custom_vars"][params["key"]] = params["value"]
        elif op in ("advert", "sync_clock"):
            pass
        elif op == "reboot":
            # Behave like the real thing: the connection drops and the supervisor reconnects.
            self._spawn(self._simulate_reboot())
        else:
            raise NotSupported(f"unknown operation {op!r}")
        return {}

    async def _simulate_reboot(self) -> None:
        await asyncio.sleep(0.3)
        self._connected = False
        if self.on_disconnect:
            await self.on_disconnect("radio rebooted")

    # ---- simulation helpers -------------------------------------------------

    def inject(self, msg: IncomingMessage) -> None:
        self._queue.append(msg)
        if self.on_messages_waiting:
            self._spawn(self.on_messages_waiting())

    def random_message(self) -> IncomingMessage:
        now = int(time.time())
        if self._rng.random() < 0.6:
            ch = self._rng.choice(SIM_CHANNELS)
            sender = self._rng.choice(CHANNEL_SENDERS)
            return IncomingMessage(
                kind="channel",
                text=self._rng.choice(PHRASES),
                channel_slot=ch.slot,
                sender_label=sender,
                sender_timestamp=now - self._rng.randint(0, 5),
                meta={"snr": round(self._rng.uniform(-8, 12), 1), "path_len": self._rng.randint(0, 3)},
            )
        contact = self._rng.choice([c for c in SIM_CONTACTS if c.kind == 1])
        return IncomingMessage(
            kind="dm",
            text=self._rng.choice(PHRASES),
            pubkey_prefix=contact.public_key[:12],
            sender_timestamp=now - self._rng.randint(0, 5),
            meta={"snr": round(self._rng.uniform(-8, 12), 1)},
        )

    def _spawn(self, coro) -> None:
        task = asyncio.create_task(coro)
        self._pending.add(task)
        task.add_done_callback(self._pending.discard)

    async def _deliver_ack(self, code: str, delay: float) -> None:
        await asyncio.sleep(delay)
        if self._connected and self.on_ack:
            await self.on_ack(code)

    async def _auto_reply(self, contact: RadioContact, delay: float) -> None:
        await asyncio.sleep(delay)
        if self._connected:
            self.inject(
                IncomingMessage(
                    kind="dm",
                    text=self._rng.choice(["Got it 👍", "Copy that.", "Thanks!", "Roger, talk soon."]),
                    pubkey_prefix=contact.public_key[:12],
                    sender_timestamp=int(time.time()),
                )
            )

    async def _generator(self) -> None:
        try:
            while self._connected:
                await asyncio.sleep(self._rng.uniform(0.5, 1.5) * self.interval)
                self.inject(self.random_message())
        except asyncio.CancelledError:
            pass
