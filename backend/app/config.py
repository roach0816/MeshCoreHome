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

APP_VERSION = "0.7.5"


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

    # Where the version number in the UI links to. "{version}" is replaced (e.g. 0.4.0). Forks can
    # point this at their own repository; set it empty to show the version without a link.
    release_notes_url: str = Field(
        default="https://github.com/roach0816/MeshCoreHome/releases/tag/v{version}", alias="RELEASE_NOTES_URL"
    )

    # ---- updates / native install ----------------------------------------------------------
    # "native" (Debian/Raspberry Pi install via deploy/native/install.sh) enables in-place
    # upgrades from the web UI; "container" (Docker/Kubernetes) only reports new versions.
    install_kind: Literal["native", "container"] = Field(default="container", alias="MESHCORE_INSTALL_KIND")
    # Writable state directory for a native install (update requests/status, setup token file).
    state_dir: str = Field(default="", alias="MESHCORE_STATE_DIR")
    # GitHub "owner/repo" whose releases are checked for updates. Empty disables update checks.
    update_repo: str = Field(default="roach0816/MeshCoreHome", alias="UPDATE_REPO")
    # MeshCore's suggested radio presets (refreshed daily; a bundled copy is used offline). Empty: bundled only.
    radio_presets_url: str = Field(default="https://api.meshcore.nz/api/v1/config", alias="RADIO_PRESETS_URL")
    update_api_url: str = Field(default="https://api.github.com", alias="UPDATE_API_URL")

    # Directory holding the built frontend. Empty disables static serving (dev uses the Vite server).
    static_dir: str = Field(default="app/static", alias="STATIC_DIR")


@lru_cache
def get_settings() -> Settings:
    return Settings()
