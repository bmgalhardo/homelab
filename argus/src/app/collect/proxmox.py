import ssl
from datetime import UTC, datetime

import httpx

from app.config import Settings
from app.models import Collected, Fact

STORAGE_FULL = 0.85
GUEST_START_TASKS = {"qmstart", "vzstart", "startall"}


class ProxmoxCollector:
    name = "proxmox"

    def __init__(self, settings: Settings) -> None:
        token = f"{settings.proxmox_token_id}={settings.proxmox_token_secret.get_secret_value()}"
        self.client = httpx.Client(
            base_url=f"{settings.proxmox_api_host.rstrip('/')}/api2/json",
            headers={"Authorization": f"PVEAPIToken={token}"},
            verify=ssl.create_default_context(cafile=settings.ca_file),
            timeout=30,
        )

    def collect(self, since: datetime, until: datetime) -> Collected:
        collected = Collected()
        online_nodes = self._cluster_status(collected)
        self._tasks(collected, since)
        self._guests(collected)
        for node in online_nodes:
            self._zfs(collected, node)
            self._storage(collected, node)
        return collected

    def _get(self, path: str) -> list[dict]:
        return self.client.get(path).raise_for_status().json()["data"]

    def _fact(self, check: str, subject: str, value: str, detail: str = "") -> Fact:
        return Fact(source=self.name, check=check, subject=subject, value=value, detail=detail)

    def _cluster_status(self, collected: Collected) -> list[str]:
        online = []
        for item in self._get("/cluster/status"):
            if item["type"] == "cluster" and not item.get("quorate"):
                collected.facts.append(self._fact("cluster_not_quorate", item["name"], "0"))
            elif item["type"] == "node":
                if item.get("online"):
                    online.append(item["name"])
                    collected.facts.append(self._fact("node_online", item["name"], "online"))
                else:
                    collected.facts.append(self._fact("node_offline", item["name"], "offline"))
        return online

    def _tasks(self, collected: Collected, since: datetime) -> None:
        for task in self._get("/cluster/tasks"):
            status = task.get("status")
            if task.get("starttime", 0) < since.timestamp() or status is None:
                continue
            subject = f"node={task['node']} type={task['type']} id={task.get('id', '')}"
            started = f"started {datetime.fromtimestamp(task['starttime'], UTC).isoformat()}"
            if status != "OK":
                collected.facts.append(self._fact("task_failed", subject, status, started))
            elif task["type"] in GUEST_START_TASKS:
                collected.facts.append(self._fact("guest_started", subject, status, started))

    def _guests(self, collected: Collected) -> None:
        for guest in self._get("/cluster/resources?type=vm"):
            if guest.get("status") != "running":
                continue
            collected.facts.append(
                self._fact(
                    "guest_running",
                    f"node={guest['node']} vmid={guest['vmid']} name={guest.get('name', '')}"
                    f" type={guest['type']}",
                    f"{guest.get('maxmem', 0) / 2**30:.1f} GiB",
                    f"uptime {guest.get('uptime', 0) // 3600}h",
                )
            )

    def _zfs(self, collected: Collected, node: str) -> None:
        for pool in self._get(f"/nodes/{node}/disks/zfs"):
            if pool.get("health") != "ONLINE":
                collected.facts.append(
                    self._fact(
                        "zfs_pool_unhealthy",
                        f"node={node} pool={pool['name']}",
                        pool.get("health", "unknown"),
                    )
                )

    def _storage(self, collected: Collected, node: str) -> None:
        for storage in self._get(f"/nodes/{node}/storage"):
            total = storage.get("total") or 0
            if not storage.get("active") or not total:
                continue
            used = storage.get("used", 0) / total
            if used > STORAGE_FULL:
                collected.facts.append(
                    self._fact(
                        "storage_full",
                        f"node={node} storage={storage['storage']}",
                        f"{used:.2f} used fraction",
                    )
                )
