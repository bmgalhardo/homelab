import json
from datetime import UTC, datetime, timedelta

import httpx

from app.collect.loki import EVENTS, LokiCollector, _event_facts
from app.emit import loki
from app.models import Collected, Fact, Finding, LogLine, Report, Usage

UNTIL = datetime(2026, 10, 16, 3, 30, tzinfo=UTC)
SINCE = UNTIL - timedelta(hours=24)


def test_push_sends_report_as_one_json_line(monkeypatch):
    sent = {}

    def post(url, json, timeout):
        sent.update(url=url, body=json)
        return httpx.Response(204, request=httpx.Request("POST", url))

    monkeypatch.setattr(httpx, "post", post)
    report = Report(
        headline="h",
        findings=[
            Finding(
                severity="warning",
                status="new",
                since="2026-10-16",
                title="t",
                detail="d",
                evidence=[],
            )
        ],
    )
    collected = Collected(facts=[Fact(source="prometheus", check="up", subject="s", value="0")])
    usage = Usage(model="m", input_tokens=1, output_tokens=2, cost_usd=0.1, batch=True)
    loki.push(
        "http://loki:3100", loki.record(report, collected, SINCE, UNTIL, usage), UNTIL, "sent"
    )

    assert sent["url"] == "http://loki:3100/loki/api/v1/push"
    (stream,) = sent["body"]["streams"]
    assert stream["stream"] == {"job": "argus", "mode": "sent"}
    ((ts, line),) = stream["values"]
    assert ts == str(int(UNTIL.timestamp() * 1e9))
    entry = json.loads(line)
    assert entry["report"]["findings"][0]["title"] == "t"
    assert entry["facts"][0]["check"] == "up"
    assert entry["usage"]["batch"] is True


def test_collector_skips_its_own_reports():
    queried = []

    def handler(request):
        if request.url.path.endswith("/label/job/values"):
            return httpx.Response(200, json={"data": ["argus", "docker"]})
        queried.append(request.url.params["query"])
        return httpx.Response(200, json={"data": {"result": []}})

    collector = LokiCollector.__new__(LokiCollector)
    collector.client = httpx.Client(base_url="http://loki", transport=httpx.MockTransport(handler))
    collector.pattern, collector.limit = "error", 10
    collector.collect(SINCE, UNTIL)
    assert queried == ['{job="docker"} |~ `error`'] + [selector for _, selector in EVENTS]


def test_events_become_one_fact_per_host_with_times():
    lines = [
        LogLine(
            labels={"host": "udm"}, timestamp=UNTIL - timedelta(hours=h), line="eth8: Link is Down"
        )
        for h in (2, 12)
    ]
    [fact] = _event_facts("link_down", lines)
    assert (fact.subject, fact.value) == ("host=udm", "2 events")
    assert fact.detail == "at 2026-10-15T15:30Z, 2026-10-16T01:30Z; sample: eth8: Link is Down"


def test_previous_reads_the_latest_sent_report_including_old_records(monkeypatch):
    old_entry = {
        "until": "2026-10-15T02:30:00+00:00",
        "report": {"headline": "h", "findings": [{"severity": "info", "title": "old"}]},
    }
    new_entry = {
        "until": "2026-10-16T02:30:00+00:00",
        "report": {
            "headline": "h",
            "findings": [
                {
                    "severity": "critical",
                    "status": "ongoing",
                    "since": "2026-10-11",
                    "title": "vault 403",
                    "detail": "d",
                    "evidence": [],
                }
            ],
        },
    }

    def get(url, params, timeout):
        assert params["query"] == '{job="argus", mode="sent"}'
        values = [["1", json.dumps(old_entry)], ["2", json.dumps(new_entry)]]
        return httpx.Response(
            200, json={"data": {"result": [{"values": values}]}}, request=httpx.Request("GET", url)
        )

    monkeypatch.setattr(httpx, "get", get)
    previous = loki.previous("http://loki:3100", UNTIL)
    assert previous.until == new_entry["until"]
    [finding] = previous.findings
    assert (finding.status, finding.since, finding.title) == ("ongoing", "2026-10-11", "vault 403")

    old = loki.PreviousReport(until="x", findings=old_entry["report"]["findings"])
    assert (old.findings[0].status, old.findings[0].since) == ("new", "")


def test_previous_is_none_without_reports(monkeypatch):
    monkeypatch.setattr(
        httpx,
        "get",
        lambda url, params, timeout: httpx.Response(
            200, json={"data": {"result": []}}, request=httpx.Request("GET", url)
        ),
    )
    assert loki.previous("http://loki:3100", UNTIL) is None
