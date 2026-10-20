import json
import logging
import os
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

from app.config import Settings
from app.models import Collected, Fact

log = logging.getLogger(__name__)

CLUSTER_LABEL = "omni.sidero.dev/cluster"


class TalosCollector:
    name = "talos"

    def __init__(self, settings: Settings) -> None:
        self.cluster = settings.omni_cluster
        self.env = {
            **os.environ,
            "OMNI_ENDPOINT": settings.omni_endpoint,
            "OMNI_SERVICE_ACCOUNT_KEY": settings.omni_service_account_key.get_secret_value(),
        }
        if settings.ca_file:
            self.env["SSL_CERT_FILE"] = str(settings.ca_file)

    def collect(self, since: datetime, until: datetime) -> Collected:
        collected = Collected()
        with tempfile.TemporaryDirectory() as home:
            env = {**self.env, "HOME": home}
            talosconfig = Path(home) / "talosconfig"
            _run(
                [
                    "omnictl",
                    "talosconfig",
                    "-c",
                    self.cluster,
                    "--merge=false",
                    "-f",
                    str(talosconfig),
                ],
                env,
            )
            for node in self._nodes(env):
                self._volumes(collected, node, talosconfig, env)
        return collected

    def _nodes(self, env: dict[str, str]) -> list[str]:
        output = _run(["omnictl", "get", "clustermachineidentity", "-o", "json"], env)
        return sorted(
            item["spec"]["nodename"]
            for item in _json_stream(output)
            if item["metadata"].get("labels", {}).get(CLUSTER_LABEL) == self.cluster
        )

    def _volumes(
        self, collected: Collected, node: str, talosconfig: Path, env: dict[str, str]
    ) -> None:
        try:
            output = _run(
                [
                    "talosctl",
                    "--talosconfig",
                    str(talosconfig),
                    "-n",
                    node,
                    "get",
                    "volumestatus",
                    "-o",
                    "json",
                ],
                env,
            )
        except CommandError as exc:
            collected.facts.append(
                Fact(
                    source=self.name,
                    check="node_unreachable",
                    subject=f"node={node}",
                    value="unreachable",
                    detail=str(exc),
                )
            )
            return
        for volume in _json_stream(output):
            spec = volume["spec"]
            if spec.get("phase") != "ready" or spec.get("errorMessage"):
                collected.facts.append(
                    Fact(
                        source=self.name,
                        check="volume_not_ready",
                        subject=f"node={node} volume={volume['metadata']['id']}",
                        value=spec.get("phase", "unknown"),
                        detail=spec.get("errorMessage") or "",
                    )
                )


class CommandError(Exception):
    pass


def _run(args: list[str], env: dict[str, str]) -> str:
    log.debug("running %s", " ".join(args[:4]))
    try:
        return subprocess.run(
            args, env=env, capture_output=True, text=True, timeout=120, check=True
        ).stdout
    except subprocess.CalledProcessError as exc:
        raise CommandError(f"{args[0]} {args[1]}: {_last_line(exc.stderr)}") from exc


def _json_stream(text: str) -> list[dict]:
    decoder = json.JSONDecoder()
    items, index = [], 0
    while index < len(text):
        rest = text[index:].lstrip()
        if not rest:
            break
        item, consumed = decoder.raw_decode(rest)
        items.append(item)
        index = len(text) - len(rest) + consumed
    return items


def _last_line(text: str | None) -> str:
    lines = (text or "").strip().splitlines()
    return lines[-1][:300] if lines else ""
