from types import SimpleNamespace

import pytest

from app import judge
from app.models import Report

REPORT = Report(headline="nothing new", findings=[])
REPORT_JSON = REPORT.model_dump_json()


def message(text=REPORT_JSON, stop_reason="end_turn"):
    return SimpleNamespace(
        model="claude-opus-5-5",
        stop_reason=stop_reason,
        stop_details=None,
        content=[SimpleNamespace(type="text", text=text)],
        usage=SimpleNamespace(input_tokens=30_000, output_tokens=2_000),
    )


class FakeBatches:
    def __init__(self, statuses, result):
        self.statuses = iter(statuses)
        self.result = result
        self.cancelled = False

    def create(self, requests):
        return SimpleNamespace(id="b1", processing_status=next(self.statuses))

    def retrieve(self, batch_id):
        return SimpleNamespace(id=batch_id, processing_status=next(self.statuses))

    def results(self, batch_id):
        return iter([SimpleNamespace(custom_id="argus", result=self.result)])

    def cancel(self, batch_id):
        self.cancelled = True


def client(batches):
    return SimpleNamespace(messages=SimpleNamespace(batches=batches))


@pytest.fixture(autouse=True)
def no_sleep(monkeypatch):
    monkeypatch.setattr(judge.time, "sleep", lambda _: None)


def test_batch_returns_report_at_half_price():
    succeeded = SimpleNamespace(type="succeeded", message=message())
    report, usage = judge._batch(client(FakeBatches(["in_progress", "ended"], succeeded)), {}, 60)

    assert report == REPORT
    assert usage.batch and usage.cost_usd == pytest.approx(0.08)


def test_batch_cancelled_after_timeout():
    batches = FakeBatches(["in_progress"] * 3, None)
    with pytest.raises(TimeoutError):
        judge._batch(client(batches), {}, 0)
    assert batches.cancelled


def test_batch_error_raises():
    errored = SimpleNamespace(type="errored", error="overloaded")
    with pytest.raises(RuntimeError, match="errored"):
        judge._batch(client(FakeBatches(["ended"], errored)), {}, 60)


def test_refusal_raises():
    with pytest.raises(RuntimeError, match="refused"):
        judge._report(message(text="", stop_reason="refusal"), batch=True)


def test_evidence_carries_the_previous_report():
    from datetime import UTC, datetime

    from app.models import Collected, PreviousReport

    when = datetime(2026, 10, 18, 2, 30, tzinfo=UTC)
    previous = PreviousReport(
        until="2026-10-17T02:30:00+00:00",
        findings=[{"severity": "warning", "status": "new", "since": "2026-10-17", "title": "t"}],
    )
    text = judge._evidence(Collected(), [], [], when, when, previous)
    assert '"previous_report":{"until":"2026-10-17T02:30:00+00:00"' in text
    assert '"previous_report":null' in judge._evidence(Collected(), [], [], when, when)
