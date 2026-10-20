from pathlib import Path
from typing import Annotated, Literal

from pydantic import SecretStr, field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

ARGUS_DIR = Path(__file__).resolve().parents[2]
ENV_FILE = ARGUS_DIR / ".env"
DEFAULT_LOKI_PATTERN = r"(?i)(error|fail|fatal|panic|denied|refused|timeout|oom|unhealthy)"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=ENV_FILE, extra="ignore")

    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"
    window_hours: int = 48
    context_dir: Path | None = None
    context_exclude: Annotated[set[str], NoDecode] = set()
    max_log_clusters: int = 100
    ca_file: Path | None = None

    anthropic_api_key: SecretStr
    anthropic_model: str = "claude-opus-5-5"
    anthropic_effort: Literal["low", "medium", "high", "xhigh", "max"] = "medium"
    anthropic_batch: bool = True
    batch_timeout_minutes: int = 360

    telegram_bot_token: SecretStr | None = None
    telegram_chat_id: str | None = None

    loki_url: str | None = None
    loki_pattern: str = DEFAULT_LOKI_PATTERN
    loki_limit: int = 20000

    prometheus_url: str | None = None

    proxmox_api_host: str | None = None
    proxmox_token_id: str | None = None
    proxmox_token_secret: SecretStr | None = None

    omni_endpoint: str | None = None
    omni_service_account_key: SecretStr | None = None
    omni_cluster: str = "elysium"

    @field_validator("context_exclude", mode="before")
    @classmethod
    def comma_separated(cls, value: str | set[str]) -> set[str]:
        if isinstance(value, str):
            return {name.strip() for name in value.split(",") if name.strip()}
        return value

    @field_validator("context_dir", "ca_file")
    @classmethod
    def relative_to_argus(cls, path: Path | None) -> Path | None:
        return ARGUS_DIR / path if path and not path.is_absolute() else path
