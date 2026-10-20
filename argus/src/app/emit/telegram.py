import html
from datetime import datetime

import httpx

from app import __version__
from app.models import Collected, Report, Source, Usage

MAX_MESSAGE = 4096
ICONS = {"critical": "🔴", "warning": "🟡", "info": "🔵"}
RANK = {"critical": 0, "warning": 1, "info": 2}


def render(
    report: Report, collected: Collected, until: datetime, usage: Usage | None = None
) -> str:
    ranked = sorted(report.findings, key=lambda f: RANK[f.severity])
    new = [f for f in ranked if f.status == "new"]
    ongoing = [f for f in ranked if f.status == "ongoing"]
    resolved = [f for f in ranked if f.status == "resolved"]
    open_ = new + ongoing
    head = ICONS[min(open_, key=lambda f: RANK[f.severity]).severity] if open_ else "✅"
    counts = [
        f"{n} {severity}" for severity in RANK if (n := sum(f.severity == severity for f in open_))
    ]
    counts += [f"{len(resolved)} resolved"] if resolved else []
    lines = [f"{head} <b>Argus {until:%Y-%m-%d %H:%M}</b> — {' · '.join(counts) or 'quiet'}"]
    lines.append(f"<i>Summary: {html.escape(report.headline)}</i>")
    for finding in new:
        lines.append(f"\n{ICONS[finding.severity]} <b>{html.escape(finding.title)}</b>")
        lines.append(html.escape(finding.detail))
    if ongoing:
        lines.append("\n<b>Still open</b>")
        lines += [
            f"{ICONS[f.severity]} {html.escape(f.title)} <i>(since {html.escape(f.since)})</i>"
            for f in ongoing
        ]
    if resolved:
        lines.append("\n<b>✅ Resolved</b>")
        lines += [f"{html.escape(f.title)}: {html.escape(f.detail)}" for f in resolved]
    for error in collected.errors:
        lines.append(f"\n⚠️ collector <b>{error.collector}</b> failed: {html.escape(error.error)}")
    footer = [f"<i>note: {html.escape(note)}</i>" for note in collected.notes]
    if usage:
        cost = f" · ${usage.cost_usd:.3f}" if usage.cost_usd is not None else ""
        cost += " · batch" if usage.batch else ""
        footer.append(
            f"<i>{usage.model} · {usage.input_tokens:,} in / {usage.output_tokens:,} out{cost}</i>"
        )
    inputs = "".join(f" · {_source(s)}" for s in collected.sources)
    footer.append(f"<i>argus {__version__}{inputs}</i>")
    lines.append("\n" + "\n".join(footer))
    return "\n".join(lines)


def _source(source: Source) -> str:
    counts = [f"{source.logs:,} logs"] if source.logs else []
    counts += [f"{source.facts:,} facts"] if source.facts or not source.logs else []
    return f"{source.name} {', '.join(counts)}"


def split(text: str, limit: int = MAX_MESSAGE) -> list[str]:
    chunks, current = [], ""
    for line in text.split("\n"):
        while len(line) > limit:
            chunks.append(line[:limit])
            line = line[limit:]
        if len(current) + len(line) + 1 > limit:
            chunks.append(current)
            current = ""
        current = f"{current}\n{line}" if current else line
    if current:
        chunks.append(current)
    return chunks


def send(token: str, chat_id: str, text: str) -> None:
    with httpx.Client(base_url=f"https://api.telegram.org/bot{token}", timeout=30) as client:
        for chunk in split(text):
            response = client.post(
                "/sendMessage",
                json={
                    "chat_id": chat_id,
                    "text": chunk,
                    "parse_mode": "HTML",
                    "disable_web_page_preview": True,
                },
            )
            if response.is_error:
                raise RuntimeError(f"telegram {response.status_code}: {response.text[:300]}")
