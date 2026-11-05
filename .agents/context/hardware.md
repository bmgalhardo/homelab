# Hardware & Rack Layout

## Rack Configuration

| Slot | Device | Model | Role | Power | Always-on |
|------|--------|-------|------|-------|-----------|
| 1U | UDM Pro | Unifi Dream Machine | Gateway/Switch/NVR (camera SSD) | ~35W | Yes |
| 1U | Patch Panel | — | Cable mgmt | — | — |
| 1U | Cover | — | Aesthetics | — | — |
| 1U | Pi Rack | — | 4-slot holder | — | — |
| — | Hermes | Pi 1 B+ (ARMv6) | DNS/LB (Alpine) | 5W | No |
| — | Athena | Pi 4 (4GB, arm64) + 120GB SSD | Monitoring: logging/metrics + argus agent | 5W | Yes |
| 1U | Shelf | — | Mini PC mount | — | — |
| — | Apollo | Beelink S12 Pro | Proxmox + K8s | ~12W (plug) | Yes |
| 1U | Brush Panel | — | Cable mgmt | — | — |
| 4U | Hades | Ryzen 5 PC + 750Ti GPU | Proxmox + NAS | ~32W on (plug) | No |
| 2U | Cover | — | Aesthetics | — | — |

**Power metering (2026-11):** Shelly Mini PM G3 on the rack feed (`Homelab
Monitor`; baseline 58W with Hades off, i.e. UDM + SSD + Pis ≈ 45W), Shelly Plug G3 on Apollo and on Hades.
Native MQTT → HA (`infra/mqtt-devices/`) → athena Prometheus via HA's
`/api/prometheus`. Dashboards: HA `Homelab` (`config/dashboards/homelab.yaml`),
Grafana `hosts/Rack power`. "Network & Pis" = feed − Apollo − Hades.

## Compute Nodes

### Apollo (Primary - Always On)
- **IP:** 192.168.1.197
- **Device:** Beelink S12 Pro
- **Role:** Proxmox host + K8s control/worker
- **Specs:** TODO (CPU cores, RAM, storage)
- **Runs:**
  - LXC: `qdevice` (192.168.1.89) — corosync-qnetd for cluster quorum.
    Debian, not Alpine as earlier planned. Set up 2026-09-07 (see
    services.md). Needs `--onboot 1`.
  - LXC: `cerberus` — Protect kiosk on Apollo's HDMI (LXC 105, on/off
    by hand, no onboot; see services.md)
  - VMs: vault, authentik, postgres, omni, talos-control, talos-worker
  - VM 101 `daedalus` (remote agents)
  - K8s workloads: see services.md
- **Network:** Bridged to UDM (no bonding)
- **Must verify:** RAM sufficient for corosync LXC + K8s + VMs

### Hermes (Utility - Power Managed)
- **IP:** 192.168.1.199
- **Device:** Raspberry Pi **1** Model B+ — **ARMv6**, 512MB RAM, single core
  (confirmed 2026-09-07)
- **Role:** DNS + Load Balancer (independent from Proxmox cluster)
- **OS:** Alpine Linux (lightweight: ~50MB)
- ⚠️ **ARMv6 is the binding constraint here.** Most modern Go/Rust agents ship
  arm64 and armv7 builds only — Grafana Alloy, for one, has no ARMv6 build.
  Anything needed on Hermes has to be busybox-native or built from source.
  For log shipping this is fine: dnsmasq and haproxy log to syslog, and
  busybox `syslogd -R host:port` forwards remotely (see plans/argus.md).
- **Runs:**
  - dnsmasq (DNS resolver for bgalhardo.internal)
  - HAProxy (L4 load balancer, SSL termination)
- **Network:** Bridged to UDM (no bonding)
- **NOT in cluster:** Independent by design
- **Benefit:** Services resolve DNS even if Proxmox cluster down

### Hades (Secondary - Power Managed)
- **IP:** 192.168.1.198
- **Device:** AMD Ryzen 5 PC
- **Role:** Proxmox host + NAS (power-managed, can turn off)
- **GPU:** GeForce 750 Ti (VM passthrough)
- **Specs:** Ryzen 5 3600 (Zen 2, 6c/12t), ASUS PRIME B550M-A (WI-FI),
  BIOS 3621 (2025-01-13). RAM: Corsair LPX `CMK16GX4M2B3200C16` (2×8GB
  kit, 3200 XMP) + `CMK32GX4M2E3200C16` (2×16GB kit, one stick dead).
  Since 2026-11-04: A1 empty, A2 16GB, B1 8GB, B2 8GB — 32GB, all single
  rank, 2133 (JEDEC)
- **Runs:**
  - Proxmox (2-node cluster with Apollo)
  - virtiofs shares (photos, media) into `elysium-hades`
  - VMs: `elysium-hades`, 1103 `elysium-hades-gpu` (750 Ti), 102 `personal`
    (Ubuntu workstation, 750 Ti, on-demand)
  - LXC 106 `hephaestus` (Blender worker, `onboot 0`)
