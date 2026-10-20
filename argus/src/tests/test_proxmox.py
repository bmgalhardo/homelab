from datetime import UTC, datetime

from app.collect.proxmox import ProxmoxCollector
from app.models import Collected

SINCE = datetime(2026, 10, 11, 0, 0, tzinfo=UTC)
RESPONSES = {
    "/cluster/tasks": [
        {
            "node": "apollo",
            "type": "qmstart",
            "id": "1004",
            "status": "OK",
            "starttime": 1791734925,
        },
        {
            "node": "apollo",
            "type": "vzdump",
            "id": "100",
            "status": "ERROR",
            "starttime": 1791734925,
        },
        {"node": "apollo", "type": "qmstart", "id": "1000", "status": "OK", "starttime": 1},
        {"node": "apollo", "type": "qmstop", "id": "1004", "starttime": 1791734925},
    ],
    "/cluster/resources?type=vm": [
        {
            "node": "apollo",
            "vmid": 1004,
            "name": "hal9000-cp",
            "type": "qemu",
            "status": "running",
            "maxmem": 4 * 2**30,
            "uptime": 7200,
        },
        {
            "node": "hades",
            "vmid": 1103,
            "name": "elysium-hades-gpu",
            "type": "qemu",
            "status": "stopped",
        },
    ],
}


def collector() -> ProxmoxCollector:
    c = ProxmoxCollector.__new__(ProxmoxCollector)
    c._get = RESPONSES.__getitem__
    return c


def test_tasks_report_failures_and_guest_starts_in_window():
    collected = Collected()
    collector()._tasks(collected, SINCE)
    assert [(f.check, f.subject) for f in collected.facts] == [
        ("guest_started", "node=apollo type=qmstart id=1004"),
        ("task_failed", "node=apollo type=vzdump id=100"),
    ]


def test_guests_lists_only_running():
    collected = Collected()
    collector()._guests(collected)
    [fact] = collected.facts
    assert fact.subject == "node=apollo vmid=1004 name=hal9000-cp type=qemu"
    assert (fact.value, fact.detail) == ("4.0 GiB", "uptime 2h")
