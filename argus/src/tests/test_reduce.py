from datetime import UTC, datetime

from app.models import LogCluster, LogLine
from app.reduce import cluster_logs, normalize, select

T0 = datetime(2026, 10, 2, 4, 0, tzinfo=UTC)


def line(text: str, **labels: str) -> LogLine:
    return LogLine(labels={"job": "pod-logs", **labels}, timestamp=T0, line=text)


def test_normalize_strips_volatile_tokens():
    a = normalize("E1002 08:58:28.530252 1 x.go:71] dial 10.0.0.5:443 id=3f2a9c1e7b timeout")
    b = normalize("E1002 09:12:01.000001 1 x.go:71] dial 10.0.0.9:443 id=aa11bb22cc timeout")
    assert a == b


def test_cluster_logs_groups_by_stream_and_fingerprint():
    clusters = cluster_logs(
        [
            line("request 1 failed", namespace="a"),
            line("request 2 failed", namespace="a"),
            line("request 3 failed", namespace="b"),
        ]
    )
    assert [(c.stream, c.count) for c in clusters] == [
        ("job=pod-logs namespace=a", 2),
        ("job=pod-logs namespace=b", 1),
    ]


def cluster(stream: str, count: int, fp: str) -> LogCluster:
    return LogCluster(
        stream=stream, fingerprint=fp, count=count, first_seen=T0, last_seen=T0, sample="x"
    )


def test_select_keeps_quiet_streams_next_to_noisy_ones():
    noisy = [cluster("noisy", 100 - i, f"n{i}") for i in range(10)]
    quiet = [cluster("quiet", 1, "q")]
    chosen = select(noisy + quiet, limit=4, per_stream=3)
    assert {c.fingerprint for c in chosen} == {"n0", "n1", "n2", "q"}
