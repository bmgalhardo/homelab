from pathlib import Path

import pytest

from app.config import ARGUS_DIR, Settings


@pytest.fixture
def required_env(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setenv("TELEGRAM_BOT_TOKEN", "bot-test")
    monkeypatch.setenv("TELEGRAM_CHAT_ID", "123")
    monkeypatch.setenv("OMNI_ENDPOINT", "https://omni.test")
    monkeypatch.setenv("OMNI_SERVICE_ACCOUNT_KEY", "omni-test")


def test_settings_from_env(required_env):
    settings = Settings(_env_file=None)

    assert settings.telegram_chat_id == "123"
    assert settings.anthropic_api_key.get_secret_value() == "sk-test"


def test_log_level_defaults_to_info(required_env):
    assert Settings(_env_file=None).log_level == "INFO"


def test_relative_paths_resolve_against_argus_dir(required_env, monkeypatch):
    monkeypatch.setenv("CONTEXT_DIR", "../.claude/context")
    monkeypatch.setenv("CA_FILE", "/ca/root-ca.crt")
    settings = Settings(_env_file=None)

    assert settings.context_dir == ARGUS_DIR / "../.claude/context"
    assert settings.ca_file == Path("/ca/root-ca.crt")


def test_context_exclude_is_comma_separated(required_env, monkeypatch):
    monkeypatch.setenv("CONTEXT_EXCLUDE", "deployment.md, todos.md")

    assert Settings(_env_file=None).context_exclude == {"deployment.md", "todos.md"}
