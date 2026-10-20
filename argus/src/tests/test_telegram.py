from datetime import UTC, datetime

from app import __version__
from app.emit.telegram import render, split
from app.judge import usage
from app.models import Collected, CollectorError, Finding, Report, Source

UNTIL = datetime(2026, 10, 2, 4, 0, tzinfo=UTC)


def finding(severity, title, detail="d", status="new", since="2026-10-02"):
    return Finding(
        severity=severity, status=status, since=since, title=title, detail=detail, evidence=[]
    )


def test_quiet_night_is_one_line():
    text = render(Report(headline="nothing new", findings=[]), Collected(), UNTIL)
    assert text == (
        f"✅ <b>Argus 2026-10-02 04:00</b> — quiet\n<i>Summary: nothing new</i>"
        f"\n\n<i>argus {__version__}</i>"
    )


def test_worst_severity_leads_and_html_is_escaped():
    report = Report(
        headline="two things",
        findings=[
            finding("info", "a<b", "x"),
            finding("critical", "pool DEGRADED", "y"),
        ],
    )
    errors = Collected(errors=[CollectorError(collector="talos", error="omnictl: denied")])
    text = render(report, errors, UNTIL)
    assert text.startswith("🔴 <b>Argus 2026-10-02 04:00</b> — 1 critical · 1 info\n")
    assert "<i>Summary: two things</i>" in text
    assert text.index("pool DEGRADED") < text.index("a&lt;b")
    assert "collector <b>talos</b> failed" in text


def test_split_respects_limit_on_line_boundaries():
    chunks = split("\n".join(["x" * 30] * 10), limit=100)
    assert all(len(c) <= 100 for c in chunks)
    assert "\n".join(chunks) == "\n".join(["x" * 30] * 10)


def test_usage_footer():
    report = Report(headline="nothing new", findings=[])
    text = render(report, Collected(), UNTIL, usage("claude-opus-5-5", 30_000, 2_000))
    assert text.endswith(
        f"<i>claude-opus-5-5 · 30,000 in / 2,000 out · $0.160</i>\n<i>argus {__version__}</i>"
    )


def test_usage_footer_without_known_price():
    text = render(Report(headline="x", findings=[]), Collected(), UNTIL, usage("unknown", 1, 1))
    assert text.endswith(f"<i>unknown · 1 in / 1 out</i>\n<i>argus {__version__}</i>")


def test_batch_usage_is_half_price_and_labelled():
    report = Report(headline="nothing new", findings=[])
    text = render(report, Collected(), UNTIL, usage("claude-opus-5-5", 30_000, 2_000, batch=True))
    assert text.endswith(
        f"<i>claude-opus-5-5 · 30,000 in / 2,000 out · $0.080 · batch</i>\n<i>argus {__version__}</i>"
    )


def test_inputs_footer_lists_each_collector():
    collected = Collected(
        sources=[
            Source(name="loki", facts=0, logs=13_072),
            Source(name="prometheus", facts=19, logs=0),
            Source(name="talos", facts=0, logs=0),
        ]
    )
    text = render(Report(headline="x", findings=[]), collected, UNTIL)
    assert text.endswith(
        f"<i>argus {__version__} · loki 13,072 logs · prometheus 19 facts · talos 0 facts</i>"
    )


def test_notes_go_in_the_footer():
    collected = Collected(notes=["collector talos disabled (not configured)"])
    text = render(Report(headline="x", findings=[]), collected, UNTIL)
    assert "\n\n<i>note: collector talos disabled (not configured)</i>\n<i>argus" in text


def test_ongoing_is_one_line_and_resolved_is_listed_but_not_counted():
    report = Report(
        headline="x",
        findings=[
            finding("warning", "wan drops"),
            finding("critical", "vault 403", status="ongoing", since="2026-10-11"),
            finding("warning", "grafana restarts", "stopped 20:30Z", status="resolved"),
        ],
    )
    text = render(report, Collected(), UNTIL)
    assert text.startswith("🔴 <b>Argus 2026-10-02 04:00</b> — 1 critical · 1 warning · 1 resolved")
    assert "<b>Still open</b>\n🔴 vault 403 <i>(since 2026-10-11)</i>" in text
    assert "<b>✅ Resolved</b>\ngrafana restarts: stopped 20:30Z" in text
    assert text.index("wan drops") < text.index("Still open") < text.index("Resolved")


def test_only_resolved_is_green():
    report = Report(headline="x", findings=[finding("critical", "a", status="resolved")])
    assert render(report, Collected(), UNTIL).startswith(
        "✅ <b>Argus 2026-10-02 04:00</b> — 1 resolved"
    )
