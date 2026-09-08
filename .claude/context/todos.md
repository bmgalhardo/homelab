# Todos: Priorities & Blockers

## P0: Critical (Blocking)

### Nothing in This Stack Auto-Renews ⛔
- **Task:** Recognize this as a systemic pattern, not one-off bugs, and
  prioritize renewal automation accordingly
- **Why:** As of 2026-08-21, several independent credentials/certs were
  found expired or misconfigured across totally different systems, all
  with the same root cause (manual issuance, no automation, no expiry
  alerts):
  1. All 9 `pki_infra` leaf certs (the original P0 — fixed 2026-08-20/21)
  2. Omni's own service-account JWT — issued 2025-07-06, expired
     2026-07-06, unnoticed for 46 days (found 2026-08-21)
  3. Authentik's self-signed SAML signing cert — expired 2026-05-25,
     broke SSO into Omni (found + fixed 2026-08-21, but required
     restarting Omni afterward since it caches IdP metadata — will
     recur ~2027-08 unless automated)
- **Status:** Not started — no automation exists for any of these yet
- **Benefit:** Prevents the next 3-month silent outage, whatever it turns
  out to be

### Fix Apollo DNS Record  (downgraded 2026-09-08 — not a P0)
- **Task:** Add explicit dnsmasq records for `apollo` / `hades` / `hermes`
  (`.197` / `.198` / `.199`). They currently have none, so they fall
  through the `address=/.bgalhardo.internal/192.168.1.200` wildcard to the
  k8s ingress.
- **Why:** Found 2026-08-21 reaching the Proxmox API by hostname. Refined
  2026-09-08: it's a *missing* record + a catch-all wildcard, not a bad
  record. **Low severity** — nothing resolves these names today (Proxmox
  API is hit by IP; the HA name is `proxmox.bgalhardo.internal` → .199).
  Worth doing so a mistyped hostname fails clean instead of hitting the
  wrong box.
- **Effort:** Trivial (three `address=/…/` lines on Hermes).
- **Status:** Not started.

### Corosync on Pi Burden ✅ (done 2026-09-07)
- **Task:** Migrate corosync-qdevice to Apollo LXC
- **Status:** Done. Pi (Hermes) re-flashed to Alpine, running dnsmasq +
  HAProxy. New `qdevice` LXC on Apollo (192.168.1.89, Debian) runs
  corosync-qnetd; `pvecm qdevice setup 192.168.1.89` completed. See
  services.md for setup gotchas and the Apollo co-location caveat.
- **Remaining:** confirm `pct set <ctid> --onboot 1` on the LXC; verify
  `pvecm status` shows `Total votes: 3`; test HAProxy failover on Alpine.

## P1: High (This Month)

### 3-2-1 Backup Strategy
- **Task:** Implement 3-copy backup resilience
- **Why:** Currently no automated *offsite* backup; manual process fragile
- **Effort:** 12 hours (4 phases)
- **Blocker:** Backup PC specs, power strategy decision
- **Status:** Planning — Phase 1 partially confirmed 2026-08-21:
  - **Postgres:** `infra/olympus/services/postgres/backup.sh` runs inside the
    `pg_backup` sidecar (in the compose file, confirmed live), does
    daily/weekly/monthly `pg_dumpall` with real retention (7d/28d/365d)
    — but only writes to local disk on the postgres VM
    (`/backups/{daily,weekly,monthly}`). Nothing ships these off-box.
  - **Vault:** No backup mechanism exists at all — worse than Postgres.
    Vault's compose file (`infra/olympus/services/vault/`) has no backup sidecar,
    no snapshot script, nothing. This is the most critical service in
    the homelab with zero backup coverage.
- **Phases:**
  - Phase 1 (2h): Document current DB scripts, retention — postgres done,
    **add a Vault raft snapshot mechanism (`vault operator raft snapshot`)
    — doesn't exist yet, not just undocumented**
  - Phase 2 (4h): Setup rsync/shipping of `backup.sh` output (postgres)
    and new Vault snapshots to backup PC
  - Phase 3 (3h): Enable ZFS snapshots, test restore
  - Phase 4 (3h): Setup monthly external drive sync
- **Benefit:** Resilience against data loss; meets 3-2-1 standard

### Argus: Centralized Logging + Daily Report Agent
- **Task:** Loki + Prometheus + Grafana on the `athena` node (Pi4, off the
  cluster), then an agent that reads 24h of logs + deterministic fact
  probes at 04:00, reports to Telegram, writes eventful things to
  `logbook/YYYY-MM.md`
