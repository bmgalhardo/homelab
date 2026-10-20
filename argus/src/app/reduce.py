import hashlib
import re
from collections import defaultdict

from app.models import LogCluster, LogLine

STREAM_LABELS = ("job", "host", "node", "namespace", "container", "unit", "service_name", "app")

_NOISE = [
    (
        re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?"),
        "<ts>",
    ),
    (
        re.compile(
            r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.IGNORECASE
        ),
        "<uuid>",
    ),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"), "<ip>"),
    (re.compile(r"\b(?:0x)?[0-9a-f]{8,}\b", re.IGNORECASE), "<hex>"),
    (re.compile(r"-[a-z0-9]{5,10}-[a-z0-9]{5}\b"), "-<pod>"),
    (re.compile(r"\d+(?:\.\d+)?"), "<n>"),
]


def normalize(line: str) -> str:
    for pattern, token in _NOISE:
        line = pattern.sub(token, line)
    return " ".join(line.split())[:400]


def stream_key(labels: dict[str, str]) -> str:
    return " ".join(f"{k}={labels[k]}" for k in STREAM_LABELS if labels.get(k))


def cluster_logs(lines: list[LogLine]) -> list[LogCluster]:
    groups: dict[tuple[str, str], list[LogLine]] = defaultdict(list)
    for line in lines:
        groups[(stream_key(line.labels), normalize(line.line))].append(line)

    clusters = [
        LogCluster(
            stream=stream,
            fingerprint=hashlib.sha1(f"{stream}|{normalized}".encode()).hexdigest()[:12],
            count=len(members),
            first_seen=min(m.timestamp for m in members),
            last_seen=max(m.timestamp for m in members),
            sample=max(members, key=lambda m: m.timestamp).line[:200],
        )
        for (stream, normalized), members in groups.items()
    ]
    return sorted(clusters, key=lambda c: c.count, reverse=True)


def select(clusters: list[LogCluster], limit: int, per_stream: int = 3) -> list[LogCluster]:
    """Top clusters by count, but every stream keeps its first few so one noisy
    stream cannot crowd out the rest."""
    taken: dict[str, int] = defaultdict(int)
    guaranteed, rest = [], []
    for cluster in clusters:
        if taken[cluster.stream] < per_stream:
            taken[cluster.stream] += 1
            guaranteed.append(cluster)
        else:
            rest.append(cluster)
    chosen = (guaranteed + rest)[:limit]
    return sorted(chosen, key=lambda c: c.count, reverse=True)