- **Network:** Bridged to UDM (no bonding)
- **Instability (memory subsystem — board, CPU IMC or DIMM, undetermined):** 2026-11-03 21:18 hard freeze — host and
  guest logs stop the same minute, no kernel message reached Loki, plug flat
  at ~32W (stuck, not off). Power cycle 11-04 12:35 hung at boot. An earlier
  similar episode was cleared by pulling a DIMM. At the freeze it ran 3
  mixed sticks (8+8+16, two kits). Tests 2026-11-04, alone in A2 at 2133:
  16GB #1 dead (no POST in any slot, the earlier pulled one); 8GB #1, 8GB #2,
  16GB #2 memtest PASS. 8GB #1 POSTs in A1, A2, B1, B2 (slots OK).
  3-stick layout above (16GB per channel): memtest86+ 3 passes clean
  2026-11-04. Soaking from then. If it freezes: DRAM 1.35V at 2133, then
  2×8 in A2+B2, or replace the dead 16GB to pair 16GB #2.
  D.O.C.P. (XMP) confirmed Disabled 2026-11-04; keep it off. BIOS current.
  Back in service 2026-11-04 ~22:20 (1102 onboot restored, hephaestus up).
- **Storage:**
  - XFS pool: TODO size (movies, videos)
  - ZFS pool: 8TB (2x 8TB HDDs) for photos + backups

### Athena (monitoring node — online 2026-09-08)

- **Device:** Raspberry Pi 4, **4GB**, arm64 (eth0 MAC `2C:CF:67:64:2C:1D`)
- **OS/disk:** Alpine 3.24, kernel 6.18-rpi, on a **120GB Kingston SATA
  SSD** (`/dev/sda`, `SHFS37A120G`, HyperX Fury) — persistent `sys` install, boots
  from the SSD, no SD card in play
- **USB boot is fragile.** SSD on a USB3/UAS adapter (`14b0:0206`). On
  2026-10-01 a reboot hung in the bootloader (`MSD cmd timeout … FAT read
  failed`) and took 3 cold power cycles, stuck because `BOOT_ORDER=0x234`
  had no `f` (restart). No undervoltage (`get_throttled=0x0`).
  Same day: bootloader 2025-02-11 → **2026-09-23**, `BOOT_ORDER=0xf14`
  (USB-MSD → SD → restart, retries on its own). Applied by self-update —
  no SD card: `pieeprom.upd` (built with `rpi-eeprom-config`) + `pieeprom.sig`
  (sha256 + `ts:`) in `/boot`, reboot, delete both. `vcgencmd` via
  `raspberrypi-utils`; Alpine has no `rpi-eeprom-update`.
- **Recurred 2026-10-25** after a mains outage (~19:08; apollo/hermes back
  19:11). Bootloader read the MBR and FAT header (`Trying partition: 0 type:
  32 lba: 2048 'mkfs.fat' 'NO NAME'`) then stalled — down ~19h, unnoticed
  (all monitoring lives on athena). 1st cold cycle hung again, 2nd booted
  with no repair, so not FS corruption (fsck only cleared the FAT dirty
  bit; ext4 journal replay; syslog tail lost as NULs). The `f` in
  `BOOT_ORDER` can't help: a stall is not a failure, so no retry.
  Likely: bootloader USB-MSD vs this adapter/SSD, worse after unsafe
  power-off (inference, unproven). **Plan:** boot from SD (SanDisk, `/boot`
  copy, mounted `ro`), root stays on the SSD by UUID, `BOOT_ORDER=0xf41`;
  sync the SSD's `sda1` after kernel upgrades so the USB fallback isn't stale.
  Detection: `watch-athena` on hermes (Telegram after 5 missed pings)
- **Kernel cmdline:** `infra/athena/boot/cmdline.txt` (`cgroup_enable=memory`)
- **IP:** `192.168.1.196` (DHCP → pin in UniFi)
- **Role:** Monitoring stack — Loki + Prometheus + Grafana + Alloy + Vault
  Agent + (later) the argus agent. Independent of the Proxmox cluster on
  purpose. See `.agents/context/plans/argus.md`.
- **Power:** ~5W

## Spare Hardware

- **Backup PC:** TrueNAS (power-managed, specs TODO)

## Network Core

- **Gateway:** 192.168.1.1 (UDM Pro)
- **ISP Uplink:** UDM port 9 to MEO Thomson (bridge mode)
- **Switch:** UDM IS the managed switch (no separate switch)
- **POE Switch:** Separate, feeds cameras, AP U6+, household outlets
- **Bonding:** None (no LAGG between nodes)

## Summary

- **2-node Proxmox cluster:** Apollo + Hades (always-on + power-managed)
- **Qdevice:** Apollo LXC `qdevice` (192.168.1.89) — note: co-located on
  Apollo, so an Apollo outage drops both Apollo's vote and the qdevice
- **Utility node:** Hermes (DNS/LB, independent from cluster)
- **Single K8s control plane:** Apollo (not HA yet)
- **Storage single-point-of-failure:** Hades (virtiofs media/photos)