- **Why:** Every silent outage in this file (expired certs, expired Omni JWT,
  missing `token_reviewer_jwt`) went unnoticed for months. Nothing watches.
- **Status (2026-09-08):** `athena` node online (`.196`), stack written
  (`infra/athena/`), not yet deployed. Vault Agent sidecar built here as
  the reusable pattern. Phase 1 = deploy + verify.
- **Full design, decisions and phase checklist:** `.claude/context/argus.md`
- **Benefit:** Directly addresses the "nothing in this stack auto-renews"
  P0 above — it can't fix renewals, but it stops them failing silently

### Full VM Provisioning: Terraform + Bundled Compose ⚠️
- **Task:** Two parts.
  1. **Fix or formally retire the Olympus Terraform.** State has drifted
     ~9 months out of sync with the live cluster and cannot be safely
     `apply`d as-is.
  2. **Standardize the VM contract:** Terraform provisions the VM, then a
     single `docker-compose.yml` per VM bundles *everything that VM needs*
     — the service itself + Vault Agent (secret injection) + backup script
     + log shipping (Alloy, or syslog forward for Argus). Create the VM,
     drop in the compose file, done. The 200-series `postgres` VM (with
     its `pg_backup` sidecar) is the closest existing pattern — extend it
     to cover secrets and logging too.
- **Why (drift evidence, gathered 2026-09-08):**
  - No `terraform` binary on the workstation; no remote backend — state is
    one gitignored file, last written **2025-12-12** (hal9000 state:
    2025-07-06)
  - `infra/terraform.tfvars` still uses `root@pam!terraform` → 401/revoked
    (network.md). Needs a **user-scoped** write token — token-scoped ACLs
    are non-functional on this PVE build (network.md)
  - `vault` / `authentik` / `omni` were rebuilt by hand at vmid
    **107 / 103 / 100**; state still says 204 / 205 / 206
  - `netboot-webserver` (vmid 203) retired but still in state
  - `tftp-server` (vmid 202) removed 2026-09-08 from tfvars + repo; still
    in state (and the VM itself, until deleted)
  - hal9000 `worker-1` is **8192 MB** live, 4096 in code + state
- **Options:**
  - A: **Reconcile** — install TF, mint a user-scoped write token, update
    `terraform.tfvars`, `state rm` + re-import the 4 drifted resources,
    wrestle `plan` to zero-diff on the 3 hand-built VMs, then it's usable
  - B: **Retire** — accept deployment.md's "static per VM" reality, delete
    `infra/olympus/terraform/`, document the Olympus VMs as hand-created,
    keep only `infra/hal9000/terraform/`
- **Connects to:** every future Olympus VM; and the hal9000 rebuild (P2) —
  do the `worker-1` resize there. (Argus ended up on a bare Pi4, not a VM,
  so it no longer depends on this.)
- **Status:** Not started. Documented 2026-09-08. User chose option A
  (reconcile) initially; revisit given the full scope above.

### Backup PC Power Strategy Decision ⚠️
- **Task:** Choose backup PC operation mode
- **Options:**
  - A: Always-on 24/7 (~50W, simplest)
  - B: Wake-on-LAN 2-3x daily (~20W, medium complexity)
  - C: Replace with N100 NAS (~5W, $400 investment)
- **Trade-off:** Power cost vs automation vs capital investment
- **Effort:** 0 (decision only)
- **Status:** Pending decision
- **Impact:** Drives backup automation approach

## P2: Medium (Next Month)

### Trivial cipassword on VM Cloud-Init
- **Task:** `infra/olympus/terraform/main.tf` sets `cipassword = "root"`
  via cloud-init on every VM — password auth enabled with a trivial
  password, on top of SSH keys. Should be removed or set to something
  Vault-managed.
- **Status:** Not started. Private LAN only, so not urgent.

### K8s (hal9000) Rebuild Prep
- **Task:** Grant Claude access to `talosctl` and `omnictl`
- **Why:** hal9000 (Talos k8s cluster) is being rebuilt from scratch later;
  `infra/hal9000/` is intentionally untouched for now (2026-08-21 decision)
- **Status:** Not started — user to set up access when ready
- **Note:** User is installing `kubectl` locally in the meantime to check
  current cluster status by hand
