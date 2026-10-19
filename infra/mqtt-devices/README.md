# mqtt-devices

`devices.yml` defines the MQTT devices (Shelly native MQTT, plus BLE sensors
relayed by `shelly_scripts/ble2ha.js`). Generated from it:

- `kubernetes/30-apps/home/config/packages/mqtt_devices.yaml` — Home Assistant entities
- the `Devices` block in `shelly_scripts/ble2ha.js`

After editing `devices.yml`:

```sh
uv run generate.py           # rewrite both outputs
uv run generate.py --check   # exit 1 if outputs are stale
```

Then commit; Flux rolls Home Assistant.

## Shelly devices

`shelly/<name>.yaml` holds a device's settings (any `<Section>.SetConfig`
fields) and the scripts it runs. Push it over the local RPC API:

```sh
uv run apply_shelly.py shelly/homelab.yaml           # show drift only
uv run apply_shelly.py shelly/homelab.yaml --apply   # write config, upload + start scripts
```

The device must already be on Wi-Fi. It reboots only when a setting needs it.
