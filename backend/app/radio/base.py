"""Application-owned radio adapter contract.

These names describe *our* adapter, not upstream library methods. Concrete adapters
(simulated, MeshCore TCP) translate to and from this shape so the rest of the app
never touches the protocol library directly.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

# Default UTF-8 byte budgets for message text. MeshCore does not expose these through the
# client library; they are conservative defaults and MUST be verified on real hardware
# (ASCII, newlines and multibyte emoji at the boundary) before being relied upon.
DM_MAX_BYTES = 150
CHANNEL_MAX_BYTES = 150  # includes the "<node name>: " prefix the firmware adds


class RadioError(Exception):
    """A radio operation failed in a known way."""


@dataclass
class DeviceSnapshot:
    public_key: str
    name: str
    is_simulated: bool
    model: str | None = None
    firmware: str | None = None
    radio: dict[str, Any] = field(default_factory=dict)  # freq/bw/sf/cr/tx power — no secrets
    raw_device_info: dict[str, Any] = field(default_factory=dict)
    lat: float | None = None  # the gateway's own advertised position, if set
    lon: float | None = None


@dataclass
class RadioContact:
    public_key: str
    name: str
    kind: int = 1
    last_advert: int | None = None  # epoch seconds, from the radio
    meta: dict[str, Any] = field(default_factory=dict)
    lat: float | None = None  # position from the node's advert, if it shares one
    lon: float | None = None


@dataclass
class RadioChannel:
    slot: int
    name: str
    # Used only to compute a keyed fingerprint; never persisted or returned by the API.
    secret: bytes = b""


@dataclass
class IncomingMessage:
    kind: str  # "dm" | "channel"
    text: str
    txt_type: int = 0
    sender_timestamp: int | None = None
    pubkey_prefix: str | None = None  # DMs: hex prefix of sender key
    channel_slot: int | None = None  # channel messages
    sender_label: str | None = None  # channel messages: label as supplied by the sender
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass
class SendResult:
    ok: bool
    expected_ack: str | None = None
    suggested_timeout_ms: int | None = None
    error: str | None = None


AckCallback = Callable[[str], Awaitable[None]]
WaitingCallback = Callable[[], Awaitable[None]]
DisconnectCallback = Callable[[str], Awaitable[None]]


class RadioAdapter(ABC):
    is_simulated: bool = False

    def __init__(self) -> None:
        self.on_ack: AckCallback | None = None
        self.on_messages_waiting: WaitingCallback | None = None
        self.on_disconnect: DisconnectCallback | None = None

    @abstractmethod
    async def connect(self) -> None:
        """Open the transport and complete the companion handshake. Raises RadioError."""

    @abstractmethod
    async def disconnect(self) -> None: ...

    @abstractmethod
    async def get_device_snapshot(self) -> DeviceSnapshot: ...

    @abstractmethod
    async def get_contacts(self) -> list[RadioContact]: ...

    @abstractmethod
    async def get_channels(self) -> list[RadioChannel]: ...

    @abstractmethod
    async def fetch_next_message(self) -> IncomingMessage | None:
        """Retrieve one queued message from the radio, or None when the queue is empty."""

    @abstractmethod
    async def send_channel(self, slot: int, text: str, timestamp: int) -> SendResult: ...

    @abstractmethod
    async def send_dm(self, public_key: str, text: str, timestamp: int) -> SendResult: ...

    async def sync_clock(self, epoch_seconds: int) -> None:  # noqa: B027 - optional hook
        """Set the radio clock where supported."""


def advert_position(lat: Any, lon: Any) -> tuple[float | None, float | None]:
    """Normalise an advertised position. MeshCore uses 0,0 for "no location"; reject out-of-range values."""
    try:
        la, lo = float(lat), float(lon)
    except (TypeError, ValueError):
        return None, None
    if (la == 0 and lo == 0) or not (-90 <= la <= 90 and -180 <= lo <= 180):
        return None, None
    return la, lo


def split_channel_text(text: str) -> tuple[str | None, str]:
    """Channel text arrives as "<sender name>: <body>". Keep the label as supplied.

    Returns (label, body). If there is no recognisable prefix the whole text is the body.
    """
    head, sep, tail = text.partition(": ")
    if sep and 0 < len(head) <= 32 and "\n" not in head:
        return head, tail
    return None, text
