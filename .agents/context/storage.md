# Storage Architecture

## K8s Storage (elysium) — rebuilt 2026-09-11, NFS retired

Two classes, and the distinction matters for backups:

| class | backing | used for | survives node loss? |
|-------|---------|----------|---------------------|
| **virtiofs** (static PVs) | host disks, node-bound: Hades → `elysium-hades`, Apollo → `elysium-apollo` | Hades: `series`, `movies`, `downloads` (mediacenter). Apollo: `immich` | yes — lives on the host |
| **local-path** | per-node data disk (`scsi1`), Talos user volume at `/var/mnt/local-path` | every other PVC | **no — treat as volatile** |

- **NFS is retired.** Hades' NFS server was turned off at the rebuild;
  `storageClassName: ""` + `volumeName:` now binds the static virtiofs PVs
  (`kubernetes/elysium/20-infra-wiring/virtiofs-pvs.yaml`).
- **`series` runs full by design.** Hades `/mnt/series` (`sdc`, XFS) at
  ~100% is accepted, not actionable — the owner won't act on it.
- **virtiofs is node-bound.** Each share exists only on its host's worker, so
  any pod using it pins there. A pod on Apollo cannot mount them — which is
  why an Apollo local-path PVC cannot be backed up to Hades storage by any
  single pod.
- **local-path is a plain node-local directory.** No replication. Node lost =
  data lost. Manifests come back from git via Flux; only *data* needs
  restoring.

gaia has the same `local-path` class on its own `scsi1` (30G), holding the
Postgres data (`pg-1`, 15Gi) and its dumps (`pg-backups`, 10Gi).

The local-path disk is selected in `infra/elysium/omni/patches/local-path.yaml`.
Talos reports these disks' transport as **virtio** (the `virtio-scsi-single`
controller), although they appear as `/dev/sdX`. `talosctl get volumestatus`
shows the volume's state.

## Local Storage (Hades)

### XFS Pool
- **Capacity:** TODO
- **Purpose:** Movies, videos (separate from critical data)
- **Backup:** Optional (media replicated or re-downloaded)

### ZFS Pool
- **Capacity:** 8TB (2x 8TB HDDs)
- **Purpose:** Photos, backups (critical)
- **Snapshots:** `odin/photos` via sanoid (7d/4w/6m)
- **Redundancy:** RAID-1 (2 drives)

## VM Storage (Apollo + Hades)

### Local Proxmox Storage
- **Purpose:** VMs (vault, authentik, omni, talos nodes, gaia)
- **Backend:** Proxmox local storage on each node
- **Capacity:** TODO

### Per-node data disk (k8s)
- **Purpose:** the Talos `local-path` user volume — every non-virtiofs PVC
- **Backing:** a second disk per worker (`scsi1`): elysium-apollo 60G,
  elysium-hades 100G, declared in `infra/elysium/terraform/`
- **Separate from the system disk on purpose** — EPHEMERAL owns the system
  disk

## Backups

| What | How | When |
|------|-----|------|
| Postgres (gaia) | CronJob `pg-dump`: `pg_dumpall` over TLS to PVC `pg-backups` (daily 7, weekly 4, monthly 12) | 02:00 Europe/Lisbon |
| Postgres → Hades | CronJob `pg-upload`: SFTP mirror to `/odin/k8s-backups/gaia-postgres` (skips while Hades is off) | hourly :30 |
| Immich library | Hades `photos-mirror` pulls apollo `/mnt/immich` → `/odin/photos` | boot + 03:00 (needs Hades up) |
| `odin/photos` | sanoid snapshots 7d/4w/6m | sanoid.timer |
| Forgejo | `forgejo dump` CronJob to its PVC | 03:30 |

**Hades SFTP drop** (`infra/olympus/hosts/README.md`): ZFS `odin/k8s-backups`
(200G quota), one chrooted SFTP-only user per client. Clients: `gaia-postgres`.
The client's private key lives only in its cluster Secret (gaia:
`postgres/pg-backup-ssh`, key `id_ed25519`). After a rebuild, generate a new
key, re-run `k8s-backup-client.sh <client> <pubkey>` on Hades, and recreate
the Secret; nothing needs restoring.

**Restore (Postgres):** `gunzip -c all_pg_daily_<date>.sql.gz | psql -U postgres -d postgres`
into a fresh instance with `vchord.so` preloaded. The only expected error is
`role "postgres" already exists`. Verified 2026-11-24: all databases, roles and
extensions identical to live.

Targets and plan: `overmind memory get homelab/backup-strategy.md`.
