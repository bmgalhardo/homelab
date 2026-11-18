import re
import ssl
from datetime import datetime

import httpx

from app.config import Settings
from app.models import Collected, Fact

NOT_REPORTING = {"unknown", "unavailable"}


class HomeAssistantCollector:
    name = "homeassistant"

    def __init__(self, settings: Settings) -> None:
        self.low = settings.ha_battery_low
        self.exclude = (
            re.compile(settings.ha_battery_exclude) if settings.ha_battery_exclude else None
        )
        self.client = httpx.Client(
            base_url=settings.ha_url.rstrip("/"),
            headers={"Authorization": f"Bearer {settings.ha_token.get_secret_value()}"},
            verify=ssl.create_default_context(cafile=settings.ca_file),
            timeout=30,
        )

    def collect(self, since: datetime, until: datetime) -> Collected:
        collected = Collected()
        self._batteries(collected, self._states())
        return collected

    def _states(self) -> list[dict]:
        return self.client.get("/api/states").raise_for_status().json()

    def _fact(self, check: str, subject: str, value: str, detail: str = "") -> Fact:
        return Fact(source=self.name, check=check, subject=subject, value=value, detail=detail)

    def _batteries(self, collected: Collected, states: list[dict]) -> None:
        for state in states:
            entity = state["entity_id"]
            attributes = state.get("attributes", {})
            if not entity.startswith("sensor.") or attributes.get("device_class") != "battery":
                continue
            if attributes.get("unit_of_measurement") != "%":
                continue
            if self.exclude and self.exclude.search(entity):
                continue
            subject = f"entity={entity} name={attributes.get('friendly_name', '')}"
            value = state.get("state", "")
            if value in NOT_REPORTING:
                collected.facts.append(
                    self._fact(
                        "battery_not_reporting",
                        subject,
                        value,
                        f"since {state.get('last_changed', '')}",
                    )
                )
                continue
            try:
                level = float(value)
            except ValueError:
                continue
            if level < self.low:
                collected.facts.append(
                    self._fact("battery_low", subject, f"{level:.0f}%", f"threshold {self.low}%")
                )
