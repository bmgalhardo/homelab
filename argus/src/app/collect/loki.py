from datetime import UTC, datetime

import httpx

from app.config import Settings
from app.emit.loki import JOB as OWN_JOB
from app.models import Collected, Fact, LogLine

# (check, LogQL selector) for events that matter but match no error pattern.
# Reported as one fact per host with the event times.
EVENTS: list[tuple[str, str]] = [
    ("link_down", '{job="syslog"} |= "Link is Down"'),
]


class LokiCollector:
    name = "loki"

    def __init__(self, settings: Settings) -> None:
        self.client = httpx.Client(base_url=settings.loki_url, timeout=60)
        self.pattern = settings.loki_pattern
        self.limit = settings.loki_limit

    def collect(self, since: datetime, until: datetime) -> Collected:
        jobs = self.client.get("/loki/api/v1/label/job/values").raise_for_status().json()
        collected = Collected()
        for job in jobs.get("data", []):
            if job == OWN_JOB:
                continue
            lines = self._query(job, since, until)
            if len(lines) >= self.limit:
                collected.notes.append(
                    f"loki job={job}: hit the {self.limit} line limit, older matches dropped"
                )
            collected.logs += lines
        for check, selector in EVENTS:
            collected.facts += _event_facts(check, self._range(selector, since, until))
        return collected

    def _query(self, job: str, since: datetime, until: datetime) -> list[LogLine]:
        return self._range(f'{{job="{job}"}} |~ `{self.pattern}`', since, until)

    def _range(self, query: str, since: datetime, until: datetime) -> list[LogLine]:
        response = self.client.get(
            "/loki/api/v1/query_range",
            params={
                "query": query,
                "start": _ns(since),
                "end": _ns(until),
                "limit": self.limit,
                "direction": "backward",
            },
        ).raise_for_status()
        return [
            LogLine(
                labels=stream["stream"],
                timestamp=datetime.fromtimestamp(int(ts) / 1e9, UTC),
                line=line,
            )
            for stream in response.json()["data"]["result"]
            for ts, line in stream["values"]
        ]


def _event_facts(check: str, lines: list[LogLine]) -> list[Fact]:
    by_host: dict[str, list[LogLine]] = {}
    for line in lines:
        by_host.setdefault(line.labels.get("host", "unknown"), []).append(line)
    return [
        Fact(
            source="loki",
            check=check,
            subject=f"host={host}",
            value=f"{len(events)} events",
            detail="at "
            + ", ".join(f"{e.timestamp:%Y-%m-%dT%H:%MZ}" for e in sorted(events, key=_at))
            + f"; sample: {max(events, key=_at).line[:120]}",
        )
        for host, events in sorted(by_host.items())
    ]


def _at(line: LogLine) -> datetime:
    return line.timestamp


def _ns(when: datetime) -> int:
    return int(when.timestamp() * 1e9)
