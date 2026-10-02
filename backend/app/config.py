"""Process-level configuration from environment variables.

Only deployment plumbing lives here (database URL, cookie policy, kill switches).
Anything specific to an installation — the owner account, the radio's address,
the radio mode — is captured by the first-run setup wizard and stored in the
database, so nothing installation-specific needs to be committed to the repo.
"""

from functools import lru_cache
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

APP_VERSION = "0.1.1"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, extra="ignore")

    # postgresql+asyncpg://user:password@host:5432/dbname — supplied by the environment / a Secret.
    database_url: str = Field(default="", alias="DATABASE_URL")

    # Global kill switch: false keeps the radio closed regardless of saved settings
    # (useful for restore/demo environments).
    radio_enabled: bool = Field(default=True, alias="RADIO_ENABLED")

    # Optional fixed setup token. When unset, a random one is generated at startup and logged.
    setup_token: str | None = Field(default=None, alias="SETUP_TOKEN")

    # "auto" marks cookies Secure when the request arrived over HTTPS (directly or via X-Forwarded-Proto).
    cookie_secure: Literal["auto", "true", "false"] = Field(default="auto", alias="COOKIE_SECURE")

    session_days: int = Field(default=30, alias="SESSION_DAYS")
    send_expiry_seconds: int = Field(default=60, alias="SEND_EXPIRY_SECONDS")
    log_level: str = Field(default="INFO", alias="LOG_LEVEL")

    # Directory holding the built frontend. Empty disables static serving (dev uses the Vite server).
    static_dir: str = Field(default="app/static", alias="STATIC_DIR")


@lru_cache
def get_settings() -> Settings:
    return Settings()
