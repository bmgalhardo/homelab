# Hardware & Rack Layout

## Rack Configuration

| Slot | Device | Model | Role | Power | Always-on |
|------|--------|-------|------|-------|-----------|
| 1U | UDM Pro | Unifi Dream Machine | Gateway/Switch/NVR | 20W | Yes |
| 1U | Patch Panel | — | Cable mgmt | — | — |
| 1U | Cover | — | Aesthetics | — | — |
| 1U | Pi Rack | — | 4-slot holder | — | — |
| — | Hermes | Pi 1 B+ (ARMv6) | DNS/LB (Alpine) | 5W | No |
| — | Athena | Pi 4 (4GB, arm64) + 120GB SSD | Argus: logging/metrics/report | 5W | Yes |
| 1U | Shelf | — | Mini PC mount | — | — |
| — | Apollo | Beelink S12 Pro | Proxmox + K8s | TODO W | Yes |
| 1U | Brush Panel | — | Cable mgmt | — | — |
| 4U | Hades | Ryzen 5 PC + 750Ti GPU | Proxmox + NAS | TODO W | No |
| 2U | Cover | — | Aesthetics | — | — |

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
  - VMs: vault, authentik, postgres, omni, talos-control, talos-worker
  - VM: `manager` (192.168.1.170) — jump host with real SSH/Terraform
    access to the Olympus VMs; not in any prior doc, found 2026-08-21
  - Retired VMs: `tftp` (2026-09-08, PXE unused — repo removed, VM
    deletion pending), `netboot` (2026-08-21, cert revoked) — see network.md
  - K8s: Home Assistant, Immich, homepage/pgadmin/redis (`system` ns) —
    confirmed live 2026-08-21. Mediacenter, monitoring (Grafana/Loki/
    Mimir/Alloy), gaming, and nvidia have manifests in `kubernetes/` but
    are **not deployed** — see services.md
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
  busybox `syslogd -R host:port` forwards remotely (see argus.md).
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
- **Specs:** TODO (CPU cores, RAM, storage)
- **Runs:**
  - Proxmox (2-node cluster with Apollo)
  - NFS server (/mnt/photos, /mnt/media for K8s)
  - Ubuntu personal workstation VM with GPU passthrough
- **Network:** Bridged to UDM (no bonding)
- **Storage:**
  - XFS pool: TODO size (movies, videos)
  - ZFS pool: 8TB (2x 8TB HDDs) for photos + backups

### Athena (Argus node — online 2026-09-08)

- **Device:** Raspberry Pi 4, **4GB**, arm64 (eth0 MAC `2C:CF:67:64:2C:1D`)
- **OS/disk:** Alpine 3.24, kernel 6.18-rpi, on a **120GB KingSpec SATA
  SSD** (`/dev/sda`, `SHFS37A120G`) — persistent `sys` install, boots
  from the SSD, no SD card in play
- **IP:** `192.168.1.196` (DHCP → pin in UniFi)
- **Role:** Argus stack — Loki + Prometheus + Grafana + Alloy + Vault
  Agent + (later) the report agent. Independent of the Proxmox cluster on
  purpose. See `.claude/context/argus.md`.
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
- **NFS single-point-of-failure:** Hades
