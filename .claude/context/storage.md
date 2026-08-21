# Storage Architecture

## NFS (Hades → K8s/Services)

### Server: Hades
- **Service:** NFS server
- **Exports:**
  - `/mnt/photos` — Immich, Home Assistant backups, shared
  - `/mnt/media` — Plex media library
- **Clients:** Apollo K8s cluster, services
- **Performance:** Single point of failure; monitor usage

### K8s Storage
- **Current (confirmed live 2026-08-21):** Longhorn backs Home Assistant
  (`home` ns) and Immich's `encoded-video`/`thumbs` volumes (`immich`
  ns); Immich's `photos` volume is already NFS. One orphaned Longhorn
  PVC (`data-mongo-0`, `system` ns) with no live workload attached.
- **⚠️ Single-node storage:** Longhorn only runs on the worker node
  (`talos-y6i-w43`) — the control-plane node is excluded, so every
  volume is single-replica (`robustness: degraded`), no in-cluster
  redundancy. See services.md.
- **Planned:** NFS mounts for Plex, further HA migration
- **Benefit:** Persistent across pod restarts, easier backup

## Local Storage (Hades)

### XFS Pool
- **Capacity:** TODO
- **Purpose:** Movies, videos (separate from critical data)
- **Backup:** Optional (media replicated or re-downloaded)

### ZFS Pool
- **Capacity:** 8TB (2x 8TB HDDs)
- **Purpose:** Photos, backups (critical)
- **Snapshots:** Daily (TODO - enable?)
- **Retention:** 7 days
- **Encryption:** TODO (enable?)
- **Redundancy:** RAID-1 (2 drives)

## VM Storage (Apollo + Hades)

### Local Proxmox Storage
- **Purpose:** VMs (vault, authentik, postgres, omni, talos nodes)
- **Backend:** Proxmox local storage on each node
- **Capacity:** TODO

### NFS Proxmox Storage
- **Purpose:** K8s persistent volumes, shared workloads
- **Mount:** /mnt/nfs/hades
- **Provider:** Hades NFS exports
- **Capacity:** Shared with NFS exports

## Backup Destinations

### Backup PC (TrueNAS)
- **Hostname:** TODO
- **IP:** TODO (when powered on)
- **Capacity:** TODO
- **Purpose:** 3-2-1 backup destination (copy 2)
- **Connection:** rsync via SSH (encrypted)
- **Schedule:** Daily (TODO - time)
- **Retention:** 30 days

### External Drive (Offline)
- **Purpose:** True offsite (3-2-1 rule, copy 3)
- **Frequency:** Monthly manual rotation
- **Storage:** TODO (capacity, format, encryption)
- **Location:** TODO (home, friend, safety deposit)
- **Rotation:** Keep 2 drives (one on-site, one off-site)

## 3-2-1 Backup Summary

| Data | Copy 1 | Copy 2 | Copy 3 |
|------|--------|--------|--------|
| **Postgres** | Local (Hades) /mnt/backups | Backup PC (rsync, 30d) | External drive (monthly) |
| **Vault** | Local (Hades) /mnt/backups | Backup PC (rsync, 30d) | External drive (monthly) |
| **Immich photos** | Live on NFS | ZFS snapshot (7d) | Backup PC rsync (30d) |

## Current Backup Status

| Service | Backup | Frequency | Status |
|---------|--------|-----------|--------|
| Postgres | Daily dump | 2AM | ✅ Running (local disk only, not offsite) |
| Vault | None | — | ❌ No backup mechanism exists at all — see todos.md |
| Immich | Manual | On-demand | ❌ Not automated |
| Backup PC sync | Manual | Manual | ❌ Not automated |

## Known Issues

⚠️ **Single NFS provider** — Hades failure = K8s data loss
⚠️ **No automated Immich backup** — Manual until rsync setup
⚠️ **Backup PC power strategy** — Always-on vs WoL (pending decision)
⚠️ **ZFS snapshots** — Not confirmed enabled on Hades
⚠️ **External drive offsite** — No true offsite (pending location)

## Future Improvements

- Enable ZFS snapshots (daily, 7-day retention)
- Automate rsync to backup PC
- Implement external drive rotation (monthly)
- Add N100 NAS if Hades becomes bottleneck
- Consider Immich GPU acceleration on Hades K8s worker
