import re

from app.collect.homeassistant import HomeAssistantCollector
from app.models import Collected


def battery(entity: str, state: str, name: str = "") -> dict:
    return {
        "entity_id": entity,
        "state": state,
        "last_changed": "2026-11-17T08:00:00+00:00",
        "attributes": {
            "device_class": "battery",
            "unit_of_measurement": "%",
            "friendly_name": name,
        },
    }


STATES = [
    battery("sensor.sensor_kitchen_battery", "77", "Sensor Kitchen Battery"),
    battery("sensor.sensor_babyroom_battery", "12", "Sensor Babyroom Battery"),
    battery("sensor.sensor_bedroom_battery", "unknown", "Sensor Bedroom Battery"),
    battery("sensor.brunos_iphone_battery_level", "5", "iPhone"),
    {
        "entity_id": "sensor.kitchen_temperature",
        "state": "3",
        "attributes": {"device_class": "temperature"},
    },
    {
        "entity_id": "binary_sensor.door_battery",
        "state": "on",
        "attributes": {"device_class": "battery"},
    },
]


def collector(exclude: str = "phone") -> HomeAssistantCollector:
    c = HomeAssistantCollector.__new__(HomeAssistantCollector)
    c.low = 20
    c.exclude = re.compile(exclude) if exclude else None
    return c


def test_low_and_not_reporting_batteries_are_facts():
    collected = Collected()
    collector()._batteries(collected, STATES)
    assert [(f.check, f.subject, f.value) for f in collected.facts] == [
        (
            "battery_low",
            "entity=sensor.sensor_babyroom_battery name=Sensor Babyroom Battery",
            "12%",
        ),
        (
            "battery_not_reporting",
            "entity=sensor.sensor_bedroom_battery name=Sensor Bedroom Battery",
            "unknown",
        ),
    ]


def test_exclude_is_optional():
    collected = Collected()
    collector(exclude="")._batteries(collected, STATES)
    assert "battery_low" in {f.check for f in collected.facts if "iphone" in f.subject}
