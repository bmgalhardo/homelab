from app.collect.prometheus import _subject, _value
from app.collect.talos import _json_stream


def test_prometheus_subject_drops_metric_name_and_sorts():
    assert _subject({"__name__": "up", "job": "node", "instance": "hades"}) == (
        "instance=hades job=node"
    )


def test_prometheus_value_formatting():
    assert _value("1", "restarts") == "1 restarts"
    assert _value("10.6234", "days") == "10.62 days"
    assert _value("1791734680", "timestamp") == "2026-10-11T16:04Z"


def test_json_stream_reads_concatenated_pretty_objects():
    text = '{\n "a": 1\n}\n{\n "a": 2\n}\n'
    assert _json_stream(text) == [{"a": 1}, {"a": 2}]


def test_disabled_collectors_are_named():
    from types import SimpleNamespace

    from app.collect import disabled_notes

    enabled = [SimpleNamespace(name="loki"), SimpleNamespace(name="prometheus")]
    assert disabled_notes(enabled) == [
        "collector proxmox disabled (not configured)",
        "collector talos disabled (not configured)",
    ]
