import logging
from datetime import datetime
from typing import Protocol

from app.config import Settings
from app.models import Collected, CollectorError, Source

log = logging.getLogger(__name__)

NAMES = ("loki", "prometheus", "proxmox", "talos")


class Collector(Protocol):
    name: str

    def collect(self, since: datetime, until: datetime) -> Collected: ...


def build_collectors(settings: Settings) -> list[Collector]:
    from app.collect.loki import LokiCollector
    from app.collect.prometheus import PrometheusCollector
    from app.collect.proxmox import ProxmoxCollector
    from app.collect.talos import TalosCollector

    collectors: list[Collector] = []
    if settings.loki_url:
        collectors.append(LokiCollector(settings))
    if settings.prometheus_url:
        collectors.append(PrometheusCollector(settings))
    if settings.proxmox_api_host and settings.proxmox_token_id and settings.proxmox_token_secret:
        collectors.append(ProxmoxCollector(settings))
    if settings.omni_endpoint and settings.omni_service_account_key:
        collectors.append(TalosCollector(settings))
    return collectors


def disabled_notes(collectors: list[Collector]) -> list[str]:
    enabled = {c.name for c in collectors}
    return [f"collector {name} disabled (not configured)" for name in NAMES if name not in enabled]


def collect_all(collectors: list[Collector], since: datetime, until: datetime) -> Collected:
    collected = Collected()
    for collector in collectors:
        log.info("collecting from %s", collector.name)
        try:
            result = collector.collect(since, until)
        except Exception as exc:
            log.exception("collector %s failed", collector.name)
            collected.errors.append(CollectorError(collector=collector.name, error=str(exc)))
            continue
        log.info("%s: %d facts, %d log lines", collector.name, len(result.facts), len(result.logs))
        collected.extend(result)
        collected.sources.append(
            Source(name=collector.name, facts=len(result.facts), logs=len(result.logs))
        )
    return collected
