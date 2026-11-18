"""The documentation the judge reads: local files and URLs, with a cache for outages.

A URL that can't be fetched falls back to its last good copy on disk, so a run
never fails because the host serving the documentation is down. Each fallback
or miss becomes a context_unreachable fact.
"""

import hashlib
import logging
import ssl
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlsplit

import httpx

from app.config import Settings
from app.models import Fact

log = logging.getLogger(__name__)

TIMEOUT_SECONDS = 10


def load(settings: Settings) -> tuple[str, list[Fact]]:
    """Return the <documentation> block and the facts about sources that failed."""
    docs: list[str] = []
    facts: list[Fact] = []

    if settings.context_dir is not None:
        if settings.context_dir.is_dir():
            docs += [
                _doc(path.name, path.read_text())
                for path in sorted(settings.context_dir.glob("*.md"))
                if path.name not in settings.context_exclude
            ]
        else:
            log.warning("context dir %s does not exist", settings.context_dir)

    sources = [(url, None) for url in settings.context_urls]
    token = settings.context_token.get_secret_value() if settings.context_token else None
    sources += [(url, token) for url in settings.context_private_urls]
    if sources:
        with _client(settings) as client:
            for url, auth in sources:
                doc, fact = _fetch(client, url, auth, settings.context_cache_dir)
                if doc:
                    docs.append(doc)
                if fact:
                    facts.append(fact)

    if not docs:
        log.warning("no documentation, judging without it")
        return "<documentation>none available</documentation>", facts
    return "<documentation>\n" + "\n".join(docs) + "\n</documentation>", facts


def _client(settings: Settings) -> httpx.Client:
    verify = ssl.create_default_context()
    if settings.ca_file:
        verify.load_verify_locations(cafile=settings.ca_file)
    return httpx.Client(verify=verify, timeout=TIMEOUT_SECONDS, follow_redirects=True)


def _fetch(
    client: httpx.Client, url: str, token: str | None, cache_dir: Path | None
) -> tuple[str | None, Fact | None]:
    name = Path(urlsplit(url).path).name or url
    cache = _cache_path(cache_dir, url)
    headers = {"Authorization": f"token {token}"} if token else {}
    try:
        text = client.get(url, headers=headers).raise_for_status().text
    except httpx.HTTPError as exc:
        reason = type(exc).__name__
        if isinstance(exc, httpx.HTTPStatusError):
            reason = f"HTTP {exc.response.status_code}"
        log.warning("context %s unreachable: %s", url, reason)
        host = urlsplit(url).hostname or url
        if cache and cache.is_file():
            as_of = datetime.fromtimestamp(cache.stat().st_mtime, UTC)
            fact = Fact(
                source="argus",
                check="context_unreachable",
                subject=f"host={host} doc={name}",
                value="cached",
                detail=f"{reason}; using the copy from {as_of:%Y-%m-%dT%H:%MZ}",
            )
            return _doc(name, cache.read_text(), as_of), fact
        fact = Fact(
            source="argus",
            check="context_unreachable",
            subject=f"host={host} doc={name}",
            value="missing",
            detail=f"{reason}; no cached copy, judged without it",
        )
        return None, fact

    if cache:
        try:
            cache.parent.mkdir(parents=True, exist_ok=True)
            tmp = cache.with_suffix(".tmp")
            tmp.write_text(text)
            tmp.replace(cache)
        except OSError:
            log.exception("caching %s failed", url)
    return _doc(name, text), None


def _cache_path(cache_dir: Path | None, url: str) -> Path | None:
    if cache_dir is None:
        return None
    digest = hashlib.sha256(url.encode()).hexdigest()[:12]
    return cache_dir / f"{digest}-{Path(urlsplit(url).path).name or 'doc'}"


def _doc(name: str, text: str, as_of: datetime | None = None) -> str:
    stale = f' cached_as_of="{as_of:%Y-%m-%dT%H:%MZ}"' if as_of else ""
    return f'<doc name="{name}"{stale}>\n{text}\n</doc>'
