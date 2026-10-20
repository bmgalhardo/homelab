import json
from datetime import datetime

import httpx

from app import __version__
from app.models import Collected, PreviousReport, Report, Usage

JOB = "argus"


def record(
    report: Report, collected: Collected, since: datetime, until: datetime, usage: Usage | None
) -> dict:
    return {
        "version": __version__,
        "since": since.isoformat(),
        "until": until.isoformat(),
        "report": report.model_dump(),
        "usage": usage.model_dump() if usage else None,
        "facts": [f.model_dump() for f in collected.facts],
        "errors": [e.model_dump() for e in collected.errors],
        "notes": collected.notes,
        "sources": [s.model_dump() for s in collected.sources],
    }


def push(loki_url: str, entry: dict, until: datetime, mode: str) -> None:
    stream = {
        "stream": {"job": JOB, "mode": mode},
        "values": [[str(int(until.timestamp() * 1e9)), json.dumps(entry, separators=(",", ":"))]],
    }
    httpx.post(
        f"{loki_url}/loki/api/v1/push", json={"streams": [stream]}, timeout=30
    ).raise_for_status()


def previous(loki_url: str, until: datetime, lookback_days: int = 7) -> PreviousReport | None:
    """The last sent report before `until`, or None if there is none in the lookback."""
    response = httpx.get(
        f"{loki_url}/loki/api/v1/query_range",
        params={
            "query": f'{{job="{JOB}", mode="sent"}}',
            "start": int((until.timestamp() - lookback_days * 86400) * 1e9),
            "end": int(until.timestamp() * 1e9),
            "limit": 1,
            "direction": "backward",
        },
        timeout=30,
    ).raise_for_status()
    values = [v for stream in response.json()["data"]["result"] for v in stream["values"]]
    if not values:
        return None
    entry = json.loads(max(values)[1])
    return PreviousReport(until=entry["until"], findings=entry["report"]["findings"])
