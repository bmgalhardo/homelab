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

### Fix Apollo DNS Record ⛔
- **Task:** `apollo.bgalhardo.internal` resolves to `192.168.1.200` via
  Hermes dnsmasq — wrong. Real, reachable IP is `192.168.1.197`
- **Why:** Found 2026-08-21 while trying to reach the Proxmox API by
  hostname; `.200` doesn't respond to ping or port 8006 at all
- **Effort:** Trivial (one dnsmasq record on Hermes)
- **Status:** Not started

### Corosync on Pi Burden ⛔
- **Task:** Migrate corosync-qdevice to Apollo LXC
- **Why:** Hermes should run lightweight Alpine, not heavy Debian
- **Effort:** 6-8 hours
- **Blocker:** Apollo specs verification (do we have enough RAM?)
- **Status:** Ready (pending specs check)
- **Steps:**
  1. Verify Apollo has sufficient resources
  2. Create corosync-qdevice LXC on Apollo (Alpine, 512MB)
  3. Reconfigure Proxmox cluster to use Apollo as qdevice
  4. Flash Hermes to Alpine Linux
  5. Restore dnsmasq + HAProxy config to Alpine Hermes
  6. Test cluster quorum
  7. Test HAProxy failover
- **Benefit:** Hermes boots in 30s; lighter resource usage; freedom to use Alpine

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

### Proxmox Read-Only API Access Still Broken ⚠️
- **Task:** `claude@pve!claude-readonly` token (PVEAuditor role, path `/`,
  confirmed present in Datacenter → Permissions) still returns
  `403 Sys.Audit` on everything except `/version` and `/nodes` listing
- **Why:** Wanted for filling in the hardware-spec TODOs below without
  manual copy-paste — nothing critical depends on it
- **Status:** Unresolved. Waited 20 min for possible `pveproxy` cache —
  no change. Next untried step: restart `pveproxy` on Apollo
- **Blocker:** None, just needs someone to restart the service or debug
  further

### Fill in Specifications

**Apollo (Beelink S12 Pro):**
- [ ] CPU model & core count
- [ ] RAM capacity
- [ ] Storage capacity
- [ ] Power/thermal specs
- **Why:** Verify sufficient for corosync LXC + K8s + VMs overhead

**Hades (Ryzen 5 PC):**
- [ ] CPU model & core count
- [ ] RAM capacity
- [ ] Storage: XFS partition size, ZFS pool name
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

- **P0 Blockers:** 3 (renewal-automation pattern, Apollo DNS record,
  corosync migration)
- **P1 High Priority:** 2 (backup 3-2-1, backup PC decision)
- **P2 Medium:** Multiple specs to fill, deployments to plan
- **P3 Nice-to-Have:** 4 future enhancements
- **Decision Rate:** 7 made, 5 pending

**Next Step:** Build Vault raft snapshot automation + offsite shipping
for both Vault and Postgres backups (a manual Vault snapshot was taken
2026-08-21, not yet automated).
