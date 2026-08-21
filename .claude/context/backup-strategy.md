# Backup Strategy: 3-2-1 Model

## Definition

**3-2-1 Rule:**
- **3 copies** of data
- **2 different storage media types**
- **1 copy offsite**

## Current State

Confirmed 2026-08-21 by reading the live compose files directly (see
todos.md P1 for detail) — the table below corrects an earlier draft
that had Vault backups running and Postgres backups on Hades; neither
was true.

| Service | Backup | Frequency | Location | Status |
|---------|--------|-----------|----------|--------|
| Postgres | `pg_backup` sidecar, daily/weekly/monthly retention | 2AM | Local disk on the postgres VM only (`/backups/`) — not shipped anywhere | ⚠️ Running, but not offsite |
| Vault | None | — | — | ❌ No backup mechanism exists at all |
| Immich | Manual | On-demand | Hades NFS | ❌ Not automated |
| Backup PC | Manual | Manual | External drive | ❌ Manual only |

## Implementation Plan

### Phase 1: Document (This Week)
- [ ] Find postgres backup script location
- [ ] Find vault backup script location
- [ ] Document retention policy
- [ ] List backup storage paths

### Phase 2: Automate Database Backups (Week 1)
- [ ] Setup rsync to backup PC (daily, 3AM)
- [ ] Postgres: local dump → backup PC
- [ ] Vault: local snapshot → backup PC
- [ ] Set retention: 30 days

### Phase 3: NFS Snapshots (Week 2)
- [ ] Enable ZFS snapshots on Hades (daily, 1AM)
- [ ] Snapshot /mnt/photos (7-day retention)
- [ ] Snapshot /mnt/media (7-day retention)
- [ ] Test restore from snapshot

### Phase 4: Offsite Backup (Week 3)
- [ ] Acquire external USB drive (2TB+)
- [ ] Monthly rsync from backup PC to external
- [ ] Rotate drives (one on-site, one off-site)
- [ ] Document rotation procedure

## 3-2-1 Target Configuration

### Postgres

**Copy 1: Local (Hades)**
```
/mnt/backups/postgres/daily/postgres-$(date +%Y%m%d).sql.gz
Frequency: Daily 2AM
Retention: 7 days
```

**Copy 2: Backup PC (TrueNAS)**
```
rsync daily 3AM (remote backup)
Destination: /mnt/backups/postgres/
Retention: 30 days
Media: HDD (different from NVMe)
```

**Copy 3: External Drive (Offsite)**
```
Monthly sync from backup PC
Destination: /external-drive/postgres-backups/
Rotation: 2 drives (one off-site)
```

### Vault

Same as Postgres:
- Local snapshot on Hades
- Daily rsync to backup PC
- Monthly external drive sync

### Immich Photos

**Copy 1: Live on NFS (Hades /mnt/photos)**
```
Original production data
```

**Copy 2: ZFS Snapshot (Hades)**
```
Daily 1AM snapshot
Retention: 7 days (instant restore via zfs rollback)
```

**Copy 3: Backup PC (rsync)**
```
Daily 4AM rsync to backup PC
Retention: 30 days
```

**Copy 4 (Ideal): External Drive**
```
Monthly sync (true offsite)
```

## Disaster Recovery Scenarios

| Scenario | RTO | RPO | Recovery |
|----------|-----|-----|----------|
| **Postgres lost** | 1-2h | 1 day | Restore from backup PC rsync |
| **Immich lost** | 30m | 1 day | Restore from ZFS snapshot or backup PC |
| **Vault lost** | 1-2h | 1 day | Restore from raft snapshot + backup PC |
| **Apollo dies** | 2-4h | Varies | Fail to Hades, restore VMs from snapshots |
| **Hades dies** | 2-4h | Varies | Restore from Proxmox backup + NFS from backup PC |
| **Backup PC lost** | 1 day | Varies | Restore from external drive (if synced) |

## Backup PC Power Strategy (Decision Needed)

### Option A: Always-on 24/7
- **Power:** ~50W continuous
- **Availability:** Immediate backup
- **Automation:** Simplest (cron rsync runs whenever)
- **Cost:** Higher electricity

### Option B: Wake-on-LAN (2-3x daily)
- **Power:** ~50W only during backup windows
- **Automation:** Cron triggers WoL, rsync runs, PC sleeps
- **Availability:** Delayed backup
- **Setup:** Requires WoL-enabled motherboard + cron script

### Option C: Replace with N100 NAS
- **Power:** ~5-10W always-on (low cost)
- **Availability:** Always available
- **Automation:** Simplest (always-on NFS + rsync)
- **Cost:** ~$300-500 upfront investment
- **Benefit:** Dedicated hardware, professional NAS OS

**Recommendation:** Option A or B (decide on power budget/convenience trade-off)

## Encryption Strategy

### Databases
- **Current:** None
- **Planned:** pgbackrest with encryption or native Vault backup encryption
- **Benefit:** Protects backups at rest

### Transfer
- **SSH/rsync:** Encrypted in transit
- **No TLS setup needed:** SSH handles it

### Storage
- **ZFS encryption:** TODO (enable on Hades?)
- **External drive:** VeraCrypt or BitLocker
- **Benefit:** Protects offsite backups

## Backup Retention Policies

| Data | Local | Backup PC | External |
|------|-------|-----------|----------|
| Postgres | 7 days | 30 days | Monthly rotation |
| Vault | 7 days | 30 days | Monthly rotation |
| Immich | 7 days (ZFS) | 30 days | Monthly rotation |

## Testing Restore Procedures

**Critical:** Before relying on backups, test restore at least once per quarter.

### Test Checklist
- [ ] Restore Postgres from local backup
- [ ] Restore Postgres from backup PC backup
- [ ] Restore Vault from local snapshot
- [ ] Restore Vault from backup PC backup
- [ ] Restore Immich photos from ZFS snapshot
- [ ] Restore Immich photos from backup PC backup
- [ ] Document time required for each restore

## Backup Monitoring

- **Alert if:** Backup PC unreachable for 24h
- **Alert if:** Backup size anomaly (0 bytes, etc.)
- **Manual check:** Monthly backup verification
- **Log rotation:** Backup logs → 90-day retention

## Cost Analysis

| Option | Hardware | Power | Setup | Ongoing |
|--------|----------|-------|-------|---------|
| A (24/7) | Existing PC | $50/mo | 0h | Low |
| B (WoL) | Existing PC | $20/mo | 2h | Medium |
| C (N100) | $400 | $5/mo | 4h | Low |

**Budget decision:** Awaiting your input
