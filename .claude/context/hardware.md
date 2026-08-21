# Hardware & Rack Layout

## Rack Configuration

| Slot | Device | Model | Role | Power | Always-on |
|------|--------|-------|------|-------|-----------|
| 1U | UDM Pro | Unifi Dream Machine | Gateway/Switch/NVR | 20W | Yes |
| 1U | Patch Panel | — | Cable mgmt | — | — |
| 1U | Cover | — | Aesthetics | — | — |
| 1U | Pi Rack | — | 4-slot holder | — | — |
| — | Hermes | Pi B+ | DNS/LB (Alpine) | 5W | No |
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
  - LXC: corosync-qdevice (Alpine, 512MB)
  - VMs: vault, authentik, postgres, omni, tftp, talos-control, talos-worker
  - VM: `manager` (192.168.1.170) — jump host with real SSH/Terraform
    access to the Olympus VMs; not in any prior doc, found 2026-08-21
  - Retired VM: netboot (cert revoked, no longer in use — see network.md)
  - K8s: Home Assistant, Immich, homepage/pgadmin/redis (`system` ns) —
    confirmed live 2026-08-21. Mediacenter, monitoring (Grafana/Loki/
    Mimir/Alloy), gaming, and nvidia have manifests in `kubernetes/` but
    are **not deployed** — see services.md
- **Network:** Bridged to UDM (no bonding)
- **Must verify:** RAM sufficient for corosync LXC + K8s + VMs

### Hermes (Utility - Power Managed)
- **IP:** 192.168.1.199
- **Device:** Raspberry Pi B+
- **Role:** DNS + Load Balancer (independent from Proxmox cluster)
- **OS:** Alpine Linux (lightweight: ~50MB)
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

## Spare Hardware

- **Pi4:** Not in use (candidate for DNS backup or K8s worker)
- **Backup PC:** TrueNAS (power-managed, specs TODO)

## Network Core

- **Gateway:** 192.168.1.1 (UDM Pro)
- **ISP Uplink:** UDM port 9 to MEO Thomson (bridge mode)
- **Switch:** UDM IS the managed switch (no separate switch)
- **POE Switch:** Separate, feeds cameras, AP U6+, household outlets
- **Bonding:** None (no LAGG between nodes)

## Summary

- **2-node Proxmox cluster:** Apollo + Hades (always-on + power-managed)
- **Qdevice:** Apollo LXC (independent)
- **Utility node:** Hermes (DNS/LB, independent from cluster)
- **Single K8s control plane:** Apollo (not HA yet)
- **NFS single-point-of-failure:** Hades
