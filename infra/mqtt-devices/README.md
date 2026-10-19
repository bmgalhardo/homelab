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

Then commit; Flux rolls Home Assistant. Updated Shelly scripts are uploaded to
the device by hand (web UI → Scripts).
