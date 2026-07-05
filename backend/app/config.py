from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """App configuration, read from environment variables (or a .env file)."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # --- Claude / Anthropic ---
    anthropic_api_key: str
    # Default to the most capable model. For a high-volume personal tracker you can
    # switch to a cheaper tier without code changes: claude-sonnet-5 or claude-haiku-4-5.
    anthropic_model: str = "claude-opus-4-8"

    # --- Database ---
    # postgresql+asyncpg://user:password@host:5432/dbname
    database_url: str

    # --- API auth ---
    # If set, every request (except /health) must send: Authorization: Bearer <api_key>
    # Leave empty to disable auth (fine only behind a trusted reverse proxy / LAN).
    api_key: str = ""

    # --- Defaults ---
    daily_calorie_goal: int = 2000


@lru_cache
def get_settings() -> Settings:
    return Settings()