- **Rename at rebuild (decided 2026-09-08):** `hal9000` → **`elysium`**
  (the blessed realm — fits the app layer above the Olympus VM substrate;
  drops the odd 2001 reference). Don't rename the live cluster — do it as
  part of the from-scratch rebuild: `infra/hal9000/` → `infra/elysium/`,
  Omni/Talos cluster name, kubeconfigs, `kubernetes/` refs, docs. Also
  consider deity names for the Talos nodes instead of `control-1`/`worker-1`.

### ~~Proxmox Read-Only API Access Still Broken~~ ✅ Fixed 2026-08-25
- Upgrading PVE (9.2.3 → 9.2.11) did **not** fix token-scoped ACL
  resolution — confirmed still broken on the newer version.
- Fix: switched `claude@pve!claude-readonly` to `--privsep 0` and moved
  the `PVEAuditor` grant from the token entity to the plain user
  `claude@pve` (matching the already-working `automation@pve` pattern).
  Token now resolves full audit permissions and the API returns real
  data. See network.md's Proxmox API Access section for the root-cause
  writeup — token-scoped (`type: token`, privsep=1) ACL entries appear
  to just never be honored by this PVE build, independent of version.

### Fill in Specifications

**Apollo (Beelink S12 Pro)** — confirmed 2026-08-25 via Proxmox API
(`claude@pve!claude-readonly`, now working — see network.md):
- [x] CPU — **Intel N100**, 1 socket, 4 cores/4 threads
- [x] RAM — **16GB** (15.4 GiB as reported: 16535810048 bytes)
- [x] Storage — 1x NVMe, **Crucial CT1000P3PSSD8, 1TB** (931 GiB usable),
  SMART health PASSED, **69% life remaining (31% worn)** — not urgent,
  but worth a periodic glance since Apollo is the always-on node
- [ ] Power/thermal specs — not exposed via the Proxmox API (no sensor
  data in `/nodes/apollo/status`); would need `sensors` run on-host
- **Why:** Verify sufficient for corosync LXC + K8s + VMs overhead —
  4 cores/16GB confirms this is tight, worth keeping in mind for the
  corosync-LXC migration sizing decision (P0 above)

**Hades (Ryzen 5 PC)** — confirmed 2026-08-25 via Proxmox API:
- [x] CPU — **AMD Ryzen 5 3600**, 1 socket, 6 cores/12 threads
- [x] RAM — **32GB** (31.25 GiB as reported: 33556340736 bytes)
- [x] Storage — full disk picture, confirmed 2026-08-25 via
  `/nodes/hades/disks/list` (not just `/nodes/hades/storage`, which
  only shows Proxmox-registered storage and misses unregistered
  filesystems):
  - `nvme0n1` — WD Blue SN570 1TB, boot/OS drive, 96% SSD life left
  - `sda` + `sdb` — 2x Seagate ST8000DM004 8TB (5400rpm), used by ZFS,
    mirrored into pool **`odin`** (~7.27TB usable, health ONLINE —
    this is the NAS/NFS pool)
  - `sdc` + `sdd` — 2x Seagate ST4000DM004 4TB (5400rpm), **XFS**,
    unpartitioned (no GPT), **not registered as a Proxmox storage** —
    invisible to `/nodes/hades/storage`, only shows up via the raw
    disk list. Purpose/mount point not yet confirmed — worth checking
    `/etc/fstab` on Hades directly.
  - Also present: `local` (dir, ~94GB, PVE OS/ISO/backups) and
    `local-lvm` (LVM-thin, ~795GB) as Proxmox-registered storages.
- **Why:** Resource planning, identify bottlenecks

**Backup PC (TrueNAS):**
- [ ] Hostname
- [ ] IP address (when powered on)
- [ ] Storage capacity
- [ ] TrueNAS version

**K8s Configuration:**
- [x] Kubernetes version — **v1.33.2** (confirmed 2026-08-21 via `kubectl get nodes`)
- [x] Talos version — **v1.10.5**
- [x] Node count — **2** (`talos-y43-va4` control-plane, `talos-y6i-w43`
  worker), IPs `192.168.1.56`/`.57`, both `Ready`, **410 days uptime**
- [ ] Pod CIDR (default: 10.244.0.0/16?)
- [ ] Service CIDR (default: 10.96.0.0/12?)
- **Note:** This is the *pre-rebuild* cluster — `infra/hal9000` is being
  left alone per 2026-08-21 decision; cluster will be rebuilt from
  scratch once `talosctl`/`omnictl` access is granted (see P2 above).
  These specs may be irrelevant post-rebuild.

