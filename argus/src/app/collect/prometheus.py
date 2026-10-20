from datetime import UTC, datetime

import httpx

from app.config import Settings
from app.models import Collected, Fact

# (check, PromQL, value unit). Each query returns only the series worth reporting.
CHECKS: list[tuple[str, str, str]] = [
    ("target_down_now", "up == 0", ""),
    ("target_down_in_window", "min_over_time(up[{w}]) == 0", ""),
    ("probe_failed_in_window", "min_over_time(probe_success[{w}]) == 0", ""),
    (
        "tls_cert_expiring",
        "(min by (instance) (probe_ssl_earliest_cert_expiry) - time()) / 86400 < 30",
        "days",
    ),
    (
        "certmanager_renewal_overdue",
        "(time() - certmanager_certificate_renewal_timestamp_seconds) / 3600 > 1",
        "hours",
    ),
    (
        "certmanager_cert_expiring",
        "(certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 7",
        "days",
    ),
    (
        "certmanager_cert_not_ready",
        'certmanager_certificate_ready_status{condition="True"} == 0',
        "",
    ),
    (
        "filesystem_full",
        (
            "max_over_time((1 - node_filesystem_avail_bytes"
            '{fstype!~"overlay|squashfs|nsfs|tracefs|ramfs"}'
            " / node_filesystem_size_bytes)[{w}:5m]) > 0.85"
        ),
        "used fraction (max)",
    ),
    (
        "memory_pressure",
        (
            "max_over_time((1 - node_memory_MemAvailable_bytes"
            " / node_memory_MemTotal_bytes)[{w}:5m]) > 0.9"
        ),
        "used fraction (max)",
    ),
    (
        "memory_pressure_now",
        (
            "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)"
            " and on (instance) max_over_time((1 - node_memory_MemAvailable_bytes"
            " / node_memory_MemTotal_bytes)[{w}:5m]) > 0.9"
        ),
        "used fraction (now)",
    ),
    (
        "pod_restarts",
        "sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[{w}])) > 0.5",
        "restarts",
    ),
    (
        "pod_not_running",
        'sum by (namespace, pod, phase) (kube_pod_status_phase{phase=~"Pending|Failed|Unknown"}) > 0',
        "",
    ),
    ("deployment_unavailable", "kube_deployment_status_replicas_unavailable > 0", "replicas"),
    (
        "node_not_ready",
        'kube_node_status_condition{condition="Ready",status="true"} == 0',
        "",
    ),
    (
        "node_pressure",
        (
            'kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure",'
            'status="true"} == 1'
        ),
        "",
    ),
    ("pvc_not_bound", 'kube_persistentvolumeclaim_status_phase{phase!="Bound"} == 1', ""),
    ("haproxy_server_down", 'haproxy_server_status{state="DOWN"} == 1', ""),
    (
        "host_rebooted",
        "node_boot_time_seconds and changes(node_boot_time_seconds[{w}]) > 0",
        "timestamp",
    ),
    ("oom_kills", "increase(node_vmstat_oom_kill[{w}]) > 0.5", "kills"),
    (
        "cert_reissued_often",
        "max by (instance) (changes(probe_ssl_earliest_cert_expiry[{w}])) > 2",
        "new certs",
    ),
]


class PrometheusCollector:
    name = "prometheus"

    def __init__(self, settings: Settings) -> None:
        self.client = httpx.Client(base_url=settings.prometheus_url, timeout=60)
        self.window = f"{settings.window_hours}h"

    def collect(self, since: datetime, until: datetime) -> Collected:
        collected = Collected()
        for check, template, unit in CHECKS:
            query = template.replace("{w}", self.window)
            response = self.client.get(
                "/api/v1/query", params={"query": query, "time": until.timestamp()}
            ).raise_for_status()
            for series in response.json()["data"]["result"]:
                collected.facts.append(
                    Fact(
                        source=self.name,
                        check=check,
                        subject=_subject(series["metric"]),
                        value=_value(series["value"][1], unit),
                    )
                )
        return collected


def _subject(metric: dict[str, str]) -> str:
    return " ".join(f"{k}={v}" for k, v in sorted(metric.items()) if k != "__name__")


def _value(raw: str, unit: str) -> str:
    number = float(raw)
    if unit == "timestamp":
        return f"{datetime.fromtimestamp(number, UTC):%Y-%m-%dT%H:%MZ}"
    text = f"{number:.0f}" if number.is_integer() else f"{number:.2f}"
    return f"{text} {unit}".strip()
