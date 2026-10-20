import logging
from datetime import UTC, datetime, timedelta

from app import judge, reduce
from app.collect import build_collectors, collect_all, disabled_notes
from app.config import Settings
from app.emit import loki, telegram
from app.models import Collected, Finding, LogCluster, Report

log = logging.getLogger(__name__)


def run(settings: Settings, dry_run: bool) -> int:
    until = datetime.now(UTC)
    since = until - timedelta(hours=settings.window_hours)

    collectors = build_collectors(settings)
    log.info("collectors enabled: %s", ", ".join(c.name for c in collectors) or "none")
    collected = collect_all(collectors, since, until)
    collected.notes += disabled_notes(collectors)
    clusters = reduce.cluster_logs(collected.logs)
    log.info(
        "%d facts, %d log lines in %d clusters, %d collector errors",
        len(collected.facts),
        len(collected.logs),
        len(clusters),
        len(collected.errors),
    )

    previous = None
    if settings.loki_url:
        try:
            previous = loki.previous(settings.loki_url, until)
        except Exception as exc:
            log.exception("reading the previous report failed")
            collected.notes.append(f"previous report unavailable ({type(exc).__name__})")

    usage = None
    try:
        report, usage = judge.judge(settings, collected, clusters, since, until, previous)
    except Exception as exc:
        log.exception("judge failed")
        report = unjudged_report(collected, clusters, exc, f"{until:%Y-%m-%d}")

    text = telegram.render(report, collected, until.astimezone(), usage)
    store(settings, loki.record(report, collected, since, until, usage), until, dry_run)
    if dry_run:
        log.info("dry run, report not sent:\n%s", text)
        return 0
    if not (settings.telegram_bot_token and settings.telegram_chat_id):
        log.error("TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are required unless --dry-run")
        return 2
    try:
        telegram.send(
            settings.telegram_bot_token.get_secret_value(), settings.telegram_chat_id, text
        )
    except Exception:
        log.exception("telegram send failed")
        return 1
    log.info("report sent")
    return 0


def store(settings: Settings, entry: dict, until: datetime, dry_run: bool) -> None:
    if not settings.loki_url:
        return
    try:
        loki.push(settings.loki_url, entry, until, "dry" if dry_run else "sent")
        log.info("report stored in loki")
    except Exception:
        log.exception("storing the report in loki failed")


def unjudged_report(
    collected: Collected, clusters: list[LogCluster], exc: Exception, today: str
) -> Report:
    findings = [
        Finding(
            severity="warning",
            status="new",
            since=today,
            title=f"{f.check}: {f.subject}",
            detail=f"{f.value} {f.detail}".strip(),
            evidence=[f.source],
        )
        for f in collected.facts
    ]
    findings += [
        Finding(
            severity="info",
            status="new",
            since=today,
            title=f"{c.count}× {c.stream}",
            detail=c.sample[:200],
            evidence=["loki"],
        )
        for c in clusters[:5]
    ]
    return Report(
        headline=f"judge failed ({type(exc).__name__}); raw facts below", findings=findings
    )
