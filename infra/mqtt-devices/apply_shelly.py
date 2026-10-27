# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml"]
# ///
"""Push shelly/<name>.yaml (config + scripts) to the device over its local RPC API.

    uv run apply_shelly.py shelly/homelab.yaml           # show the diff only
    uv run apply_shelly.py shelly/homelab.yaml --apply   # write it
"""
import json
import sys
import urllib.request
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
CHUNK = 1024


class Shelly:
    def __init__(self, host: str):
        self.url = f"http://{host}/rpc"

    def call(self, method: str, **params):
        body = json.dumps({"id": 1, "method": method, "params": params}).encode()
        req = urllib.request.Request(self.url, body, {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            reply = json.load(resp)
        if "error" in reply:
            sys.exit(f"{method}: {reply['error']}")
        return reply["result"]

    def get_code(self, script_id: int) -> str:
        code, offset = "", 0
        while True:
            part = self.call("Script.GetCode", id=script_id, offset=offset)
            code += part["data"]
            offset += len(part["data"])
            if not part.get("left"):
                return code


def drift(want: dict, have: dict, path: str = "") -> list[str]:
    out = []
    for key, value in want.items():
        current = have.get(key)
        if isinstance(value, dict) and isinstance(current, dict):
            out += drift(value, current, f"{path}{key}.")
        elif value != current:
            out.append(f"{path}{key}: {current!r} -> {value!r}")
    return out


def sync_config(dev: Shelly, sections: dict, apply: bool) -> bool:
    restart = False
    for section, want in sections.items():
        name, _, cid = section.partition(":")
        ids = {"id": int(cid)} if cid else {}
        changes = drift(want, dev.call(f"{name}.GetConfig", **ids))
        for change in changes:
            print(f"  {section}.{change}")
        if changes and apply:
            restart |= dev.call(f"{name}.SetConfig", config=want, **ids).get("restart_required", False)
    return restart


def sync_scripts(dev: Shelly, scripts: dict, apply: bool) -> None:
    on_device = {s["name"]: s for s in dev.call("Script.List")["scripts"]}
    for name in on_device.keys() - scripts.keys():
        print(f"  script {name}: on device, not in git (left alone)")
    for name, file in scripts.items():
        code = (HERE / file).read_text()
        current = on_device.get(name)
        if current and dev.get_code(current["id"]) == code:
            if current["enable"] and current["running"]:
                continue
            print(f"  script {name}: not enabled/running")
        else:
            print(f"  script {name}: {'code differs' if current else 'missing'}")
        if not apply:
            continue
        script_id = current["id"] if current else dev.call("Script.Create", name=name)["id"]
        if current and current["running"]:
            dev.call("Script.Stop", id=script_id)
        for i in range(0, len(code), CHUNK):
            dev.call("Script.PutCode", id=script_id, code=code[i : i + CHUNK], append=i > 0)
        dev.call("Script.SetConfig", id=script_id, config={"enable": True})
        dev.call("Script.Start", id=script_id)


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    spec = yaml.safe_load(Path(sys.argv[1]).read_text())
    apply = "--apply" in sys.argv
    dev = Shelly(spec["host"])
    found = dev.call("Shelly.GetDeviceInfo")["id"]
    if found != spec["id"]:
        sys.exit(f"{spec['host']} is {found}, expected {spec['id']}")
    print(f"{spec['id']} ({spec['host']})")
    restart = sync_config(dev, spec.get("config", {}), apply)
    sync_scripts(dev, spec.get("scripts", {}), apply)
    if restart:
        print("  rebooting (restart_required)")
        dev.call("Shelly.Reboot")


if __name__ == "__main__":
    main()
