from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class Fact(BaseModel):
    source: str
    check: str
    subject: str
    value: str
    detail: str = ""


class LogLine(BaseModel):
    labels: dict[str, str]
    timestamp: datetime
    line: str


class Source(BaseModel):
    name: str
    facts: int
    logs: int


class CollectorError(BaseModel):
    collector: str
    error: str


class Collected(BaseModel):
    facts: list[Fact] = Field(default_factory=list)
    logs: list[LogLine] = Field(default_factory=list)
    errors: list[CollectorError] = Field(default_factory=list)
    notes: list[str] = Field(default_factory=list)
    sources: list[Source] = Field(default_factory=list)

    def extend(self, other: "Collected") -> None:
        self.facts += other.facts
        self.logs += other.logs
        self.errors += other.errors
        self.notes += other.notes
        self.sources += other.sources


class LogCluster(BaseModel):
    stream: str
    fingerprint: str
    count: int
    first_seen: datetime
    last_seen: datetime
    sample: str


Severity = Literal["critical", "warning", "info"]
Status = Literal["new", "ongoing", "resolved"]


class Finding(BaseModel):
    severity: Severity
    status: Status = Field(
        description="new: not in the previous report; ongoing: in it and still true; "
        "resolved: in it and no longer supported by this window"
    )
    since: str = Field(
        description="YYYY-MM-DD first reported: the previous report's value when ongoing "
        "or resolved, the window end date when new"
    )
    title: str = Field(description="One line, terse alert style")
    detail: str = Field(description="One or two sentences: what, where, likely cause")
    evidence: list[str] = Field(description="Fact checks or log streams this is based on")


class PreviousFinding(BaseModel):
    """A finding as stored by an earlier run; older runs had no status or since."""

    severity: Severity
    status: Status = "new"
    since: str = ""
    title: str


class PreviousReport(BaseModel):
    until: str
    findings: list[PreviousFinding]


class Report(BaseModel):
    headline: str = Field(
        description="At most 12 words: the root cause to act on first, or 'nothing new'. "
        "Never a list of the findings"
    )
    findings: list[Finding] = Field(description="Most severe first; empty on a quiet window")


class Usage(BaseModel):
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float | None
    batch: bool = False
