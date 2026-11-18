import httpx
import pytest

from app import context
from app.config import Settings

PUBLIC = "https://raw.example/repo/main/services.md"
PRIVATE = "https://forge.example/api/v1/repos/o/context/raw/homelab/known-issues.md"


@pytest.fixture
def required_env(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")


@pytest.fixture
def settings(required_env, monkeypatch, tmp_path):
    monkeypatch.setenv("CONTEXT_URLS", PUBLIC)
    monkeypatch.setenv("CONTEXT_PRIVATE_URLS", PRIVATE)
    monkeypatch.setenv("CONTEXT_TOKEN", "secret")
    monkeypatch.setenv("CONTEXT_CACHE_DIR", str(tmp_path / "cache"))
    return Settings(_env_file=None)


def serve(monkeypatch, handler):
    monkeypatch.setattr(
        context, "_client", lambda s: httpx.Client(transport=httpx.MockTransport(handler))
    )


def test_urls_are_comma_separated(settings):
    assert settings.context_urls == [PUBLIC]
    assert settings.context_private_urls == [PRIVATE]


def test_token_goes_only_to_private_urls(settings, monkeypatch):
    seen = {}

    def handler(request):
        seen[str(request.url)] = request.headers.get("authorization")
        return httpx.Response(200, text=f"body of {request.url.path}")

    serve(monkeypatch, handler)
    docs, facts = context.load(settings)

    assert seen == {PUBLIC: None, PRIVATE: "token secret"}
    assert '<doc name="services.md">' in docs
    assert '<doc name="known-issues.md">' in docs
    assert facts == []


def test_unreachable_falls_back_to_cache(settings, monkeypatch):
    serve(monkeypatch, lambda r: httpx.Response(200, text="known: vault has no backup"))
    context.load(settings)

    def down(request):
        raise httpx.ConnectError("no route", request=request)

    serve(monkeypatch, down)
    docs, facts = context.load(settings)

    assert "known: vault has no backup" in docs
    assert "cached_as_of=" in docs
    assert [(f.check, f.value) for f in facts] == [
        ("context_unreachable", "cached"),
        ("context_unreachable", "cached"),
    ]
    assert "host=forge.example doc=known-issues.md" in facts[1].subject


def test_unreachable_without_cache_judges_without_it(settings, monkeypatch):
    serve(monkeypatch, lambda r: httpx.Response(503))
    docs, facts = context.load(settings)

    assert docs == "<documentation>none available</documentation>"
    assert {f.value for f in facts} == {"missing"}
    assert "HTTP 503" in facts[0].detail


def test_local_dir_still_works(required_env, monkeypatch, tmp_path):
    (tmp_path / "network.md").write_text("vlans")
    (tmp_path / "deployment.md").write_text("skip me")
    monkeypatch.setenv("CONTEXT_DIR", str(tmp_path))
    monkeypatch.setenv("CONTEXT_EXCLUDE", "deployment.md")
    docs, facts = context.load(Settings(_env_file=None))

    assert '<doc name="network.md">\nvlans\n</doc>' in docs
    assert "skip me" not in docs
    assert facts == []