### Service Deployments (K8s)

**Immich:**
- Design NFS mount points
- Test restore from backup
- Evaluate GPU acceleration (optional)

**Plex:**
- Design NFS mount
- Test with media library
- Monitor performance

**Home Assistant:**
- Migrate from Longhorn to NFS
- Test persistence
- Verify backup strategy

### Corosync LXC Setup
- Create LXC container for qdevice (Alpine)
- Test failover behavior
- Document resource usage
- Effort: 2 hours (after Phase 1 is complete)

## P3: Nice-to-Have (Later)

### Periodic Rotation for All Secrets
- **Task:** Rotate all secrets on a schedule — Vault unseal key, Vault
  root token, Postgres password, Authentik secrets, everything currently
  static in a VM's `.env`
- **Why:** Trivial once compose services pull secrets dynamically from
  Vault instead of a static `.env` (restart picks up a freshly-issued
  value automatically); doing it by hand today means editing `.env` on
  each VM manually, so it doesn't happen. The Vault root token
  specifically is worth rotating/revoking periodically regardless of
  the rest of this — it's the most powerful credential in Vault and
  shouldn't live indefinitely.
- **Blocker:** Depends on wiring compose services to pull secrets from
  Vault directly (dynamic secrets / templated `.env` via
  `vault agent` or similar) instead of today's static per-VM `.env`
  files — that integration doesn't exist yet.
- **Status:** Vision only
- **Benefit:** Removes the whole class of "secret sat unrotated for
  months" issues this session kept surfacing

### K8s High Availability
- **Task:** 3-node control plane (Pi4 as 3rd node)
- **Effort:** 2-3 weeks
- **Status:** Not planned yet
- **Benefit:** True HA for K8s control plane

### Agentic DNS Controller
- **Task:** Autonomous DNS based on infrastructure state
- **Effort:** TBD (design phase)
- **Status:** Vision only
- **Benefit:** Self-healing DNS failover

### Agentic Atlas Knowledge Graph
- **Task:** Queryable infrastructure dependencies
- **Effort:** TBD (design phase)
- **Status:** Vision only
- **Benefit:** Machine-understandable infrastructure

### GPU Acceleration for Immich
- **Task:** Use Hades GeForce 750 Ti for transcoding
- **Effort:** 4-6 hours (K8s GPU worker setup)
- **Status:** Future (evaluate after Immich deployment)
- **Benefit:** Faster thumbnail generation, transcoding

## Decisions Made ✅

| Decision | Rationale | Status |
|----------|-----------|--------|
| Corosync → Apollo LXC | Hermes needs Alpine, not Debian | Decided |
| Hermes OS → Alpine | Lightweight, fast boot, minimal resources | Decided |
| DNS independence | Hermes DNS survives cluster outage | Decided |
| Service placement | VMs for core (Vault/Auth), K8s for apps | Decided |
| Deployment method | Static docker-compose per VM, plain `.env` for secrets (Ansible retired 2026-08-21) | Decided |
| Pi4 future role | DNS failover candidate | Decided |
| Hades strategy | Keep as Proxmox + NAS (power-managed) | Decided |

## Decisions Pending ⚠️

| Decision | Options | Impact | Timeline |
|----------|---------|--------|----------|
| Backup PC power | Always-on vs WoL vs N100 | Backup automation | This week |
| Apollo resources | Sufficient for corosync + K8s + VMs? | P0 blocker | This week |
| Immich GPU | K8s worker vs Hades VM? | Performance | Next month |
| External backup location | Home vs friend vs safety deposit? | Offsite strategy | Next month |
| K8s HA control plane | Implement 3-node? | Resilience | Future |

## Status Summary

- **P0 Blockers:** 1 (renewal-automation pattern). Corosync migration done
  2026-09-07; Apollo DNS record downgraded 2026-09-08 (missing record +
  wildcard, low severity).
- **P1 High Priority:** 4 (backup 3-2-1, backup PC decision, Argus
  logging+agent, full VM provisioning / Terraform reconcile)
- **P2 Medium:** Multiple specs to fill, deployments to plan
- **P3 Nice-to-Have:** 4 future enhancements
- **Decision Rate:** 7 made, 5 pending

**Next Step:** Build Vault raft snapshot automation + offsite shipping
for both Vault and Postgres backups (a manual Vault snapshot was taken
2026-08-21, not yet automated).
