/**
 * Reads BLE data and decodes from the specific devices in defined in <Config>, specifically:
 * - Govee Temperature/Humidity Sensors
 * - Shelly Door/Window Sensors
 */

//===================
// Shelly DW code taken from https://github.com/ALLTERCO/shelly-script-examples/blob/main/ble-shelly-dw.js
//===================
const uint8 = 0;
const int8 = 1;
const uint16 = 2;
const int16 = 3;
const uint24 = 4;
const int24 = 5;

// The BTH object defines the structure of the BTHome data
const BTH = {
  0x00: { n: "pid", t: uint8 },
  0x01: { n: "battery", t: uint8, u: "%" },
  0x02: { n: "temperature", t: int16, f: 0.01, u: "tC" },
  0x03: { n: "humidity", t: uint16, f: 0.01, u: "%" },
  0x05: { n: "illuminance", t: uint24, f: 0.01 },
  0x21: { n: "motion", t: uint8 },
  0x2d: { n: "window", t: uint8 },
  0x2e: { n: "humidity", t: uint8, u: "%" },
  0x3a: { n: "button", t: uint8 },
  0x3f: { n: "rotation", t: int16, f: 0.1 },
  0x45: { n: "temperature", t: int16, f: 0.1, u: "tC" },
};

function getByteSize(type) {
  if (type === uint8 || type === int8) return 1;
  if (type === uint16 || type === int16) return 2;
  if (type === uint24 || type === int24) return 3;
  //impossible as advertisements are much smaller;
  return 255;
}

// functions for decoding and unpacking the service data from Shelly BLU devices
const ShellyLib = {
  utoi: function (num, bitsz) {
    const mask = 1 << (bitsz - 1);
    return num & mask ? num - (1 << bitsz) : num;
  },
  getUInt8: function (buffer) {
    return buffer.at(0);
  },
  getInt8: function (buffer) {
    return this.utoi(this.getUInt8(buffer), 8);
  },
  getUInt16LE: function (buffer) {
    return 0xffff & ((buffer.at(1) << 8) | buffer.at(0));
  },
  getInt16LE: function (buffer) {
    return this.utoi(this.getUInt16LE(buffer), 16);
  },
  getUInt24LE: function (buffer) {
    return (
      0x00ffffff & ((buffer.at(2) << 16) | (buffer.at(1) << 8) | buffer.at(0))
    );
  },
  getInt24LE: function (buffer) {
    return this.utoi(this.getUInt24LE(buffer), 24);
  },
  getBufValue: function (type, buffer) {
    if (buffer.length < getByteSize(type)) return null;
    let res = null;
    if (type === uint8) res = this.getUInt8(buffer);
    if (type === int8) res = this.getInt8(buffer);
    if (type === uint16) res = this.getUInt16LE(buffer);
    if (type === int16) res = this.getInt16LE(buffer);
    if (type === uint24) res = this.getUInt24LE(buffer);
    if (type === int24) res = this.getInt24LE(buffer);
    return res;
  },

  // Unpacks the service data buffer from a Shelly BLU device
  unpack: function (buffer) {
    //beacons might not provide BTH service data
    if (typeof buffer !== "string" || buffer.length === 0) return null;
    let result = {};
    let _dib = buffer.at(0);
    result["encryption"] = _dib & 0x1 ? true : false;
    result["BTHome_version"] = _dib >> 5;
    if (result["BTHome_version"] !== 2) return null;
    //can not handle encrypted data
    if (result["encryption"]) return result;
    buffer = buffer.slice(1);

    let _bth;
    let _value;
    while (buffer.length > 0) {
      _bth = BTH[buffer.at(0)];
      if (typeof _bth === "undefined") {
        console.log("BTH: Unknown type");
        break;
      }
      buffer = buffer.slice(1);
      _value = this.getBufValue(_bth.t, buffer);
      if (_value === null) break;
      if (typeof _bth.f !== "undefined") _value = _value * _bth.f;

      if (typeof result[_bth.n] === "undefined") {
        result[_bth.n] = _value;
      }
      else {
        if (Array.isArray(result[_bth.n])) {
          result[_bth.n].push(_value);
        }
        else {
          result[_bth.n] = [
            result[_bth.n],
            _value
          ];
        }
      }

      buffer = buffer.slice(getByteSize(_bth.t));
    }
    return result;
  },
};

//===================
// Configurations
//===================
function decoderGovee(result){
    const data = result.manufacturer_data["ec88"];
    if (data.length === 6) {
        const basenum = (data.charCodeAt(1) << 16) | (data.charCodeAt(2) << 8) | data.charCodeAt(3);
        const measurements = {
            "temperature": basenum / 10000.0,
            "humidity": (basenum % 1000) / 10.0,
            "battery": data.charCodeAt(4) / 1.0,
            "rssi": result.rssi,
        };
        return measurements;
    }
};

function decoderShelly (result) {
    const serviceData = result.service_data["fcd2"];
    if (!serviceData) return null;
    const decoded = ShellyLib.unpack(serviceData);
    if (!decoded) return null;

    let measurements = {
        "battery": decoded.battery,
        "rssi": result.rssi,
    };

    if (decoded.window != null) {
        measurements["state"] = (decoded.window) ? "ON": "OFF";
    }
    if (decoded.button != null) {
        const press_map = {
            1: "single-press",
            2: "double-press",
            3: "triple-press",
            4: "long-press",
            254: "pressing"
        }
        for (let i = 0; i < decoded.button.length; i++) {
            if (decoded.button[i]) measurements["button_" + (i + 1)] = press_map[decoded.button[i]];
        }
    }
    return measurements;
};

// BEGIN generated by infra/mqtt-devices/generate.py
const Devices = [
    { id: "govee_01", mac: "A4:C1:38:EC:C6:28", decoder: decoderGovee },
    { id: "govee_02", mac: "A4:C1:38:00:5D:34", decoder: decoderGovee },
    { id: "govee_03", mac: "A4:C1:38:4C:B8:0C", decoder: decoderGovee },
    { id: "govee_04", mac: "A4:C1:38:95:43:B3", decoder: decoderGovee },
    { id: "shelly_dw", mac: "38:39:8f:a6:87:c8", decoder: decoderShelly },
    { id: "shelly_4_button", mac: "7c:c6:b6:b9:0d:af", decoder: decoderShelly },
];
// END generated

function BLEScanCallback(event, result) {
    if (event !== BLE.Scanner.SCAN_RESULT) return;
    for (let i = 0; i < Devices.length; i++) {
        let device = Devices[i];
        if (device.mac.toLowerCase() !== result.addr) continue;

        let measurements = device.decoder(result);
        if (!measurements) return;

        let topic = "devices/" + device.id + "/state";
        MQTT.publish(topic, JSON.stringify(measurements), retain=false);
    }
}

function init() {
    const bleScanner = BLE.Scanner.Start(options={
        duration_ms: BLE.Scanner.INFINITE_SCAN,
        active: false
    });

    if (!bleScanner) {
      console.log("Error: Can not start new scanner");
    }

    BLE.Scanner.Subscribe(BLEScanCallback);
}

init();
