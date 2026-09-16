# Storage Architecture

## K8s Storage (elysium) — rebuilt 2026-09-11, NFS retired

Two classes, and the distinction matters for backups:

| class | backing | used for | survives node loss? |
|-------|---------|----------|---------------------|
| **virtiofs** (static PVs) | Hades disks, `elysium-hades` **only** | media + photos: `series`, `movies`, `downloads`, `photos`, `immich-cache` | yes — lives on Hades |
| **local-path** | per-node data disk (`scsi1`), Talos user volume at `/var/mnt/local-path` | every other PVC | **no — treat as volatile** |

- **NFS is retired.** Hades' NFS server was turned off at the rebuild;
  `storageClassName: ""` + `volumeName:` now binds the static virtiofs PVs
  (`kubernetes/20-infra-wiring/virtiofs-pvs.yaml`).
- **virtiofs is node-bound.** Those volumes exist only on `elysium-hades`, so
  any pod using them pins there. A pod on Apollo cannot mount them — which is
  why an Apollo local-path PVC cannot be backed up to Hades storage by any
  single pod. See todos.md.
- **local-path is a plain node-local directory.** No replication. Node lost =
  data lost. Manifests come back from git via Flux; only *data* needs
  restoring.

⚠️ **The disk selector broke this silently once** (2026-09-13 → 2026-09-15):
`disk.transport == "scsi"` never matched, because the `virtio-scsi-single`
controller makes Talos report transport **virtio** even though the disks
appear as `/dev/sdX`. Every local-path PVC sat `Pending` for 38h with no error
in k8s — `talosctl get volumestatus` was the only layer that reported a cause.
Fixed in `infra/elysium/omni/patches/local-path.yaml`; full writeup in
todos.md.

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

### Per-node data disk (k8s)
- **Purpose:** the Talos `local-path` user volume — every non-virtiofs PVC
- **Backing:** a second disk per worker (`scsi1`): elysium-apollo 60G,
  elysium-hades 100G, declared in `infra/elysium/terraform/`
- **Separate from the system disk on purpose** — EPHEMERAL owns the system
  disk; sharing one caused the DiskPressure incident

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
| **Immich photos** | Live on `odin/photos` (virtiofs) | ❌ one snapshot, 2025-12-03 | ❌ never replicated |

## Current Backup Status

| Service | Backup | Frequency | Status |
|---------|--------|-----------|--------|
| Postgres | Daily dump | 2AM | ✅ Running (local disk only, not offsite) |
| Vault | None | — | ❌ No backup mechanism exists at all — see todos.md |
| Immich | Manual | On-demand | ❌ Not automated |
| Backup PC sync | Manual | Manual | ❌ Not automated |

## Known Issues

⚠️ **`odin` has effectively one copy** — one snapshot (2025-12-03), no
   sanoid/syncoid, no replication cron. `odin/backups` (40G, incl. personal
   archives) has *never* been snapshotted. The mirror is redundancy, not
   backup. **P0 in todos.md** — verified on-host 2026-09-15.
⚠️ **local-path PVCs are unbacked** — obsidian/couchdb/ollama today, plus
   every parked app's `/config` when unparked
⚠️ **No automated Immich backup** — Manual until rsync setup
⚠️ **Backup PC power strategy** — Always-on vs WoL (pending decision)
⚠️ **ZFS snapshots** — confirmed NOT running (checked 2026-09-15)
⚠️ **External drive offsite** — No true offsite (pending location)

## Future Improvements

- Enable ZFS snapshots (daily, 7-day retention)
- Automate rsync to backup PC
- Implement external drive rotation (monthly)
- Add N100 NAS if Hades becomes bottleneck
- Consider Immich GPU acceleration on Hades K8s worker
