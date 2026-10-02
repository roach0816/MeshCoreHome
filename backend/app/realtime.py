"""Realtime invalidation hub. Events are hints to refetch REST state, never the source of truth."""

import asyncio
import logging
from typing import Any

log = logging.getLogger(__name__)

PROTOCOL_VERSION = 1
CLIENT_QUEUE_SIZE = 100


class Hub:
    def __init__(self) -> None:
        self._clients: set[asyncio.Queue[dict[str, Any] | None]] = set()

    def register(self) -> asyncio.Queue[dict[str, Any] | None]:
        q: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue(maxsize=CLIENT_QUEUE_SIZE)
        self._clients.add(q)
        return q

    def unregister(self, q: asyncio.Queue) -> None:
        self._clients.discard(q)

    @property
    def client_count(self) -> int:
        return len(self._clients)

    def publish(self, event_type: str, **data: Any) -> None:
        """Call only after the related database transaction has committed."""
        envelope = {"v": PROTOCOL_VERSION, "type": event_type, **data}
        for q in list(self._clients):
            try:
                q.put_nowait(envelope)
            except asyncio.QueueFull:
                # Slow client: drop it rather than block collection. It will resync on reconnect.
                log.info("disconnecting slow websocket client")
                self._clients.discard(q)
                while not q.empty():
                    q.get_nowait()
                q.put_nowait(None)

    def close_all(self) -> None:
        for q in list(self._clients):
            try:
                q.put_nowait(None)
            except asyncio.QueueFull:
                pass
        self._clients.clear()


hub = Hub()
