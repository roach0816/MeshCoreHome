"""Installation-specific settings captured by the setup wizard and stored in the database."""

import secrets
from typing import Literal

from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import AppSetting, User, utcnow

# "hat": the radio HAT on this Pi (ZephCore on 127.0.0.1:5000, managed by the native installer).
RadioMode = Literal["simulated", "tcp", "hat", "none"]


class RadioConfig(BaseModel):
    mode: RadioMode = "simulated"
    host: str = ""
    port: int = Field(default=5000, ge=1, le=65535)
    # Maintenance pause: closes the TCP connection so a maintenance client can take over.
    paused: bool = False
    # Simulated mode only: average seconds between generated incoming messages (0 disables).
    sim_interval_seconds: int = Field(default=60, ge=0, le=3600)

    @field_validator("host")
    @classmethod
    def _strip_host(cls, v: str) -> str:
        v = v.strip()
        if any(c.isspace() for c in v) or "/" in v:
            raise ValueError("Enter a hostname or IP address only (no scheme or path)")
        return v


class InstallationConfig(BaseModel):
    home_name: str = "Home"
    setup_completed_at: str | None = None


OSM_TILE_URL = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"


class MapConfig(BaseModel):
    # Any XYZ raster tile server. OpenStreetMap's public tiles are the default; their usage policy
    # asks for attribution and light, interactive use, which fits a single household.
    tile_url: str = Field(default=OSM_TILE_URL, max_length=500)
    attribution: str = Field(default="© OpenStreetMap contributors", max_length=200)
    max_zoom: int = Field(default=19, ge=1, le=22)

    @field_validator("tile_url")
    @classmethod
    def _valid_template(cls, v: str) -> str:
        v = v.strip()
        if not v.startswith("https://"):
            raise ValueError("Tile URL must start with https://")
        if not all(p in v for p in ("{z}", "{x}", "{y}")):
            raise ValueError("Tile URL must contain {z}, {x} and {y}")
        return v


class NotificationConfig(BaseModel):
    # Sound for new incoming messages, played by open browser tabs. Per-conversation overrides
    # (conversations.sound) take precedence.
    sound: Literal["off", "all", "dms"] = "dms"


NOTIFICATIONS_KEY = "notifications"


class BotConfig(BaseModel):
    # Answer DMs that start with "/" (see app/services/bot.py). Off until the owner turns it on.
    enabled: bool = False
    # Who may use it: favourite contacts only, or every known contact.
    allow: Literal["favorites", "everyone"] = "favorites"


BOT_KEY = "bot"
RADIO_KEY = "radio"
MAP_KEY = "map"
INSTALLATION_KEY = "installation"
FINGERPRINT_KEY = "fingerprint_key"


async def _get(db: AsyncSession, key: str) -> dict | None:
    row = await db.get(AppSetting, key)
    return row.value if row else None


async def _put(db: AsyncSession, key: str, value: dict) -> None:
    stmt = insert(AppSetting).values(key=key, value=value, updated_at=utcnow())
    stmt = stmt.on_conflict_do_update(
        index_elements=[AppSetting.key], set_={"value": value, "updated_at": utcnow()}
    )
    await db.execute(stmt)


async def get_radio_config(db: AsyncSession) -> RadioConfig:
    raw = await _get(db, RADIO_KEY)
    return RadioConfig.model_validate(raw) if raw else RadioConfig(mode="none")


async def put_radio_config(db: AsyncSession, cfg: RadioConfig) -> None:
    await _put(db, RADIO_KEY, cfg.model_dump())


async def get_map_config(db: AsyncSession) -> MapConfig:
    raw = await _get(db, MAP_KEY)
    return MapConfig.model_validate(raw) if raw else MapConfig()


async def put_map_config(db: AsyncSession, cfg: MapConfig) -> None:
    await _put(db, MAP_KEY, cfg.model_dump())


async def get_notification_config(db: AsyncSession) -> NotificationConfig:
    raw = await _get(db, NOTIFICATIONS_KEY)
    return NotificationConfig.model_validate(raw) if raw else NotificationConfig()


async def put_notification_config(db: AsyncSession, cfg: NotificationConfig) -> None:
    await _put(db, NOTIFICATIONS_KEY, cfg.model_dump())


async def get_bot_config(db: AsyncSession) -> BotConfig:
    raw = await _get(db, BOT_KEY)
    return BotConfig.model_validate(raw) if raw else BotConfig()


async def put_bot_config(db: AsyncSession, cfg: BotConfig) -> None:
    await _put(db, BOT_KEY, cfg.model_dump())


async def get_installation(db: AsyncSession) -> InstallationConfig:
    raw = await _get(db, INSTALLATION_KEY)
    return InstallationConfig.model_validate(raw) if raw else InstallationConfig()


async def put_installation(db: AsyncSession, cfg: InstallationConfig) -> None:
    await _put(db, INSTALLATION_KEY, cfg.model_dump())


async def get_fingerprint_key(db: AsyncSession) -> bytes:
    """Per-installation key for channel fingerprints; generated on first use, never exposed."""
    raw = await _get(db, FINGERPRINT_KEY)
    if raw:
        return bytes.fromhex(raw["hex"])
    key = secrets.token_bytes(32)
    await _put(db, FINGERPRINT_KEY, {"hex": key.hex()})
    return key


async def setup_complete(db: AsyncSession) -> bool:
    return (await db.execute(select(User.id).limit(1))).first() is not None
